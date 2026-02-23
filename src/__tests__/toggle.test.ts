import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, writeFileSync, unlinkSync } from "fs";
import { TTS_DISABLED_FILE, MIC_DISABLED_FILE } from "../paths";
import { isTTSDisabled } from "../tts";

describe("toggle voice", () => {
  beforeEach(() => {
    // Clean up flag files
    try { unlinkSync(TTS_DISABLED_FILE); } catch {}
    try { unlinkSync(MIC_DISABLED_FILE); } catch {}
  });

  afterEach(() => {
    try { unlinkSync(TTS_DISABLED_FILE); } catch {}
    try { unlinkSync(MIC_DISABLED_FILE); } catch {}
  });

  describe("flag files", () => {
    it("TTS_DISABLED_FILE is at /tmp/.claude_tts_disabled", () => {
      expect(TTS_DISABLED_FILE).toBe("/tmp/.claude_tts_disabled");
    });

    it("MIC_DISABLED_FILE is at /tmp/.claude_mic_disabled", () => {
      expect(MIC_DISABLED_FILE).toBe("/tmp/.claude_mic_disabled");
    });
  });

  describe("isTTSDisabled", () => {
    it("returns false when flag file does not exist", () => {
      expect(isTTSDisabled()).toBe(false);
    });

    it("returns true when flag file exists", () => {
      writeFileSync(TTS_DISABLED_FILE, "disabled");
      expect(isTTSDisabled()).toBe(true);
    });

    it("returns false after flag file is removed", () => {
      writeFileSync(TTS_DISABLED_FILE, "disabled");
      expect(isTTSDisabled()).toBe(true);
      unlinkSync(TTS_DISABLED_FILE);
      expect(isTTSDisabled()).toBe(false);
    });
  });

  describe("toggle flow", () => {
    it("creating TTS flag file disables TTS, removing re-enables", () => {
      expect(existsSync(TTS_DISABLED_FILE)).toBe(false);

      // Disable
      writeFileSync(TTS_DISABLED_FILE, "disabled at test");
      expect(existsSync(TTS_DISABLED_FILE)).toBe(true);
      expect(isTTSDisabled()).toBe(true);

      // Enable
      unlinkSync(TTS_DISABLED_FILE);
      expect(existsSync(TTS_DISABLED_FILE)).toBe(false);
      expect(isTTSDisabled()).toBe(false);
    });

    it("creating MIC flag file marks mic as disabled", () => {
      expect(existsSync(MIC_DISABLED_FILE)).toBe(false);

      writeFileSync(MIC_DISABLED_FILE, "disabled at test");
      expect(existsSync(MIC_DISABLED_FILE)).toBe(true);

      unlinkSync(MIC_DISABLED_FILE);
      expect(existsSync(MIC_DISABLED_FILE)).toBe(false);
    });
  });
});
