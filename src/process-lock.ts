/**
 * MCP process lock — prevents orphan MCP server processes.
 *
 * Problem: Every Claude session spawns a new voicelayer-mcp process, but they
 * never die. Multiple orphans compete for one Voice Bar socket, causing random
 * failures, hangs, and lost audio.
 *
 * Solution: PID lockfile at /tmp/voicelayer-mcp.pid. On startup, check for
 * stale processes and kill them. On exit, clean up the lockfile.
 *
 * AIDEV-NOTE: This is the #1 reliability fix for VoiceLayer. Orphan MCP
 * servers are the root cause of most voice_speak/voice_ask failures.
 *
 * AIDEV-NOTE: LOCK1 — never SIGTERM a PID that merely reused a stale lock's
 * number. The lock persists its writer's exact kernel start time (p_starttime,
 * µs, via sysctl KERN_PROC_PID). Reclaim requires the live PID's start time to
 * be EXACTLY that value, re-read immediately before the signal. Legacy locks,
 * unknown or changed start times and stale observations claim without killing.
 * argv is never consulted: identity is the generation, not the launch spelling.
 */

import { dlopen, FFIType, ptr } from "bun:ffi";
import { existsSync, lstatSync, readFileSync, unlinkSync } from "fs";
import { isAbsolute, join, relative, resolve, sep } from "path";
import { safeWriteFileSync } from "./paths";

export const MCP_PID_FILE = "/tmp/voicelayer-mcp.pid";
const MCP_PID_OVERRIDE_ENV = "QA_VOICE_MCP_PID_PATH";

/** Oldest identity observation we will still act on with a numeric-PID signal. */
const MAX_OBSERVATION_AGE_MS = 250;

// Capture the preload boundary before tests temporarily change their env.
// NODE_ENV catches a Bun test runner that bypassed the preload: fail closed.
const testRunRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
const testMode = !!testRunRoot || process.env.NODE_ENV === "test";

/** Require a private test PID path, including before fixture setup/cleanup. */
export function assertTestPidPath(pidPath: string): void {
  const refuse = () => {
    throw new Error(`[voicelayer] test PID lock refused outside the isolated run: ${pidPath}`);
  };
  if (!testRunRoot) return refuse();
  const root = resolve(testRunRoot);
  const tail = relative(root, resolve(pidPath));
  if (!tail || tail === ".." || tail.startsWith(`..${sep}`) || isAbsolute(tail)) return refuse();
  // A lexical child can still lead to a resident file through a symlink.
  let component = root;
  for (const part of ["", ...tail.split(sep)]) {
    component = join(component, part);
    try {
      if (lstatSync(component).isSymbolicLink()) refuse();
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
}

export function getMcpPidFilePath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  const override = env[MCP_PID_OVERRIDE_ENV]?.trim();
  return override || MCP_PID_FILE;
}

interface PidLockData {
  pid: number;
  startedAt: string;
  /** Writer's kernel start time, µs since epoch. Absent in legacy locks. */
  processStartUs?: number;
}

interface AcquireResult {
  acquired: boolean;
  killedStale: boolean;
  stalePid?: number;
}

interface AcquireProcessLockOptions {
  killAlive?: boolean;
  /** Test hook: override the owner's kernel start-time probe. */
  readProcessStartUs?: (pid: number) => number | null;
  /** Test hook: override the monotonic clock bounding observation age. */
  monotonicNowMs?: () => number;
}

/** Check if a process is alive using kill(pid, 0) signal probe. */
export function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: unknown) {
    const code = (err as NodeJS.ErrnoException).code;
    // EPERM = alive but we can't signal it; ESRCH = not found (dead)
    return code === "EPERM";
  }
}

// struct kinfo_proc (<sys/sysctl.h>), LP64: kp_proc.p_un.__p_starttime is
// a timeval at offset 0 (tv_sec i64, tv_usec i32 at 8); kp_proc.p_pid at 40.
const CTL_KERN = 1;
const KERN_PROC = 14;
const KERN_PROC_PID = 1;
const KINFO_PROC_SIZE = 648;
const P_PID_OFFSET = 40;

type SysctlFn = (
  name: number,
  namelen: number,
  oldp: number,
  oldlenp: number,
  newp: null,
  newlen: bigint,
) => number;

let sysctl: SysctlFn | null | undefined;

function loadSysctl(): SysctlFn | null {
  if (sysctl !== undefined) return sysctl;
  sysctl = null;
  if (process.platform !== "darwin") return null;
  try {
    const lib = dlopen("/usr/lib/libSystem.B.dylib", {
      sysctl: {
        args: [FFIType.ptr, FFIType.u32, FFIType.ptr, FFIType.ptr, FFIType.ptr, FFIType.u64],
        returns: FFIType.i32,
      },
    });
    sysctl = lib.symbols.sysctl as unknown as SysctlFn;
  } catch {
    sysctl = null;
  }
  return sysctl;
}

/**
 * Exact kernel start time of `pid` in µs since the epoch (numeric, no text,
 * no timezone), or null when the process is gone or the probe is unavailable.
 */
export function readProcessStartUs(pid: number): number | null {
  if (!Number.isInteger(pid) || pid <= 0) return null;
  const call = loadSysctl();
  if (!call) return null;
  try {
    const mib = new Int32Array([CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]);
    const buf = new Uint8Array(KINFO_PROC_SIZE);
    const len = new BigUint64Array([BigInt(KINFO_PROC_SIZE)]);
    if (call(ptr(mib), mib.length, ptr(buf), ptr(len), null, 0n) !== 0) return null;
    // A missing PID answers success with zero bytes.
    if (len[0] !== BigInt(KINFO_PROC_SIZE)) return null;
    const view = new DataView(buf.buffer);
    if (view.getInt32(P_PID_OFFSET, true) !== pid) return null;
    const sec = Number(view.getBigInt64(0, true));
    const usec = view.getInt32(8, true);
    if (sec <= 0 || usec < 0 || usec >= 1_000_000) return null;
    const startUs = sec * 1_000_000 + usec;
    return Number.isSafeInteger(startUs) ? startUs : null;
  } catch {
    return null;
  }
}

let ownStartUs: number | null | undefined;

type ReclaimOutcome =
  | "signalled"
  | "legacy_lock"
  | "start_unknown"
  | "start_mismatch"
  | "start_changed"
  | "observation_expired"
  | "signal_failed";

/**
 * SIGTERM `pid` only when it is the exact generation that wrote the lock.
 *
 * Residual race: macOS has no generation-checked signal, so the final
 * sysctl and kill(2) still address a numeric PID. Hitting it needs the owner
 * to exit and its PID to be reissued between those two adjacent syscalls.
 */
function signalIfSameGeneration(
  pid: number,
  lock: PidLockData,
  options: AcquireProcessLockOptions,
): ReclaimOutcome {
  const persisted = lock.processStartUs;
  if (typeof persisted !== "number" || !Number.isSafeInteger(persisted)) {
    return "legacy_lock";
  }
  const readStart = options.readProcessStartUs ?? readProcessStartUs;
  const now = options.monotonicNowMs ?? (() => performance.now());

  const observedAt = now();
  const observed = readStart(pid);
  if (observed === null) return "start_unknown";
  if (observed !== persisted) return "start_mismatch";

  // Revalidate immediately before the signal, within a bounded age.
  if (readStart(pid) !== persisted) return "start_changed";
  if (now() - observedAt > MAX_OBSERVATION_AGE_MS) return "observation_expired";
  try {
    process.kill(pid, "SIGTERM");
    return "signalled";
  } catch {
    return "signal_failed";
  }
}

/** Read and parse the PID file. Returns null if missing, corrupt, or invalid. */
function readPidFile(pidPath: string = getMcpPidFilePath()): PidLockData | null {
  try {
    if (!existsSync(pidPath)) return null;
    const content = readFileSync(pidPath, "utf-8").trim();
    if (!content) return null;
    const data = JSON.parse(content);
    if (!data || typeof data.pid !== "number") return null;
    return data as PidLockData;
  } catch {
    return null;
  }
}

/**
 * Acquire a process lock.
 *
 * 1. If no PID file exists → claim it
 * 2. If PID file exists with dead process → claim it
 * 3. If PID file exists with alive process whose kernel start time exactly
 *    equals the persisted one → SIGTERM it, wait briefly, claim it
 * 4. Otherwise (legacy lock, PID reuse, unknown/changed/stale evidence) →
 *    claim WITHOUT signalling
 *
 * Always succeeds when killAlive is true — we're the new owner regardless.
 *
 * @param pidPath Optional PID file path. Defaults to MCP_PID_FILE.
 *   Use DAEMON_PID_FILE from paths.ts for the standalone daemon.
 */
export function acquireProcessLock(
  pidPath: string = getMcpPidFilePath(),
  options: AcquireProcessLockOptions = {},
): AcquireResult {
  if (testMode) assertTestPidPath(pidPath);
  const killAlive = options.killAlive ?? true;
  const existing = readPidFile(pidPath);

  if (!existing) {
    writePidFile(pidPath);
    return { acquired: true, killedStale: false };
  }

  // Stale process found — try to kill it
  const stalePid = existing.pid;

  if (stalePid === process.pid) {
    // We already own the lock (shouldn't happen, but handle gracefully)
    return { acquired: true, killedStale: false };
  }

  let killedStale = false;

  if (isProcessAlive(stalePid)) {
    if (!killAlive) {
      return { acquired: false, killedStale: false, stalePid };
    }

    const outcome = signalIfSameGeneration(stalePid, existing, options);
    if (outcome === "signalled") {
      killedStale = true;
      console.error(
        `[voicelayer] Sent SIGTERM to orphan process (PID ${stalePid}) — was started at ${existing.startedAt}`,
      );
      // Brief wait for the process to die before claiming the lock
      Bun.sleepSync(200);
    } else if (outcome === "signal_failed") {
      console.error(
        `[voicelayer] Could not kill orphan process (PID ${stalePid}) — claiming lock anyway`,
      );
    } else {
      console.error(
        `[voicelayer] Live PID ${stalePid} is not proven to be the lock's writer (${outcome}) — claiming without signalling`,
      );
    }
  } else {
    console.error(
      `[voicelayer] Cleaned up stale PID file (PID ${stalePid} is dead)`,
    );
  }

  writePidFile(pidPath);
  return { acquired: true, killedStale, stalePid };
}

/** Write our PID to the lockfile. */
function writePidFile(pidPath: string = getMcpPidFilePath()): void {
  if (ownStartUs === undefined) ownStartUs = readProcessStartUs(process.pid);
  const data: PidLockData = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
    ...(ownStartUs === null ? {} : { processStartUs: ownStartUs }),
  };
  safeWriteFileSync(pidPath, JSON.stringify(data));
}

/**
 * Release the lock by removing the PID file. Only removes if we own it.
 *
 * @param pidPath Optional PID file path. Defaults to MCP_PID_FILE.
 */
export function releaseProcessLock(pidPath: string = getMcpPidFilePath()): void {
  if (testMode) assertTestPidPath(pidPath);
  try {
    const existing = readPidFile(pidPath);
    // Only remove if we own it (or it's corrupt/missing)
    if (existing && existing.pid !== process.pid) return;
    if (existsSync(pidPath)) {
      unlinkSync(pidPath);
    }
  } catch {
    // Best-effort cleanup
  }
}
