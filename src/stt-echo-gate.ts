/** A bounded repeated suffix is removable only over independently quiet PCM.
 * Text alone never authorizes deletion. Missing/invalid/stale timings keep it.
 */
import { evaluateSilentSpan, findCandidateSpan, measureWavWindows, normalizeOutroKey,
  type OutroGateOptions } from "./stt-outro-gate";
import type { TranscriptSegment } from "./stt-transcript-alignment";

// Existing echo search bounds from stt.ts; these are not acoustic thresholds.
const MIN_WORDS = 3;
const MAX_WORDS = 10;
const LOOKBACK_WORDS = 18;

export interface EchoGateDecision {
  text: string;
  segments?: TranscriptSegment[];
  segmentsText?: string;
  reason: string;
  removedWords: number;
}

export function stripAudioUnsupportedEcho(
  text: string, wavData: Uint8Array, options: OutroGateOptions = {},
): EchoGateDecision {
  const keep = (reason: string): EchoGateDecision => ({ text, segments: options.segments,
    segmentsText: options.segmentsText, reason, removedWords: 0 });
  const segments = options.segments;
  if (!segments?.length || options.segmentsMatchAudio === false) return keep("no-segments");
  if ((options.segmentsText !== undefined && options.segmentsText !== text) ||
      normalizeOutroKey(text) !== normalizeOutroKey(segments.map(s => s.text).join(" "))) {
    return keep("segments-stale");
  }
  const windows = measureWavWindows(wavData);
  if (!windows) return keep("no-audio");
  let previousEnd = 0;
  for (const s of segments) {
    // Echo deletion has no out-of-file allowance. Never clamp an invalid span.
    if (!Number.isFinite(s.startS) || !Number.isFinite(s.endS) || s.startS < previousEnd ||
        s.endS <= s.startS || s.endS > windows.durationSeconds) return keep("invalid-segments");
    previousEnd = s.endS;
  }
  const words = [...text.matchAll(/\S+/gu)];
  const wordKey = (word: string) => word.toLowerCase()
    .replace(/^[.,?;:"'`()\[\]{}«»…]+/gu, "")
    .replace(/[.,!?;:"'`()\[\]{}«»…]+$/gu, "");
  const key = (ws: RegExpMatchArray[]) => ws.map(w => wordKey(w[0]) || w[0].toLowerCase()).join(" ");
  // Never fold an ellipsis/cut-off into an ordinary word match.
  const fragment = (ws: RegExpMatchArray[]) => ws.some(w => /…|\.{2,}|[\p{L}\p{N}][-–—](?:[.,!?])?$/u.test(w[0]));
  let reason = "no-candidate";
  for (let count = Math.min(MAX_WORDS, Math.floor(words.length / 2)); count >= MIN_WORDS; count--) {
    const at = words.length - count, suffix = words.slice(at);
    if (fragment(suffix)) continue;
    const suffixKey = key(suffix);
    let found = false;
    for (let i = at - count; i >= Math.max(0, at - LOOKBACK_WORDS); i--) {
      const earlier = words.slice(i, i + count);
      if (!fragment(earlier) && key(earlier) === suffixKey) { found = true; break; }
    }
    if (!found) continue;
    const startIndex = suffix[0]!.index!;
    const span = findCandidateSpan(segments, { phrase: text.slice(startIndex),
      key: normalizeOutroKey(text.slice(startIndex)), startIndex, endIndex: text.length, isTail: true }, text);
    if (!span) { reason = "segment-not-found"; continue; }
    const acoustic = evaluateSilentSpan(windows, span.startS, span.endS, true);
    reason = acoustic.reason;
    if (reason !== "removed") continue;
    const prefix = text.slice(0, startIndex).trimEnd();
    // Keep timings only if the cut is exactly on a segment boundary. A cut
    // inside a segment cannot allocate time to the surviving words safely.
    let retained: TranscriptSegment[] | undefined;
    for (let n = segments.length - 1; n > 0; n--) {
      const candidate = segments.slice(0, n);
      if (normalizeOutroKey(candidate.map(s => s.text).join(" ")) === normalizeOutroKey(prefix)) {
        retained = candidate; break;
      }
    }
    return { text: prefix, segments: retained, segmentsText: retained ? prefix : undefined,
      reason: "removed", removedWords: count };
  }
  return keep(reason);
}
