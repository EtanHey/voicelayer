import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { stripHallucinatedCaption } from "../stt-caption-gate";
import { parseWavAudioInfo } from "../stt-pause-map";

const fixtureRoot = join(import.meta.dir, "fixtures", "caption-soft-tail");
function samples(name: string): Float32Array {
  const wav = readFileSync(join(fixtureRoot, name));
  const info = parseWavAudioInfo(wav)!;
  const pcm = new DataView(wav.buffer, wav.byteOffset + info.dataOffset, info.dataSize);
  return Float32Array.from({ length: info.dataSize / 2 }, (_, i) => pcm.getInt16(i * 2, true) / 32768);
}
function peakNormalize(input: Float32Array, dbfs: number): Float32Array {
  const peak = Math.max(...input);
  const gain = 10 ** (dbfs / 20) / peak;
  return input.map((sample) => sample * gain);
}
function wav(samples: Float32Array): Uint8Array {
  const out = Buffer.alloc(44 + samples.length * 2);
  out.write("RIFF", 0); out.writeUInt32LE(36 + samples.length * 2, 4);
  out.write("WAVEfmt ", 8); out.writeUInt32LE(16, 16);
  out.writeUInt16LE(1, 20); out.writeUInt16LE(1, 22);
  out.writeUInt32LE(16000, 24); out.writeUInt32LE(32000, 28);
  out.writeUInt16LE(2, 32); out.writeUInt16LE(16, 34);
  out.write("data", 36); out.writeUInt32LE(samples.length * 2, 40);
  samples.forEach((sample, i) => out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(sample * 32767))), 44 + i * 2));
  return out;
}

test("real Silero keeps a quiet spoken caption after normal speech", async () => {
  const lead = peakNormalize(samples("lead.wav"), -6);
  const tail = peakNormalize(samples("tail.wav"), -46);
  const leadStart = 8000, gap = 16000, after = 12800;
  const tailStart = leadStart + lead.length + gap;
  const audio = new Float32Array(tailStart + tail.length + after);
  let seed = 7;
  const noiseAmp = 10 ** (-70 / 20) * Math.sqrt(3);
  for (let i = 0; i < audio.length; i++) {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    audio[i] = (seed / 0x7fffffff * 2 - 1) * noiseAmp;
  }
  lead.forEach((sample, i) => audio[leadStart + i] += sample);
  tail.forEach((sample, i) => audio[tailStart + i] += sample);
  const transcript = "Okay, ship the release tonight after the checks finish. How to pronounce this";
  const result = await stripHallucinatedCaption(transcript, wav(audio), {
    segmentsText: transcript,
    segments: [
      { text: "Okay, ship the release tonight after the checks finish.", startS: leadStart / 16000, endS: (leadStart + lead.length) / 16000 },
      { text: " How to pronounce this", startS: tailStart / 16000, endS: (tailStart + tail.length) / 16000 },
    ],
  });
  expect(result.text).toBe(transcript);
  expect(result.removed).toBeNull();
});
