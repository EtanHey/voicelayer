import { AsyncLocalStorage } from "node:async_hooks";
import { randomUUID } from "node:crypto";
import { closeSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { updateGateFilePath } from "./paths";
import { readUpdateGate, transitionUpdateGate, type UpdateGateLease, type UpdateGateState, type UpdateGateTransition } from "./update-gate";
import { withUpdateGateLock, persistUpdateGateState, resolveUpdateGatePath } from "./update-gate-storage";
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
  try {
    writeFileSync(fd, JSON.stringify(value) + "\n");
    renameSync(staged, destination);
  } finally {
    try { closeSync(fd); } finally {
      try { unlinkSync(staged); } catch { /* renamed or retained for recovery */ }
    }
  }
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
    if (state.kind === "UNKNOWN" || degraded.has(path) || hasDiagnostic(path) || !ledger.isDirectory() || ledger.isSymbolicLink()) return null;
    return { state, active: readdirSync(path + ".admissions") };
  } catch { return null; }
}
const degraded = new Set<string>();
const lastDiagnostic = new Map<string, number>();
function hasDiagnostic(path: string): boolean {
  try { lstatSync(path + ".voice-diag.json"); return true; }
  catch (error) { return (error as NodeJS.ErrnoException).code !== "ENOENT"; }
}
function logDiagnostic(path: string): void {
  const now = Date.now();
  if (!lastDiagnostic.has(path) || now - lastDiagnostic.get(path)! >= 60_000) {
    lastDiagnostic.set(path, now);
    try { console.error("[update-gate] UNKNOWN gate fault; updates REFUSED; voice fail-open policy active; recovery required"); } catch { /* diagnostics never throw */ }
  }
}
/** First-seen evidence is exclusive and sticky until verified recovery. Never print raw errors. */
function diagnose(path: string): boolean {
  degraded.add(path);
  logDiagnostic(path);
  try {
    writeFileSync(path + ".voice-diag.json", JSON.stringify({ kind: "UNKNOWN", pid: process.pid, at: new Date().toISOString() }) + "\n", { flag: "wx", mode: 0o600 });
  } catch {
    // Even a disk-full write can leave an exclusive empty file. A directory is
    // also refusal evidence if file creation itself failed. Never replace bytes.
    try { mkdirSync(path + ".voice-diag.json", { mode: 0o700 }); } catch { /* original evidence wins */ }
  }
  try { const marker = lstatSync(path + ".voice-diag.json"); return marker.isFile() || marker.isDirectory(); }
  catch { return false; }
}
/** Catch INSIDE the primitive: a body fault must never orphan G1's lock. */
function safeGateLock<T>(body: (path: string) => T, fallback: T, env: NodeJS.ProcessEnv, retryContention = false, diagnoseContention = true): T {
  let path: string | undefined;
  try {
    path = resolveUpdateGatePath(env);
    return withUpdateGateLock(p => {
      try { return body(p); } catch {
        if (!diagnose(p)) throw Error("UPDATE_GATE_FAULT_UNSAVED"); // Retain our lock as fault evidence.
        return fallback;
      }
    }, env);
  } catch (error) {
    if (error instanceof Error && error.message === "UPDATE_GATE_LOCKED") {
      if (retryContention) throw error;
      if (!diagnoseContention) return fallback; // A live holder is not a fault.
    }
    if (path) diagnose(path);
    else {
      // Remember the logical path without writing through a failed isolation
      // check. A later successful check must not silently authorize updates.
      let key = "unresolved";
      try { key = resolve(updateGateFilePath(env)); degraded.add(key); } catch { /* no usable path */ }
      logDiagnostic(key);
    }
    return fallback;
  }
}
const unregistered = (): Admission => ({ refs: 0, release() {} });
function initializeUnderLock(path: string) {
  if (degraded.has(path) || hasDiagnostic(path)) {
    diagnose(path); return { kind: "UNKNOWN" as const };
  }
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
    diagnose(path);
  }
  return state;
}
/** Voice availability bootstrap only. Updater commands never initialize or repair evidence. */
export function initializeVoiceGate(env: NodeJS.ProcessEnv = process.env): Promise<void> {
  const attempt = () => safeGateLock(path => { initializeUnderLock(path); }, undefined, env, true);
  try { attempt(); return Promise.resolve(); }
  catch { return retryGate(attempt, () => safeGateLock(path => { initializeUnderLock(path); }, undefined, env), 1500); }
}
function acquire(retryContention = false): Admission {
  const env = { ...process.env };
  // This MUST precede lock acquisition: known faults never delay another capture.
  try {
    const path = resolveUpdateGatePath(env);
    if (degraded.has(path) || hasDiagnostic(path)) { diagnose(path); return unregistered(); }
  } catch {
    return safeGateLock(() => { throw Error("UPDATE_GATE_PATH_FAULT"); }, unregistered(), env);
  }
  const body = (path: string): Admission | null => {
    const state = initializeUnderLock(path);
    if (state.kind === "UNKNOWN") return unregistered();
    if (state.kind !== "OPEN") return null;
    const token = randomUUID(), file = join(path + ".admissions", token);
    const owner = { token, pid: process.pid, incarnation, generation: state.generation };
    persistVisible(path, file, owner);
    return { refs: 0, release: () => releaseWhenUnlocked(() => withUpdateGateLock(() => {
      // An anomalous owner is a recoverable registration, never an orphaned host lock.
      try {
        const stat = lstatSync(file);
        if (!stat.isFile() || stat.isSymbolicLink() || readFileSync(file, "utf8") !== JSON.stringify(owner) + "\n") return false;
        unlinkSync(file); return true;
      } catch { diagnose(path); return false; }
    }, env)) };
  };
  const deadline = performance.now() + 2;
  let result: Admission | null;
  for (;;) {
    try { result = safeGateLock(body, unregistered(), env, true); break; }
    catch (error) {
      if (retryContention) throw error;
      if (performance.now() < deadline) continue; // <=2ms spin, never sleep on the event loop.
      result = safeGateLock(body, unregistered(), env); break;
    }
  }
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
function runAdmitted<T>(admission: Admission, work: () => T): T {
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
/** Synchronous media boundaries cannot wait: faults admit unregistered immediately. */
export function withVoiceAdmission<T>(work: () => T): T {
  const inherited = context.getStore();
  return runAdmitted(inherited && inherited.refs > 0 ? inherited : acquire(), work);
}
export type VoiceAdmissionOptions = { maxWaitMs?: number };
type PendingAdmission = { cancelled: boolean };
const pendingAdmissions = new Set<PendingAdmission>();
export class VoiceAdmissionCancelledError extends Error {
  constructor() { super("Voice admission cancelled before start"); }
}
/** Global Stop/Cancel also invalidate work that has not reached its media body yet. */
export function cancelPendingVoiceAdmissions(): boolean {
  for (const pending of pendingAdmissions) pending.cancelled = true;
  return pendingAdmissions.size > 0;
}
function checkPending(pending?: PendingAdmission): void {
  if (pending?.cancelled) throw new VoiceAdmissionCancelledError();
}
async function retryGate<T>(attempt: () => T, fallback: () => T, maxWaitMs: number, pending?: PendingAdmission): Promise<T> {
  const deadline = performance.now() + maxWaitMs;
  let delay = 1;
  for (;;) {
    checkPending(pending);
    const remaining = deadline - performance.now();
    if (remaining <= 0) return fallback();
    await Bun.sleep(Math.min(delay, remaining));
    checkPending(pending);
    try { return attempt(); } catch (error) {
      if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED") throw error;
      delay = Math.min(delay * 2, 32);
    }
  }
}
/** Healthy ACKs remain synchronous; a cancelled deferred body never starts or retries. */
export function withDeferredVoiceAdmission<T>(work: () => T, options: VoiceAdmissionOptions = {}): T | Promise<Awaited<T>> {
  const inherited = context.getStore();
  let admission: Admission;
  try { admission = inherited && inherited.refs > 0 ? inherited : acquire(true); }
  catch (error) {
    if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED") throw error;
    const pending = { cancelled: false }; pendingAdmissions.add(pending);
    return retryGate(() => acquire(true), () => acquire(), options.maxWaitMs ?? 1500, pending).then(value => {
      pendingAdmissions.delete(pending);
      if (pending.cancelled) { value.release(); throw new VoiceAdmissionCancelledError(); }
      return runAdmitted(value, work);
    }).finally(() => pendingAdmissions.delete(pending)) as Promise<Awaited<T>>;
  }
  return runAdmitted(admission, work);
}
export function withAsyncVoiceAdmission<T>(work: () => T, options?: VoiceAdmissionOptions): Promise<Awaited<T>> {
  try { return Promise.resolve(withDeferredVoiceAdmission(work, options)) as Promise<Awaited<T>>; }
  catch (error) { return Promise.reject(error); }
}
/** All capture starts have a <=20ms contention budget, before any microphone opens. */
export function withCaptureVoiceAdmission<T>(work: () => T): Promise<Awaited<T>> {
  return withAsyncVoiceAdmission(work, { maxWaitMs: 20 });
}
export function withFreshAsyncVoiceAdmission<T>(work: () => T, options?: VoiceAdmissionOptions): Promise<Awaited<T>> {
  return context.exit(() => withAsyncVoiceAdmission(work, options));
}
export function withFreshDeferredVoiceAdmission<T>(work: () => T, options?: VoiceAdmissionOptions): T | Promise<Awaited<T>> {
  return context.exit(() => withDeferredVoiceAdmission(work, options));
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
  return safeGateLock<UpdateGateTransition>(path => {
    const current = snapshot(path);
    if (!current) return { kind: "REFUSED", reason: "UNKNOWN" };
    const result = transitionUpdateGate(current.state, command);
    if (result.kind === "APPLIED" && (result.state.kind === "PREPARED" || result.state.kind === "COMMITTED") &&
      (current.active.length !== 0 || verify?.(current.state) !== true)) return { kind: "REFUSED", reason: "UNKNOWN" };
    if (result.kind === "APPLIED") persistUpdateGateState(path, result.state);
    return result;
  }, { kind: "REFUSED", reason: "UNKNOWN" }, env, false, false);
}
/** G3/updater supplies live identity, handoff, archive-durability and competing-owner evidence. */
export function acknowledgeVoiceDrain(lease: UpdateGateLease, verify: ParticipantProof) {
  return safeGateLock(path => {
    const current = snapshot(path);
    if (!current || current.state.kind === "OPEN" || current.active.length ||
      transitionUpdateGate(current.state, { kind: "REQUEST", lease }).kind !== "UNCHANGED" || verify(current.state) !== true) return null;
    return { lease, activeOperations: 0 as const, openArchives: 0 as const };
  }, null, process.env, false, false);
}
