import { describe, it, expect } from "bun:test";
import {
  VAD_CHUNK_SAMPLES,
  VAD_CHUNK_BYTES,
  SILENCE_MODE_SECONDS,
  silenceChunksForMode,
  processVADChunk,
  isSpeech,
  resetVAD,
  evaluateChunkBoundary,
  MAX_STT_CHUNK_SECONDS,
  STT_CHUNK_OVERLAP_SECONDS,
} from "../vad";

describe("vad module", () => {
  describe("constants", () => {
    it("VAD_CHUNK_SAMPLES is 512", () => {
      expect(VAD_CHUNK_SAMPLES).toBe(512);
    });

    it("VAD_CHUNK_BYTES is 1024 (512 samples * 2 bytes)", () => {
      expect(VAD_CHUNK_BYTES).toBe(1024);
    });
  });

  describe("silence mode config", () => {
    it("quick mode is 0.5 seconds", () => {
      expect(SILENCE_MODE_SECONDS.quick).toBe(0.5);
    });

    it("standard mode is 1.5 seconds", () => {
      expect(SILENCE_MODE_SECONDS.standard).toBe(1.5);
    });

    it("thoughtful mode is 2.5 seconds", () => {
      expect(SILENCE_MODE_SECONDS.thoughtful).toBe(2.5);
    });
  });

  describe("silenceChunksForMode", () => {
    it("quick mode requires ~16 chunks (0.5s * 31.25 chunks/s)", () => {
      const chunks = silenceChunksForMode("quick");
      expect(chunks).toBeGreaterThanOrEqual(15);
      expect(chunks).toBeLessThanOrEqual(17);
    });

    it("standard mode requires ~47 chunks (1.5s * 31.25 chunks/s)", () => {
      const chunks = silenceChunksForMode("standard");
      expect(chunks).toBeGreaterThanOrEqual(46);
      expect(chunks).toBeLessThanOrEqual(48);
    });

    it("thoughtful mode requires ~79 chunks (2.5s * 31.25 chunks/s)", () => {
      const chunks = silenceChunksForMode("thoughtful");
      expect(chunks).toBeGreaterThanOrEqual(78);
      expect(chunks).toBeLessThanOrEqual(80);
    });
  });

  describe("isSpeech", () => {
    it("returns true for probability >= 0.5", () => {
      expect(isSpeech(0.5)).toBe(true);
      expect(isSpeech(0.9)).toBe(true);
      expect(isSpeech(1.0)).toBe(true);
    });

    it("returns false for probability < 0.5", () => {
      expect(isSpeech(0.0)).toBe(false);
      expect(isSpeech(0.49)).toBe(false);
      expect(isSpeech(0.1)).toBe(false);
    });
  });

  describe("processVADChunk", () => {
    it("returns low probability for silence", async () => {
      await resetVAD();
      const silentChunk = new Uint8Array(VAD_CHUNK_BYTES); // all zeros = silence
      const prob = await processVADChunk(silentChunk);
      expect(prob).toBeGreaterThanOrEqual(0);
      expect(prob).toBeLessThan(0.5);
    });

    it("returns a number between 0 and 1", async () => {
      await resetVAD();
      const chunk = new Uint8Array(VAD_CHUNK_BYTES);
      const prob = await processVADChunk(chunk);
      expect(prob).toBeGreaterThanOrEqual(0);
      expect(prob).toBeLessThanOrEqual(1);
    });
  });

  describe("resetVAD", () => {
    it("does not throw", async () => {
      await expect(resetVAD()).resolves.toBeUndefined();
    });
  });

  describe("Phase 7 chunk boundary handling", () => {
    it("forces a rollover when chunk duration reaches the max cap", () => {
      expect(
        evaluateChunkBoundary({
          hasSpeech: true,
          silenceChunks: 0,
          silenceMode: "thoughtful",
          chunkDurationSeconds: MAX_STT_CHUNK_SECONDS,
          sampleRate: 16000,
        }),
      ).toEqual({
        shouldCloseChunk: true,
        reason: "max-duration",
        overlapBytes: STT_CHUNK_OVERLAP_SECONDS * 16000 * 2,
      });
    });

    it("closes the chunk on VAD silence after speech starts", () => {
      expect(
        evaluateChunkBoundary({
          hasSpeech: true,
          silenceChunks: silenceChunksForMode("standard"),
          silenceMode: "standard",
          chunkDurationSeconds: 12,
          sampleRate: 16000,
        }),
      ).toEqual({
        shouldCloseChunk: true,
        reason: "silence",
        overlapBytes: STT_CHUNK_OVERLAP_SECONDS * 16000 * 2,
      });
    });

    it("keeps the chunk open while speech is active and under the cap", () => {
      expect(
        evaluateChunkBoundary({
          hasSpeech: true,
          silenceChunks: 0,
          silenceMode: "quick",
          chunkDurationSeconds: 8,
          sampleRate: 16000,
        }),
      ).toEqual({
        shouldCloseChunk: false,
        reason: "continue",
        overlapBytes: 0,
      });
    });
  });
});
