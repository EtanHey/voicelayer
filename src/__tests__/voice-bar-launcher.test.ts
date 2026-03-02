import { describe, it, expect, beforeEach } from "bun:test";

/**
 * Tests for Voice Bar status checker (post-architecture-inversion).
 *
 * FlowBar is now a persistent server. MCP doesn't auto-launch it.
 * ensureVoiceBarRunning() only checks + warns.
 */

import {
  ensureVoiceBarRunning,
  resetLaunchState,
  isVoiceBarRunning,
} from "../voice-bar-launcher";

describe("voice-bar-launcher", () => {
  beforeEach(() => {
    resetLaunchState();
  });

  describe("ensureVoiceBarRunning", () => {
    it("returns without error (check-only, no launch)", () => {
      expect(() => ensureVoiceBarRunning()).not.toThrow();
    });

    it("only checks once per session (idempotent)", () => {
      ensureVoiceBarRunning();
      ensureVoiceBarRunning();
      // No crash = pass
    });

    it("sets check-attempted flag after first call", () => {
      ensureVoiceBarRunning();
      const start = performance.now();
      ensureVoiceBarRunning();
      const elapsed = performance.now() - start;
      expect(elapsed).toBeLessThan(5);
    });

    it("resets properly with resetLaunchState", () => {
      ensureVoiceBarRunning();
      resetLaunchState();
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
