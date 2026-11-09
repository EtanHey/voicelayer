/**
 * T9 (Etan QA 2026-11-09, "hollow or weird when it speaks fast or slow"; Codex round 1, finding 2): the resident
 * player's scaled speed is SoX's WSOLA `tempo -s <rate> 20 5 8` (see buildPlaybackArgv). File-to-file only: SoX
 * renders into the isolated test directory, so no audio device is opened. Skips loudly when SoX is not installed.
 */
import { describe, expect, it } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { buildPlaybackArgv, TEMPO_WSOLA_PARAMS } from "../tts";
import { TEST_TMP } from "./setup/test-tmp";

const sox = Bun.which("sox");
const SR = 24_000;
const BURST = 0.02;
const RATES = [0.75, 1.25, 1.5, 2];
const PEAK = Math.round(0.8 * 32767);

/** Silence with 20 ms 1 kHz bursts at `starts` (seconds). */
function writeBursts(path: string, seconds: number, starts: number[]): void {
  const n = Math.round(SR * seconds);
  const pcm = new Int16Array(n);
  for (const start of starts) {
    for (let i = Math.round(start * SR); i < Math.min(n, Math.round((start + BURST) * SR)); i++) {
      pcm[i] = Math.round(PEAK * Math.sin((2 * Math.PI * 1000 * i) / SR));
    }
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + pcm.byteLength, 4); header.write("WAVE", 8);
  header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(SR, 24); header.writeUInt32LE(SR * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write("data", 36); header.writeUInt32LE(pcm.byteLength, 40);
  writeFileSync(path, Buffer.concat([header, Buffer.from(pcm.buffer)]));
}

function readPcm(path: string): Int16Array {
  const bytes = readFileSync(path);
  const data = bytes.indexOf("data");
  const length = bytes.readUInt32LE(data + 4);
  return new Int16Array(bytes.buffer.slice(bytes.byteOffset + data + 8, bytes.byteOffset + data + 8 + length));
}

/** Each burst's output peak and first onset, looked for around its source time / rate (the last one to EOF). */
function measure(pcm: Int16Array, starts: number[], rate: number) {
  return starts.map((start, index) => {
    const from = Math.max(0, Math.round((start / rate - 0.03) * SR));
    const to = index === starts.length - 1 ? pcm.length : Math.min(pcm.length, Math.round((start / rate + BURST / rate + 0.06) * SR));
    let peak = 0, onset = -1;
    for (let i = from; i < to; i++) {
      const value = Math.abs(pcm[i]);
      peak = Math.max(peak, value);
      if (onset < 0 && value > 3000) onset = i / SR;
    }
    return { peak, onsetError: onset < 0 ? Infinity : Math.abs(onset - start / rate) };
  });
}

function stretch(source: string, output: string, rate: number, params: readonly string[]): void {
  const run = Bun.spawnSync([sox!, source, output, "tempo", "-s", String(rate), ...params],
    { env: process.env, stdout: "ignore", stderr: "pipe" });
  expect(run.exitCode).toBe(0);
}

describe("T9 pitch-preserving speed (SoX WSOLA tempo)", () => {
  it("plays the production argv: tempo -s <rate> with the swept 20/5/8 ms windows", () => {
    expect(buildPlaybackArgv("afplay", "/x/a.mp3", true, 2, "/sox/play").slice(-5)).toEqual(["-s", "2", ...TEMPO_WSOLA_PARAMS]);
  });

  it.skipIf(!sox)("keeps every 20 ms burst, interior and at EOF, across rates and nearby file lengths", () => {
    const directory = join(TEST_TMP, "tempo-wsola");
    mkdirSync(directory, { recursive: true });
    // Two bands of lengths, 2.6 ms apart (not a multiple of any window), and Codex's exact 4.000 s / 4.013 s pair.
    const lengths = [...Array.from({ length: 10 }, (_, k) => 2 + k * 0.0026), ...Array.from({ length: 10 }, (_, k) => 3.98 + k * 0.0026), 4, 4.013];
    let cases = 0;
    for (const [index, seconds] of lengths.entries()) {
      const starts = [0.5, 1 + index * 0.0017, seconds - BURST];
      const source = join(directory, `bursts-${index}.wav`);
      writeBursts(source, seconds, starts);
      for (const rate of RATES) {
        const output = join(directory, `out-${index}-${rate}.wav`);
        stretch(source, output, rate, TEMPO_WSOLA_PARAMS);
        const pcm = readPcm(output);
        for (const [burst, result] of measure(pcm, starts, rate).entries()) {
          const label = `${seconds.toFixed(4)} s at ${rate}x, burst ${burst}`;
          expect(result.peak, label).toBeGreaterThanOrEqual(0.5 * PEAK);
          expect(result.onsetError, label).toBeLessThan(0.012);
          cases++;
        }
        // Output is the source at exactly 1/rate: the clock's audio-ms = wall-ms x rate holds to the end.
        expect(Math.abs(pcm.length / SR - seconds / rate)).toBeLessThan(0.002);
      }
    }
    expect(cases).toBe(lengths.length * RATES.length * 3);
  });

  it.skipIf(!sox)("RED witness: SoX's default speech profile loses Codex's 4.013 s EOF burst at 2x", () => {
    const directory = join(TEST_TMP, "tempo-wsola-default");
    mkdirSync(directory, { recursive: true });
    const starts = [1, 2, 3, 4.013 - BURST];
    const source = join(directory, "codex-4013.wav");
    writeBursts(source, 4.013, starts);
    const output = join(directory, "default.wav");
    stretch(source, output, 2, []);
    expect(measure(readPcm(output), starts, 2).at(-1)!.peak).toBeLessThan(0.5 * PEAK);
  });

  if (!sox) it("SKIPPED: SoX is not installed, so the WSOLA timing receipts did not run", () => {});
});
