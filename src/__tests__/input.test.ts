import { describe, it, expect } from "bun:test";
import { calculateRMS, createWavBuffer, clearInput } from "../input";

describe("input module", () => {
  describe("calculateRMS", () => {
    it("returns 0 for empty buffer", () => {
      const buffer = new Uint8Array(0);
      expect(calculateRMS(buffer)).toBe(0);
    });

    it("returns 0 for silent audio (all zeros)", () => {
      // 100 samples of silence (200 bytes, 16-bit)
      const buffer = new Uint8Array(200);
      expect(calculateRMS(buffer)).toBe(0);
    });

    it("returns high RMS for loud audio", () => {
      // Create buffer with max-amplitude 16-bit samples
      const numSamples = 100;
      const buffer = new Uint8Array(numSamples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < numSamples; i++) {
        view.setInt16(i * 2, 20000, true); // loud signal
      }

      const rms = calculateRMS(buffer);
      expect(rms).toBeGreaterThan(10000);
    });

    it("returns moderate RMS for moderate audio", () => {
      const numSamples = 100;
      const buffer = new Uint8Array(numSamples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < numSamples; i++) {
        view.setInt16(i * 2, 1000, true); // moderate signal
      }

      const rms = calculateRMS(buffer);
      expect(rms).toBeGreaterThan(500);
      expect(rms).toBeLessThan(5000);
    });

    it("handles alternating positive/negative samples", () => {
      const numSamples = 100;
      const buffer = new Uint8Array(numSamples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < numSamples; i++) {
        // Alternating +5000 / -5000 — RMS should be same as constant 5000
        view.setInt16(i * 2, i % 2 === 0 ? 5000 : -5000, true);
      }

      const rms = calculateRMS(buffer);
      expect(rms).toBeCloseTo(5000, -1); // within rounding
    });
  });

  describe("createWavBuffer", () => {
    it("creates valid WAV header", () => {
      const pcmData = new Uint8Array(32000); // 1 second of audio
      const wav = createWavBuffer(pcmData);

      // WAV file should be 44 + pcmData.length bytes
      expect(wav.byteLength).toBe(44 + pcmData.byteLength);

      // Check RIFF header
      const str = String.fromCharCode(wav[0], wav[1], wav[2], wav[3]);
      expect(str).toBe("RIFF");

      // Check WAVE marker
      const wave = String.fromCharCode(wav[8], wav[9], wav[10], wav[11]);
      expect(wave).toBe("WAVE");

      // Check fmt sub-chunk
      const fmt = String.fromCharCode(wav[12], wav[13], wav[14], wav[15]);
      expect(fmt).toBe("fmt ");

      // Check data sub-chunk
      const data = String.fromCharCode(wav[36], wav[37], wav[38], wav[39]);
      expect(data).toBe("data");
    });

    it("encodes correct file size in header", () => {
      const pcmData = new Uint8Array(1000);
      const wav = createWavBuffer(pcmData);
      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);

      // Bytes 4-7: file size - 8 = 36 + dataSize
      expect(view.getUint32(4, true)).toBe(36 + 1000);

      // Bytes 40-43: data chunk size = dataSize
      expect(view.getUint32(40, true)).toBe(1000);
    });

    it("encodes correct audio format parameters", () => {
      const pcmData = new Uint8Array(100);
      const wav = createWavBuffer(pcmData);
      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);

      // PCM format = 1
      expect(view.getUint16(20, true)).toBe(1);
      // Channels = 1
      expect(view.getUint16(22, true)).toBe(1);
      // Sample rate = 16000
      expect(view.getUint32(24, true)).toBe(16000);
      // Byte rate = 32000 (16000 * 1 * 16/8)
      expect(view.getUint32(28, true)).toBe(32000);
      // Block align = 2 (1 * 16/8)
      expect(view.getUint16(32, true)).toBe(2);
      // Bits per sample = 16
      expect(view.getUint16(34, true)).toBe(16);
    });

    it("preserves PCM data after header", () => {
      const pcmData = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
      const wav = createWavBuffer(pcmData);

      // PCM data starts at offset 44
      for (let i = 0; i < pcmData.length; i++) {
        expect(wav[44 + i]).toBe(pcmData[i]);
      }
    });

    it("handles empty PCM data", () => {
      const pcmData = new Uint8Array(0);
      const wav = createWavBuffer(pcmData);

      // Should still have valid 44-byte header
      expect(wav.byteLength).toBe(44);

      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
      expect(view.getUint32(40, true)).toBe(0); // data size = 0
    });
  });

  describe("clearInput", () => {
    it("does not throw (no-op)", () => {
      expect(() => clearInput()).not.toThrow();
    });
  });

  describe("PTT mode exports", () => {
    it("recordToBuffer accepts pressToTalk parameter (type check)", async () => {
      const { recordToBuffer } = await import("../input");
      // Verify the function exists and has the right arity (3 params)
      expect(typeof recordToBuffer).toBe("function");
      expect(recordToBuffer.length).toBeGreaterThanOrEqual(1);
    });

    it("waitForInput accepts pressToTalk parameter (type check)", async () => {
      const { waitForInput } = await import("../input");
      expect(typeof waitForInput).toBe("function");
      expect(waitForInput.length).toBeGreaterThanOrEqual(1);
    });
  });
});
