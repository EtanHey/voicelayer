import { describe, it, expect, beforeEach, afterEach, mock } from "bun:test";
import { existsSync, writeFileSync, unlinkSync } from "fs";
import * as actualPaths from "../paths";
import { isTTSDisabled } from "../tts";

const TEST_TTS_DISABLED_FILE = `/tmp/voicelayer-toggle-${process.pid}-tts-disabled`;
const TEST_MIC_DISABLED_FILE = `/tmp/voicelayer-toggle-${process.pid}-mic-disabled`;

mock.module("../paths", () => ({
  ...actualPaths,
  TTS_DISABLED_FILE: TEST_TTS_DISABLED_FILE,
  MIC_DISABLED_FILE: TEST_MIC_DISABLED_FILE,
}));

describe("toggle voice", () => {
  beforeEach(() => {
    // Clean up flag files
    try { unlinkSync(TEST_TTS_DISABLED_FILE); } catch {}
    try { unlinkSync(TEST_MIC_DISABLED_FILE); } catch {}
  });

  afterEach(() => {
    try { unlinkSync(TEST_TTS_DISABLED_FILE); } catch {}
    try { unlinkSync(TEST_MIC_DISABLED_FILE); } catch {}
  });

  describe("flag files", () => {
    it("uses an isolated TTS flag path for this test file", () => {
      expect(TEST_TTS_DISABLED_FILE).toContain("voicelayer-toggle");
    });

    it("uses an isolated mic flag path for this test file", () => {
      expect(TEST_MIC_DISABLED_FILE).toContain("voicelayer-toggle");
    });
  });

  describe("isTTSDisabled", () => {
    it("returns false when flag file does not exist", () => {
      expect(isTTSDisabled()).toBe(false);
    });

    it("returns true when flag file exists", () => {
      writeFileSync(TEST_TTS_DISABLED_FILE, "disabled");
      expect(isTTSDisabled()).toBe(true);
    });

    it("returns false after flag file is removed", () => {
      writeFileSync(TEST_TTS_DISABLED_FILE, "disabled");
      expect(isTTSDisabled()).toBe(true);
      unlinkSync(TEST_TTS_DISABLED_FILE);
      expect(isTTSDisabled()).toBe(false);
    });
  });

  describe("toggle flow", () => {
    it("creating TTS flag file disables TTS, removing re-enables", () => {
      expect(existsSync(TEST_TTS_DISABLED_FILE)).toBe(false);

      // Disable
      writeFileSync(TEST_TTS_DISABLED_FILE, "disabled at test");
      expect(existsSync(TEST_TTS_DISABLED_FILE)).toBe(true);
      expect(isTTSDisabled()).toBe(true);

      // Enable
      unlinkSync(TEST_TTS_DISABLED_FILE);
      expect(existsSync(TEST_TTS_DISABLED_FILE)).toBe(false);
      expect(isTTSDisabled()).toBe(false);
    });

    it("creating MIC flag file marks mic as disabled", () => {
      expect(existsSync(TEST_MIC_DISABLED_FILE)).toBe(false);

      writeFileSync(TEST_MIC_DISABLED_FILE, "disabled at test");
      expect(existsSync(TEST_MIC_DISABLED_FILE)).toBe(true);

      unlinkSync(TEST_MIC_DISABLED_FILE);
      expect(existsSync(TEST_MIC_DISABLED_FILE)).toBe(false);
    });
  });
});
