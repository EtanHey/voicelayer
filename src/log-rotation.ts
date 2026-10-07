/**
 * Log rotation for daemon log files.
 *
 * Rotates log files when they exceed MAX_LOG_SIZE (10MB).
 * Keeps one rotated backup (.1 suffix). Runs on an interval.
 */

import { existsSync, statSync, renameSync } from "fs";
import {
  isDefaultTmpRoot, isDefaultStateDir,
  isDefaultVoiceBarSocketPath, isDefaultMcpSocketPath,
} from "./paths";

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
    // LaunchAgent will recreate the file on next write automatically.
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
  paths?: string[],
  intervalMs: number = CHECK_INTERVAL_MS,
): void {
  if (rotationTimer) return; // Already running
  // Child output may be inherited handles, pipes, or arbitrary redirects; an
  // isolated root does not tell us the actual log filenames. Only the resident
  // defaults are known. Isolated callers must supply their output paths.
  const isolated = !isDefaultTmpRoot() || !isDefaultStateDir() ||
    !isDefaultVoiceBarSocketPath() || !isDefaultMcpSocketPath() ||
    !!process.env.QA_VOICE_MCP_PID_PATH?.trim() ||
    !!process.env.QA_VOICE_MCP_HEARTBEAT_PATH?.trim();
  const logPaths = paths ?? (isolated ? [] : LOG_PATHS);
  if (logPaths.length === 0) return;
  rotationTimer = setInterval(() => {
    for (const path of logPaths) {
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
