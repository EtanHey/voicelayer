/**
 * Transcript-to-audio alignment shared by the pause-aware text stages.
 *
 * Pause paragraphs (`src/stt-paragraphs.ts`) and the terminal-punctuation floor
 * (`src/stt-punctuation.ts`) read whisper segments, the Silero pause map and a
 * few clause heuristics from here. Nothing in this module rewrites text.
 *
 * AIDEV-NOTE: alignment does NOT use whisper's per-word timestamps. Measured on
 * recording `2026-09-06T12-56-44-855Z-28f3916c`, whisper claims "for some
 * reason just killed" spans 5.41-7.65 s while raw RMS energy over that window
 * is -60..-66 dB — silent. Whisper interpolates words across silence, and
 * `-dtw large.v3.turbo` changes nothing. Whisper's SEGMENT ends, by contrast,
 * land within ~0.15 s of the real pauses (30.02 vs 30.11, 35.54 vs 35.68,
 * 39.54 vs 39.68). So we trust segment ends and the Silero pause map, and place
 * words inside a segment by splitting them across that segment's speech runs in
 * proportion to run duration.
 */

import type { PauseSpan } from "./stt-pause-map";
import { TERMINAL_PERIOD_ABBREVIATIONS } from "./rules-engine";

/** One whisper segment: its text and where it sits in the recording. */
export interface TranscriptSegment {
  text: string;
  startS: number;
  endS: number;
}

/** A stretch of continuous speech between two pauses. */
export interface SpeechRun {
  startS: number;
  endS: number;
}

/** A pause shorter than this is breath, not a stop Etan meant. */
export const MIN_BOUNDARY_PAUSE_SECONDS = 0.4;

/** How far a segment end may sit from a pause and still count as that pause. */
export const BOUNDARY_PAUSE_TOLERANCE_SECONDS = 0.3;

/**
 * How many words of slack the word<->time estimate gets. Words are placed by
 * splitting a segment across its speech runs in proportion to duration, which
 * is accurate to about one word; this is that error bar, not a policy choice.
 */
export const WORD_ALIGNMENT_TOLERANCE = 1;

/**
 * Openers that attach BACKWARDS — they finish the clause before them instead of
 * starting a new one. This is the discriminator Rule B turns on.
 *
 * Etan, 2026-09-06 17:32, choosing Rule B over the literal rule: "B, its more
 * about subject/sentence building, this isnt inventing anything." A mark with no
 * pause under it is fine as long as what follows really does start a new
 * subject; it is wrong only when the next words carry on the same clause. In the
 * gold he said "...of the next couple of words i guess" — "I guess" is a tag on
 * that clause, not a new sentence, so the period before it goes. Two words later
 * "It might have been..." IS a new subject, so that period stays.
 */
const CONTINUATION_OPENER_PHRASES = [
  "i guess",
  "i think",
  "i mean",
  "i suppose",
  "i believe",
  "i hope",
  "you know",
  "you see",
  "or something",
  "or anything",
  "or whatever",
  "or so",
  "kind of",
  "sort of",
  "more or less",
].map((phrase) => phrase.split(" "));

/** Single words that cannot open a sentence at all. */
const CONTINUATION_OPENER_WORDS = new Set([
  "of",
  "for",
  "with",
  "than",
  "which",
  "nor",
  "whom",
  "whose",
]);

/**
 * The token ending at `end`, including any internal periods — "e.g.", "U.S.",
 * "Dr." — so an abbreviation can be recognised. `tokenizeWords` splits on the
 * periods, so the plain word before the mark is not enough on its own.
 */
function abbreviationCandidate(text: string, end: number): string {
  const match = /[\p{L}\p{N}.]+$/u.exec(text.slice(0, end));
  if (!match) return "";
  return match[0].replace(/\.+$/u, "").normalize("NFC").toLowerCase();
}

/**
 * True when the period at `end` is part of an abbreviation rather than the end
 * of a sentence. Treating "Dr." as a sentence end would corrupt the word, so
 * callers never touch these (Macroscope round 1). The set is shared with
 * `src/rules-engine.ts` so the two stages cannot drift apart.
 */
export function endsWithAbbreviation(text: string, end: number): boolean {
  const candidate = abbreviationCandidate(text, end);
  if (!candidate) return false;
  if (TERMINAL_PERIOD_ABBREVIATIONS.has(candidate)) return true;
  // Dotted initialisms: U.S., a.m., Ph.D already covered above.
  return /^(?:\p{L}\.)+\p{L}$/u.test(candidate);
}

/**
 * `\p{M}` keeps a DECOMPOSED grapheme together: "é" written as e + U+0301 would
 * otherwise split into two words. Matching the marks instead of NFC-normalising
 * the whole input keeps every word offset pointing into the caller's original
 * text (Macroscope round 1).
 */
const WORD_PATTERN = /[\p{L}\p{N}\p{M}'’]+/gu;

interface TextWord {
  value: string;
  start: number;
  end: number;
}

function normalizeWord(word: string): string {
  // NFC first: a decomposed "é" is L + combining mark, and the combining mark
  // is not in WORD_PATTERN, so the word would otherwise split in two.
  return word.normalize("NFC").toLowerCase().replace(/[’]/g, "'");
}

function tokenizeWords(text: string): TextWord[] {
  const words: TextWord[] = [];
  for (const match of text.matchAll(WORD_PATTERN)) {
    if (match.index === undefined) continue;
    words.push({
      value: match[0],
      start: match.index,
      end: match.index + match[0].length,
    });
  }
  return words;
}

/**
 * True when the words starting at `index` carry on the clause before them
 * rather than opening a new one — Rule B's operative test.
 *
 * Positive evidence only. Anything this does not recognise as a continuation is
 * treated as a new subject and its mark is KEPT, because the failure this rule
 * exists to correct is over-demotion: applied literally, the pause-only rule
 * demoted ~177 marks across 56 of the 86 recon clips, most of them sentences
 * Etan really did mean to end.
 */
export function continuesSameClause(words: string[], index: number): boolean {
  if (index >= words.length) return false;
  const normalized = words.slice(index).map(normalizeWord);
  if (CONTINUATION_OPENER_WORDS.has(normalized[0])) return true;
  return CONTINUATION_OPENER_PHRASES.some((phrase) =>
    phrase.every((word, offset) => normalized[offset] === word),
  );
}

/**
 * The stretches of speech inside `[startS, endS]`, i.e. the window minus every
 * pause that overlaps it. Pure; `pauses` need not be sorted.
 */
export function speechRunsWithin(
  pauses: PauseSpan[],
  startS: number,
  endS: number,
): SpeechRun[] {
  if (!(endS > startS)) return [];
  const overlapping = pauses
    .filter((pause) => pause.endS > startS && pause.startS < endS)
    .sort((left, right) => left.startS - right.startS);

  const runs: SpeechRun[] = [];
  let cursor = startS;
  for (const pause of overlapping) {
    const pauseStart = Math.max(pause.startS, startS);
    if (pauseStart > cursor) runs.push({ startS: cursor, endS: pauseStart });
    cursor = Math.max(cursor, Math.min(pause.endS, endS));
  }
  if (cursor < endS) runs.push({ startS: cursor, endS });
  return runs;
}

/**
 * True when a real stop begins at `timeS` — a pause of at least
 * `MIN_BOUNDARY_PAUSE_SECONDS` starting within the tolerance of it.
 */
export function pauseStartsAt(
  pauses: PauseSpan[],
  timeS: number,
  minPauseSeconds = MIN_BOUNDARY_PAUSE_SECONDS,
  toleranceSeconds = BOUNDARY_PAUSE_TOLERANCE_SECONDS,
): boolean {
  // Both bounds are inclusive, with a float guard: pause times come from
  // sample-count division, so a boundary that is exactly at the tolerance can
  // land a few ULPs the wrong side of it.
  const epsilon = 1e-9;
  return pauses.some(
    (pause) =>
      pause.endS - pause.startS >= minPauseSeconds - epsilon &&
      Math.abs(pause.startS - timeS) <= toleranceSeconds + epsilon,
  );
}

/**
 * The word indices, over the concatenated segment words, that a pause follows.
 *
 * Within each segment the words are split across that segment's speech runs in
 * proportion to run duration, and the last word of a run is marked whenever a
 * qualifying pause begins at that run's end. A segment whose end is not a pause
 * (whisper split mid-speech) contributes no mark for its last word, so a break
 * there is treated as unsupported rather than assumed good.
 */
export function pauseSupportedWordIndices(
  segments: TranscriptSegment[],
  pauses: PauseSpan[],
  options: { minPauseSeconds?: number; toleranceSeconds?: number } = {},
): Set<number> {
  const minPauseSeconds = options.minPauseSeconds ?? MIN_BOUNDARY_PAUSE_SECONDS;
  const toleranceSeconds =
    options.toleranceSeconds ?? BOUNDARY_PAUSE_TOLERANCE_SECONDS;

  const supported = new Set<number>();
  let offset = 0;

  for (const segment of segments) {
    const words = tokenizeWords(segment.text);
    if (words.length === 0) continue;

    const runs = speechRunsWithin(pauses, segment.startS, segment.endS);
    const totalSpeech = runs.reduce(
      (sum, run) => sum + (run.endS - run.startS),
      0,
    );

    if (runs.length > 0 && totalSpeech > 0) {
      let elapsed = 0;
      let cursor = 0;
      for (const run of runs) {
        elapsed += run.endS - run.startS;
        const boundary = Math.round((elapsed / totalSpeech) * words.length);
        const lastIndex = Math.min(boundary, words.length) - 1;
        if (
          lastIndex >= cursor &&
          pauseStartsAt(pauses, run.endS, minPauseSeconds, toleranceSeconds)
        ) {
          // Proportional allocation places a run's last word to about +/-1 word:
          // speech rate is not constant inside a run. Marking the neighbours as
          // supported too is how the ratified rule ("a pause at this boundary")
          // is honestly applied through an estimator with that much noise —
          // without it, every off-by-one demotes a period Etan really did stop
          // on. Measured over the 86 recon clips it takes demotions from ~202
          // to ~177 (whisper decoding varies a little run to run), and it does
          // NOT save the gold's wrong period, which sits 2 words from its run
          // end. The remaining 177 are not estimator noise — they are places
          // Etan genuinely did not pause. That count is the open question for
          // him, not something this tolerance can tune away.
          for (
            let offsetIndex = -WORD_ALIGNMENT_TOLERANCE;
            offsetIndex <= WORD_ALIGNMENT_TOLERANCE;
            offsetIndex++
          ) {
            const candidate = lastIndex + offsetIndex;
            if (candidate >= 0 && candidate < words.length) {
              supported.add(offset + candidate);
            }
          }
        }
        cursor = Math.max(cursor, Math.min(boundary, words.length));
      }
    }

    offset += words.length;
  }

  return supported;
}

/**
 * Longest-common-subsequence alignment between two word lists.
 *
 * Polish rewrites words ("1" -> "one"), so the final text's word sequence is not
 * always the raw one. Only positions that actually match are returned; a final
 * word with no match is one we have no timing for, and the caller leaves its
 * boundary alone.
 *
 * AIDEV-NOTE: known limitation (Macroscope round 1, finding 7). With a repeated
 * word the LCS backtrack can anchor a position to a different occurrence than
 * the one a human would pick. The alignment stays MONOTONIC either way, so a
 * mis-anchor moves a mark's timing by a word or two — which the +/-1 word
 * tolerance already absorbs — rather than mixing up the order. Fixing it
 * properly needs a positional tie-break through the whole DP table; it is not
 * worth that until a real transcript is seen to break on it. See the `.todo`
 * case in `stt-transcript-alignment.test.ts`.
 */
function alignWords(
  finalWords: string[],
  rawWords: string[],
  maxCells: number,
): Map<number, number> {
  const aligned = new Map<number, number>();
  if (finalWords.length === 0 || rawWords.length === 0) return aligned;
  if ((finalWords.length + 1) * (rawWords.length + 1) > maxCells)
    return aligned;

  const lengths = Array.from(
    { length: finalWords.length + 1 },
    () => new Uint32Array(rawWords.length + 1),
  );
  for (let f = 1; f <= finalWords.length; f++) {
    for (let r = 1; r <= rawWords.length; r++) {
      lengths[f][r] =
        finalWords[f - 1] === rawWords[r - 1]
          ? lengths[f - 1][r - 1] + 1
          : Math.max(lengths[f - 1][r], lengths[f][r - 1]);
    }
  }

  let f = finalWords.length;
  let r = rawWords.length;
  while (f > 0 && r > 0) {
    if (finalWords[f - 1] === rawWords[r - 1]) {
      aligned.set(f - 1, r - 1);
      f--;
      r--;
    } else if (lengths[f - 1][r] > lengths[f][r - 1]) {
      f--;
    } else {
      r--;
    }
  }
  return aligned;
}

/** Cap on the alignment table, mirroring `stt-polish.ts`'s projection cap. */
const MAX_BOUNDARY_ALIGNMENT_CELLS = 1_000_000;

/** Shared bounded word alignment for whitespace-only pause paragraphing. */
export function alignTranscriptWordIndices(
  text: string,
  segments: TranscriptSegment[],
  onCellLimit?: (cells: number, limit: number) => void,
): Map<number, number> {
  const finalWords = tokenizeWords(text).map(w => normalizeWord(w.value));
  const rawWords = segments.flatMap(s => tokenizeWords(s.text).map(w => normalizeWord(w.value)));
  const cells = (finalWords.length + 1) * (rawWords.length + 1);
  if (cells > MAX_BOUNDARY_ALIGNMENT_CELLS) {
    onCellLimit?.(cells, MAX_BOUNDARY_ALIGNMENT_CELLS);
    return new Map();
  }
  return alignWords(finalWords, rawWords, MAX_BOUNDARY_ALIGNMENT_CELLS);
}

