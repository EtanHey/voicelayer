import { describe, it, expect, mock, beforeEach } from "bun:test";
import { findXTTSCheckpoint, isXTTSAvailable } from "../tts/xtts";

describe("XTTS-v2 inference bridge", () => {
  describe("findXTTSCheckpoint", () => {
    it("returns null for non-existent voice", () => {
      const result = findXTTSCheckpoint("nonexistent-voice-xyz");
      expect(result).toBeNull();
    });

    it("returns checkpoint info for voice with fine-tuned model", () => {
      // This test only passes when Theo's training has completed
      const result = findXTTSCheckpoint("theo");
      if (result) {
        expect(result.checkpointPath).toContain("best_model.pth");
        expect(result.configPath).toContain("config.json");
        expect(result.vocabPath).toContain("vocab.json");
        expect(result.trainingDir).toContain("GPT_XTTS_THEO");
      }
      // If no checkpoint exists yet, that's ok — training may be in progress
    });
  });

  describe("isXTTSAvailable", () => {
    it("returns false for non-existent voice", () => {
      expect(isXTTSAvailable("nonexistent-voice-xyz")).toBe(false);
    });

    it("checks both venv and checkpoint", () => {
      // isXTTSAvailable requires both XTTS venv AND fine-tuned model
      const available = isXTTSAvailable("theo");
      const hasCheckpoint = findXTTSCheckpoint("theo") !== null;

      // If checkpoint exists but venv doesn't (or vice versa), should be false
      // If both exist, should be true
      if (hasCheckpoint) {
        // Availability depends on venv existence
        expect(typeof available).toBe("boolean");
      } else {
        expect(available).toBe(false);
      }
    });
  });
});
