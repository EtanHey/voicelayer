import { closeSync, fsyncSync, lstatSync, mkdirSync, openSync,
  readFileSync, renameSync, rmdirSync, writeFileSync, linkSync, unlinkSync } from "fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "path";
import { dlopen } from "bun:ffi";
import { z } from "zod";
import { updateGateFilePath } from "./paths";
import { updateVoiceGate } from "./update-gate-admission";
import { readUpdateGate, updateGateLeaseSchema, type UpdateGateState, type UpdateGateTransition } from "./update-gate";

// Darwin's fsync alone need not flush a drive's write cache. No fallback on error.
const mediaSync = process.platform === "darwin" ? dlopen("/usr/lib/libSystem.B.dylib", {
  fcntl: { args: ["i32", "i32", "i32"], returns: "i32" },
}) : null;

// Capture the preload boundary so a test cannot opt itself back into live paths.
const testRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
const testMode = !!testRoot || process.env.NODE_ENV === "test";
export function resolveUpdateGatePath(env: NodeJS.ProcessEnv): string {
  const path = resolve(updateGateFilePath(env));
  if (testMode) {
    if (!testRoot) throw new Error("update gate requires isolated test root");
    const root = resolve(testRoot);
    const tail = relative(root, path);
    if (!tail || tail === ".." || tail.startsWith(`..${sep}`) || isAbsolute(tail)) {
      throw new Error("update gate escaped isolated test root");
    }
    let component = root;
    for (const part of ["", ...tail.split(sep)]) {
      component = join(component, part);
      try {
        if (lstatSync(component).isSymbolicLink()) throw new Error("update gate test symlink refused");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
  }
  return path;
}

function readState(path: string): ReturnType<typeof readUpdateGate> {
  try {
    const stat = lstatSync(path);
    if (!stat.isFile() || stat.isSymbolicLink()) return { kind: "UNKNOWN" };
    return readUpdateGate(JSON.parse(readFileSync(path, "utf8")));
  } catch { return { kind: "UNKNOWN" }; }
}

/** Observation only. Admissions must recheck under withUpdateGateLock. */
export function readUpdateGateFile(env: NodeJS.ProcessEnv = process.env): ReturnType<typeof readUpdateGate> {
  const path = resolveUpdateGatePath(env);
  try { lstatSync(`${path}.voice-diag.json`); return { kind: "UNKNOWN" }; }
  catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") return { kind: "UNKNOWN" }; }
  try { lstatSync(`${path}.lock`); return { kind: "UNKNOWN" }; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return { kind: "UNKNOWN" };
  }
  return readState(path);
}

/**
 * POSIX mkdir, without recursive=true, is the sole acquisition operation.
 * Swift uses Darwin.mkdir on exactly the same path. Never reap a stale lock.
 * Callbacks MUST be synchronous; any exception retains the lock for recovery.
 */
export function withUpdateGateLock<T>(body: (path: string) => T, env: NodeJS.ProcessEnv = process.env): T {
  const path = resolveUpdateGatePath(env);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const lock = `${path}.lock`;
  try { mkdirSync(lock, { mode: 0o700 }); }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error("UPDATE_GATE_LOCKED");
    throw error;
  }
  // No finally cleanup: errors (including uncertain persistence) fail closed.
  const result = body(path);
  if (result && typeof (result as { then?: unknown }).then === "function") {
    throw new Error("UPDATE_GATE_ASYNC_CALLBACK");
  }
  rmdirSync(lock); // Only remove the empty directory this invocation created.
  return result;
}

function persistGateRecord(path: string, destination: string, name: string, value: unknown, exclusive = false): void {
  const staged = join(`${path}.lock`, name);
  const fd = openSync(staged, "wx", 0o600);
  try {
    writeFileSync(fd, JSON.stringify(value) + "\n");
    fsyncSync(fd);
    if (exclusive) { linkSync(staged, destination); unlinkSync(staged); }
    else renameSync(staged, destination); // Same filesystem: readers see the old or new record.
    const directory = openSync(dirname(path), "r");
    try { fsyncSync(directory); }
    finally { closeSync(directory); }
    if (mediaSync && mediaSync.symbols.fcntl(fd, 51 /* F_FULLFSYNC */, 0) !== 0) {
      throw new Error("UPDATE_GATE_MEDIA_SYNC_FAILED");
    }
  } finally {
    try { closeSync(fd); } finally {
      try { unlinkSync(staged); } catch { /* published or retained for recovery */ }
    }
  }
}

const controllerSchema = z.strictObject({ version: z.literal(1),
  lease: updateGateLeaseSchema.pick({ generation: true, operationId: true }),
  pid: z.number().int().positive().safe(), identity: z.string().min(1) });
type Controller = z.infer<typeof controllerSchema>;
const sameControllerLease = (a: Controller["lease"], b: Controller["lease"]) =>
  a.generation === b.generation && a.operationId === b.operationId;
export function readInstallerController(path: string): Controller | null {
  try {
    const stat = lstatSync(path + ".controller");
    if (!stat.isFile() || stat.isSymbolicLink()) return null;
    return controllerSchema.parse(JSON.parse(readFileSync(path + ".controller", "utf8")));
  } catch { return null; }
}
/** Installer-only proof callback calls this under COMMIT's existing G1 lock. */
export function persistInstallerController(path: string, value: Controller): boolean {
  const controller = controllerSchema.parse(value), file = path + ".controller";
  try {
    lstatSync(file);
    const previous = readInstallerController(path);
    if (!previous || !sameControllerLease(previous.lease, controller.lease) ||
      previous.pid !== controller.pid || previous.identity !== controller.identity)
      return false;
  } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") return false; }
  persistGateRecord(path, file, "controller.json", controller);
  return true;
}
export function persistUpdateGateState(path: string, state: UpdateGateState, exclusive = false): void {
  if (state.kind === "OPEN" && state.released) {
    const controller = readInstallerController(path);
    if (controller && sameControllerLease(controller.lease, state.released)) {
      unlinkSync(path + ".controller");
      const directory = openSync(dirname(path), "r");
      try { fsyncSync(directory); } finally { closeSync(directory); }
    }
  }
  persistGateRecord(path, path, "state.json", state, exclusive);
}

/** Compatibility entrypoint: all commands now use the admission-aware commit path. */
export function applyUpdateGateCommand(command: unknown, env: NodeJS.ProcessEnv = process.env,
  verifyCommit?: (state: UpdateGateState) => boolean): UpdateGateTransition {
  return updateVoiceGate(command, verifyCommit && (state => {
    try { return verifyCommit(state) === true; } catch { return false; }
  }), env);
}
