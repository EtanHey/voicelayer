import { closeSync, fsyncSync, lstatSync, mkdirSync, openSync,
  readFileSync, renameSync, rmdirSync, writeFileSync, linkSync, unlinkSync } from "fs";
import { dirname, isAbsolute, join, relative, resolve, sep } from "path";
import { dlopen } from "bun:ffi";
import { updateGateFilePath } from "./paths";
import { updateVoiceGate } from "./update-gate-admission";
import { readUpdateGate, type UpdateGateState, type UpdateGateTransition } from "./update-gate";

// Darwin's fsync alone need not flush a drive's write cache. No fallback on error.
const mediaSync = process.platform === "darwin" ? dlopen("/usr/lib/libSystem.B.dylib", {
  fcntl: { args: ["i32", "i32", "i32"], returns: "i32" },
}) : null;

// Capture the preload boundary so a test cannot opt itself back into live paths.
const testRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
const testMode = !!testRoot || process.env.NODE_ENV === "test";
function gatePath(env: NodeJS.ProcessEnv): string {
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
  const path = gatePath(env);
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
  const path = gatePath(env);
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

export function persistUpdateGateState(path: string, state: UpdateGateState, exclusive = false): void {
  const staged = join(`${path}.lock`, "state.json");
  const fd = openSync(staged, "wx", 0o600);
  try {
    writeFileSync(fd, JSON.stringify(state) + "\n");
    fsyncSync(fd);
    if (exclusive) { linkSync(staged, path); unlinkSync(staged); }
    else renameSync(staged, path); // Same filesystem: readers see the old or new record.
    const directory = openSync(dirname(path), "r");
    try { fsyncSync(directory); }
    finally { closeSync(directory); }
    if (mediaSync && mediaSync.symbols.fcntl(fd, 51 /* F_FULLFSYNC */, 0) !== 0) {
      throw new Error("UPDATE_GATE_MEDIA_SYNC_FAILED");
    }
  } finally { closeSync(fd); }
}

/** Compatibility entrypoint: all commands now use the admission-aware commit path. */
export function applyUpdateGateCommand(command: unknown, env: NodeJS.ProcessEnv = process.env,
  verifyCommit?: (state: UpdateGateState) => boolean): UpdateGateTransition {
  return updateVoiceGate(command, verifyCommit, env);
}
