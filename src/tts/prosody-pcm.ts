import type { WordBoundary } from "../socket-protocol";

export interface PCMUtterance { pcm: Float32Array; words: WordBoundary[]; pauseMs: number }
export interface PCMExtent {
  /** First and last sample above -42 dBFS (DC removed), widened to cover aligned words. */
  firstSample: number;
  lastSample: number;
  /** Trim bounds: 15 ms lead / 30 ms tail margins, snapped outward to a zero crossing. */
  startSample: number;
  endSample: number;
  /** Untrimmed silence before the first and after the last speech sample. */
  leadMs: number;
  tailMs: number;
}
export interface SpliceOptions {
  /** Silence after the last utterance, assuming the next chunk keeps its 15 ms lead margin. */
  trailingPauseMs?: number;
  /** Silence before the first utterance, completing a gap after a previous chunk's measured tail. */
  leadingPauseMs?: number;
  previousTailMs?: number;
}

const THRESHOLD = 10 ** (-42 / 20);
const samples = (ms: number, rate: number) => Math.round(ms * rate / 1000);

function removeDC(pcm: Float32Array): Float32Array {
  const out = pcm.slice();
  const mean = out.reduce((sum, x) => sum + x, 0) / (out.length || 1);
  for (let i = 0; i < out.length; i++) out[i] -= mean;
  return out;
}

function extentOf(pcm: Float32Array, rate: number, words: readonly WordBoundary[]): PCMExtent {
  let first = pcm.findIndex((x) => Math.abs(x) > THRESHOLD), last = pcm.length - 1;
  if (first < 0) first = 0;
  while (last > first && Math.abs(pcm[last]) <= THRESHOLD) last--;
  // Include timestamp extents too: never trim an aligned word's real tail.
  for (const word of words) {
    first = Math.max(0, Math.min(first, samples(word.offset_ms, rate)));
    last = Math.max(last, Math.min(pcm.length - 1, samples(word.offset_ms + word.duration_ms, rate) - 1));
  }
  const reach = samples(2, rate);
  // Snap outward only: the start never passes the onset, the end never cuts into the tail.
  let start = Math.max(0, first - samples(15, rate));
  for (let j = start; j >= Math.max(0, start - reach); j--) {
    if (j + 1 < pcm.length && pcm[j] * pcm[j + 1] <= 0) { start = j; break; }
  }
  let end = Math.min(pcm.length, last + 1 + samples(30, rate));
  for (let j = end; j <= Math.min(pcm.length - 1, end + reach); j++) {
    if (pcm[j - 1] * pcm[j] <= 0) { end = j; break; }
  }
  return { firstSample: first, lastSample: last, startSample: start, endSample: end,
    leadMs: first * 1000 / rate, tailMs: (pcm.length - last - 1) * 1000 / rate };
}

/** Speech extent of mono float PCM, e.g. a raw chunk played untrimmed whose tail the next chunk completes. */
export function measurePCMExtent(pcm: Float32Array, sampleRate: number, words: readonly WordBoundary[] = []): PCMExtent {
  return extentOf(removeDC(pcm), sampleRate, words);
}

/** Mono float PCM. All offsets are samples until publication; no rounded-ms accumulation. */
export function splicePCM(parts: PCMUtterance[], sampleRate: number, options: SpliceOptions = {}) {
  if (!Number.isInteger(sampleRate) || sampleRate <= 0) throw new Error("Invalid PCM sample rate");
  const { trailingPauseMs = 0, leadingPauseMs = 0, previousTailMs = 0 } = options;
  const at = (ms: number) => samples(ms, sampleRate);
  const prepared = parts.map((part) => {
    const pcm = removeDC(part.pcm);
    const { firstSample: first, lastSample: last, startSample: start, endSample: end } = extentOf(pcm, sampleRate, part.words);
    const trimmed = pcm.slice(start, end);
    for (const [length, reverse] of [[at(3), false], [at(5), true]] as const) {
      const n = Math.min(length, trimmed.length);
      for (let i = 0; i < n; i++) {
        const index = reverse ? trimmed.length - 1 - i : i;
        trimmed[index] *= (1 - Math.cos(Math.PI * i / Math.max(1, n - 1))) / 2;
      }
    }
    return { ...part, pcm: trimmed, start, lead: first - start, tail: end - last - 1 };
  });
  const buffers: Float32Array[] = [], words: WordBoundary[] = [];
  let offset = 0;
  if (leadingPauseMs > 0 && prepared.length) {
    const pad = Math.max(0, at(leadingPauseMs) - at(previousTailMs) - prepared[0].lead);
    buffers.push(new Float32Array(pad)); offset += pad;
  }
  for (const [i, part] of prepared.entries()) {
    buffers.push(part.pcm);
    for (const word of part.words) words.push({ ...word, offset_ms: word.offset_ms + (offset - part.start) * 1000 / sampleRate });
    offset += part.pcm.length;
    const next = prepared[i + 1];
    if (next || trailingPauseMs > 0) {
      const pad = Math.max(0, at(next ? part.pauseMs : trailingPauseMs) - part.tail - (next?.lead ?? at(15)));
      buffers.push(new Float32Array(pad)); offset += pad;
    }
  }
  const pcm = new Float32Array(offset);
  let cursor = 0;
  for (const buffer of buffers) { pcm.set(buffer, cursor); cursor += buffer.length; }
  return { pcm, words, durationMs: pcm.length * 1000 / sampleRate };
}
