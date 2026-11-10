import { fileURLToPath } from "node:url";
/**
 * Voice Bar launcher — auto-starts VoiceBar.app if not running.
 *
 * AIDEV-NOTE: Architecture inversion (Phase 0) — VoiceBar is a persistent
 * server on /tmp/voicelayer.sock. MCP connects as client. This module
 * auto-launches VoiceBar.app on first voice_speak if it's not running,
 * so "enable voice programmatically" actually works.
 */

/** Whether we've already attempted a launch this session. */
let launchAttempted = false;

/**
 * Check if Voice Bar (VoiceBar) process is currently running.
 * Uses pgrep to check for the process by name.
 */
export function isVoiceBarRunning(): boolean {
  try {
    const result = Bun.spawnSync(["pgrep", "-x", "VoiceBar"]);
    return result.exitCode === 0;
  } catch {
    return false;
  }
}

/**
 * Ensure Voice Bar is running. Auto-launches VoiceBar.app if not.
 * Called on first voice_speak per session. Idempotent — only tries once.
 */
export function ensureVoiceBarRunning(): void {
  if (launchAttempted) return;
  launchAttempted = true;

  if (isVoiceBarRunning()) {
    console.error("[voicelayer] Voice Bar is running");
    return;
  }

  // The canonical resident is always started and verified through launchd.
  console.error("[voicelayer] Voice Bar not running — launching...");
  try {
    const result = Bun.spawnSync(["/bin/bash", fileURLToPath(new URL("../scripts/start-voicebar.sh", import.meta.url))], { env: process.env });
    if (result.exitCode === 0) {
      console.error("[voicelayer] Voice Bar launched successfully");
    } else {
      console.error(
        "[voicelayer] Failed to launch Voice Bar — run voicelayer setup; launchd startup/ownership verification failed",
      );
    }
  } catch {
    console.error(
      "[voicelayer] Failed to launch Voice Bar — run voicelayer setup; launchd startup/ownership verification failed",
    );
  }
}

/**
 * Reset launch state — for testing only.
 */
export function resetLaunchState(): void {
  launchAttempted = false;
}
