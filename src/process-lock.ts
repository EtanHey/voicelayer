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
 */

import { existsSync, lstatSync, readFileSync, unlinkSync } from "fs";
import { isAbsolute, join, relative, resolve, sep } from "path";
import { safeWriteFileSync } from "./paths";

export const MCP_PID_FILE = "/tmp/voicelayer-mcp.pid";
const MCP_PID_OVERRIDE_ENV = "QA_VOICE_MCP_PID_PATH";

// Capture the preload boundary before tests temporarily change their env.
// NODE_ENV catches a Bun test runner that bypassed the preload: fail closed.
const testRunRoot = process.env.VOICELAYER_TEST_RUN_ROOT;
const testMode = !!testRunRoot || process.env.NODE_ENV === "test";

function assertTestPidPath(pidPath: string): void {
  if (!testMode) return;
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
}

interface AcquireResult {
  acquired: boolean;
  killedStale: boolean;
  stalePid?: number;
}

interface AcquireProcessLockOptions {
  killAlive?: boolean;
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
 * 3. If PID file exists with alive process → SIGTERM it, wait briefly, claim it
 *
 * Always succeeds — we're the new owner regardless.
 *
 * @param pidPath Optional PID file path. Defaults to MCP_PID_FILE.
 *   Use DAEMON_PID_FILE from paths.ts for the standalone daemon.
 */
export function acquireProcessLock(
  pidPath: string = getMcpPidFilePath(),
  options: AcquireProcessLockOptions = {},
): AcquireResult {
  assertTestPidPath(pidPath);
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

    try {
      process.kill(stalePid, "SIGTERM");
      killedStale = true;
      console.error(
        `[voicelayer] Sent SIGTERM to orphan process (PID ${stalePid}) — was started at ${existing.startedAt}`,
      );
      // Brief wait for the process to die before claiming the lock
      Bun.sleepSync(200);
    } catch {
      console.error(
        `[voicelayer] Could not kill orphan process (PID ${stalePid}) — claiming lock anyway`,
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
  const data: PidLockData = {
    pid: process.pid,
    startedAt: new Date().toISOString(),
  };
  safeWriteFileSync(pidPath, JSON.stringify(data));
}

/**
 * Release the lock by removing the PID file. Only removes if we own it.
 *
 * @param pidPath Optional PID file path. Defaults to MCP_PID_FILE.
 */
export function releaseProcessLock(pidPath: string = getMcpPidFilePath()): void {
  assertTestPidPath(pidPath);
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
