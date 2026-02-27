/**
 * Auto-launch Voice Bar on first voice_speak call.
 *
 * Checks if the Voice Bar macOS app is running. If not, launches it
 * from the built binary path. Only attempts once per MCP session to
 * avoid repeated launch checks on every voice_speak call.
 *
 * Fails silently — if the binary doesn't exist or launch fails,
 * voice_speak continues to work normally (TTS still plays, just no
 * Voice Bar UI).
 */

import { existsSync } from "fs";
import { resolve, dirname } from "path";

/**
 * Path to the built Voice Bar binary.
 * Resolved relative to project root (two levels up from src/).
 */
export const VOICE_BAR_BINARY_PATH = resolve(
  dirname(import.meta.dir),
  "flow-bar/.build/arm64-apple-macosx/debug/FlowBar",
);

/** Whether we've already attempted to launch this session. */
let launchAttempted = false;

/**
 * Check if Voice Bar (FlowBar) process is currently running.
 * Uses pgrep to check for the process by name.
 */
export function isVoiceBarRunning(): boolean {
  try {
    const result = Bun.spawnSync(["pgrep", "-x", "FlowBar"]);
    return result.exitCode === 0;
  } catch {
    return false;
  }
}

/**
 * Ensure Voice Bar is running. Called on first voice_speak per session.
 *
 * - If already attempted this session, returns immediately (no-op)
 * - If Voice Bar is already running, marks as attempted and returns
 * - If binary exists, launches it and marks as attempted
 * - If binary missing or launch fails, logs warning and continues
 */
export function ensureVoiceBarRunning(): void {
  if (launchAttempted) return;
  launchAttempted = true;

  // Check if already running — no need to launch
  if (isVoiceBarRunning()) {
    console.error("[voicelayer] Voice Bar already running — skipping launch");
    return;
  }

  // Check if binary exists
  if (!existsSync(VOICE_BAR_BINARY_PATH)) {
    console.error(
      `[voicelayer] Voice Bar binary not found at ${VOICE_BAR_BINARY_PATH} — skipping auto-launch`,
    );
    return;
  }

  // Launch Voice Bar in background (detached, no stdout/stderr capture)
  try {
    Bun.spawn([VOICE_BAR_BINARY_PATH], {
      stdout: "ignore",
      stderr: "ignore",
    });
    console.error("[voicelayer] Voice Bar auto-launched");
  } catch (err: unknown) {
    console.error(
      `[voicelayer] Failed to launch Voice Bar: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

/**
 * Reset launch state — for testing only.
 * Allows tests to verify the once-per-session behavior.
 */
export function resetLaunchState(): void {
  launchAttempted = false;
}
