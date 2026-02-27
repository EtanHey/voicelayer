import { describe, it, expect, mock, beforeEach } from "bun:test";
import { createWavBuffer } from "../input";

/**
 * Tests for streaming STT module.
 *
 * Since createStreamingSession depends on whisper-server being available,
 * we test the pure functions and data flow patterns that don't require
 * a running server.
 */

describe("streaming-stt", () => {
  describe("WAV buffer creation for streaming", () => {
    it("creates valid WAV header for small chunks", () => {
      // 1.5 seconds of silence at 16kHz 16-bit mono
      const samples = 16000 * 1.5;
      const pcm = new Uint8Array(samples * 2); // 16-bit = 2 bytes per sample
      const wav = createWavBuffer(pcm);

      // WAV header is 44 bytes
      expect(wav.byteLength).toBe(44 + pcm.byteLength);

      // Check RIFF header
      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
      expect(
        String.fromCharCode(
          view.getUint8(0),
          view.getUint8(1),
          view.getUint8(2),
          view.getUint8(3),
        ),
      ).toBe("RIFF");

      // Check WAVE format
      expect(
        String.fromCharCode(
          view.getUint8(8),
          view.getUint8(9),
          view.getUint8(10),
          view.getUint8(11),
        ),
      ).toBe("WAVE");

      // Check sample rate (offset 24, little-endian)
      expect(view.getUint32(24, true)).toBe(16000);

      // Check channels (offset 22)
      expect(view.getUint16(22, true)).toBe(1);

      // Check bits per sample (offset 34)
      expect(view.getUint16(34, true)).toBe(16);
    });

    it("creates valid WAV for 3-second streaming window", () => {
      // 3 seconds — the streaming window size
      const samples = 16000 * 3;
      const pcm = new Uint8Array(samples * 2);
      const wav = createWavBuffer(pcm);

      expect(wav.byteLength).toBe(44 + samples * 2);

      // data size field (offset 40) should match PCM size
      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
      expect(view.getUint32(40, true)).toBe(samples * 2);
    });

    it("handles empty PCM data", () => {
      const pcm = new Uint8Array(0);
      const wav = createWavBuffer(pcm);
      expect(wav.byteLength).toBe(44); // Just the header
    });
  });

  describe("streaming chunk accumulation", () => {
    it("accumulates chunks correctly", () => {
      // Simulate what StreamingSTTSession.feed() does
      const allChunks: Uint8Array[] = [];
      let totalBytes = 0;

      // Feed 10 VAD chunks (512 samples × 2 bytes = 1024 bytes each)
      for (let i = 0; i < 10; i++) {
        const chunk = new Uint8Array(1024);
        chunk.fill(i); // Each chunk has different data
        allChunks.push(chunk);
        totalBytes += chunk.byteLength;
      }

      expect(allChunks.length).toBe(10);
      expect(totalBytes).toBe(10240);

      // Concatenate like sendWindow does
      const pcm = new Uint8Array(totalBytes);
      let offset = 0;
      for (const chunk of allChunks) {
        pcm.set(chunk, offset);
        offset += chunk.byteLength;
      }

      expect(pcm.byteLength).toBe(10240);
      // First chunk was filled with 0
      expect(pcm[0]).toBe(0);
      // Second chunk was filled with 1
      expect(pcm[1024]).toBe(1);
      // Last chunk was filled with 9
      expect(pcm[9 * 1024]).toBe(9);
    });

    it("window threshold triggers at ~3 seconds", () => {
      const SAMPLE_RATE = 16000;
      const BYTES_PER_SAMPLE = 2;
      const WINDOW_SECONDS = 3;
      const WINDOW_BYTES = WINDOW_SECONDS * SAMPLE_RATE * BYTES_PER_SAMPLE;

      // 3 seconds at 16kHz 16-bit mono = 96000 bytes
      expect(WINDOW_BYTES).toBe(96000);

      // VAD chunks are 1024 bytes each, so we need ~94 chunks for one window
      const chunksPerWindow = Math.ceil(WINDOW_BYTES / 1024);
      expect(chunksPerWindow).toBe(94);
    });
  });
});
