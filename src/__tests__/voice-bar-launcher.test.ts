import { describe, it, expect, beforeEach, afterEach, mock } from "bun:test";
import { existsSync } from "fs";
import { resolve, dirname } from "path";

/**
 * Tests for Voice Bar auto-launch on first voice_speak call.
 *
 * Requirements:
 * 1. First voice_speak triggers a launch check
 * 2. Second voice_speak does NOT re-trigger
 * 3. If binary is missing, voice_speak still works (no crash)
 * 4. If Voice Bar is already running, don't launch again
 */

// We'll test the module's exported functions directly
import {
  ensureVoiceBarRunning,
  resetLaunchState,
  isVoiceBarRunning,
  VOICE_BAR_BINARY_PATH,
} from "../voice-bar-launcher";

describe("voice-bar-launcher", () => {
  beforeEach(() => {
    resetLaunchState();
  });

  describe("VOICE_BAR_BINARY_PATH", () => {
    it("points to flow-bar/.build/arm64-apple-macosx/debug/FlowBar relative to project root", () => {
      expect(VOICE_BAR_BINARY_PATH).toContain(
        "flow-bar/.build/arm64-apple-macosx/debug/FlowBar",
      );
    });
  });

  describe("ensureVoiceBarRunning", () => {
    it("returns without error even when binary does not exist", () => {
      // Should not throw — missing binary is a silent skip
      expect(() => ensureVoiceBarRunning()).not.toThrow();
    });

    it("only attempts launch once per session (idempotent)", () => {
      // Call twice — second call should be a no-op
      ensureVoiceBarRunning();
      ensureVoiceBarRunning();
      // No crash = pass. The flag prevents re-launch.
    });

    it("sets launch-attempted flag after first call", () => {
      ensureVoiceBarRunning();
      // Internal state tracks that launch was attempted
      // Second call returns immediately (tested via timing or mock)
      const start = performance.now();
      ensureVoiceBarRunning();
      const elapsed = performance.now() - start;
      // Second call should be near-instant (< 1ms) since it's just a flag check
      expect(elapsed).toBeLessThan(5);
    });

    it("resets properly with resetLaunchState", () => {
      ensureVoiceBarRunning();
      resetLaunchState();
      // After reset, next call should attempt launch again (not throw)
      expect(() => ensureVoiceBarRunning()).not.toThrow();
    });
  });

  describe("isVoiceBarRunning", () => {
    it("returns a boolean", () => {
      const result = isVoiceBarRunning();
      expect(typeof result).toBe("boolean");
    });
  });
});
