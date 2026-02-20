/**
 * Session-level voice booking — lockfile-based mutex for mic/speaker access.
 *
 * When a Claude session books voice, it holds the mic for the entire work session.
 * Other sessions see "line busy" and fall back to text.
 *
 * Lockfile: /tmp/voicelayer-session.lock
 * Stop signal: /tmp/voicelayer-stop (touch to end current recording)
 */

import { existsSync, readFileSync, writeFileSync, unlinkSync } from "fs";
import { LOCK_FILE, STOP_FILE } from "./paths";

export interface SessionLock {
  pid: number;
  sessionId: string;
  startedAt: string;
}

/**
 * Check if a process is alive.
 * ESRCH = no such process (dead). EPERM = exists but can't signal (alive, not ours).
 */
function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err: unknown) {
    // ESRCH means process doesn't exist — it's dead
    const code = err instanceof Object && "code" in err ? (err as { code: string }).code : undefined;
    if (code === "ESRCH") return false;
    // EPERM means process exists but we can't signal it — it's alive
    return true;
  }
}

/**
 * Read the current lock file. Returns null if no lock or file is invalid.
 */
function readLock(): SessionLock | null {
  if (!existsSync(LOCK_FILE)) return null;
  try {
    const data = JSON.parse(readFileSync(LOCK_FILE, "utf-8"));
    if (data.pid && data.sessionId && data.startedAt) {
      return data as SessionLock;
    }
    return null;
  } catch {
    return null;
  }
}

/**
 * Check and clean stale locks (dead PID). Returns true if a stale lock was cleaned.
 */
export function cleanStaleLock(): boolean {
  const lock = readLock();
  if (!lock) return false;

  if (!isProcessAlive(lock.pid)) {
    try {
      unlinkSync(LOCK_FILE);
    } catch {}
    return true;
  }
  return false;
}

/**
 * Book a voice session. Returns success or error message.
 */
export function bookVoiceSession(sessionId?: string): {
  success: boolean;
  error?: string;
  lock?: SessionLock;
} {
  // Clean stale locks first
  cleanStaleLock();

  const existing = readLock();
  if (existing) {
    // Already booked by us?
    if (existing.pid === process.pid) {
      return { success: true, lock: existing };
    }
    return {
      success: false,
      error: `Line is busy — voice booked by session ${existing.sessionId} (PID ${existing.pid}) since ${existing.startedAt}`,
    };
  }

  const lock: SessionLock = {
    pid: process.pid,
    sessionId: sessionId || `mcp-${process.pid}`,
    startedAt: new Date().toISOString(),
  };

  try {
    // Use 'wx' flag for atomic exclusive create — prevents TOCTOU race
    writeFileSync(LOCK_FILE, JSON.stringify(lock, null, 2), { flag: "wx" });
    return { success: true, lock };
  } catch (err: unknown) {
    // Another process grabbed the lock between our check and write
    const code = err instanceof Object && "code" in err ? (err as { code: string }).code : undefined;
    if (code === "EEXIST") {
      const winner = readLock();
      return {
        success: false,
        error: `Line is busy — voice booked by session ${winner?.sessionId ?? "unknown"} (race condition)`,
      };
    }
    throw err instanceof Error ? err : new Error(String(err));
  }
}

/**
 * Release the voice session lock. Only releases if we own it.
 */
export function releaseVoiceSession(): void {
  const lock = readLock();
  if (lock && lock.pid === process.pid) {
    try {
      unlinkSync(LOCK_FILE);
    } catch {}
  }
  // Also clean stop signal
  clearStopSignal();
}

/**
 * Check if voice is currently booked and by whom.
 */
export function isVoiceBooked(): {
  booked: boolean;
  ownedByUs: boolean;
  owner?: SessionLock;
} {
  cleanStaleLock();
  const lock = readLock();
  if (!lock) return { booked: false, ownedByUs: false };
  return {
    booked: true,
    ownedByUs: lock.pid === process.pid,
    owner: lock,
  };
}

/**
 * Check if a stop signal has been sent (user touched /tmp/voicelayer-stop).
 */
export function hasStopSignal(): boolean {
  return existsSync(STOP_FILE);
}

/**
 * Clear the stop signal file.
 */
export function clearStopSignal(): void {
  if (existsSync(STOP_FILE)) {
    try {
      unlinkSync(STOP_FILE);
    } catch {}
  }
}

/**
 * Release lock + clean up on process exit.
 */
function cleanup() {
  releaseVoiceSession();
}

process.on("SIGTERM", () => { cleanup(); process.exit(0); });
process.on("SIGINT", () => { cleanup(); process.exit(0); });
process.on("exit", cleanup);
