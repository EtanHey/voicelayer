import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { closeSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { readUpdateGate, transitionUpdateGate, type UpdateGateLease, type UpdateGateState, type UpdateGateTransition } from "./update-gate";
import { withUpdateGateLock, persistUpdateGateState } from "./update-gate-storage";
export class UpdateBusyError extends Error {
  constructor() { super("UPDATE_BUSY: update gate closed; retry when the update finishes"); }
}
const incarnation = randomUUID();
type Admission = { refs: number; release: () => void };
const context = new AsyncLocalStorage<Admission>();
/** Visibility only: no media-sync latency on the capture admission path. */
function persistVisible(path: string, destination: string, value: unknown): void {
  const staged = join(path + ".lock", "admission.json");
  const fd = openSync(staged, "wx", 0o600);
  try { writeFileSync(fd, JSON.stringify(value) + "\n"); } finally { closeSync(fd); }
  renameSync(staged, destination);
}
function diskState(path: string) {
  try {
    const stat = lstatSync(path);
    return stat.isFile() && !stat.isSymbolicLink() ? readUpdateGate(JSON.parse(readFileSync(path, "utf8"))) : { kind: "UNKNOWN" as const };
  } catch { return { kind: "UNKNOWN" as const }; }
}
function snapshot(path: string) {
  try {
    const state = diskState(path), ledger = lstatSync(path + ".admissions");
    if (state.kind === "UNKNOWN" || existsSync(path + ".voice-diag.json") || !ledger.isDirectory() || ledger.isSymbolicLink()) return null;
    return { state, active: readdirSync(path + ".admissions") };
  } catch { return null; }
}
function voiceLock<T>(body: (path: string) => T, env: NodeJS.ProcessEnv): T {
  const deadline = performance.now() + 1500;
  let delay = 1;
  for (;;) {
    try { return withUpdateGateLock(body, env); } catch (error) {
      if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED") throw error;
      if (performance.now() >= deadline) throw Error("UPDATE_GATE_LOCK_TIMEOUT");
      Bun.sleepSync(delay); delay = Math.min(delay * 2, 32);
    }
  }
}
function initializeUnderLock(path: string) {
  try { lstatSync(path); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    persistUpdateGateState(path, { version: 1, kind: "OPEN", generation: 0, released: null }, true);
  }
  const state = diskState(path);
  if (state.kind !== "UNKNOWN" && state.kind !== "OPEN") return state;
  try { lstatSync(path + ".admissions"); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    mkdirSync(path + ".admissions", { mode: 0o700 });
  }
  const ledger = lstatSync(path + ".admissions");
  if (!ledger.isDirectory() || ledger.isSymbolicLink()) throw Error("UPDATE_GATE_UNSAFE_LEDGER");
  if (state.kind === "UNKNOWN") {
    console.error("[update-gate] UNKNOWN gate evidence: preserving voice; updates REFUSED (see voice-diag marker)");
    persistVisible(path, path + ".voice-diag.json", { kind: "UNKNOWN", pid: process.pid, at: new Date().toISOString() });
  }
  return state;
}
/** Voice availability bootstrap only. Updater commands never initialize or repair evidence. */
export function initializeVoiceGate(env: NodeJS.ProcessEnv = process.env): void {
  voiceLock(path => { initializeUnderLock(path); }, env);
}
function acquire(): Admission {
  const env = { ...process.env };
  const result = voiceLock(path => {
    const state = initializeUnderLock(path);
    if (state.kind !== "OPEN" && state.kind !== "UNKNOWN") return null;
    const token = randomUUID(), file = join(path + ".admissions", token);
    const owner = { token, pid: process.pid, incarnation, generation: state.kind === "OPEN" ? state.generation : null };
    persistVisible(path, file, owner);
    return { refs: 0, release: () => releaseWhenUnlocked(() => withUpdateGateLock(() => {
      // An anomalous owner is a recoverable registration, never an orphaned host lock.
      try {
        const stat = lstatSync(file);
        if (!stat.isFile() || stat.isSymbolicLink() || readFileSync(file, "utf8") !== JSON.stringify(owner) + "\n") return false;
      } catch { return false; }
      unlinkSync(file); return true;
    }, env)) };
  }, env);
  if (!result) throw new UpdateBusyError();
  return result;
}
function releaseWhenUnlocked(work: () => boolean, delay = 10): void {
  try { if (!work()) console.error("[update-gate] registration ownership UNKNOWN; retained for recovery"); } catch (error) {
    if (error instanceof Error && error.message === "UPDATE_GATE_LOCKED") {
      setTimeout(() => releaseWhenUnlocked(work, Math.min(delay * 2, 1000)), delay); return;
    }
    console.error("[update-gate] registration retained; release requires recovery");
  }
}
function retain(admission: Admission): () => void {
  admission.refs++;
  return () => { if (--admission.refs === 0) admission.release(); };
}
/** Each child owns a reference. Async Ask continuations reuse admission after drain. */
export function withVoiceAdmission<T>(work: () => T): T {
  const inherited = context.getStore();
  const admission = inherited && inherited.refs > 0 ? inherited : acquire();
  const release = retain(admission);
  return context.run(admission, () => {
    let result: T;
    try { result = work(); } catch (error) { release(); throw error; }
    if (result && typeof (result as { then?: unknown }).then === "function") {
      return Promise.resolve(result).finally(release) as T;
    }
    release(); return result;
  });
}
/** A nonblocking return must keep ownership through player exit and durable archive writes. */
export function holdVoiceAdmission(work: Promise<unknown>): void {
  const admission = context.getStore();
  if (!admission || admission.refs === 0) throw new UpdateBusyError();
  const release = retain(admission);
  void work.then(release).catch(() => console.error("[update-gate] unconfirmed completion; admission retained for recovery"));
}
/** Queued reads retain THEIR admission, rather than borrowing the previous read's async context. */
export function captureVoiceAdmission() {
  const admission = context.getStore();
  if (!admission || admission.refs === 0) throw new UpdateBusyError();
  const release = retain(admission);
  let released = false;
  return { run: <T>(work: () => T): T => context.run(admission, work), release: () => {
    if (!released) { released = true; release(); }
  } };
}
export function withFreshVoiceAdmission<T>(work: () => T): T {
  return context.exit(() => withVoiceAdmission(work));
}
export type ParticipantProof = (state: UpdateGateState) => boolean;
/** Trusted updater API, never a raw-client assertion. Proof executes synchronously under G1's lock. */
export function updateVoiceGate(command: unknown, verify?: ParticipantProof, env: NodeJS.ProcessEnv = process.env): UpdateGateTransition {
  return withUpdateGateLock(path => {
    const current = snapshot(path);
    if (!current) return { kind: "REFUSED", reason: "UNKNOWN" };
    const result = transitionUpdateGate(current.state, command);
    if (result.kind === "APPLIED" && (result.state.kind === "PREPARED" || result.state.kind === "COMMITTED") &&
      (current.active.length !== 0 || verify?.(current.state) !== true)) return { kind: "REFUSED", reason: "UNKNOWN" };
    if (result.kind === "APPLIED") persistUpdateGateState(path, result.state);
    return result;
  }, env);
}
/** G3/updater supplies live identity, handoff, archive-durability and competing-owner evidence. */
export function acknowledgeVoiceDrain(lease: UpdateGateLease, verify: ParticipantProof) {
  return withUpdateGateLock(path => {
    const current = snapshot(path);
    if (!current || current.state.kind === "OPEN" || current.active.length ||
      transitionUpdateGate(current.state, { kind: "REQUEST", lease }).kind !== "UNCHANGED" || verify(current.state) !== true) return null;
    return { lease, activeOperations: 0 as const, openArchives: 0 as const };
  });
}
