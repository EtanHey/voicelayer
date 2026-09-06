/**
 * The hallucinated-closer gate.
 *
 * Whisper welds a short farewell into a recording wherever the audio goes
 * quiet — `Thank you.`, `Okay.`, `You.`, `and.`, `So, so, so, so, so.`,
 * `תודה.`, `תודה רבה.` It is the single largest source of Etan's #1 complaint
 * ("words get added that I never said"): 15 of the 17 word-added edits in the
 * 2026-09-06 correction corpus are 1-5 invented tokens welded to the tail, and
 * two `voice_ask` clips from the same afternoon show the same phrase appearing
 * in Hebrew and at an INTERNAL pause, between two real sentences.
 *
 * The law this module is written under (AGENTS.md): **never lose a real word.**
 * A previous attempt at the tail fixed one bug by trimming and cut real tails
 * off his sentences. So a sentence is removed only when all of this holds:
 *
 *   (a) it is a complete sentence drawn entirely from the known-hallucination
 *       lexicon — never a fragment, never an ellipsis, never a substring;
 *   (b) the audio region whisper itself attributes to it carries no sustained
 *       speech — measured against that recording's own noise floor, not
 *       guessed from the text and not compared to a fixed dB line;
 *   (c) the silence extends clear of that region on both sides, so no word
 *       Etan spoke is anywhere within what we delete.
 *
 * (c) is what makes the rule work at an INTERNAL pause as well as at the tail:
 * the phrase has to sit inside a pause, not merely somewhere quiet.
 *
 * (b) and (c) need whisper's segment timestamps, so the gate is inert without
 * them. That is deliberate, and it is why the brief's no-segments fallback
 * ("measure the last N ms of the WAV") is NOT implemented: a VAD recording
 * stops *because* it went quiet, so its last N ms are silent in every single
 * recording — a genuinely spoken "Thank you." would measure exactly like a
 * hallucinated one and get deleted. Segment ends are the trustworthy field
 * here (to ~0.15 s; see the AIDEV-NOTE on `WhisperServerTranscribeOptions`),
 * and they are what separates the two cases.
 *
 * AIDEV-NOTE: this is NOT the duplication fix and NOT the retraction rule.
 * Etan ratified "raw accurate" — a retraction stays, a cut-off word keeps its
 * ellipsis. Nothing here may start trimming for tidiness.
 */

import { parseWavAudioInfo, WAVE_FORMAT_PCM } from "./stt-pause-map";
import type { TranscriptSegment } from "./stt-sentence-boundaries";

/**
 * How far over its own noise floor a window must read to count as speech.
 *
 * The brief proposed a fixed -45 dBFS silence ceiling, drawn from the first
 * specimen (`2026-09-06T14-45-42-649Z-25ed3b89`: the invented `Thank you.` span
 * reads RMS 45-124 against a 31.9 floor, i.e. -57 to -48 dBFS, while real
 * speech there runs 1200-9700, about -29 dBFS). That line does not survive the
 * other specimens. Measured floors across the four range from -60.0 dBFS to
 * -53.2 dBFS, and the -53.2 clip (`…ac389f08`, the "Okay." tail) carries breath
 * and click windows up to -43.7 dBFS *inside its silence* — a fixed -45 would
 * have refused to gate it at all.
 *
 * So the line is drawn relative to each recording's own floor. Measured across
 * the four: the loudest window inside a silence run sits about +14 dB over its
 * clip's floor, the quietest real speech at least +22 dB. +16 dB splits them.
 */
const SPEECH_OVER_FLOOR_DB = 16;

/**
 * Floor on the relative threshold, for a recording whose measured floor is
 * digital silence — without it the threshold would sit at -Infinity.
 *
 * There is deliberately NO upper clamp. One was here (-35 dBFS) and Macroscope
 * was right to call it a real-word-deletion risk on PR #34: a low-gain
 * recording whose speech sits near -42 dBFS over a -48 dBFS floor would have
 * had its threshold clamped to -35, scoring its own speech as silence, so
 * `containsSustainedSpeech` protected nothing and a REAL closer was deletable.
 *
 * The clamp existed to stop a wall-to-wall-speech recording — one whose 10th
 * percentile is measured INSIDE speech — pushing the threshold up above real
 * words. `SPEECH_LEVEL_GUARD_DB` now covers that case directly and correctly,
 * by comparing the span against how loud this recording's speech actually is
 * rather than against a fixed line.
 */
const SPEECH_THRESHOLD_MIN_DBFS = -50;

/**
 * A span is never deleted when its peak comes within this many dB of the
 * recording's own measured speech level (`speechLevelDbfs`).
 *
 * This is the backstop that lets the upper clamp go. It asks the question the
 * fixed threshold could not: not "is this quiet in absolute terms" but "is this
 * as loud as this speaker's speech". On the RED specimens the invented spans
 * sit 15-30 dB under their clip's speech level, so 6 dB is a wide moat.
 */
const SPEECH_LEVEL_GUARD_DB = 6;

/** Consecutive over-threshold audio that counts as a word rather than a click. */
const MIN_SPEECH_RUN_SECONDS = 0.06;

/** RMS window. 20 ms is short enough to catch a single quiet syllable. */
const WINDOW_SECONDS = 0.02;

/**
 * How far clear of the surrounding speech a span must sit.
 *
 * Segment ends are accurate to about 0.15 s, so a real word's segment can jitter
 * this far into the pause beside it. Requiring the silence run to extend at
 * least this much past the span on BOTH sides is what stops the gate deleting a
 * real word whose timestamp drifted — the failure mode Finding 4 of the
 * 2026-09-06 acceptance audit documented.
 */
const SILENCE_MARGIN_SECONDS = 0.15;

/**
 * The same clearance, for a phrase in the MIDDLE of a transcript.
 *
 * Wider, because the corpus says a trailing closer and an internal one are not
 * equally suspect. At the tail, invention is the norm: 15 of 17 word-added rows
 * and all four RED specimens. Internally it is the opposite — every internal
 * `Thank you.` the corpus flags (`…a28eab5f`, `…bc42f7f7`, `…ba12d56e`) is one
 * Etan KEPT, thanking an agent mid-dictation. `…bc42f7f7` is the pair in one
 * row: he kept the internal `Thank you.` and deleted the trailing `Okay.`
 *
 * Condition (b) is what actually saves those three — he said them, so there is
 * speech under them — but when the prior says "probably real", the timestamp
 * jitter allowance should be the generous one.
 */
const INTERNAL_SILENCE_MARGIN_SECONDS = 0.3;

/** Longest sentence the gate will look at. The corpus tops out at 5 (`So, so, so, so, so.`). */
const MAX_OUTRO_WORDS = 5;

/** Most removals attempted on one transcript, so a pathological input terminates. */
const MAX_REMOVALS = 4;

/**
 * Complete phrases whisper invents over silence. Matched on the whole
 * normalized sentence, never on a substring — "thank you for the review" is not
 * here, and a sentence merely *containing* one of these is never a candidate.
 *
 * Hebrew is in the same set on Etan's ruling (brief ADDENDUM, 2026-09-06
 * 18:35): `2026-09-06T15-16-33-682Z-ff770b47` ends `תודה.` he never said, and
 * `2026-09-06T15-20-11-471Z-a6aa28aa` carries `תודה רבה.` at an internal pause.
 */
const KNOWN_OUTRO_PHRASES = new Set([
  // English
  "thank you",
  "thank you very much",
  "thank you so much",
  "thank you for watching",
  "thanks",
  "thanks a lot",
  "thanks for watching",
  "thanks for listening",
  "bye bye",
  "goodbye",
  "good bye",
  "see you next time",
  "subtitles by the amara org community",
  "subtitles by the amaraorg community",
  "subtitle by rev com",
  "subtitles by rev com",
  // Hebrew
  "תודה",
  "תודה רבה",
  "תודה רבה לכם",
  "להתראות",
  "ביי ביי",
]);

/**
 * Single tokens whisper invents on their own. Every English entry is drawn from
 * the corpus (`So.`, `Okay.`, `You.`, `I.`, `and.`) or the brief; the Hebrew
 * entries from the brief's ADDENDUM.
 *
 * AIDEV-NOTE: `right` / `all right` are deliberately absent. "All right." is a
 * thing Etan actually says to close a thought — `stt.test.ts` has a case that
 * requires it survive — and the law is that a doubtful word stays. `כן` ("yes")
 * IS in the set on the brief's instruction, and it is the riskiest entry here:
 * it is a perfectly ordinary standalone reply. It is only ever safe because
 * conditions (b) and (c) are acoustic — if he said it, there is energy under it.
 */
const OUTRO_SINGLE_TOKENS = new Set([
  "okay",
  "ok",
  "you",
  "so",
  "and",
  "i",
  "bye",
  "תודה",
  "ביי",
  "כן",
]);

/** A sentence in a transcript, with where it sits in the string. */
export interface SentenceSpan {
  text: string;
  startIndex: number;
  endIndex: number;
}

/** A sentence the gate is willing to consider deleting. */
export interface OutroCandidate {
  /** The sentence exactly as it appears in the transcript, punctuation included. */
  phrase: string;
  /** Lowercased, punctuation-stripped form the lexicon matched. */
  key: string;
  startIndex: number;
  endIndex: number;
  /** True when nothing follows it in the transcript. */
  isTail: boolean;
}

export type OutroGateReason =
  | "no-candidate"
  | "no-audio"
  | "no-segments"
  | "segment-not-found"
  | "energy-present"
  | "near-speech-level"
  | "not-clear-of-speech"
  | "segments-stale"
  | "removed";

export interface OutroRemoval {
  phrase: string;
  isTail: boolean;
  startS: number;
  endS: number;
  /** Mean dBFS over the span whisper attributed to the phrase. */
  spanDbfs: number;
  /** Loudest 20 ms window inside that span, in dBFS. */
  peakDbfs: number;
}

export interface OutroGateDecision {
  text: string;
  removed: OutroRemoval[];
  /** Why the last examined candidate was left alone, when nothing was removed. */
  reason: OutroGateReason;
}

export interface OutroGateOptions {
  segments?: TranscriptSegment[];
  /**
   * False when the segments provably came from a different decode than
   * `wavData`. Pairing one decode's words with another's timings would move
   * every span, so the gate refuses. Defaults to true.
   */
  segmentsMatchAudio?: boolean;
  /**
   * The EXACT text `segments` describe — the raw decode output, before any
   * later stage rewrote it.
   *
   * Macroscope, PR #34: the span lookup counts words to find a candidate's
   * position, so it is only sound while the text still matches the segment
   * stream. `verifyLeadingPunctuation` can swap in a retry decode that adds
   * leading words, `verifyTailForLongRecording` can merge in recovered tail
   * words, and `trimEchoedTrailingPhrase` can remove some — each shifts every
   * later offset, and the word-verification check catches most but not all
   * misalignments. When this is given and differs from `text`, the gate
   * refuses outright rather than measuring a span it cannot vouch for.
   *
   * Omitting it means the caller asserts the two are aligned.
   */
  segmentsText?: string;
}

/** `VOICELAYER_STT_OUTRO_GATE=1` opts in. Anything else stays off. */
export function outroGateEnabled(env: {
  [key: string]: string | undefined;
  VOICELAYER_STT_OUTRO_GATE?: string;
}): boolean {
  const raw = env.VOICELAYER_STT_OUTRO_GATE?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "on" || raw === "yes";
}

/** Lowercase, drop everything that is not a letter, digit or space, collapse runs. */
export function normalizeOutroKey(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isKnownOutroKey(key: string): boolean {
  if (!key) return false;
  // The lexicon is an exact whole-string match, so its own entries bound their
  // length and the word cap must not be applied to them. Macroscope, PR #34:
  // the cap ran FIRST, which made `subtitles by the amara org community` (six
  // words) unreachable — a dead entry that read as covered.
  if (KNOWN_OUTRO_PHRASES.has(key)) return true;
  // A single invented token, or that token stuttered — "So, so, so, so, so."
  // The cap belongs here, where the pattern is open-ended.
  const words = key.split(" ");
  if (words.length > MAX_OUTRO_WORDS) return false;
  const first = words[0];
  if (!first || !OUTRO_SINGLE_TOKENS.has(first)) return false;
  return words.every((word) => word === first);
}

/**
 * Split a transcript into sentences, keeping each one's offsets.
 *
 * An ellipsis (`…`, or a run of two or more dots) closes a sentence — that is
 * Etan's ratified cut-off fragment, "fu…", and it stays exactly where it is —
 * but a sentence that ENDS in one can never be a candidate. So a fragment
 * bounds its neighbours without ever being deletable itself.
 */
export function splitSentences(text: string): SentenceSpan[] {
  const spans: SentenceSpan[] = [];
  // `:` and `;` close a clause without being full stops. They matter here
  // because one corpus row glues its invented token straight onto one —
  // `…give you the post from earlier: Okay.` — and without them that whole
  // line reads as a single sentence and the `Okay.` is never even considered.
  const terminal = /(?:…|\.{2,}|[.!?:;])+/gu;
  let cursor = 0;

  for (const match of text.matchAll(terminal)) {
    const markEnd = (match.index ?? 0) + match[0].length;
    const next = text[markEnd];
    // A mark only closes a sentence when whitespace or end-of-string follows,
    // so "8.45am" and "rev.com" stay in one piece.
    if (next !== undefined && !/\s/u.test(next)) continue;
    const raw = text.slice(cursor, markEnd);
    const leading = raw.length - raw.replace(/^\s+/u, "").length;
    const sentence = raw.trim();
    if (sentence) {
      spans.push({
        text: sentence,
        startIndex: cursor + leading,
        endIndex: cursor + leading + sentence.length,
      });
    }
    cursor = markEnd;
  }

  const tail = text.slice(cursor);
  const leading = tail.length - tail.replace(/^\s+/u, "").length;
  const trailing = tail.trim();
  if (trailing) {
    spans.push({
      text: trailing,
      startIndex: cursor + leading,
      endIndex: cursor + leading + trailing.length,
    });
  }
  return spans;
}

/** Every sentence in `text` the lexicon would consider, in order. */
export function findOutroCandidates(text: string): OutroCandidate[] {
  const sentences = splitSentences(text);
  const candidates: OutroCandidate[] = [];

  for (const [index, sentence] of sentences.entries()) {
    // A single full stop, and nothing else.
    //
    // An ellipsis marks the cut-off fragment Etan ratified as kept. A question
    // mark rules the sentence out too, and that is not cosmetic: two corpus
    // rows end with a `okay?` he KEPT (`…4489474c`, `…1b8b103c`), and whisper's
    // invented closers are never questions. `!` goes with it for the same
    // reason — an exclaimed farewell is a spoken one.
    // Exactly one `.`, and no `?` or `!` anywhere in the sentence.
    //
    // Macroscope, PR #34: `/\.$/` alone let `Thank you?.` and `Okay!.` through,
    // because `normalizeOutroKey` strips punctuation before the lexicon sees
    // the words. Mixed terminal punctuation is a spoken-question artefact, and
    // the doc promises a single full stop, so require it literally.
    if (/[?!]/u.test(sentence.text)) continue;
    if (!/(?:^|[^.…])\.$/u.test(sentence.text)) continue;

    const key = normalizeOutroKey(sentence.text);
    if (!isKnownOutroKey(key)) continue;

    candidates.push({
      phrase: sentence.text,
      key,
      startIndex: sentence.startIndex,
      endIndex: sentence.endIndex,
      isTail: index === sentences.length - 1,
    });
  }
  return candidates;
}

/** The trailing candidate, if the last sentence is one. Kept for the tail-only callers. */
export function findTrailingOutroCandidate(
  text: string,
): OutroCandidate | null {
  const candidates = findOutroCandidates(text);
  const last = candidates[candidates.length - 1];
  return last?.isTail ? last : null;
}

export interface WavWindows {
  /** Mean dBFS per `windowSeconds` window, in order. */
  dbfs: number[];
  windowSeconds: number;
  durationSeconds: number;
  /** This recording's own noise floor, in dBFS (10th-percentile window). */
  floorDbfs: number;
  /** Loudest a window may be and still count as silence HERE, in dBFS. */
  speechThresholdDbfs: number;
  /**
   * How loud this recording's speech actually is: the median of the loudest
   * 20 % of windows. Used by the `SPEECH_LEVEL_GUARD_DB` backstop, and robust
   * to both a clip that is nearly all speech and one that is nearly all
   * silence — in the second case it is dragged down toward the noise, which
   * makes the guard MORE protective, which is the safe direction.
   */
  speechLevelDbfs: number;
}

/**
 * Per-window loudness over a 16-bit PCM WAV.
 *
 * Returns null for anything that is not integer 16-bit PCM — the gate would
 * rather do nothing than measure a format it is decoding wrong.
 */
export function measureWavWindows(wavData: Uint8Array): WavWindows | null {
  const info = parseWavAudioInfo(wavData);
  // `audioFormat` matters as much as the bit depth: a 16-bit WAV carrying a
  // non-PCM format tag (A-law, mu-law, IEEE float, 0xFFFE extensible) would
  // sail past a bits-and-channels check and then be read sample-by-sample as
  // integer PCM, producing an energy figure that means nothing. On this gate a
  // meaningless measurement is not a cosmetic bug — it is what would authorise
  // deleting a word Etan said. Same conservative check `computePauseMap`
  // applies in `src/stt-pause-map.ts`.
  if (
    !info ||
    info.audioFormat !== WAVE_FORMAT_PCM ||
    info.bitsPerSample !== 16 ||
    info.channels < 1
  ) {
    return null;
  }

  const bytesPerFrame = (info.bitsPerSample / 8) * info.channels;
  const available = Math.min(
    info.dataSize,
    wavData.byteLength - info.dataOffset,
  );
  const frameCount = Math.floor(available / bytesPerFrame);
  if (frameCount <= 0) return null;
  // A truncated data chunk that still parsed would make getInt16 throw
  // (RangeError) rather than return null. Refuse instead of guessing energy.
  const pcmEnd = info.dataOffset + frameCount * bytesPerFrame;
  if (pcmEnd > wavData.byteLength) return null;

  const view = new DataView(
    wavData.buffer,
    wavData.byteOffset,
    wavData.byteLength,
  );
  const framesPerWindow = Math.max(
    1,
    Math.round(info.sampleRate * WINDOW_SECONDS),
  );
  const dbfs: number[] = [];

  for (let start = 0; start < frameCount; start += framesPerWindow) {
    const end = Math.min(start + framesPerWindow, frameCount);
    let sumSquares = 0;
    let samples = 0;
    for (let frame = start; frame < end; frame++) {
      const frameOffset = info.dataOffset + frame * bytesPerFrame;
      for (let channel = 0; channel < info.channels; channel++) {
        const sampleOffset = frameOffset + channel * 2;
        if (sampleOffset + 2 > wavData.byteLength) return null;
        const sample = view.getInt16(sampleOffset, true);
        sumSquares += sample * sample;
        samples++;
      }
    }
    const rms = samples > 0 ? Math.sqrt(sumSquares / samples) : 0;
    dbfs.push(rms > 0 ? 20 * Math.log10(rms / 32768) : -Infinity);
  }

  const floorDbfs = percentileDbfs(dbfs, 0.1);
  return {
    dbfs,
    windowSeconds: framesPerWindow / info.sampleRate,
    durationSeconds: frameCount / info.sampleRate,
    floorDbfs,
    speechThresholdDbfs: speechThresholdFor(floorDbfs),
    // Median of the top 20 %: the 90th percentile of all windows.
    speechLevelDbfs: percentileDbfs(dbfs, 0.9),
  };
}

/** The `fraction` quantile of `dbfs`, ignoring digital-silence windows' -Infinity. */
function percentileDbfs(dbfs: number[], fraction: number): number {
  const finite = dbfs
    .filter((level) => Number.isFinite(level))
    .sort((a, b) => a - b);
  if (finite.length === 0) return -Infinity;
  const index = Math.min(
    finite.length - 1,
    Math.max(0, Math.floor(finite.length * fraction)),
  );
  return finite[index] ?? -Infinity;
}

/**
 * The level that separates silence from speech in ONE recording.
 *
 * Relative to that recording's own noise floor, because a fixed line does not
 * survive contact with the archive: the four RED specimens measure floors from
 * -60.0 dBFS to -53.2 dBFS, and the -53.2 one (`…ac389f08`, the "Okay." clip)
 * carries click and breath windows up to -43.7 dBFS *inside its silence* —
 * louder than the -45 dBFS the brief proposed as the silence ceiling. A fixed
 * -45 would have refused to gate that specimen at all.
 *
 * `SPEECH_OVER_FLOOR_DB` above the floor sits clear of that: real speech in all
 * four clips runs 1000-16000 RMS, at least 13x the highest measured floor,
 * while the loudest non-speech window is about 5x its floor.
 *
 * The clamps stop the relative rule going wrong at either extreme — digital
 * silence would otherwise put the threshold at -Infinity, and a recording with
 * no pauses at all (floor measured inside speech) would otherwise push the
 * threshold up into real words.
 */
function speechThresholdFor(floorDbfs: number): number {
  const relative = Number.isFinite(floorDbfs)
    ? floorDbfs + SPEECH_OVER_FLOOR_DB
    : SPEECH_THRESHOLD_MIN_DBFS;
  return Math.max(SPEECH_THRESHOLD_MIN_DBFS, relative);
}

function windowIndex(windows: WavWindows, seconds: number): number {
  return Math.floor(seconds / windows.windowSeconds);
}

function isSilentWindow(windows: WavWindows, index: number): boolean {
  if (index < 0 || index >= windows.dbfs.length) return true;
  const level = windows.dbfs[index];
  return level === undefined || level < windows.speechThresholdDbfs;
}

/**
 * Does `[first, last)` contain a real word, as opposed to a click or a breath?
 *
 * Speech has to be SUSTAINED: `MIN_SPEECH_RUN_SECONDS` of consecutive windows
 * over the threshold. A single 20 ms spike is not a syllable, and both the
 * "Okay." clip and the Hebrew tail clip have exactly one such isolated spike
 * sitting in their trailing silence (RMS 370 and 252 against floors of 72 and
 * 37) — treating those as speech would have blocked both removals.
 */
function containsSustainedSpeech(
  windows: WavWindows,
  first: number,
  last: number,
): boolean {
  const needed = Math.max(
    1,
    Math.round(MIN_SPEECH_RUN_SECONDS / windows.windowSeconds),
  );
  let run = 0;
  for (let index = Math.max(0, first); index < last; index++) {
    if (isSilentWindow(windows, index)) {
      run = 0;
      continue;
    }
    run++;
    if (run >= needed) return true;
  }
  return false;
}

/**
 * Mean and peak dBFS across `[startS, endS)`, plus whether it carries a word.
 * Null when the span falls outside the audio entirely.
 */
function measureSpan(
  windows: WavWindows,
  startS: number,
  endS: number,
): { meanDbfs: number; peakDbfs: number; hasSpeech: boolean } | null {
  const first = Math.max(0, windowIndex(windows, startS));
  const last = Math.min(
    windows.dbfs.length,
    Math.ceil(endS / windows.windowSeconds),
  );
  if (last <= first) return null;

  let sumSquares = 0;
  let count = 0;
  let peak = -Infinity;
  for (let index = first; index < last; index++) {
    const level = windows.dbfs[index];
    if (level === undefined) continue;
    if (level > peak) peak = level;
    const amplitude = level === -Infinity ? 0 : Math.pow(10, level / 20);
    sumSquares += amplitude * amplitude;
    count++;
  }
  if (count === 0) return null;
  const rms = Math.sqrt(sumSquares / count);
  return {
    meanDbfs: rms > 0 ? 20 * Math.log10(rms) : -Infinity,
    peakDbfs: peak,
    hasSpeech: containsSustainedSpeech(windows, first, last),
  };
}

/**
 * Is `[startS, endS)` sitting clear inside one contiguous silence run?
 *
 * "Clear" means the silence extends `SILENCE_MARGIN_SECONDS` past the span on
 * both sides, so a real word whose segment end drifted into the pause beside it
 * is still protected. The start and end of the recording count as silence: the
 * tail case has no audio to its right, and there is nothing to its left either
 * when the whole clip is quiet.
 */
function isClearOfSpeech(
  windows: WavWindows,
  startS: number,
  endS: number,
  marginSeconds: number,
): boolean {
  const margin = Math.max(1, Math.round(marginSeconds / windows.windowSeconds));
  const first = windowIndex(windows, startS) - margin;
  const last = Math.ceil(endS / windows.windowSeconds) + margin;
  return !containsSustainedSpeech(windows, first, last);
}

/** True when no window in the whole recording carries sustained speech. */
function isSilentThroughout(windows: WavWindows): boolean {
  return !containsSustainedSpeech(windows, 0, windows.dbfs.length);
}

/**
 * The span whisper attributed to `candidate`.
 *
 * Located POSITIONALLY, not by searching for the words: whisper's segments
 * partition the transcript, so the candidate is the run of segments covering
 * transcript words `[n, n + len)` where `n` is the word count before it. A
 * text search would pick the wrong occurrence whenever the same phrase appears
 * twice — "Ship it. Thank you. Thank you." has two identical tails and only one
 * of them sits over silence.
 *
 * The located words are then verified against the candidate key. A mismatch
 * returns null rather than a guessed span — never an off-by-one interpolation.
 * `stripHallucinatedOutro` also refuses when the whole word stream of `text`
 * disagrees with the segments (head repair / echo trim rewrote the
 * transcript), because a matching key at the wrong *index* would otherwise
 * still pass this check.
 *
 * When the run also carries real words — whisper merged the invented phrase
 * into a segment with genuine speech — the returned span covers that speech
 * too, and the energy check below keeps the phrase. That is the safe direction.
 */
export function findCandidateSpan(
  segments: TranscriptSegment[],
  candidate: OutroCandidate,
  fullText: string,
): { startS: number; endS: number } | null {
  const prefixKey = normalizeOutroKey(fullText.slice(0, candidate.startIndex));
  const skipWords = prefixKey
    ? prefixKey.split(" ").filter(Boolean).length
    : 0;
  const wantWords = candidate.key.split(" ").filter(Boolean);
  if (wantWords.length === 0) return null;

  let consumed = 0;
  let firstIndex = -1;
  let lastIndex = -1;
  const found: string[] = [];

  for (const [index, segment] of segments.entries()) {
    const words = normalizeOutroKey(segment.text).split(" ").filter(Boolean);
    for (const word of words) {
      const position = consumed++;
      if (position < skipWords) continue;
      if (found.length >= wantWords.length) break;
      if (firstIndex < 0) firstIndex = index;
      lastIndex = index;
      found.push(word);
    }
    if (found.length >= wantWords.length) break;
  }

  if (found.length !== wantWords.length) return null;
  if (found.join(" ") !== candidate.key) return null;

  const run = segments.slice(firstIndex, lastIndex + 1);
  if (run.length === 0) return null;
  const startS = Math.min(...run.map((entry) => entry.startS));
  const endS = Math.max(...run.map((entry) => entry.endS));
  if (!Number.isFinite(startS) || !Number.isFinite(endS) || endS <= startS) {
    return null;
  }
  return { startS, endS };
}

/*
 * AIDEV-NOTE: there was an "echo guard" here that kept a candidate whenever the
 * speech next to it already ended with the same phrase. It was removed, and it
 * should not come back: that condition describes the COMMON hallucination —
 * Etan says "Thank you.", whisper writes it once on the speech and a second
 * time over the silence after it — so the guard blocked exactly the removals
 * this gate exists for. Conditions (b) and (c) are strictly stronger anyway:
 * they prove no word is inside the span and that the silence extends clear of
 * it on both sides. If the phrase's own audio is silence, it was not spoken,
 * whatever the words beside it say. De-duplicating two REAL utterances remains
 * the echo trimmer's job in `stt.ts`.
 */

/** Cut `[startIndex, endIndex)` out of `text` and close the seam. */
function excise(text: string, startIndex: number, endIndex: number): string {
  const before = text.slice(0, startIndex).replace(/\s+$/u, "");
  const after = text.slice(endIndex).replace(/^\s+/u, "");
  if (!before) return after;
  if (!after) return before;
  return `${before} ${after}`;
}

/**
 * Drop hallucinated closers from `text`, or return it untouched.
 *
 * `wavData` is the audio the transcript was decoded from. Every path that
 * cannot prove the phrase's own audio is silence returns the text unchanged.
 */
export function stripHallucinatedOutro(
  text: string,
  wavData: Uint8Array,
  options: OutroGateOptions = {},
): OutroGateDecision {
  const candidates = findOutroCandidates(text);
  if (candidates.length === 0) {
    return { text, removed: [], reason: "no-candidate" };
  }

  const windows = measureWavWindows(wavData);
  if (!windows) return { text, removed: [], reason: "no-audio" };

  // A recording with no speech anywhere cannot have had a word in it, so a
  // transcript that is nothing BUT the invented phrase is safe to empty. This
  // is the 15 s silent `voice_ask` that came back "Thank you." — and it needs
  // no segments, because there is no audio anywhere to attribute.
  if (isSilentThroughout(windows)) {
    const only = candidates[0];
    if (candidates.length === 1 && only && splitSentences(text).length === 1) {
      return {
        text: "",
        removed: [
          {
            phrase: only.phrase,
            isTail: true,
            startS: 0,
            endS: windows.durationSeconds,
            spanDbfs: -Infinity,
            peakDbfs: -Infinity,
          },
        ],
        reason: "removed",
      };
    }
  }

  const segments = options.segments;
  if (
    !segments ||
    segments.length === 0 ||
    options.segmentsMatchAudio === false
  ) {
    return { text, removed: [], reason: "no-segments" };
  }

  // The span lookup is positional, so it is only valid while `text` is still
  // the text these segments describe.
  if (options.segmentsText !== undefined && options.segmentsText !== text) {
    return { text, removed: [], reason: "segments-stale" };
  }
  // Same class of bug when the caller omitted `segmentsText` (or the decode
  // `text` and the segment stream already disagree): a word-count prefix into
  // a longer stream can still land on an earlier copy of the SAME closer,
  // verification passes, and we measure the wrong span. Never delete then.
  if (
    normalizeOutroKey(text) !==
    normalizeOutroKey(segments.map((entry) => entry.text).join(" "))
  ) {
    return { text, removed: [], reason: "segments-stale" };
  }

  // Every candidate is judged against the ORIGINAL text, because that is the
  // text `segments` describes: an excision would shift the word positions the
  // span lookup counts on. Approved cuts are then applied back-to-front, so
  // each one's offsets are still valid when it is applied.
  const approved: Array<{ candidate: OutroCandidate; removal: OutroRemoval }> =
    [];
  let reason: OutroGateReason = "no-candidate";

  for (const candidate of candidates) {
    if (approved.length >= MAX_REMOVALS) break;

    const span = findCandidateSpan(segments, candidate, text);
    if (!span) {
      reason = "segment-not-found";
      continue;
    }

    const measured = measureSpan(windows, span.startS, span.endS);
    if (!measured) {
      reason = "segment-not-found";
      continue;
    }
    // (b) No word anywhere under the phrase. Checked as sustained speech, not
    // as a mean: a mean can be dragged below the floor by a long silent pad
    // around a real word, and a peak can be tripped by a lone click.
    if (measured.hasSpeech) {
      reason = "energy-present";
      continue;
    }
    // The backstop that replaces the old fixed upper clamp: however the
    // threshold landed, a span as loud as this recording's own speech is not
    // silence. Protects the low-gain recording whose speech sits only a little
    // over its noise floor.
    if (
      Number.isFinite(windows.speechLevelDbfs) &&
      measured.peakDbfs >= windows.speechLevelDbfs - SPEECH_LEVEL_GUARD_DB
    ) {
      reason = "near-speech-level";
      continue;
    }
    // (c) The silence must extend clear of the span on both sides.
    const marginSeconds = candidate.isTail
      ? SILENCE_MARGIN_SECONDS
      : INTERNAL_SILENCE_MARGIN_SECONDS;
    if (!isClearOfSpeech(windows, span.startS, span.endS, marginSeconds)) {
      reason = "not-clear-of-speech";
      continue;
    }
    approved.push({
      candidate,
      removal: {
        phrase: candidate.phrase,
        isTail: candidate.isTail,
        startS: span.startS,
        endS: span.endS,
        spanDbfs: measured.meanDbfs,
        peakDbfs: measured.peakDbfs,
      },
    });
    reason = "removed";
  }

  let current = text;
  for (const entry of [...approved].reverse()) {
    current = excise(
      current,
      entry.candidate.startIndex,
      entry.candidate.endIndex,
    );
  }

  return {
    text: current,
    removed: approved.map((entry) => entry.removal),
    reason,
  };
}
