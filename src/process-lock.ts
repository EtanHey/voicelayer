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

import { existsSync, readFileSync, unlinkSync } from "fs";
import { safeWriteFileSync } from "./paths";

export const MCP_PID_FILE = "/tmp/voicelayer-mcp.pid";

interface PidLockData {
  pid: number;
  startedAt: string;
}

interface AcquireResult {
  acquired: boolean;
  killedStale: boolean;
  stalePid?: number;
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
function readPidFile(pidPath: string = MCP_PID_FILE): PidLockData | null {
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
  pidPath: string = MCP_PID_FILE,
): AcquireResult {
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
function writePidFile(pidPath: string = MCP_PID_FILE): void {
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
export function releaseProcessLock(pidPath: string = MCP_PID_FILE): void {
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
