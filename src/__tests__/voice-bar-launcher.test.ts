import { describe, it, expect, beforeEach } from "bun:test";

/**
 * Tests for Voice Bar status checker (post-architecture-inversion).
 *
 * VoiceBar is now a persistent server. MCP doesn't auto-launch it.
 * ensureVoiceBarRunning() only checks + warns.
 */

import {
  ensureVoiceBarRunning,
  resetLaunchState,
  isVoiceBarRunning,
} from "../voice-bar-launcher";

// Real subprocesses: standalone p95 <= 36 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

describe("voice-bar-launcher", () => {
  beforeEach(() => {
    resetLaunchState();
  });

  describe("ensureVoiceBarRunning", () => {
    it("returns without error (check-only, no launch)", () => {
      expect(() => ensureVoiceBarRunning()).not.toThrow();
    }, SUBPROCESS_TEST_TIMEOUT_MS);

    it("only checks once per session (idempotent)", () => {
      ensureVoiceBarRunning();
      ensureVoiceBarRunning();
      // No crash = pass
    }, SUBPROCESS_TEST_TIMEOUT_MS);

    it("sets check-attempted flag after first call", () => {
      ensureVoiceBarRunning();
      const start = performance.now();
      ensureVoiceBarRunning();
      const elapsed = performance.now() - start;
      expect(elapsed).toBeLessThan(5);
    }, SUBPROCESS_TEST_TIMEOUT_MS);

    it("resets properly with resetLaunchState", () => {
      ensureVoiceBarRunning();
      resetLaunchState();
      expect(() => ensureVoiceBarRunning()).not.toThrow();
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  });

  describe("isVoiceBarRunning", () => {
    it("returns a boolean", () => {
      const result = isVoiceBarRunning();
      expect(typeof result).toBe("boolean");
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  });
});
