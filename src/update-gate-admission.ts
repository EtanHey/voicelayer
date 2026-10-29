import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { closeSync, fsyncSync, lstatSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { dlopen } from "bun:ffi";
import { readUpdateGate, transitionUpdateGate, type UpdateGateCommand, type UpdateGateLease, type UpdateGateState, type UpdateGateTransition } from "./update-gate";
import { withUpdateGateLock } from "./update-gate-storage";
export class UpdateBusyError extends Error {
  constructor() { super("UPDATE_BUSY: update gate closed or UNKNOWN; retry after verified recovery"); }
}
const media = process.platform === "darwin" ? dlopen("/usr/lib/libSystem.B.dylib", {
  fcntl: { args: ["i32", "i32", "i32"], returns: "i32" },
}) : null;
const incarnation = randomUUID();
type Admission = { refs: number; release: () => void };
const context = new AsyncLocalStorage<Admission>();
function syncDirectory(path: string): void {
  const fd = openSync(path, "r");
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function persist(path: string, destination: string, value: unknown): void {
  const staged = join(path + ".lock", "state.json");
  const fd = openSync(staged, "wx", 0o600);
  try {
    writeFileSync(fd, JSON.stringify(value) + "\n"); fsyncSync(fd);
    renameSync(staged, destination); syncDirectory(dirname(destination));
    if (media && media.symbols.fcntl(fd, 51, 0) !== 0) throw Error("UPDATE_GATE_MEDIA_SYNC_FAILED");
  } finally { closeSync(fd); }
}
function snapshot(path: string) {
  try {
    const file = lstatSync(path), ledger = lstatSync(path + ".admissions");
    if (!file.isFile() || file.isSymbolicLink() || !ledger.isDirectory() || ledger.isSymbolicLink()) return null;
    const state = readUpdateGate(JSON.parse(readFileSync(path, "utf8")));
    return state.kind === "UNKNOWN" ? null : { state, active: readdirSync(path + ".admissions") };
  } catch { return null; }
}
function acquire(): Admission {
  const env = { ...process.env };
  try {
    const result = withUpdateGateLock(path => {
      const current = snapshot(path);
      if (!current || current.state.kind !== "OPEN") return null;
      const token = randomUUID(), file = join(path + ".admissions", token);
      const owner = { token, pid: process.pid, incarnation, generation: current.state.generation };
      persist(path, file, owner);
      return { refs: 0, release: () => releaseWhenUnlocked(() => withUpdateGateLock(() => {
        const stat = lstatSync(file);
        if (!stat.isFile() || stat.isSymbolicLink() || readFileSync(file, "utf8") !== JSON.stringify(owner) + "\n") {
          throw Error("UPDATE_GATE_ADMISSION_OWNERSHIP");
        }
        unlinkSync(file); syncDirectory(dirname(file));
      }, env)) };
    }, env);
    if (!result) throw new UpdateBusyError();
    return result;
  } catch { throw new UpdateBusyError(); }
}
// Retry only this owner's release. A locked/orphaned gate is never removed or treated as idle.
function releaseWhenUnlocked(work: () => void, attempts = 0): void {
  try { work(); } catch (error) {
    if (error instanceof Error && error.message === "UPDATE_GATE_LOCKED" && attempts < 100) {
      setTimeout(() => releaseWhenUnlocked(work, attempts + 1), 10); return;
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
export function updateVoiceGate(command: UpdateGateCommand, verify?: ParticipantProof): UpdateGateTransition {
  return withUpdateGateLock(path => {
    const current = snapshot(path);
    if (!current) return { kind: "REFUSED", reason: "UNKNOWN" };
    const result = transitionUpdateGate(current.state, command);
    if (result.kind === "APPLIED" && (command.kind === "PREPARE" || command.kind === "COMMIT") &&
      (current.active.length !== 0 || verify?.(current.state) !== true)) return { kind: "REFUSED", reason: "UNKNOWN" };
    if (result.kind === "APPLIED") persist(path, path, result.state);
    return result;
  });
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
