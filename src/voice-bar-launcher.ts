/**
 * Voice Bar status checker.
 *
 * AIDEV-NOTE: Architecture inversion (Phase 0) — FlowBar is now a persistent
 * server. MCP doesn't manage its lifecycle. This module only checks if FlowBar
 * is running and logs a warning if not. Users add FlowBar to Login Items.
 */

/** Whether we've already checked this session. */
let checkAttempted = false;

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
 * Check if Voice Bar is running and warn if not.
 * Called on first voice_speak per session. No auto-launch — FlowBar is persistent.
 */
export function ensureVoiceBarRunning(): void {
  if (checkAttempted) return;
  checkAttempted = true;

  if (isVoiceBarRunning()) {
    console.error("[voicelayer] Voice Bar is running");
    return;
  }

  console.error(
    "[voicelayer] Voice Bar not running — start it manually or add to Login Items",
  );
}

/**
 * Reset check state — for testing only.
 */
export function resetLaunchState(): void {
  checkAttempted = false;
}
