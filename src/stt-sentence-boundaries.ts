/**
 * Pause-aware sentence boundaries — a period only where Etan actually stopped.
 *
 * Etan, 2026-09-06: "I might pause to think and then continue and finish the
 * sentence sometimes." A sentence boundary may be placed ONLY where a pause AND
 * a grammatically complete clause coincide. A pause inside an incomplete clause
 * must never insert or move a period, and a pause is not a period by itself.
 *
 * The regression this closes (recording `2026-09-06T12-56-44-855Z-28f3916c`):
 * he said "...i'm thinking [2.3 s pause] of the next couple of words i guess
 * [2.7 s pause] like i just did now". Polish put the period BEFORE "I guess",
 * where he never stopped. The pause is after "guess".
 *
 * This module only ever DEMOTES a terminal mark to a comma. It never inserts a
 * boundary the text did not already have, never deletes a word, and never
 * reorders anything: a fix that loses Etan's words is worse than the bug
 * (AGENTS.md).
 *
 * AIDEV-NOTE: alignment does NOT use whisper's per-word timestamps. Measured on
 * the gold above, whisper claims "for some reason just killed" spans 5.41-7.65 s
 * while raw RMS energy over that window is -60..-66 dB — silent. Whisper
 * interpolates words across silence, and `-dtw large.v3.turbo` changes nothing.
 * Whisper's SEGMENT ends, by contrast, land within ~0.15 s of the real pauses
 * (30.02 vs 30.11, 35.54 vs 35.68, 39.54 vs 39.68). So we trust segment ends and
 * the Silero pause map, and place words inside a segment by splitting them
 * across that segment's speech runs in proportion to run duration. That
 * reproduces the true boundaries — it puts "workers working on" exactly on the
 * 15.07 s pause.
 */

import type { PauseSpan } from "./stt-pause-map";

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

/** A terminal mark this stage turned into a comma, for the shadow row. */
export interface BoundaryDemotion {
  /** Zero-based index, over the final text's words, of the word it followed. */
  wordIndex: number;
  /** The word the mark followed, as it appears in the final text. */
  word: string;
  mark: string;
  reason: "no-pause" | "incomplete-clause";
}

export interface PauseAwareBoundaryResult {
  text: string;
  demotions: BoundaryDemotion[];
  /** Set when the stage declined to act; `text` is then the input verbatim. */
  skippedReason?: string;
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
 * Words that cannot END a complete clause. Ratified list (brief, 2026-09-06):
 * conjunctions, prepositions, determiners, auxiliaries and subject pronouns.
 * Deliberately small and closed — this is a cheap deterministic check, not a
 * parser, and every word added to it demotes more of Etan's periods.
 */
const INCOMPLETE_CLAUSE_ENDINGS = new Set([
  "and",
  "or",
  "but",
  "so",
  "because",
  "that",
  "which",
  "to",
  "of",
  "for",
  "with",
  "the",
  "a",
  "an",
  "i",
  "i'm",
  "you",
  "we",
  "they",
  "is",
  "are",
  "was",
  "were",
  "like",
  "just",
  "then",
  "if",
  "when",
]);

/** Terminal marks a sentence can end on. */
const TERMINAL_MARKS = new Set([".", "?", "!"]);

const WORD_PATTERN = /[\p{L}\p{N}'’]+/gu;

interface TextWord {
  value: string;
  start: number;
  end: number;
}

function normalizeWord(word: string): string {
  return word.toLowerCase().replace(/[’]/g, "'");
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
 * True when a clause ending on `word` can stand as a sentence.
 *
 * Ends-with test only, by design: the brief's condition (b). A clause ending in
 * a conjunction, preposition, determiner, auxiliary or subject pronoun is still
 * mid-thought however long a pause follows it.
 */
export function isCompleteClauseEnding(word: string): boolean {
  const normalized = normalizeWord(word);
  if (!normalized) return false;
  return !INCOMPLETE_CLAUSE_ENDINGS.has(normalized);
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

/**
 * Words this stage must not lowercase when it demotes the mark before them:
 * "I" and its contractions are capitalised mid-sentence too.
 */
const ALWAYS_CAPITALISED = /^i(?:$|['’])/i;

/**
 * Proper nouns, as evidenced by the text itself: a word that appears capitalised
 * somewhere that is NOT the start of a sentence is a name, not a sentence start.
 * Keeps "VoiceLayer" and "CodeRabbit" capitalised after a demoted mark.
 */
function properNounsIn(text: string, words: TextWord[]): Set<string> {
  const names = new Set<string>();
  for (let index = 0; index < words.length; index++) {
    const word = words[index];
    if (!/^\p{Lu}/u.test(word.value)) continue;
    if (/^\p{Lu}+$/u.test(word.value) || /\p{Lu}.*\p{Lu}/u.test(word.value)) {
      names.add(normalizeWord(word.value));
      continue;
    }
    const before = text.slice(0, word.start);
    if (index > 0 && !/[.!?]['"”’)\]]*\s*$/u.test(before)) {
      names.add(normalizeWord(word.value));
    }
  }
  return names;
}

export interface PauseAwareBoundaryOptions {
  minPauseSeconds?: number;
  toleranceSeconds?: number;
}

/**
 * Validate the sentence breaks in `text` against where Etan actually stopped.
 *
 * Every terminal mark is kept unless BOTH of the ratified conditions fail it:
 * (a) a qualifying pause begins at that word, and (b) the clause it closes is
 * complete. A failing mark becomes a comma. The final mark of the text is never
 * touched, nor is an ellipsis — a cut-off fragment keeps its "fu…".
 *
 * Returns the input verbatim (with `skippedReason`) whenever the evidence is not
 * good enough to judge, which is the documented "leave today's behaviour alone"
 * answer.
 */
export function applyPauseAwareBoundaries(
  text: string,
  segments: TranscriptSegment[],
  pauses: PauseSpan[],
  options: PauseAwareBoundaryOptions = {},
): PauseAwareBoundaryResult {
  if (!text.trim()) return { text, demotions: [], skippedReason: "empty text" };
  if (segments.length === 0) {
    return { text, demotions: [], skippedReason: "no segments" };
  }
  if (pauses.length === 0) {
    return { text, demotions: [], skippedReason: "no pause map" };
  }

  const finalWords = tokenizeWords(text);
  if (finalWords.length === 0) {
    return { text, demotions: [], skippedReason: "no words" };
  }

  const rawWords = segments.flatMap((segment) => tokenizeWords(segment.text));
  const alignment = alignWords(
    finalWords.map((word) => normalizeWord(word.value)),
    rawWords.map((word) => normalizeWord(word.value)),
    MAX_BOUNDARY_ALIGNMENT_CELLS,
  );
  if (alignment.size === 0) {
    return {
      text,
      demotions: [],
      skippedReason: "could not align to segments",
    };
  }

  const supported = pauseSupportedWordIndices(segments, pauses, options);
  const properNouns = properNounsIn(text, finalWords);

  const demotions: BoundaryDemotion[] = [];
  const edits: Array<{ start: number; end: number; replacement: string }> = [];

  for (let index = 0; index < finalWords.length - 1; index++) {
    const word = finalWords[index];
    const next = finalWords[index + 1];
    const between = text.slice(word.end, next.start);

    // Only a lone terminal mark directly after the word is ours. An ellipsis is
    // Etan's cut-off fragment and stays exactly as it is.
    const match = /^([.!?])(\s+)$/u.exec(between);
    if (!match) continue;
    const [, mark, gap] = match;
    if (!TERMINAL_MARKS.has(mark)) continue;

    const rawIndex = alignment.get(index);
    if (rawIndex === undefined) continue; // no timing for this word — leave it.

    const hasPause = supported.has(rawIndex);
    const complete = isCompleteClauseEnding(word.value);
    if (hasPause && complete) continue;

    const nextValue = ALWAYS_CAPITALISED.test(next.value)
      ? next.value
      : properNouns.has(normalizeWord(next.value))
        ? next.value
        : next.value.charAt(0).toLowerCase() + next.value.slice(1);

    edits.push({
      start: word.end,
      end: next.end,
      replacement: `,${gap}${nextValue}`,
    });
    demotions.push({
      wordIndex: index,
      word: word.value,
      mark,
      reason: hasPause ? "incomplete-clause" : "no-pause",
    });
  }

  if (edits.length === 0) return { text, demotions: [] };

  let out = "";
  let cursor = 0;
  for (const edit of edits) {
    out += text.slice(cursor, edit.start) + edit.replacement;
    cursor = edit.end;
  }
  out += text.slice(cursor);

  return { text: out, demotions };
}

/** `VOICELAYER_STT_SMART_BOUNDARIES=1` opts in. Anything else stays off. */
export function smartBoundariesEnabled(env: {
  [key: string]: string | undefined;
  VOICELAYER_STT_SMART_BOUNDARIES?: string;
}): boolean {
  const raw = env.VOICELAYER_STT_SMART_BOUNDARIES?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "on" || raw === "yes";
}
