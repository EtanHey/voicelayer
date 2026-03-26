/**
 * Log rotation for daemon log files.
 *
 * Rotates log files when they exceed MAX_LOG_SIZE (10MB).
 * Keeps one rotated backup (.1 suffix). Runs on an interval.
 */

import { existsSync, statSync, renameSync, truncateSync } from "fs";

const MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB
const CHECK_INTERVAL_MS = 60_000; // Check every 60 seconds

/** Rotate a single log file if it exceeds maxSize. */
export function rotateIfNeeded(
  filePath: string,
  maxSize: number = MAX_LOG_SIZE,
): boolean {
  try {
    if (!existsSync(filePath)) return false;
    const stat = statSync(filePath);
    if (stat.size <= maxSize) return false;

    const rotatedPath = `${filePath}.1`;
    // Rename current to .1 (overwrites previous rotation)
    renameSync(filePath, rotatedPath);
    // Truncate creates a fresh empty file at the original path.
    // LaunchAgent will write to the same path so we don't need to recreate.
    // The rename already moved the file, so we just need the path free.
    // LaunchAgent reopens on next write automatically.
    return true;
  } catch (err) {
    console.error(
      `[voicelayer-daemon] Log rotation error for ${filePath}: ${err instanceof Error ? err.message : String(err)}`,
    );
    return false;
  }
}

const LOG_PATHS = [
  "/tmp/voicelayer-mcp-daemon.stdout.log",
  "/tmp/voicelayer-mcp-daemon.stderr.log",
];

let rotationTimer: ReturnType<typeof setInterval> | null = null;

/** Start periodic log rotation checks. */
export function startLogRotation(
  paths: string[] = LOG_PATHS,
  intervalMs: number = CHECK_INTERVAL_MS,
): void {
  if (rotationTimer) return; // Already running
  rotationTimer = setInterval(() => {
    for (const path of paths) {
      if (rotateIfNeeded(path)) {
        console.error(`[voicelayer-daemon] Rotated log: ${path}`);
      }
    }
  }, intervalMs);
  // Don't keep process alive just for log rotation
  rotationTimer.unref();
}

/** Stop periodic log rotation. */
export function stopLogRotation(): void {
  if (rotationTimer) {
    clearInterval(rotationTimer);
    rotationTimer = null;
  }
}
