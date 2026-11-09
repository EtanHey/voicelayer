/**
 * T9 (Etan QA 2026-11-09, "hollow or weird when it speaks fast or slow"): the resident player's scaled speed is
 * SoX's WSOLA `tempo -s` behind a 30 ms tail pad (see buildPlaybackArgv). File-to-file only: SoX renders into the
 * isolated test directory, so no audio device is opened. Skips loudly when SoX is not installed.
 */
import { describe, expect, it } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { TEMPO_TAIL_PAD_SECONDS } from "../tts";
import { TEST_TMP } from "./setup/test-tmp";

const sox = Bun.which("sox");
const SR = 24_000;
const SECONDS = 4;
const BURSTS = [1.0, 2.0, 3.0, SECONDS - 0.02];

function writeMarks(path: string): void {
  const n = SR * SECONDS;
  const pcm = new Int16Array(n);
  for (const start of BURSTS) {
    for (let i = Math.round(start * SR); i < Math.min(n, Math.round((start + 0.02) * SR)); i++) {
      pcm[i] = Math.round(0.8 * 32767 * Math.sin((2 * Math.PI * 1000 * i) / SR));
    }
  }
  const header = Buffer.alloc(44);
  header.write("RIFF", 0); header.writeUInt32LE(36 + pcm.byteLength, 4); header.write("WAVE", 8);
  header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22);
  header.writeUInt32LE(SR, 24); header.writeUInt32LE(SR * 2, 28); header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write("data", 36); header.writeUInt32LE(pcm.byteLength, 40);
  writeFileSync(path, Buffer.concat([header, Buffer.from(pcm.buffer)]));
}

/** Burst onsets (s) in a 16-bit mono WAV written by SoX, and its duration. */
function onsets(path: string): { onsets: number[]; duration: number } {
  const bytes = readFileSync(path);
  const data = bytes.indexOf("data");
  const length = bytes.readUInt32LE(data + 4);
  const pcm = new Int16Array(bytes.buffer, bytes.byteOffset + data + 8, Math.floor(length / 2));
  const found: number[] = [];
  for (let i = 0; i < pcm.length; i++) {
    if (Math.abs(pcm[i]) > 3000) { found.push(i / SR); i += Math.round(0.3 * SR); }
  }
  return { onsets: found, duration: pcm.length / SR };
}

describe("T9 pitch-preserving speed (SoX WSOLA tempo)", () => {
  it.skipIf(!sox)("keeps every burst, the last included, at its source time / rate", () => {
    const directory = join(TEST_TMP, "tempo-wsola");
    mkdirSync(directory, { recursive: true });
    const source = join(directory, "marks.wav");
    writeMarks(source);
    for (const rate of [0.75, 1.25, 1.5, 2]) {
      const output = join(directory, `out-${rate}.wav`);
      const run = Bun.spawnSync([sox!, source, output, "pad", "0", String(TEMPO_TAIL_PAD_SECONDS), "tempo", "-s", String(rate)],
        { env: process.env, stdout: "ignore", stderr: "pipe" });
      expect(run.exitCode).toBe(0);
      const measured = onsets(output);
      expect(measured.onsets).toHaveLength(BURSTS.length);
      measured.onsets.forEach((at, index) => expect(Math.abs(at - BURSTS[index] / rate)).toBeLessThan(0.015));
      // Only trailing silence is added: at most the pad, scaled.
      expect(measured.duration - SECONDS / rate).toBeGreaterThanOrEqual(-0.005);
      expect(measured.duration - SECONDS / rate).toBeLessThanOrEqual(TEMPO_TAIL_PAD_SECONDS / rate + 0.005);
    }
  });

  it.skipIf(!sox)("without the pad WSOLA drops the final burst at 2× (why the pad exists)", () => {
    const directory = join(TEST_TMP, "tempo-wsola-nopad");
    mkdirSync(directory, { recursive: true });
    const source = join(directory, "marks.wav");
    writeMarks(source);
    const output = join(directory, "out.wav");
    expect(Bun.spawnSync([sox!, source, output, "tempo", "-s", "2"], { env: process.env, stdout: "ignore", stderr: "pipe" }).exitCode).toBe(0);
    expect(onsets(output).onsets.length).toBeLessThan(BURSTS.length);
  });

  if (!sox) it("SKIPPED: SoX is not installed, so the WSOLA timing receipts did not run", () => {});
});
