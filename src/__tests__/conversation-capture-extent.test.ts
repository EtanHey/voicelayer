import { expect, test } from "bun:test";
import { downmixPCM16ToMono, resamplePCM16 } from "../audio-utils";
import { normalizedCaptureByteLength } from "../conversation-capture-extent";
import { VAD_CHUNK_SAMPLES } from "../vad-constants";

for (const sampleRate of [16000, 22050, 44100, 48000]) {
  for (const channels of [1, 2]) for (const [chunks, tailFrames] of [[4, 0], [2, 5]]) {
    test(`matches real chunked conversion: ${sampleRate}Hz/${channels}ch/${chunks}chunks/${tailFrames}tail`, () => {
      expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
      const chunkFrames = Math.ceil(VAD_CHUNK_SAMPLES * sampleRate / 16000);
      const frameBytes = channels * 2;
      const native = new Uint8Array((chunkFrames * chunks + tailFrames) * frameBytes);
      const view = new DataView(native.buffer);
      for (let i = 0; i < native.byteLength; i += 2) view.setInt16(i, (i * 37) % 32767, true);
      const parts: Uint8Array[] = [];
      for (let offset = 0; offset < native.byteLength; offset += chunkFrames * frameBytes) {
        const chunk = native.slice(offset, offset + chunkFrames * frameBytes);
        const mono = channels === 1 ? chunk : downmixPCM16ToMono(chunk, channels);
        parts.push(resamplePCM16(mono, sampleRate, 16000));
      }
      const actualBytes = parts.reduce((total, pcm) => total + pcm.byteLength, 0);
      expect(normalizedCaptureByteLength(native.byteLength, sampleRate, channels)).toBe(actualBytes);
      if (sampleRate === 44100) {
        expect(actualBytes).toBe(tailFrames ? 2050 : 4096);
        expect(actualBytes).not.toBe(Math.floor(native.byteLength / frameBytes / (sampleRate / 16000)) * 2);
      }
      expect(parts.every(pcm => pcm.byteLength % 2 === 0)).toBe(true);
    });
  }
}

test("zero frames have no normalized bytes", () => {
  expect(normalizedCaptureByteLength(0, 44100, 2)).toBe(0);
});
