import { describe, expect, it } from "bun:test";
import { measurePCMExtent, splicePCM } from "../tts/prosody-pcm";

const RATE = 24000, THRESHOLD = 10 ** (-42 / 20);
/** 100 ms leading silence, 300 ms tone, 100 ms trailing silence; DC offset throughout. */
function audio() {
  const pcm = new Float32Array(12000);
  pcm.fill(0.02);
  for (let i = 2400; i < 9600; i++) pcm[i] += 0.3 * Math.sin(2 * Math.PI * (i - 2400) / 48);
  return { pcm, words: [{ text: "word", offset_ms: 100, duration_ms: 300 }] };
}
function silenceBetween(pcm: Float32Array, fromMs: number, toMs: number) {
  let silent = 0;
  for (let i = Math.round(fromMs * 24); i < Math.round(toMs * 24); i++) if (Math.abs(pcm[i]) < THRESHOLD) silent++;
  return silent / 24;
}
function maxStep(pcm: Float32Array) {
  let step = 0;
  for (let i = 1; i < pcm.length; i++) step = Math.max(step, Math.abs(pcm[i] - pcm[i - 1]));
  return step;
}

describe("splicePCM (v1 math, verified correct, reused)", () => {
  for (const pauseMs of [900, 750, 800, 600, 320, 450, 700, 550, 1000, 200, 300]) it(`silence ${pauseMs} ms, exact timestamp shift, click-free`, () => {
    const joined = splicePCM([{ ...audio(), pauseMs }, { ...audio(), pauseMs: 0 }], RATE);
    const [a, b] = joined.words;
    // Sample-exact: the speech-to-speech gap is round(pause * rate) samples.
    expect(b.offset_ms - (a.offset_ms + a.duration_ms)).toBeCloseTo(Math.round(pauseMs * 24) / 24, 6);
    expect(Math.abs(silenceBetween(joined.pcm, a.offset_ms + a.duration_ms, b.offset_ms) - pauseMs)).toBeLessThan(50);
    expect(maxStep(joined.pcm)).toBeLessThan(0.045);
  });
  it("trims neural silence to the 15 ms lead / 30 ms tail margins", () => {
    const joined = splicePCM([{ ...audio(), pauseMs: 0 }], RATE);
    expect(joined.words[0].offset_ms).toBeCloseTo(15, 0);
    expect(joined.durationMs).toBeCloseTo(15 + 300 + 30, 0);
  });
  it("rejects an invalid sample rate", () => {
    expect(() => splicePCM([{ ...audio(), pauseMs: 0 }], 0)).toThrow();
  });
});

describe("chunk-to-chunk pauses", () => {
  it("a trailing pause assumes the next chunk keeps its 15 ms lead", () => {
    const first = splicePCM([{ ...audio(), pauseMs: 0 }], RATE, { trailingPauseMs: 600 });
    const second = splicePCM([{ ...audio(), pauseMs: 0 }], RATE);
    const gap = first.durationMs - (first.words[0].offset_ms + first.words[0].duration_ms) + second.words[0].offset_ms;
    expect(gap).toBeCloseTo(600, 0);
  });
  it("a leading pause completes the gap after a raw (untrimmed) previous chunk with a measured tail", () => {
    const raw = audio();
    const extent = measurePCMExtent(raw.pcm, RATE, raw.words);
    expect(extent.tailMs).toBeCloseTo(100, 0);
    const next = splicePCM([{ ...audio(), pauseMs: 0 }], RATE, { leadingPauseMs: 800, previousTailMs: extent.tailMs });
    expect(extent.tailMs + next.words[0].offset_ms).toBeCloseTo(800, 0);
  });
  it("a previous tail longer than the pause never produces a negative pad", () => {
    const next = splicePCM([{ ...audio(), pauseMs: 0 }], RATE, { leadingPauseMs: 200, previousTailMs: 900 });
    expect(next.words[0].offset_ms).toBeCloseTo(15, 0);
  });
});

describe("v1 defect 10: zero-crossing snap never crosses the speech onset or tail", () => {
  for (const start of [1, 2, 17, 18, 19, 20, 21, 22]) it(`noise with no leading or trailing silence keeps every speech sample (seed ${start})`, () => {
    let seed = start;
    const pcm = new Float32Array(4800).map(() => { seed = (seed * 1103515245 + 12345) % 2 ** 31; return 0.4 * (seed / 2 ** 31) - 0.2; });
    const extent = measurePCMExtent(pcm, RATE, []);
    expect(extent.leadMs).toBeGreaterThanOrEqual(0);
    expect(extent.tailMs).toBeGreaterThanOrEqual(0);
    expect(extent.startSample).toBeLessThanOrEqual(extent.firstSample);
    expect(extent.endSample).toBeGreaterThan(extent.lastSample);
    const joined = splicePCM([{ pcm, words: [{ text: "x", offset_ms: 0, duration_ms: 200 }], pauseMs: 0 }], RATE);
    expect(joined.pcm.length).toBeGreaterThanOrEqual(extent.lastSample - extent.firstSample + 1);
    expect(joined.words[0].offset_ms).toBeGreaterThanOrEqual(0);
  });
  it("snaps outward to a real zero crossing when the margin lands mid-wave", () => {
    const pcm = new Float32Array(9600);
    for (let i = 0; i < pcm.length; i++) pcm[i] = 0.001 * Math.sin(2 * Math.PI * i / 37);
    for (let i = 2400; i < 7200; i++) pcm[i] += 0.3 * Math.sin(2 * Math.PI * (i - 2400) / 48);
    const extent = measurePCMExtent(pcm, RATE, []);
    expect(extent.startSample).toBeLessThanOrEqual(extent.firstSample);
    expect(extent.endSample).toBeGreaterThan(extent.lastSample);
  });
});
