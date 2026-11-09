/** Bounded alternate decodes may insert words; they never replace native text. */
import { z } from "zod";
import type { ParakeetResponse } from "./parakeet-server";

export interface SpeechGap { start: number; end: number; }
interface Word { key: string; start: number; end: number; }
const WORDS = /[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*/gu;
function words(text: string): Word[] {
  return [...text.matchAll(WORDS)].map(m => ({ key: m[0].toLowerCase(), start: m.index, end: m.index + m[0].length }));
}
const tokensSchema = z.array(z.object({ start: z.number().finite().nonnegative(), end: z.number().finite().nonnegative(), text: z.string() })
  .refine(t => t.end >= t.start));
export interface SpanRepair {
  gap: SpeechGap;
  start: number;
  end: number;
  offset: number;
  left: string[];
  right: string[];
}

/** Exact text reconstruction binds token times to character positions. */
export function planSpanRepairs(native: ParakeetResponse, gaps: SpeechGap[], duration: number): SpanRepair[] {
  const parsed = tokensSchema.safeParse(native.raw_token_times);
  if (!parsed.success || parsed.data.some((t, i, all) => t.end > duration || (i > 0 && t.start < all[i - 1]!.start))) return [];
  const joined = parsed.data.map(t => t.text).join("");
  if (joined.trim() !== native.text) return [];
  let position = -(joined.length - joined.trimStart().length);
  const tokens = parsed.data.map(t => {
    const from = position; position += t.text.length; return { ...t, from, to: position };
  });
  const timedWords = words(native.text).map(w => {
    const covered = tokens.filter(t => t.to > w.start && t.from < w.end);
    return { ...w, startS: Math.min(...covered.map(t => t.start)), endS: Math.max(...covered.map(t => t.end)) };
  });
  return gaps.flatMap(gap => {
    const next = tokens.findIndex(t => t.start >= gap.end);
    const tail = next < 0;
    const previous = tail ? tokens.at(-1) : tokens[next - 1];
    if (!previous || previous.end > gap.start) return [];
    const offset = tail ? native.text.length : previous.to;
    // A hole inside a subword is not an unambiguous insertion boundary.
    if (!tail && !/\s/u.test(native.text[offset] ?? "")) return [];
    const left = timedWords.filter(w => w.end <= offset && w.startS >= gap.start - 2).slice(-2);
    const right = tail ? [] : timedWords.filter(w => w.start >= offset && w.endS <= gap.end + 2).slice(0, 2);
    if (!left.length || (!tail && !right.length)) return [];
    return [{ gap, offset, start: Math.max(0, gap.start - 2, left[0]!.startS - .16),
      end: Math.min(duration, gap.end + 2, tail ? gap.end + .25 : right.at(-1)!.endS + .16),
      left: left.map(w => w.key), right: right.map(w => w.key) }];
  }).sort((a, b) => b.offset - a.offset);
}

/** First ten retained nonincident W hypotheses: max six-gram count <=5,
 * <=2.91 lexical words/speech second. Conservative limits reject the alternate whole;
 * they never deduplicate repetitions or delete any native word. */
export function fallbackOutputRisk(candidate: string, speechSeconds?: number): string | null {
  const ws = words(candidate), counts = new Map<string, number>();
  for (let i = 0; i + 6 <= ws.length; i++) {
    const key = ws.slice(i, i + 6).map(w => w.key).join(" ");
    const count = (counts.get(key) ?? 0) + 1; counts.set(key, count);
    if (count > 5) return "repeated-six-gram";
  }
  if (speechSeconds !== undefined && ws.length > Math.max(12, speechSeconds * 8)) return "implausible-word-rate";
  return null;
}

export function qualifySpanRepair(candidate: string, plan: SpanRepair, speechSeconds: number):
  { accepted: true; insertion: string } | { accepted: false; reason: string } {
  const risk = fallbackOutputRisk(candidate, speechSeconds);
  if (risk) return { accepted: false, reason: risk };
  const ws = words(candidate);
  const matches = (anchor: string[], positions: number[]) => positions.filter(at => at >= 0 &&
    at + anchor.length <= ws.length && anchor.every((key, i) => ws[at + i]?.key === key));
  const left = matches(plan.left, [0, 1]);
  const right = plan.right.length ? matches(plan.right, [ws.length - plan.right.length - 1, ws.length - plan.right.length]) : [ws.length];
  if (left.length !== 1 || right.length !== 1) return { accepted: false, reason: "unmatched-context" };
  const leftEnd = left[0]! + plan.left.length, rightStart = right[0]!;
  if (leftEnd > rightStart) return { accepted: false, reason: "overlapping-context" };
  // Only interior words qualify; one outer neighbour on either edge is context.
  const insertion = leftEnd === rightStart ? "" :
    candidate.slice(ws[leftEnd - 1]!.end, plan.right.length ? ws[rightStart]!.start : undefined).trim();
  return { accepted: true, insertion };
}

/** Canonical clip header; every selected PCM sample is copied unchanged. */
export function spanWav(bytes: Uint8Array, dataOffset: number, plan: SpanRepair, sampleRate: number): Uint8Array {
  if (sampleRate !== 16000) throw new RangeError("Unsupported Parakeet clip sample rate");
  const start = Math.floor(plan.start * sampleRate), end = Math.ceil(plan.end * sampleRate);
  const pcm = bytes.subarray(dataOffset + start * 2, dataOffset + end * 2), wav = Buffer.alloc(44 + pcm.length);
  wav.write("RIFF"); wav.writeUInt32LE(wav.length - 8, 4); wav.write("WAVEfmt ", 8);
  wav.writeUInt32LE(16, 16); wav.writeUInt16LE(1, 20); wav.writeUInt16LE(1, 22);
  wav.writeUInt32LE(sampleRate, 24); wav.writeUInt32LE(sampleRate * 2, 28); wav.writeUInt16LE(2, 32); wav.writeUInt16LE(16, 34);
  wav.write("data", 36); wav.writeUInt32LE(pcm.length, 40); wav.set(pcm, 44); return wav;
}
