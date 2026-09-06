/**
 * STT backend abstraction — whisper.cpp (local) or Wispr Flow (cloud fallback).
 *
 * Auto-detects the best available backend:
 *   1. whisper.cpp binary + model file → local transcription (default on Apple Silicon)
 *   2. Wispr Flow WebSocket API → cloud fallback (requires QA_VOICE_WISPR_KEY)
 *
 * Environment variables:
 *   QA_VOICE_STT_BACKEND   — "whisper-server" | "whisper" | "wispr" | "auto" (default: "auto")
 *   QA_VOICE_WHISPER_MODEL — path to GGML model file (auto-detected if not set)
 *   QA_VOICE_WISPR_KEY     — Wispr Flow API key (required for wispr backend)
 */

import { existsSync, readdirSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { calculateRMS } from "./audio-utils";
import { resolveBinary, resolveBinaryAsync } from "./resolve-binary";
import {
  isServerAvailable,
  transcribeViaServer,
  type WhisperServerTranscribeOptions,
} from "./whisper-server";
import {
  getInitialPrompt,
  getLanguageConfig,
  getLanguageModeFromEnv,
} from "./language-config";
import { getSTTVocabularyPrompt } from "./stt-cleanup";
import { createHash } from "crypto";
import {
  chooseChunkEnd,
  computePauseMap,
  isSilenceSeam,
  SMART_CHUNK_MIN_SECONDS,
  type PauseSpan,
} from "./stt-pause-map";
import {
  smartBoundariesEnabled,
  type TranscriptSegment,
} from "./stt-sentence-boundaries";
import { outroGateEnabled, stripHallucinatedOutro } from "./stt-outro-gate";
import type {
  SpeechToTextBackend,
  SpeechToTextBackendSelector,
  TranscribeAudioOptions,
  TranscriptionResult,
} from "./soundlayer";

// --- Types ---

export interface STTResult extends TranscriptionResult {
  text: string;
  backend: string;
  durationMs: number;
  /**
   * Whisper segment timestamps, present only under
   * `VOICELAYER_STT_SMART_BOUNDARIES=1` on the single-shot whisper-server path.
   * The chunked path (>= 90 s) does NOT set them, so those recordings get no
   * boundary validation: each chunk's times are chunk-relative, and stitching
   * them across C1's overlap seam is a separate change. Deliberate and
   * documented in CLAUDE.details.md (Macroscope round 1, finding 5).
   */
  segments?: TranscriptSegment[];
  /**
   * sha256 of the EXACT audio `segments` were decoded from. The boundary stage
   * refuses to use segments whose audio does not match the WAV it computes the
   * pause map over, so a retranscribe that swapped the file underneath cannot
   * silently pair one decode's segments with another's timings (Macroscope
   * round 1).
   */
  segmentsAudioSha256?: string;
}

export interface STTTranscribeOptions extends TranscribeAudioOptions {
  promptOverride?: string;
}

export interface STTBackend extends SpeechToTextBackend {
  name: string;
  isAvailable(): Promise<boolean>;
  transcribe(
    audioPath: string,
    options?: STTTranscribeOptions,
  ): Promise<STTResult>;
}

export function buildChunkPrompt(text: string, maxWords = 24): string {
  const words = text.trim().split(/\s+/).filter(Boolean);
  if (words.length <= maxWords) return words.join(" ");
  return words.slice(-(maxWords + 1)).join(" ");
}

function normalizeChunkWords(text: string): string[] {
  return text.trim().split(/\s+/).filter(Boolean);
}

function normalizeProseQuoteSpacing(text: string): string {
  let result = text.replace(/([\p{L}\p{N}])"(?=\p{L}[^"]*")/gu, '$1 "');
  result = result.replace(/"(?=\p{L})/gu, (match, offset) => {
    const quoteCountBefore = result.slice(0, offset).match(/"/g)?.length ?? 0;
    return quoteCountBefore % 2 === 1 ? `${match} ` : match;
  });
  return result;
}

// Sentence-ending punctuation stripped from token edges for overlap
// comparison. Operator/symbol chars (+ - # * / = & | < > ~ ^ @ $ %) are
// intentionally absent so code tokens like C++, C#, i++, x-- keep their
// identifying suffixes at chunk boundaries.
//
// `!` is stripped ONLY from the trailing edge (sentence-ending exclamation,
// e.g. "world!"). A leading `!` is treated as a code operator (`!flag`,
// `!=`, `!==`) and preserved so distinct operator tokens don't collapse to
// the same key.
const OVERLAP_EDGE_PUNCTUATION_LEADING = /^[.,?;:"'`()\[\]{}«»…]+/gu;
const OVERLAP_EDGE_PUNCTUATION_TRAILING = /[.,!?;:"'`()\[\]{}«»…]+$/gu;

function normalizeChunkWordForOverlap(word: string): string {
  const stripped = word
    .toLowerCase()
    .replace(OVERLAP_EDGE_PUNCTUATION_LEADING, "")
    .replace(OVERLAP_EDGE_PUNCTUATION_TRAILING, "");
  // Pure-punctuation tokens (e.g. a standalone "," from Whisper symbol emits)
  // would strip to "" and falsely overlap with each other. Fall back to the
  // original lower-cased form so distinct punctuation tokens stay distinct.
  return stripped || word.toLowerCase();
}

function overlapKey(words: string[]): string {
  return words.map(normalizeChunkWordForOverlap).join(" ");
}

const TRAILING_SENTENCE_PUNCTUATION = /[.,!?;:]+$/u;
const MAX_PREFIX_SHIFTED_SKIP_WORDS = 3;
const MIN_PREFIX_SHIFTED_MATCH_WORDS = 4;
const MIN_MEANINGFUL_TAIL_OVERLAP_WORDS = 2;
const MIN_ECHOED_TAIL_WORDS = 3;
const MAX_ECHOED_TAIL_WORDS = 10;
const MAX_ECHOED_TAIL_LOOKBACK_WORDS = 18;
const MIN_NOVEL_TAIL_SUFFIX_WORDS = 1;
const MIN_REPLAYED_TAIL_PHRASE_WORDS = 4;
const MAX_REPLAYED_TAIL_PHRASE_WORDS = 10;
const MAX_ORPHANED_TAIL_FRAGMENT_WORDS = 2;
const MAX_TAIL_PREFIX_SHIFTED_SKIP_WORDS = 6;
const MIN_SHORT_FINAL_CONFIRMATION_WORDS = 3;
const MIN_SHORT_FINAL_CONFIRMATION_RATIO = 0.7;
const DANGLING_TAIL_CONTINUATION_CUES = new Set([
  "are you",
  "are we",
  "can i",
  "can we",
  "can you",
  "could i",
  "could we",
  "could you",
  "did you",
  "do we",
  "do you",
  "does it",
  "is it",
  "should i",
  "should we",
  "should you",
  "will you",
  "would i",
  "would we",
  "would you",
]);
const MAX_LEADING_PUNCTUATION_INSERTED_WORDS = 4;
const MIN_LEADING_PUNCTUATION_OVERLAP_WORDS = 3;
const TRAILING_FILLER_AFTER_QUESTION = /\?\s+(?:yeah|ok|okay)\.?$/iu;
const LEADING_PUNCTUATION = /^[,.;:!?]+(?:\s+|$)/u;
const PUNCTUATION_ONLY_TOKEN = /^[,.;:!?]+$/u;

function preferPunctuatedOverlapWord(
  current: string,
  next: string,
  nextContinues: boolean,
): string {
  if (
    nextContinues &&
    /[?]+$/u.test(current) &&
    TRAILING_SENTENCE_PUNCTUATION.test(next) &&
    !/[?]+$/u.test(next) &&
    overlapKey([current]) === overlapKey([next])
  ) {
    return next;
  }
  if (TRAILING_SENTENCE_PUNCTUATION.test(current)) return current;
  if (!TRAILING_SENTENCE_PUNCTUATION.test(next)) return current;
  if (overlapKey([current]) !== overlapKey([next])) return current;
  return next;
}

function levenshteinDistance(left: string, right: string): number {
  if (left === right) return 0;
  if (left.length === 0) return right.length;
  if (right.length === 0) return left.length;

  const previous = Array.from(
    { length: right.length + 1 },
    (_, index) => index,
  );
  for (let i = 1; i <= left.length; i++) {
    const current = [i];
    for (let j = 1; j <= right.length; j++) {
      const cost = left[i - 1] === right[j - 1] ? 0 : 1;
      current[j] = Math.min(
        current[j - 1] + 1,
        previous[j] + 1,
        previous[j - 1] + cost,
      );
    }
    previous.splice(0, previous.length, ...current);
  }
  return previous[right.length];
}

function isAlphabeticOverlapToken(word: string): boolean {
  return /^[\p{L}]+$/u.test(normalizeChunkWordForOverlap(word));
}

function tokensAreSimilar(left: string, right: string): boolean {
  const leftKey = normalizeChunkWordForOverlap(left);
  const rightKey = normalizeChunkWordForOverlap(right);
  if (leftKey === rightKey) return true;
  if (!isAlphabeticOverlapToken(left) || !isAlphabeticOverlapToken(right)) {
    return false;
  }
  if (leftKey.length < 4 || rightKey.length < 4) return false;
  if (leftKey.startsWith(rightKey) || rightKey.startsWith(leftKey)) {
    const extra = Math.abs(leftKey.length - rightKey.length);
    return extra > 0 && extra <= 3;
  }
  return levenshteinDistance(leftKey, rightKey) <= 1;
}

function overlapAllowsSingleSubstitution(
  mergedWords: string[],
  nextWords: string[],
  size: number,
): boolean {
  const mergedTail = mergedWords.slice(-size);
  const nextHead = nextWords.slice(0, size);
  let substitutions = 0;
  for (let index = 0; index < size; index++) {
    if (
      normalizeChunkWordForOverlap(mergedTail[index]) ===
      normalizeChunkWordForOverlap(nextHead[index])
    ) {
      continue;
    }
    if (!tokensAreSimilar(mergedTail[index], nextHead[index])) return false;
    substitutions += 1;
    if (substitutions > 1) return false;
  }
  return substitutions === 1;
}

function preferOverlapWord(
  current: string,
  next: string,
  nextContinues: boolean,
): string {
  const punctuated = preferPunctuatedOverlapWord(current, next, nextContinues);
  if (punctuated !== current) return punctuated;
  const currentKey = normalizeChunkWordForOverlap(current);
  const nextKey = normalizeChunkWordForOverlap(next);
  if (tokensAreSimilar(current, next) && nextKey.length > currentKey.length) {
    return next;
  }
  return current;
}

function containsSimilarWordSequence(
  words: string[],
  sequence: string[],
): boolean {
  if (sequence.length === 0 || words.length < sequence.length) return false;
  for (let index = 0; index + sequence.length <= words.length; index++) {
    let substitutions = 0;
    if (
      sequence.every((token, offset) => {
        const word = words[index + offset];
        if (!tokensAreSimilar(word, token)) return false;
        if (
          normalizeChunkWordForOverlap(word) !==
          normalizeChunkWordForOverlap(token)
        ) {
          substitutions += 1;
        }
        return substitutions <= 1;
      })
    ) {
      return true;
    }
  }
  return false;
}

function findChunkOverlap(
  mergedWords: string[],
  nextWords: string[],
  options: { maxPrefixShiftedSkipWords?: number } = {},
): { overlap: number; skipPrefix: number } {
  const maxPrefixShiftedSkipWords =
    options.maxPrefixShiftedSkipWords ?? MAX_PREFIX_SHIFTED_SKIP_WORDS;
  const maxOverlap = Math.min(mergedWords.length, nextWords.length);

  for (let size = maxOverlap; size > 0; size--) {
    const mergedTail = overlapKey(mergedWords.slice(-size));
    const nextHead = overlapKey(nextWords.slice(0, size));
    if (mergedTail === nextHead) {
      return { overlap: size, skipPrefix: 0 };
    }
    if (
      size > 1 &&
      overlapAllowsSingleSubstitution(mergedWords, nextWords, size)
    ) {
      return { overlap: size, skipPrefix: 0 };
    }
  }

  for (
    let prefix = 1;
    prefix <= Math.min(maxPrefixShiftedSkipWords, nextWords.length - 1);
    prefix++
  ) {
    const shiftedMaxOverlap = Math.min(
      mergedWords.length,
      nextWords.length - prefix,
    );
    for (
      let size = shiftedMaxOverlap;
      size >= MIN_PREFIX_SHIFTED_MATCH_WORDS;
      size--
    ) {
      const mergedTail = overlapKey(mergedWords.slice(-size));
      const nextHead = overlapKey(nextWords.slice(prefix, prefix + size));
      if (mergedTail === nextHead) {
        return { overlap: size, skipPrefix: prefix };
      }
    }
  }

  return { overlap: 0, skipPrefix: 0 };
}

function containsEarlierWordSequence(
  words: string[],
  sequence: string[],
  beforeIndex: number,
): boolean {
  if (sequence.length === 0 || beforeIndex < sequence.length) return false;
  const sequenceKey = overlapKey(sequence);
  for (let index = 0; index + sequence.length <= beforeIndex; index++) {
    if (
      overlapKey(words.slice(index, index + sequence.length)) === sequenceKey
    ) {
      return true;
    }
  }
  return false;
}

function hasNovelTailExtension(
  currentWords: string[],
  nextWords: string[],
  overlap: number,
  skipPrefix: number,
): boolean {
  const extension = nextWords.slice(skipPrefix + overlap);
  const maxSuffixWords = Math.min(4, extension.length);
  for (
    let suffixWords = maxSuffixWords;
    suffixWords >= MIN_NOVEL_TAIL_SUFFIX_WORDS;
    suffixWords--
  ) {
    const suffix = extension.slice(extension.length - suffixWords);
    if (
      !containsEarlierWordSequence(currentWords, suffix, currentWords.length)
    ) {
      return true;
    }
  }
  return false;
}

function isDanglingTailContinuationCue(words: string[]): boolean {
  if (words.length !== 2) return false;
  return DANGLING_TAIL_CONTINUATION_CUES.has(
    words.map(normalizeChunkWordForOverlap).join(" "),
  );
}

function hasDanglingTailContinuationCue(currentWords: string[]): boolean {
  return isDanglingTailContinuationCue(currentWords.slice(-2));
}

function startsWithDanglingTailContinuationCue(words: string[]): boolean {
  return isDanglingTailContinuationCue(words.slice(0, 2));
}

function isPromptEchoedTailReplay(
  currentWords: string[],
  nextWords: string[],
  overlap: number,
  skipPrefix: number,
): boolean {
  if (hasNovelTailExtension(currentWords, nextWords, overlap, skipPrefix)) {
    return false;
  }
  if (hasDanglingTailContinuationCue(currentWords)) {
    return false;
  }

  const maxReplayWords = Math.min(
    MAX_REPLAYED_TAIL_PHRASE_WORDS,
    nextWords.length - skipPrefix,
  );
  if (maxReplayWords < MIN_REPLAYED_TAIL_PHRASE_WORDS) return false;

  const boundaryStart = currentWords.length - overlap;
  for (
    let replayWords = maxReplayWords;
    replayWords >= MIN_REPLAYED_TAIL_PHRASE_WORDS;
    replayWords--
  ) {
    if (
      containsEarlierWordSequence(
        currentWords,
        nextWords.slice(skipPrefix, skipPrefix + replayWords),
        boundaryStart,
      )
    ) {
      return true;
    }
  }
  return false;
}

interface TailVerificationMergeResult {
  text: string;
  confirmedOverlap: boolean;
}

function mergeTailVerificationWords(
  currentWords: string[],
  tailWords: string[],
): TailVerificationMergeResult | null {
  const { overlap, skipPrefix } = findChunkOverlap(currentWords, tailWords, {
    maxPrefixShiftedSkipWords: MAX_TAIL_PREFIX_SHIFTED_SKIP_WORDS,
  });
  if (overlap < MIN_MEANINGFUL_TAIL_OVERLAP_WORDS) return null;
  if (isPromptEchoedTailReplay(currentWords, tailWords, overlap, skipPrefix)) {
    return null;
  }

  const merged = [...currentWords];
  for (let index = 0; index < overlap; index++) {
    const mergedIndex = merged.length - overlap + index;
    merged[mergedIndex] = preferPunctuatedOverlapWord(
      merged[mergedIndex],
      tailWords[skipPrefix + index],
      skipPrefix + index < tailWords.length - 1,
    );
  }
  merged.push(...tailWords.slice(skipPrefix + overlap));
  const text = merged.join(" ").trim();
  return text ? { text, confirmedOverlap: true } : null;
}

function mergeTailVerificationTranscript(
  current: string,
  tail: string,
): TailVerificationMergeResult {
  const currentWords = normalizeChunkWords(current);
  const tailWords = normalizeChunkWords(tail);
  const directMerge = mergeTailVerificationWords(currentWords, tailWords);
  if (directMerge) return directMerge;

  for (
    let dropWords = 1;
    dropWords <=
    Math.min(MAX_ORPHANED_TAIL_FRAGMENT_WORDS, currentWords.length);
    dropWords++
  ) {
    const retainedWords = currentWords.slice(0, -dropWords);
    const droppedWords = currentWords.slice(-dropWords);
    if (
      dropWords === 1 &&
      normalizeChunkWordForOverlap(droppedWords[0]).length <= 2
    ) {
      continue;
    }
    if (
      !containsEarlierWordSequence(
        retainedWords,
        droppedWords,
        retainedWords.length,
      )
    ) {
      continue;
    }

    const repairedMerge = mergeTailVerificationWords(retainedWords, tailWords);
    if (repairedMerge) return repairedMerge;
  }

  return { text: current, confirmedOverlap: false };
}

function hasLeadingPunctuationRepairOverlap(
  originalText: string,
  retryText: string,
): boolean {
  const originalWords = normalizeChunkWords(originalText).filter(
    (word) => !PUNCTUATION_ONLY_TOKEN.test(word),
  );
  const retryWords = normalizeChunkWords(retryText);
  const overlapWords = Math.min(
    MIN_LEADING_PUNCTUATION_OVERLAP_WORDS,
    originalWords.length,
  );

  if (overlapWords === 0) return false;

  const originalPrefix = overlapKey(originalWords.slice(0, overlapWords));
  for (
    let insertedWords = 0;
    insertedWords <=
    Math.min(MAX_LEADING_PUNCTUATION_INSERTED_WORDS, retryWords.length);
    insertedWords++
  ) {
    if (
      overlapKey(
        retryWords.slice(insertedWords, insertedWords + overlapWords),
      ) === originalPrefix
    ) {
      return true;
    }
  }

  return false;
}

function repairLeadingPunctuationFromHead(
  originalText: string,
  headText: string,
): string | null {
  const trimmedOriginal = originalText.trim();
  const trimmedHead = headText.trim();
  if (
    !LEADING_PUNCTUATION.test(trimmedOriginal) ||
    LEADING_PUNCTUATION.test(trimmedHead)
  ) {
    return null;
  }

  const originalWords = normalizeChunkWords(trimmedOriginal).filter(
    (word) => !PUNCTUATION_ONLY_TOKEN.test(word),
  );
  const headWords = normalizeChunkWords(trimmedHead);
  const overlapWords = Math.min(
    MIN_LEADING_PUNCTUATION_OVERLAP_WORDS,
    originalWords.length,
  );
  if (overlapWords === 0) return null;

  const originalPrefix = overlapKey(originalWords.slice(0, overlapWords));
  for (
    let insertedWords = 0;
    insertedWords <=
    Math.min(MAX_LEADING_PUNCTUATION_INSERTED_WORDS, headWords.length);
    insertedWords++
  ) {
    if (
      overlapKey(
        headWords.slice(insertedWords, insertedWords + overlapWords),
      ) !== originalPrefix
    ) {
      continue;
    }

    const strippedOriginal = trimmedOriginal.replace(LEADING_PUNCTUATION, "");
    const insertedPrefix = headWords.slice(0, insertedWords).join(" ");
    return [insertedPrefix, strippedOriginal].filter(Boolean).join(" ").trim();
  }

  return null;
}

interface WavPcmInfo {
  durationSeconds: number;
  dataOffset: number;
  dataSize: number;
  byteRate: number;
  blockAlign: number;
}

const WAV_TAIL_VERIFY_MIN_SECONDS = 12.5;
const WAV_TAIL_VERIFY_SECONDS = 12;
const WAV_HEAD_VERIFY_SECONDS = 12;
const WAV_ADJACENT_ECHO_CLEANUP_MIN_SECONDS = 20;
const WAV_CHUNKED_DECODE_MIN_SECONDS = 90;
const WAV_CHUNK_SECONDS = 30;
const WAV_CHUNK_OVERLAP_SECONDS = 5;

/**
 * Overlap kept at a SILENCE SEAM.
 *
 * An ordinary seam re-decodes `WAV_CHUNK_OVERLAP_SECONDS` of audio so the merge
 * has shared words to align on. A seam that lands inside a pause has no shared
 * words to find — that is the whole point — so it keeps only enough audio to
 * guarantee no gap, and the two texts are concatenated instead of reconciled.
 */
const SILENCE_SEAM_OVERLAP_SECONDS = 0.5;

/**
 * Least fraction of a recording that must decode as speech before its pause map
 * is trusted to place boundaries.
 *
 * A map that reports almost no speech carries no information about where the
 * WORDS are, so "this cut is inside a pause" stops meaning "this cut is between
 * two words" — and the silence seam's concatenate-without-reconcile step rests
 * on exactly that. Found by turning the flag on by default: `stt.test.ts`
 * builds its long fixtures from a 180 Hz sine, Silero correctly scores the
 * whole thing as non-speech, and every seam was then classified as silence.
 * Below this floor the decode keeps the fixed cuts and the anchor merge.
 *
 * 5 % is set from measurement, not taste: across the 18 recordings of >=90 s in
 * the 2026-09-06 recon corpus the speech share runs 19.0 %-79.6 % (the 19.0 %
 * one is a real, very pause-heavy 183 s dictation and must stay smart-chunked),
 * while the synthetic tone fixtures score 0.0 %. The floor separates "no speech
 * was detected at all" from "a quiet recording", and nothing real is near it.
 */
const MIN_SMART_CHUNK_SPEECH_RATIO = 0.05;

/**
 * Silence-aware boundaries for the saved-WAV chunk path. Opt-in.
 *
 * Default OFF: unset, every boundary is exactly `WAV_CHUNK_SECONDS` and every
 * seam uses the anchor merge, i.e. the shipped decode.
 *
 * It was briefly flipped ON by default and the 18-clip corpus gate said no. ON
 * is the only configuration in that run that produced NO looped text at all
 * (0 looped words against 109, 0/18 adjacent duplicates against 4/18) and it is
 * 1.9x faster — but it lost more CONTENT (337 words against 210, 110 of them
 * within 5 s of a chosen cut). AGENTS.md ranks a lost word above a duplicated
 * one, so it stays opt-in until the seam losses are understood. Numbers and
 * method: PR #31.
 */
export function isSmartWavChunkingEnabled(
  env: Record<string, string | undefined> = process.env,
): boolean {
  const raw = env.VOICELAYER_STT_SMART_CHUNKS?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

const MIN_SUSPECT_LOOP_WORDS = 6;
const MAX_SUSPECT_LOOP_WORDS = 16;
const MIN_SUSPECT_LOOP_OCCURRENCES = 3;
const MAX_SUSPECT_LOOP_CANDIDATES = 2_048;
const MAX_SUSPECT_LOOP_RESCAN_PASSES = 16;
const SUSPECT_CONTEXT_WORDS = 6;
const EXTENSION_BOUNDARY_ANCHOR_WORDS = 3;
const WITNESS_AGREEMENT_ANCHOR_WORDS = 6;
const CHUNK_NO_SPEECH_MIN_DBFS = -55;

interface SuspectChunkLoop {
  firstOccurrence: number;
  lastOccurrenceEnd: number;
  loopWordCount: number;
  occurrenceStarts: number[];
}

function findSuspectChunkLoops(text: string): SuspectChunkLoop[] {
  const words = normalizeChunkWords(text);
  const maxLoopWords = Math.min(
    MAX_SUSPECT_LOOP_WORDS,
    Math.floor(words.length / MIN_SUSPECT_LOOP_OCCURRENCES),
  );
  const suspects: SuspectChunkLoop[] = [];

  for (
    let loopWords = maxLoopWords;
    loopWords >= MIN_SUSPECT_LOOP_WORDS;
    loopWords--
  ) {
    const occurrences = new Map<string, number[]>();
    for (let index = 0; index + loopWords <= words.length; index++) {
      const key = overlapKey(words.slice(index, index + loopWords));
      const indexes = occurrences.get(key) ?? [];
      if (
        indexes.length === 0 ||
        index >= indexes[indexes.length - 1] + loopWords
      ) {
        indexes.push(index);
        occurrences.set(key, indexes);
      }
    }

    for (const indexes of occurrences.values()) {
      if (indexes.length < MIN_SUSPECT_LOOP_OCCURRENCES) continue;
      const candidate = {
        firstOccurrence: indexes[0],
        lastOccurrenceEnd: indexes[indexes.length - 1] + loopWords,
        loopWordCount: loopWords,
        occurrenceStarts: indexes,
      };
      suspects.push(candidate);
      if (suspects.length >= MAX_SUSPECT_LOOP_CANDIDATES) return suspects;
    }
  }

  return suspects;
}

function findSuspectChunkLoop(text: string): SuspectChunkLoop | null {
  return findSuspectChunkLoops(text)[0] ?? null;
}

function witnessCoversSuspectContext(
  suspectText: string,
  suspect: SuspectChunkLoop,
  witnessText: string,
): boolean {
  const suspectWords = normalizeChunkWords(suspectText);
  const prefix = suspectWords.slice(
    Math.max(0, suspect.firstOccurrence - SUSPECT_CONTEXT_WORDS),
    suspect.firstOccurrence,
  );
  const suffix = suspectWords.slice(
    suspect.lastOccurrenceEnd,
    suspect.lastOccurrenceEnd + SUSPECT_CONTEXT_WORDS,
  );
  const witnessKey = canonicalWitnessText(witnessText);
  const anchor = prefix.length > 0 ? prefix : suffix;
  return (
    anchor.length > 0 &&
    witnessKey.includes(canonicalWitnessText(anchor.join(" ")))
  );
}

function canonicalWitnessText(text: string): string {
  // AIDEV-NOTE: This compact form is comparison-only. It tolerates Whisper's
  // contraction and split-token drift; never use it to construct emitted text,
  // because it intentionally removes separators and fragment ellipses.
  return text
    .normalize("NFKC")
    .toLocaleLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "");
}

function collapseSuspectLoopWords(
  text: string,
  suspect: SuspectChunkLoop | null = findSuspectChunkLoop(text),
  keepOccurrences = 1,
): string[] {
  const words = normalizeChunkWords(text);
  if (!suspect) return words;
  const duplicateStarts = new Set(
    suspect.occurrenceStarts.slice(keepOccurrences),
  );
  const collapsed: string[] = [];
  for (let index = 0; index < words.length;) {
    if (duplicateStarts.has(index)) {
      index += suspect.loopWordCount;
      continue;
    }
    collapsed.push(words[index]);
    index++;
  }
  return collapsed;
}

function collapsedWitnessKey(text: string): string {
  return canonicalWitnessText(collapseSuspectLoopWords(text).join(" "));
}

function collapseAcousticallyRejectedLoop(
  text: string,
  suspect: SuspectChunkLoop,
  supportedOccurrences: number,
): string {
  return collapseSuspectLoopWords(
    text,
    suspect,
    supportedOccurrences,
  ).join(" ");
}

function hasDistinctSuspectSuffix(
  originalText: string,
  suspect: SuspectChunkLoop,
): boolean {
  const originalWords = normalizeChunkWords(originalText);
  const suffixWords = originalWords.slice(
    suspect.lastOccurrenceEnd,
    suspect.lastOccurrenceEnd + SUSPECT_CONTEXT_WORDS,
  );
  const suffixKey = canonicalWitnessText(suffixWords.join(" "));
  const suspectRegionKey = canonicalWitnessText(
    originalWords
      .slice(suspect.firstOccurrence, suspect.lastOccurrenceEnd)
      .join(" "),
  );
  return Boolean(suffixKey) && !suspectRegionKey.includes(suffixKey);
}

function hasDetectableResidualLoop(suspect: SuspectChunkLoop): boolean {
  let minimumStride = Number.POSITIVE_INFINITY;
  for (let index = 1; index < suspect.occurrenceStarts.length; index++) {
    minimumStride = Math.min(
      minimumStride,
      suspect.occurrenceStarts[index] - suspect.occurrenceStarts[index - 1],
    );
  }
  const residualWords = minimumStride - suspect.loopWordCount;
  return residualWords === 0 || residualWords >= MIN_SUSPECT_LOOP_WORDS;
}

function countSuspectPhraseOccurrences(
  originalText: string,
  suspect: SuspectChunkLoop,
  witnessText: string,
  extensionBoundaryText: string | null,
): number | null {
  const originalWords = normalizeChunkWords(originalText);
  const phraseKey = canonicalWitnessText(
    originalWords
      .slice(
        suspect.firstOccurrence,
        suspect.firstOccurrence + suspect.loopWordCount,
      )
      .join(" "),
  );
  const phraseWords = originalWords.slice(
    suspect.firstOccurrence,
    suspect.firstOccurrence + suspect.loopWordCount,
  );
  const witnessWords = normalizeChunkWords(witnessText);
  const prefixWords = originalWords.slice(
    Math.max(0, suspect.firstOccurrence - SUSPECT_CONTEXT_WORDS),
    suspect.firstOccurrence,
  );
  const suffixWords = originalWords.slice(
    suspect.lastOccurrenceEnd,
    suspect.lastOccurrenceEnd + SUSPECT_CONTEXT_WORDS,
  );
  const suffixBoundaryIsDistinct = hasDistinctSuspectSuffix(
    originalText,
    suspect,
  );
  // The witness is five seconds longer than the production chunk. A repeated
  // phrase after the original suffix belongs to that extension and cannot
  // authorize retaining another copy inside the original 30-second decode.
  let searchFrom = 0;
  if (prefixWords.length > 0) {
    const prefixRange = findChunkWordSequence(
      witnessWords,
      prefixWords,
      searchFrom,
    );
    if (!prefixRange) return null;
    searchFrom = prefixRange.end;
  }
  // The same suffix words may have been spoken earlier in the witness. Anchor
  // the boundary search after an actual occurrence of the suspect phrase so
  // an earlier suffix cannot make the original acoustic region look empty.
  const firstPhraseRange = findChunkWordSequence(
    witnessWords,
    phraseWords,
    searchFrom,
  );
  // A completely hallucinated loop is legitimately absent from both
  // witnesses, so zero occurrences remains usable acoustic evidence. Only
  // shift the boundary search when the phrase actually occurs.
  const boundarySearchFrom = firstPhraseRange?.end ?? searchFrom;
  const extensionBoundaryWords = normalizeChunkWords(
    extensionBoundaryText ?? "",
  ).slice(0, EXTENSION_BOUNDARY_ANCHOR_WORDS);
  const extensionBoundaryKey = canonicalWitnessText(
    extensionBoundaryWords.join(" "),
  );
  const originalChunkKey = canonicalWitnessText(originalWords.join(" "));
  // If the extension begins with the loop itself, text cannot distinguish the
  // true time boundary from an in-chunk loop copy. Fail closed rather than
  // deleting a genuine repetition on an ambiguous acoustic boundary.
  const ambiguousExtensionBoundary =
    Boolean(extensionBoundaryKey) &&
    originalChunkKey.includes(extensionBoundaryKey);
  // A loop at the original chunk tail has no textual suffix. Decode the
  // witness-only five seconds separately and use its first acoustic words as
  // the boundary instead. If that decode is empty or cannot be located, leave
  // the original unchanged rather than guessing at timing.
  const suffixRange =
    suffixBoundaryIsDistinct
      ? findChunkWordSequence(witnessWords, suffixWords, boundarySearchFrom)
      : null;
  const extensionRange =
    !suffixRange &&
    extensionBoundaryWords.length > 0 &&
    !ambiguousExtensionBoundary
      ? findChunkWordSequence(
          witnessWords,
          extensionBoundaryWords,
          boundarySearchFrom,
        )
      : null;
  const boundaryRange = suffixRange ?? extensionRange;
  if (!boundaryRange) return null;
  const originalRegionKey = canonicalWitnessText(
    witnessWords.slice(searchFrom, boundaryRange.start).join(" "),
  );
  let count = 0;
  let searchOffset = 0;
  while (phraseKey && searchOffset + phraseKey.length <= originalRegionKey.length) {
    const matchOffset = originalRegionKey.indexOf(phraseKey, searchOffset);
    if (matchOffset < 0) break;
    count++;
    searchOffset = matchOffset + phraseKey.length;
  }
  return count;
}

function findChunkWordSequence(
  words: string[],
  sequence: string[],
  fromIndex: number,
): { start: number; end: number } | null {
  const sequenceKey = canonicalWitnessText(sequence.join(" "));
  const minimumWords = Math.max(1, sequence.length - 2);
  const maximumWords = sequence.length + 2;
  let bestMatch: { start: number; end: number; extraCharacters: number } | null =
    null;
  for (let index = fromIndex; index < words.length; index++) {
    for (let wordCount = minimumWords; wordCount <= maximumWords; wordCount++) {
      if (index + wordCount > words.length) break;
      const candidateKey = canonicalWitnessText(
        words.slice(index, index + wordCount).join(" "),
      );
      if (!candidateKey.includes(sequenceKey)) continue;
      const extraCharacters = candidateKey.length - sequenceKey.length;
      if (extraCharacters === 0) {
        return { start: index, end: index + wordCount };
      }
      if (!bestMatch || extraCharacters < bestMatch.extraCharacters) {
        bestMatch = {
          start: index,
          end: index + wordCount,
          extraCharacters,
        };
      }
    }
  }
  return bestMatch
    ? { start: bestMatch.start, end: bestMatch.end }
    : null;
}

function witnessContainsSuspectSuffix(
  originalText: string,
  suspect: SuspectChunkLoop,
  witnessText: string,
): boolean {
  const originalWords = normalizeChunkWords(originalText);
  const suffixWords = originalWords.slice(
    suspect.lastOccurrenceEnd,
    suspect.lastOccurrenceEnd + SUSPECT_CONTEXT_WORDS,
  );
  return (
    hasDistinctSuspectSuffix(originalText, suspect) &&
    findChunkWordSequence(normalizeChunkWords(witnessText), suffixWords, 0) !==
      null
  );
}

function witnessesAgree(leftText: string, rightText: string): boolean {
  const leftKey = canonicalWitnessText(leftText);
  const rightKey = canonicalWitnessText(rightText);
  if (!leftKey || !rightKey) return false;
  const canonicalContainment =
    leftKey.includes(rightKey) || rightKey.includes(leftKey);
  const leftLoop = findSuspectChunkLoop(leftText);
  const rightLoop = findSuspectChunkLoop(rightText);
  if (leftLoop || rightLoop) {
    if (!leftLoop || !rightLoop) return false;
    const collapsedLeft = collapsedWitnessKey(leftText);
    const collapsedRight = collapsedWitnessKey(rightText);
    return (
      collapsedLeft.includes(collapsedRight) ||
      collapsedRight.includes(collapsedLeft)
    );
  }
  if (canonicalContainment) return true;

  const leftWords = normalizeChunkWords(leftText);
  const rightWords = normalizeChunkWords(rightText);
  const shorterWords =
    leftWords.length <= rightWords.length ? leftWords : rightWords;
  const longerKey = leftWords.length <= rightWords.length ? rightKey : leftKey;
  let firstAnchorEnd = -1;
  for (
    let index = 0;
    index + WITNESS_AGREEMENT_ANCHOR_WORDS <= shorterWords.length;
    index++
  ) {
    const anchorKey = canonicalWitnessText(
      shorterWords
        .slice(index, index + WITNESS_AGREEMENT_ANCHOR_WORDS)
        .join(" "),
    );
    if (!longerKey.includes(anchorKey)) continue;
    if (firstAnchorEnd < 0) {
      firstAnchorEnd = index + WITNESS_AGREEMENT_ANCHOR_WORDS;
    } else if (index >= firstAnchorEnd) {
      return true;
    }
  }
  return false;
}

function chooseWordPreservingWitness(leftText: string, rightText: string): string {
  return collapsedWitnessKey(rightText).length > collapsedWitnessKey(leftText).length
    ? rightText
    : leftText;
}

function witnessPreservesOriginalWords(
  originalText: string,
  originalLoop: SuspectChunkLoop | null,
  witnessText: string,
): boolean {
  const originalKey = canonicalWitnessText(
    collapseSuspectLoopWords(originalText, originalLoop).join(" "),
  );
  return collapsedWitnessKey(witnessText).includes(originalKey);
}

function readAscii(bytes: Uint8Array, offset: number, length: number): string {
  return String.fromCharCode(...bytes.slice(offset, offset + length));
}

function parseWavPcmInfo(wavData: Uint8Array): WavPcmInfo | null {
  if (wavData.byteLength < 44) return null;
  const view = new DataView(
    wavData.buffer,
    wavData.byteOffset,
    wavData.byteLength,
  );
  if (
    readAscii(wavData, 0, 4) !== "RIFF" ||
    readAscii(wavData, 8, 4) !== "WAVE"
  ) {
    return null;
  }

  let dataOffset = -1;
  let dataSize = 0;
  let byteRate = 0;
  let blockAlign = 0;

  for (let offset = 12; offset + 8 <= wavData.byteLength;) {
    const chunkId = readAscii(wavData, offset, 4);
    const chunkSize = view.getUint32(offset + 4, true);
    const chunkDataOffset = offset + 8;
    if (chunkDataOffset + chunkSize > wavData.byteLength) return null;

    if (chunkId === "fmt " && chunkSize >= 16) {
      byteRate = view.getUint32(chunkDataOffset + 8, true);
      blockAlign = view.getUint16(chunkDataOffset + 12, true);
    } else if (chunkId === "data") {
      dataOffset = chunkDataOffset;
      dataSize = chunkSize;
      break;
    }

    offset = chunkDataOffset + chunkSize + (chunkSize % 2);
  }

  if (dataOffset < 0 || dataSize <= 0 || byteRate <= 0 || blockAlign <= 0) {
    return null;
  }

  return {
    durationSeconds: dataSize / byteRate,
    dataOffset,
    dataSize,
    byteRate,
    blockAlign,
  };
}

function sliceWavSegment(
  wavData: Uint8Array,
  startSeconds: number,
  durationSeconds: number,
): Uint8Array | null {
  const info = parseWavPcmInfo(wavData);
  if (!info || durationSeconds <= 0 || startSeconds >= info.durationSeconds) {
    return null;
  }

  const startByte =
    Math.floor((startSeconds * info.byteRate) / info.blockAlign) *
    info.blockAlign;
  const requestedEndByte =
    Math.floor(
      (Math.min(startSeconds + durationSeconds, info.durationSeconds) *
        info.byteRate) /
        info.blockAlign,
    ) * info.blockAlign;
  const segmentStart = Math.max(0, Math.min(startByte, info.dataSize));
  const segmentEnd = Math.max(
    segmentStart,
    Math.min(requestedEndByte, info.dataSize),
  );
  const segmentSize = segmentEnd - segmentStart;
  if (segmentSize <= 0) return null;

  const header = wavData.slice(0, info.dataOffset);
  const segment = new Uint8Array(header.byteLength + segmentSize);
  segment.set(header, 0);
  segment.set(
    wavData.slice(info.dataOffset + segmentStart, info.dataOffset + segmentEnd),
    header.byteLength,
  );

  const segmentView = new DataView(segment.buffer);
  segmentView.setUint32(4, segment.byteLength - 8, true);
  segmentView.setUint32(info.dataOffset - 4, segmentSize, true);
  return segment;
}

function sliceWavTail(wavData: Uint8Array, seconds: number): Uint8Array | null {
  const info = parseWavPcmInfo(wavData);
  if (!info || info.durationSeconds <= seconds) return null;

  return sliceWavSegment(
    wavData,
    Math.max(0, info.durationSeconds - seconds),
    seconds,
  );
}

function isLowEnergyWavSegment(wavData: Uint8Array): boolean {
  const info = parseWavPcmInfo(wavData);
  if (!info) return true;
  const pcm = wavData.slice(info.dataOffset, info.dataOffset + info.dataSize);
  const rms = calculateRMS(pcm);
  if (rms <= 0) return true;
  const dbfs = 20 * Math.log10(rms / 32768);
  return dbfs < CHUNK_NO_SPEECH_MIN_DBFS;
}

/**
 * How two consecutive chunk texts meet.
 *
 * `anchor` is the historical behaviour: the chunks share several seconds of
 * re-decoded audio, so the merge finds the repeated words and folds them
 * together. `silence` is the smart path's seam inside a pause — the chunks
 * share only silence, so there is nothing to align and nothing to dedupe, and
 * reconciling anyway is what invented the "and I mean … and I mean" repeat on
 * golden clip B. Concatenating is not a shortcut here; it is the correct
 * operation, because the two texts are disjoint by construction.
 */
export type ChunkSeamKind = "anchor" | "silence";

export function mergeChunkTranscripts(
  chunks: string[],
  /** `seams[i]` describes the seam BEFORE `chunks[i]`; `seams[0]` is unused. */
  seams: ChunkSeamKind[] = [],
): string {
  const merged: string[] = [];

  for (const [chunkIndex, chunk] of chunks.entries()) {
    const nextWords = normalizeChunkWords(chunk);
    if (nextWords.length === 0) continue;

    if (merged.length === 0) {
      merged.push(...nextWords);
      continue;
    }

    if (seams[chunkIndex] === "silence") {
      merged.push(...nextWords);
      continue;
    }

    const { overlap, skipPrefix } = findChunkOverlap(merged, nextWords);

    if (overlap > 0) {
      for (let index = 0; index < overlap; index++) {
        const mergedIndex = merged.length - overlap + index;
        merged[mergedIndex] = preferOverlapWord(
          merged[mergedIndex],
          nextWords[skipPrefix + index],
          skipPrefix + index < nextWords.length - 1,
        );
      }
    }

    merged.push(...nextWords.slice(skipPrefix + overlap));
  }

  return normalizeProseQuoteSpacing(merged.join(" ").trim());
}

function hasChunkBoundaryOverlap(
  currentText: string,
  nextText: string,
): boolean {
  const currentWords = normalizeChunkWords(currentText);
  const nextWords = normalizeChunkWords(nextText);
  if (currentWords.length === 0 || nextWords.length === 0) return false;
  return findChunkOverlap(currentWords, nextWords).overlap > 0;
}

function shortFinalChunkAgrees(
  promptedText: string,
  unpromptedText: string,
): boolean {
  const promptedWords = normalizeChunkWords(promptedText);
  const unpromptedWords = normalizeChunkWords(unpromptedText);
  if (promptedWords.length === 0 || unpromptedWords.length === 0) return false;
  if (containsSimilarWordSequence(unpromptedWords, promptedWords)) return true;
  if (!containsSimilarWordSequence(promptedWords, unpromptedWords))
    return false;

  const minimumConfirmationWords =
    promptedWords.length <= 2
      ? promptedWords.length
      : Math.max(
          MIN_SHORT_FINAL_CONFIRMATION_WORDS,
          Math.ceil(promptedWords.length * MIN_SHORT_FINAL_CONFIRMATION_RATIO),
        );
  return unpromptedWords.length >= minimumConfirmationWords;
}

function stripTailVerificationArtifact(text: string, fullText: string): string {
  if (TRAILING_FILLER_AFTER_QUESTION.test(fullText.trim())) return text;
  return text.replace(TRAILING_FILLER_AFTER_QUESTION, "?");
}

function trimOneEchoedTrailingPhrase(
  text: string,
  options: {
    allowAdjacentEcho: boolean;
    allowAdjacentEchoContinuation: boolean;
  },
): { text: string; trimmedAdjacentEcho: boolean } {
  const words = normalizeChunkWords(text);
  const maxPhraseWords = Math.min(
    MAX_ECHOED_TAIL_WORDS,
    Math.floor(words.length / 2),
  );

  for (
    let phraseWords = maxPhraseWords;
    phraseWords >= MIN_ECHOED_TAIL_WORDS;
    phraseWords--
  ) {
    const tailStart = words.length - phraseWords;
    const tailKey = overlapKey(words.slice(tailStart));
    const searchStart = Math.max(0, tailStart - MAX_ECHOED_TAIL_LOOKBACK_WORDS);

    for (let index = tailStart - phraseWords; index >= searchStart; index--) {
      const candidate = words.slice(index, index + phraseWords);
      const interveningWords = tailStart - (index + phraseWords);
      const bridgeWords = words.slice(index + phraseWords, tailStart);
      if (startsWithDanglingTailContinuationCue(bridgeWords)) {
        continue;
      }
      const repeatedEarlier = containsEarlierWordSequence(
        words,
        candidate,
        index,
      );
      const repeatedPhraseBridge =
        isRepeatedPhraseBridge(bridgeWords, phraseWords, tailKey) ||
        containsWordSequence(bridgeWords, candidate);
      const allowedSeparatedEcho =
        interveningWords >= 2 && !repeatedPhraseBridge;
      const allowedAdjacentEcho =
        options.allowAdjacentEcho &&
        (interveningWords === 0 || repeatedPhraseBridge) &&
        (options.allowAdjacentEchoContinuation || repeatedEarlier);
      const allowedGap = allowedSeparatedEcho || allowedAdjacentEcho;
      if (allowedGap && overlapKey(candidate) === tailKey) {
        return {
          text: words.slice(0, tailStart).join(" ").trim(),
          trimmedAdjacentEcho: interveningWords === 0,
        };
      }
    }
  }

  return { text: text.trim(), trimmedAdjacentEcho: false };
}

function isRepeatedPhraseBridge(
  bridgeWords: string[],
  phraseWords: number,
  phraseKey: string,
): boolean {
  if (bridgeWords.length === 0 || bridgeWords.length % phraseWords !== 0) {
    return false;
  }
  for (let offset = 0; offset < bridgeWords.length; offset += phraseWords) {
    if (
      overlapKey(bridgeWords.slice(offset, offset + phraseWords)) !== phraseKey
    ) {
      return false;
    }
  }
  return true;
}

function containsWordSequence(words: string[], sequence: string[]): boolean {
  if (sequence.length === 0 || words.length < sequence.length) return false;
  const sequenceKey = overlapKey(sequence);
  for (let index = 0; index + sequence.length <= words.length; index++) {
    if (
      overlapKey(words.slice(index, index + sequence.length)) === sequenceKey
    ) {
      return true;
    }
  }
  return false;
}

function trimEchoedTrailingPhrase(
  text: string,
  options: { allowAdjacentEcho: boolean },
): string {
  let current = text.trim();
  let allowAdjacentEchoContinuation = false;
  for (let passes = 0; passes < 8; passes++) {
    const result = trimOneEchoedTrailingPhrase(current, {
      ...options,
      allowAdjacentEchoContinuation,
    });
    const trimmed = result.text;
    if (trimmed === current) return current;
    allowAdjacentEchoContinuation = result.trimmedAdjacentEcho;
    current = trimmed;
  }
  return current;
}

function allowsAdjacentTailEchoCleanup(wavData: Uint8Array): boolean {
  const info = parseWavPcmInfo(wavData);
  return (
    !!info && info.durationSeconds >= WAV_ADJACENT_ECHO_CLEANUP_MIN_SECONDS
  );
}

function combinePromptOverride(
  original: string | undefined,
  transcript: string,
): string | undefined {
  const tailPrompt = buildChunkPrompt(transcript);
  return [original, tailPrompt].filter(Boolean).join(" ").trim() || undefined;
}

// --- WhisperCpp Backend ---

/** Default model search order (most preferred first) */
const MODEL_SEARCH_PATHS = [
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-large-v3-turbo-q5_0.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.en.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-base.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-small.en.bin"),
  () => join(homedir(), ".cache", "whisper", "ggml-small.bin"),
];

/** Known binary names in preference order (v1.8.3+ renamed to whisper-cli) */
const WHISPER_BINARY_NAMES = ["whisper-cli", "whisper-cpp"];

/** Find whisper-cpp binary path. Probes Homebrew paths for daemon context. */
function findWhisperBinary(): string | null {
  for (const name of WHISPER_BINARY_NAMES) {
    const resolved = resolveBinary(name, [
      `/opt/homebrew/bin/${name}`,
      `/usr/local/bin/${name}`,
    ]);
    if (resolved) return resolved;
  }
  return null;
}

/**
 * The CLI binary `WhisperCppBackend` would run, resolved WITHOUT blocking the
 * event loop. Same names and same preference order as `findWhisperBinary()` —
 * one source of truth — but every probe is bounded, so provenance can ask which
 * executable produced a `whisper.cpp` transcript without a hanging binary
 * stalling daemon startup. See `src/recording-provenance.ts`.
 */
export async function resolveWhisperCliBinaryAsync(
  timeoutMs?: number,
): Promise<string | null> {
  for (const name of WHISPER_BINARY_NAMES) {
    const resolved = await resolveBinaryAsync(
      name,
      [`/opt/homebrew/bin/${name}`, `/usr/local/bin/${name}`],
      timeoutMs,
    );
    if (resolved) return resolved;
  }
  return null;
}

/** Find a GGML model file. Returns null if none found. */
function findModel(): string | null {
  // 1. Explicit env var
  const envModel = process.env.QA_VOICE_WHISPER_MODEL;
  if (envModel) {
    if (existsSync(envModel)) return envModel;
    console.error(
      `[voicelayer] Warning: QA_VOICE_WHISPER_MODEL path does not exist: ${envModel}`,
    );
  }

  // 2. Search standard paths
  for (const pathFn of MODEL_SEARCH_PATHS) {
    const p = pathFn();
    if (existsSync(p)) return p;
  }

  // 3. Scan ~/.cache/whisper/ for any ggml model
  const cacheDir = join(homedir(), ".cache", "whisper");
  if (existsSync(cacheDir)) {
    try {
      const files = readdirSync(cacheDir);
      const model = files.find(
        (f: string) => f.startsWith("ggml-") && f.endsWith(".bin"),
      );
      if (model) return join(cacheDir, model);
    } catch {
      // Ignore scan errors
    }
  }

  return null;
}

/** Get homebrew prefix for Metal shader resources (cached) */
let cachedBrewPrefix: string | null | undefined = undefined;
function getBrewPrefix(): string | null {
  if (cachedBrewPrefix !== undefined) return cachedBrewPrefix;
  const brewBinary = resolveBinary("brew", [
    "/opt/homebrew/bin/brew",
    "/usr/local/bin/brew",
  ]);
  if (!brewBinary) {
    cachedBrewPrefix = null;
    return cachedBrewPrefix;
  }
  const result = Bun.spawnSync([brewBinary, "--prefix", "whisper-cpp"]);
  cachedBrewPrefix =
    result.exitCode === 0 ? result.stdout.toString().trim() : null;
  return cachedBrewPrefix;
}

export class WhisperCppBackend implements STTBackend {
  name = "whisper.cpp";
  private binaryPath: string | null = null;
  private modelPath: string | null = null;

  async isAvailable(): Promise<boolean> {
    this.binaryPath = findWhisperBinary();
    this.modelPath = findModel();
    return this.binaryPath !== null && this.modelPath !== null;
  }

  async transcribe(
    audioPath: string,
    options?: STTTranscribeOptions,
  ): Promise<STTResult> {
    if (!this.binaryPath) this.binaryPath = findWhisperBinary();
    if (!this.modelPath) this.modelPath = findModel();

    if (!this.binaryPath) {
      throw new Error(
        "whisper-cpp binary not found (looked for: whisper-cli, whisper-cpp). Install:\n" +
          "  macOS: brew install whisper-cpp\n" +
          "  Linux: build from source — https://github.com/ggerganov/whisper.cpp",
      );
    }
    if (!this.modelPath) {
      throw new Error(
        "No whisper model found. Download one:\n" +
          "  mkdir -p ~/.cache/whisper\n" +
          "  curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\\n" +
          "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin",
      );
    }

    const start = Date.now();

    // Build env with Metal shader path if available
    const env: Record<string, string> = {};
    for (const [k, v] of Object.entries(process.env)) {
      if (typeof v === "string") env[k] = v;
    }
    const brewPrefix = getBrewPrefix();
    if (brewPrefix) {
      env.GGML_METAL_PATH_RESOURCES = join(brewPrefix, "share", "whisper-cpp");
    }

    // AIDEV-NOTE: Language config drives whisper args — supports auto (mixed
    // Hebrew-English), hebrew, or english modes. Auto omits -l for auto-detect.
    // Initial prompt primes vocabulary for dev terms in the configured language.
    const langMode = getLanguageModeFromEnv();
    const langConfig = getLanguageConfig(langMode);
    const basePrompt = [getInitialPrompt(langMode), getSTTVocabularyPrompt()]
      .filter(Boolean)
      .join(" ")
      .trim();
    const prompt = options?.promptOverride
      ? `${basePrompt} ${options.promptOverride}`.trim()
      : basePrompt;
    const whisperArgs = [...langConfig.whisperArgs];
    const promptIndex = whisperArgs.indexOf("--prompt");
    if (promptIndex >= 0 && promptIndex + 1 < whisperArgs.length) {
      whisperArgs[promptIndex + 1] = prompt;
    }

    const args = [
      this.binaryPath,
      "-m",
      this.modelPath,
      "-f",
      audioPath,
      "--no-timestamps",
      ...whisperArgs,
      "--no-prints", // suppress progress output
    ];

    const proc = Bun.spawn(args, {
      stdout: "pipe",
      stderr: "pipe",
      env,
    });

    const [stdout, stderr] = await Promise.all([
      new Response(proc.stdout).text(),
      new Response(proc.stderr).text(),
    ]);
    const exitCode = await proc.exited;

    if (exitCode !== 0) {
      throw new Error(
        `whisper-cpp failed (exit ${exitCode}): ${stderr.slice(0, 500)}`,
      );
    }

    // whisper-cpp outputs transcription text, clean it up
    const text = stdout
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0)
      .join(" ")
      .trim();

    return {
      text,
      backend: this.name,
      durationMs: Date.now() - start,
    };
  }

  /** Get info about the detected model (for logging) */
  getModelInfo(): { binary: string | null; model: string | null } {
    return {
      binary: this.binaryPath ?? findWhisperBinary(),
      model: this.modelPath ?? findModel(),
    };
  }
}

// --- Resident Whisper Server Backend ---

interface WhisperServerBackendDeps {
  isServerAvailable?: () => boolean;
  transcribeViaServer?: (
    wavData: Uint8Array,
    options?: WhisperServerTranscribeOptions,
  ) => Promise<string>;
  fallbackBackend?: STTBackend;
}

export class WhisperServerBackend implements STTBackend {
  name = "whisper-server";
  private readonly isResidentAvailable: () => boolean;
  private readonly transcribeResident: (
    wavData: Uint8Array,
    options?: WhisperServerTranscribeOptions,
  ) => Promise<string>;
  private readonly fallbackBackend: STTBackend;

  constructor(deps: WhisperServerBackendDeps = {}) {
    this.isResidentAvailable = deps.isServerAvailable ?? isServerAvailable;
    this.transcribeResident =
      deps.transcribeViaServer ??
      ((wavData, options) => transcribeViaServer(wavData, undefined, options));
    this.fallbackBackend = deps.fallbackBackend ?? new WhisperCppBackend();
  }

  async isAvailable(): Promise<boolean> {
    return this.isResidentAvailable();
  }

  async transcribe(
    audioPath: string,
    options?: STTTranscribeOptions,
  ): Promise<STTResult> {
    const start = Date.now();
    const wavData = new Uint8Array(await Bun.file(audioPath).arrayBuffer());

    try {
      const chunkedResult = await this.transcribeChunkedLongRecording(
        wavData,
        options,
      );
      if (chunkedResult) {
        // The outro gate does not run here. Each chunk's segment timestamps are
        // chunk-relative, so stitching them across C1's overlap seam into one
        // timeline is a separate change — and a span measured against the wrong
        // offset is exactly how this gate would delete a real word. Same
        // exclusion the pause-aware boundaries carry (PR #30).
        const backendParts = [this.name, "chunks"];
        if (chunkedResult.witnessed) backendParts.push("witness");
        if (chunkedResult.headChanged) backendParts.push("head");
        if (chunkedResult.cleaned) backendParts.push("clean");
        return {
          text: chunkedResult.text,
          backend: backendParts.join("+"),
          durationMs: Date.now() - start,
        };
      }

      const smartBoundaries = smartBoundariesEnabled(process.env);
      const outroGate = outroGateEnabled(process.env);
      let segments: TranscriptSegment[] | undefined;
      // Either flag needs `verbose_json`; with both off the request stays
      // byte-for-byte the shipped `json` one.
      const text = await this.transcribeResident(wavData, {
        ...buildWhisperServerOptions(options),
        ...(smartBoundaries || outroGate
          ? {
              onSegments: (found: TranscriptSegment[]) => {
                segments = found;
              },
            }
          : {}),
      });
      if (!text.trim()) {
        console.error(
          "[voicelayer] whisper-server returned empty text, falling back to whisper-cli",
        );
        const fallback = await this.fallbackBackend.transcribe(
          audioPath,
          options,
        );
        return {
          ...fallback,
          backend: `${this.name}->${fallback.backend}`,
          durationMs: Date.now() - start,
        };
      }
      const headResult = await this.verifyLeadingPunctuation(
        audioPath,
        wavData,
        text,
        options,
      );
      const verifiedText = await this.verifyTailForLongRecording(
        wavData,
        headResult.text,
        options,
      );
      const cleanedText = trimEchoedTrailingPhrase(verifiedText, {
        allowAdjacentEcho: allowsAdjacentTailEchoCleanup(wavData),
      });
      // Last, on the finished text: an invented closer is only removable
      // against the audio it was attributed to, and `segments` describe THIS
      // decode of THIS wav.
      //
      // `segmentsText` is the raw decode output, so the gate can refuse when an
      // earlier stage rewrote the transcript out from under those timings.
      // `verifyLeadingPunctuation` can swap in a whole retry decode,
      // `verifyTailForLongRecording` can merge in recovered tail words, and
      // `trimEchoedTrailingPhrase` can remove some — each shifts the word
      // positions the span lookup counts on. A repaired transcript therefore
      // gets NO outro gating, which is the deliberate trade: skipping a
      // hallucinated closer is recoverable, deleting a real word is not.
      //
      // AIDEV-NOTE: that is also the answer to "a long recording through
      // `verifyTailForLongRecording` can still keep its closer" — it can, by
      // design, whenever that stage changed the text. Widening this needs the
      // repaired text's own decode segments, not a looser check here.
      const gated = outroGate
        ? stripHallucinatedOutro(cleanedText, wavData, {
            segments,
            segmentsText: text,
          })
        : { text: cleanedText, removed: [], reason: "no-candidate" as const };
      if (outroGate && gated.reason === "segments-stale") {
        console.error(
          "[voicelayer] outro gate: transcript was repaired after the decode; " +
            "segment timings no longer describe it, skipping",
        );
      }
      for (const removal of gated.removed) {
        console.error(
          `[voicelayer] outro gate: dropped ${JSON.stringify(removal.phrase)} at ` +
            `${removal.startS.toFixed(2)}-${removal.endS.toFixed(2)}s ` +
            `(${removal.spanDbfs.toFixed(1)} dBFS mean, ${removal.peakDbfs.toFixed(1)} peak)`,
        );
      }
      const backendParts = [this.name];
      if (headResult.changed) {
        backendParts.push(headResult.backendSuffix ?? "head");
      }
      if (verifiedText !== headResult.text) backendParts.push("tail");
      if (cleanedText !== verifiedText) backendParts.push("clean");
      if (gated.removed.length > 0) backendParts.push("outro");
      return {
        text: gated.text,
        backend: backendParts.join("+"),
        durationMs: Date.now() - start,
        ...(segments && segments.length > 0
          ? {
              segments,
              segmentsAudioSha256: createHash("sha256")
                .update(wavData)
                .digest("hex"),
            }
          : {}),
      };
    } catch (err) {
      console.error(
        `[voicelayer] whisper-server failed, falling back to whisper-cli: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
      const fallback = await this.fallbackBackend.transcribe(
        audioPath,
        options,
      );
      return {
        ...fallback,
        backend: `${this.name}->${fallback.backend}`,
        durationMs: Date.now() - start,
      };
    }
  }

  private async verifyLeadingPunctuation(
    audioPath: string,
    wavData: Uint8Array,
    fullText: string,
    options?: STTTranscribeOptions,
  ): Promise<{ text: string; changed: boolean; backendSuffix?: string }> {
    if (!LEADING_PUNCTUATION.test(fullText.trim())) {
      return { text: fullText, changed: false };
    }

    try {
      const retryText = await this.transcribeResident(
        wavData,
        buildWhisperServerOptions(options),
      );
      const trimmedRetry = retryText.trim();
      if (
        trimmedRetry &&
        !LEADING_PUNCTUATION.test(trimmedRetry) &&
        hasLeadingPunctuationRepairOverlap(fullText, trimmedRetry)
      ) {
        return { text: trimmedRetry, changed: true };
      }
    } catch (err) {
      console.error(
        `[voicelayer] whisper-server head verification failed; trying whisper-cli fallback: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }

    try {
      const fallback = await this.fallbackBackend.transcribe(
        audioPath,
        options,
      );
      const fallbackText = fallback.text.trim();
      if (
        fallbackText &&
        !LEADING_PUNCTUATION.test(fallbackText) &&
        hasLeadingPunctuationRepairOverlap(fullText, fallbackText)
      ) {
        return { text: fallbackText, changed: true, backendSuffix: "head-cli" };
      }
    } catch (err) {
      console.error(
        `[voicelayer] whisper-cli head verification failed; keeping full-window text: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }

    return { text: fullText, changed: false };
  }

  private async verifyTailForLongRecording(
    wavData: Uint8Array,
    fullText: string,
    options?: STTTranscribeOptions,
  ): Promise<string> {
    const info = parseWavPcmInfo(wavData);
    if (!info || info.durationSeconds < WAV_TAIL_VERIFY_MIN_SECONDS) {
      return fullText;
    }

    const tailWav = sliceWavTail(wavData, WAV_TAIL_VERIFY_SECONDS);
    if (!tailWav) return fullText;
    // Late-stop PTT often leaves a silent last 12s. Decoding that window
    // hallucinates YouTube outros ("All right. Thank you.") and merge can
    // append them after a 2-word overlap such as "All right".
    if (isLowEnergyWavSegment(tailWav)) return fullText;

    try {
      const tailText = await this.transcribeResident(
        tailWav,
        buildWhisperServerOptions({
          promptOverride: combinePromptOverride(
            options?.promptOverride,
            fullText,
          ),
        }),
      );
      const merged = mergeTailVerificationTranscript(fullText, tailText);
      if (merged.text !== fullText) {
        return stripTailVerificationArtifact(merged.text, fullText);
      }
      if (
        merged.confirmedOverlap &&
        !hasDanglingTailContinuationCue(normalizeChunkWords(fullText))
      ) {
        return fullText;
      }

      const unpromptedTailText = await this.transcribeResident(
        tailWav,
        buildWhisperServerOptions({ ...options, promptOverride: undefined }),
      );
      const unpromptedMerged = mergeTailVerificationTranscript(
        fullText,
        unpromptedTailText,
      );
      return unpromptedMerged.text !== fullText
        ? stripTailVerificationArtifact(unpromptedMerged.text, fullText)
        : fullText;
    } catch (err) {
      console.error(
        `[voicelayer] whisper-server tail verification failed; keeping full-window text: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
      return fullText;
    }
  }

  private async transcribeChunkedLongRecording(
    wavData: Uint8Array,
    options?: STTTranscribeOptions,
  ): Promise<{
    text: string;
    witnessed: boolean;
    headChanged: boolean;
    cleaned: boolean;
  } | null> {
    const info = parseWavPcmInfo(wavData);
    if (!info || info.durationSeconds < WAV_CHUNKED_DECODE_MIN_SECONDS) {
      return null;
    }

    const transcripts: string[] = [];
    // seamKinds[i] describes the seam BEFORE transcripts[i]. A boundary chosen
    // deep inside a pause makes the NEXT chunk's seam a silence seam.
    const seamKinds: ChunkSeamKind[] = [];
    let nextSeamKind: ChunkSeamKind = "anchor";
    let witnessed = false;
    let scheduleShiftedByWitness = false;
    let fullUnpromptedWitness: Promise<string> | null = null;
    const getFullUnpromptedWitness = (): Promise<string> => {
      fullUnpromptedWitness ??= this.transcribeResident(
        wavData,
        buildWhisperServerOptions({
          ...options,
          promptOverride: undefined,
        }),
      );
      return fullUnpromptedWitness;
    };
    // AIDEV-NOTE: the pause map is computed once per recording (Silero over the
    // whole file is ~0.3 s for 109 s of audio) and only when the flag is on. A
    // failure here is never fatal: an empty map makes chooseChunkEnd return the
    // fixed cut, i.e. today's behaviour.
    let pauseMap: PauseSpan[] = [];
    if (isSmartWavChunkingEnabled()) {
      try {
        const candidate = await computePauseMap(wavData);
        const pauseSeconds = candidate.reduce(
          (total, span) => total + (span.endS - span.startS),
          0,
        );
        const speechRatio =
          (info.durationSeconds - pauseSeconds) / info.durationSeconds;
        if (speechRatio < MIN_SMART_CHUNK_SPEECH_RATIO) {
          console.error(
            `[voicelayer] smart chunking skipped: only ${(speechRatio * 100).toFixed(1)}% of ` +
              `this recording decodes as speech; keeping fixed ${WAV_CHUNK_SECONDS}s cuts`,
          );
        } else {
          pauseMap = candidate;
          console.error(
            `[voicelayer] smart chunk pause map: ${pauseMap.length} pause(s) >= 300ms, ` +
              `${(speechRatio * 100).toFixed(1)}% speech`,
          );
        }
      } catch (err) {
        console.error(
          `[voicelayer] smart chunking unavailable; keeping fixed ${WAV_CHUNK_SECONDS}s cuts: ${
            err instanceof Error ? err.message : String(err)
          }`,
        );
      }
    }

    for (
      let startSeconds = 0;
      startSeconds < info.durationSeconds;
      // startSeconds advances explicitly below because an accepted 35-second
      // witness changes the next boundary while preserving the 5-second overlap.
    ) {
      // With the flag off this is always WAV_CHUNK_SECONDS, so every expression
      // below reduces to the constant it used before.
      const plannedChunkSeconds =
        pauseMap.length > 0
          ? chooseChunkEnd(
              startSeconds,
              pauseMap,
              { min: SMART_CHUNK_MIN_SECONDS, max: WAV_CHUNK_SECONDS },
              // A recording ends in silence, so the last pause the boundary
              // rule can see often ends a fraction of a second before the file
              // does — and the scrap left behind is exactly what the very-short
              // -final-chunk check below throws away, because a silence seam
              // never has the overlap that check treats as evidence of health.
              // Tell the boundary rule how much audio is left so it splits the
              // remainder instead of stranding it.
              {
                durationS: info.durationSeconds,
                minFinalSeconds: WAV_TAIL_VERIFY_MIN_SECONDS,
              },
            ) - startSeconds
          : WAV_CHUNK_SECONDS;
      // A cut inside a pause needs no anchor, so it keeps only enough overlap
      // to guarantee no gap. Everything else keeps the full re-decoded overlap.
      const cutIsSilenceSeam = isSilenceSeam(
        startSeconds + plannedChunkSeconds,
        pauseMap,
        SILENCE_SEAM_OVERLAP_SECONDS,
      );
      const seamOverlapSeconds = cutIsSilenceSeam
        ? SILENCE_SEAM_OVERLAP_SECONDS
        : WAV_CHUNK_OVERLAP_SECONDS;
      let seamKindAfterThisChunk: ChunkSeamKind = cutIsSilenceSeam
        ? "silence"
        : "anchor";
      const seamKindBeforeThisChunk = nextSeamKind;
      let nextStartSeconds =
        startSeconds + plannedChunkSeconds - seamOverlapSeconds;
      const remainingSeconds = info.durationSeconds - startSeconds;
      const chunkSeconds =
        scheduleShiftedByWitness &&
        remainingSeconds < plannedChunkSeconds + WAV_TAIL_VERIFY_MIN_SECONDS
          ? remainingSeconds
          : plannedChunkSeconds;
      const isVeryShortFinalChunk =
        chunkSeconds >= remainingSeconds &&
        remainingSeconds < WAV_TAIL_VERIFY_MIN_SECONDS;
      // AIDEV-NOTE: a skipped chunk means audio was OMITTED between the last
      // decoded chunk and the next one, so they cannot share words and the
      // anchor merge would be free to "dedupe" a genuine repeat across the gap
      // and lose it (CodeRabbit, PR #31). Only applied on the smart path: with
      // the pause map empty this is the shipped fixed-cut decode, and the same
      // hazard there is pre-existing and out of scope for an opt-in flag.
      const seamAfterSkip: ChunkSeamKind =
        pauseMap.length > 0 ? "silence" : seamKindAfterThisChunk;
      const segment = sliceWavSegment(wavData, startSeconds, chunkSeconds);
      if (!segment) {
        nextSeamKind = seamAfterSkip;
        startSeconds = nextStartSeconds;
        continue;
      }
      if (isLowEnergyWavSegment(segment)) {
        nextSeamKind = seamAfterSkip;
        startSeconds = nextStartSeconds;
        continue;
      }

      const mergedSoFar = mergeChunkTranscripts(transcripts, seamKinds);
      let text = await this.transcribeResident(
        segment,
        buildWhisperServerOptions({
          promptOverride: mergedSoFar
            ? combinePromptOverride(options?.promptOverride, mergedSoFar)
            : options?.promptOverride,
        }),
      );
      if (!text.trim()) return null;
      const suspectLoops = mergedSoFar ? findSuspectChunkLoops(text) : [];
      const suspectLoop = suspectLoops[0] ?? null;
      // At a silence seam the chunks share only silence, so a missing overlap
      // is the expected outcome, not evidence of damage. Firing the witness
      // machinery here is what produced the seam repeat on golden clip B.
      const droppedBoundaryOverlap =
        seamKindBeforeThisChunk !== "silence" &&
        Boolean(mergedSoFar) &&
        !hasChunkBoundaryOverlap(mergedSoFar, text);
      if (
        (suspectLoop || droppedBoundaryOverlap) &&
        startSeconds + chunkSeconds < info.durationSeconds
      ) {
        const witnessSeconds = plannedChunkSeconds + WAV_CHUNK_OVERLAP_SECONDS;
        const witnessSegment = sliceWavSegment(
          wavData,
          startSeconds,
          witnessSeconds,
        );
        const witnessInfo = witnessSegment
          ? parseWavPcmInfo(witnessSegment)
          : null;
        if (
          witnessSegment &&
          witnessInfo &&
          witnessInfo.durationSeconds > plannedChunkSeconds
        ) {
          const promptedWitness = await this.transcribeResident(
            witnessSegment,
            buildWhisperServerOptions({
              ...options,
              promptOverride: combinePromptOverride(
                options?.promptOverride,
                mergedSoFar,
              ),
            }),
          );
          const unpromptedWitness = await this.transcribeResident(
            witnessSegment,
            buildWhisperServerOptions({
              ...options,
              promptOverride: undefined,
            }),
          );
          const promptedCovers = suspectLoop
            ? suspectLoops.some((candidate) =>
                witnessCoversSuspectContext(text, candidate, promptedWitness),
              )
            : hasChunkBoundaryOverlap(mergedSoFar, promptedWitness);
          const unpromptedCovers = suspectLoop
            ? suspectLoops.some((candidate) =>
                witnessCoversSuspectContext(text, candidate, unpromptedWitness),
              )
            : hasChunkBoundaryOverlap(mergedSoFar, unpromptedWitness);
          let chosenWitness: string | null = null;
          let supportingWitnesses: string[] = [];
          let agreement = "none";
          let rejectedByWordLossGuard = false;
          let acousticallyRejectedLoop = false;
          let genuineRepeatedSpeech = false;
          let witnessCountDisagreement = false;

          if (
            promptedCovers &&
            unpromptedCovers &&
            witnessesAgree(promptedWitness, unpromptedWitness)
          ) {
            chosenWitness = chooseWordPreservingWitness(
              promptedWitness,
              unpromptedWitness,
            );
            supportingWitnesses = [promptedWitness, unpromptedWitness];
            agreement = "extended-pair";
          } else {
            const fullWitness = await getFullUnpromptedWitness();
            const fullSupportsPrompted =
              promptedCovers && witnessesAgree(fullWitness, promptedWitness);
            const fullSupportsUnprompted =
              unpromptedCovers && witnessesAgree(fullWitness, unpromptedWitness);
            if (fullSupportsPrompted !== fullSupportsUnprompted) {
              chosenWitness = fullSupportsPrompted
                ? promptedWitness
                : unpromptedWitness;
              supportingWitnesses = fullSupportsPrompted
                ? [fullWitness, promptedWitness]
                : [fullWitness, unpromptedWitness];
              agreement = "full-window-third";
            } else if (fullSupportsPrompted && fullSupportsUnprompted) {
              chosenWitness = chooseWordPreservingWitness(
                promptedWitness,
                unpromptedWitness,
              );
              supportingWitnesses = [
                fullWitness,
                promptedWitness,
                unpromptedWitness,
              ];
              agreement = "full-window-both";
            }
          }

          let extensionBoundaryText: string | null = null;
          const needsAcousticExtensionBoundary =
            Boolean(suspectLoop) &&
            supportingWitnesses.length >= 2 &&
            suspectLoops.some((candidate) =>
              supportingWitnesses.some(
                (witness) =>
                  !witnessContainsSuspectSuffix(text, candidate, witness),
              ),
            );
          if (needsAcousticExtensionBoundary) {
            const extensionSegment = sliceWavSegment(
              wavData,
              startSeconds + chunkSeconds,
              WAV_CHUNK_OVERLAP_SECONDS,
            );
            if (extensionSegment && !isLowEnergyWavSegment(extensionSegment)) {
              extensionBoundaryText = await this.transcribeResident(
                extensionSegment,
                buildWhisperServerOptions({
                  ...options,
                  promptOverride: undefined,
                }),
              );
            }
          }

          if (
            chosenWitness &&
            suspectLoop &&
            supportingWitnesses.length >= 2
          ) {
            for (
              let pass = 0;
              pass < MAX_SUSPECT_LOOP_RESCAN_PASSES;
              pass++
            ) {
              const candidates = findSuspectChunkLoops(text);
              if (candidates.length === 0) break;

              const supportedCandidates: Array<{
                candidate: SuspectChunkLoop;
                acousticOccurrences: number;
                distinctSuffixBoundary: boolean;
                detectableResidualLoop: boolean;
              }> = [];
              let failClosedOnCountDisagreement = false;
              for (const candidate of candidates) {
                const occurrenceCounts = supportingWitnesses.map((witness) =>
                  witnessCoversSuspectContext(text, candidate, witness)
                    ? countSuspectPhraseOccurrences(
                        text,
                        candidate,
                        witness,
                        extensionBoundaryText,
                      )
                    : null,
                );
                const firstCount = occurrenceCounts[0];
                if (firstCount === null || occurrenceCounts.includes(null)) {
                  continue;
                }
                if (!occurrenceCounts.every((count) => count === firstCount)) {
                  if (occurrenceCounts.every((count) => (count ?? 0) > 0)) {
                    failClosedOnCountDisagreement = true;
                    break;
                  }
                  continue;
                }
                supportedCandidates.push({
                  candidate,
                  acousticOccurrences: firstCount,
                  distinctSuffixBoundary: hasDistinctSuspectSuffix(
                    text,
                    candidate,
                  ),
                  detectableResidualLoop:
                    hasDetectableResidualLoop(candidate),
                });
              }
              if (failClosedOnCountDisagreement) {
                witnessCountDisagreement = true;
                break;
              }
              supportedCandidates.sort(
                (left, right) => {
                  const leftUnsupported =
                    left.candidate.occurrenceStarts.length -
                    Math.max(1, left.acousticOccurrences);
                  const rightUnsupported =
                    right.candidate.occurrenceStarts.length -
                    Math.max(1, right.acousticOccurrences);
                  // Prefer the candidate that explains the most unsupported
                  // copies without leaving a repeated fragment below the
                  // detector floor, then one ending at a distinct suffix.
                  return (
                    Number(right.detectableResidualLoop) -
                      Number(left.detectableResidualLoop) ||
                    rightUnsupported - leftUnsupported ||
                    Number(right.distinctSuffixBoundary) -
                      Number(left.distinctSuffixBoundary) ||
                    right.acousticOccurrences - left.acousticOccurrences ||
                    right.candidate.loopWordCount -
                      left.candidate.loopWordCount
                  );
                },
              );
              const supported = supportedCandidates[0];
              if (!supported) break;
              const supportedOccurrences = Math.max(
                1,
                supported.acousticOccurrences,
              );
              if (
                supportedOccurrences >=
                supported.candidate.occurrenceStarts.length
              ) {
                genuineRepeatedSpeech = true;
                break;
              }

              // The acoustic witnesses authorize removal of unsupported loop
              // copies only. Preserve their agreed repetition count and every
              // other original token, including retractions/fragments.
              text = collapseAcousticallyRejectedLoop(
                text,
                supported.candidate,
                supportedOccurrences,
              );
              acousticallyRejectedLoop = true;
            }
            chosenWitness = null;
          } else if (
            chosenWitness &&
            !witnessPreservesOriginalWords(text, null, chosenWitness)
          ) {
            chosenWitness = null;
            rejectedByWordLossGuard = true;
          }

          console.error(
            `[voicelayer] chunk witness ${JSON.stringify({
              startSeconds,
              reason: suspectLoop ? "repeated-loop" : "dropped-overlap",
              retrySeconds: witnessInfo.durationSeconds,
              promptedCovers,
              unpromptedCovers,
              agreement,
              chosen: acousticallyRejectedLoop
                ? "original-minus-acoustically-rejected-loop"
                : witnessCountDisagreement
                  ? "original-witness-count-disagreement"
                  : genuineRepeatedSpeech
                    ? "original-genuine-repeat"
                    : chosenWitness
                      ? "witness"
                      : rejectedByWordLossGuard
                        ? "original-word-loss-guard"
                        : "original",
            })}`,
          );
          if (acousticallyRejectedLoop) {
            witnessed = true;
          } else if (chosenWitness) {
            text = chosenWitness;
            witnessed = true;
            scheduleShiftedByWitness = true;
            // The witness moved the boundary off the pause it was chosen in,
            // so the next seam is an ordinary anchor seam again.
            seamKindAfterThisChunk = "anchor";
            nextStartSeconds =
              startSeconds + witnessSeconds - WAV_CHUNK_OVERLAP_SECONDS;
          }
        }
      }
      // AIDEV-NOTE: NOT skipped at a silence seam. The trigger is a missing
      // overlap, which a silence seam always has, but the check itself compares
      // a prompted and an unprompted decode of the SAME audio — it never uses
      // the anchor. Skipping it let a hallucinated very short final chunk be
      // appended unconfirmed (Macroscope, PR #31).
      if (
        isVeryShortFinalChunk &&
        mergedSoFar &&
        !hasChunkBoundaryOverlap(mergedSoFar, text)
      ) {
        const unpromptedText = await this.transcribeResident(
          segment,
          buildWhisperServerOptions({ ...options, promptOverride: undefined }),
        );
        if (!shortFinalChunkAgrees(text, unpromptedText)) {
          break;
        }
      }
      seamKinds[transcripts.length] = seamKindBeforeThisChunk;
      transcripts.push(text);
      nextSeamKind = seamKindAfterThisChunk;

      if (startSeconds + chunkSeconds >= info.durationSeconds) {
        break;
      }
      startSeconds = nextStartSeconds;
    }

    const mergedText = mergeChunkTranscripts(transcripts, seamKinds);
    if (!mergedText) return null;

    const headResult = await this.verifyChunkedLeadingPunctuation(
      wavData,
      mergedText,
      options,
    );
    const cleanedText = trimEchoedTrailingPhrase(headResult.text, {
      allowAdjacentEcho: allowsAdjacentTailEchoCleanup(wavData),
    });
    return {
      text: cleanedText,
      witnessed,
      headChanged: headResult.changed,
      cleaned: cleanedText !== headResult.text,
    };
  }

  private async verifyChunkedLeadingPunctuation(
    wavData: Uint8Array,
    fullText: string,
    options?: STTTranscribeOptions,
  ): Promise<{ text: string; changed: boolean }> {
    if (!LEADING_PUNCTUATION.test(fullText.trim())) {
      return { text: fullText, changed: false };
    }

    const headWav = sliceWavSegment(wavData, 0, WAV_HEAD_VERIFY_SECONDS);
    if (!headWav) return { text: fullText, changed: false };

    try {
      const headText = await this.transcribeResident(
        headWav,
        buildWhisperServerOptions(options),
      );
      const repaired = repairLeadingPunctuationFromHead(fullText, headText);
      if (repaired) {
        return { text: repaired, changed: true };
      }
    } catch (err) {
      console.error(
        `[voicelayer] whisper-server chunked head verification failed; keeping chunked text: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    }

    return { text: fullText, changed: false };
  }
}

export function buildWhisperServerOptions(
  options?: STTTranscribeOptions,
): WhisperServerTranscribeOptions | undefined {
  const langMode = getLanguageModeFromEnv();
  const languageConfig = getLanguageConfig(langMode);

  // In auto mode, preserve language-config's safety behavior for one-shot
  // audio: no vocabulary prompt unless a chunk-continuity prompt is present.
  // Otherwise borderline silence/noise can decode into prompt-biased dev terms.
  const basePrompt =
    languageConfig.mode === "auto"
      ? ""
      : `${getInitialPrompt(langMode)} ${getSTTVocabularyPrompt()}`.trim();
  const prompt = [basePrompt, options?.promptOverride]
    .filter(Boolean)
    .join(" ")
    .trim();

  const result: WhisperServerTranscribeOptions = {};
  result.language = languageConfig.whisperLang;
  if (prompt) {
    result.prompt = prompt;
  }
  return result.language || result.prompt ? result : undefined;
}

// --- Wispr Flow Backend ---

export class WisprFlowBackend implements STTBackend {
  name = "wispr-flow";

  async isAvailable(): Promise<boolean> {
    return !!process.env.QA_VOICE_WISPR_KEY;
  }

  async transcribe(
    audioPath: string,
    _options?: STTTranscribeOptions,
  ): Promise<STTResult> {
    const apiKey = process.env.QA_VOICE_WISPR_KEY;
    if (!apiKey) {
      throw new Error(
        "QA_VOICE_WISPR_KEY not set. Get your API key from Wispr Flow settings.",
      );
    }

    const start = Date.now();
    const audioData = await Bun.file(audioPath).arrayBuffer();
    const audioBytes = new Uint8Array(audioData);

    // Send recorded audio to Wispr Flow WebSocket
    const wsUrl = `wss://platform-api.wisprflow.ai/api/v1/dash/ws?api_key=Bearer%20${apiKey}`;

    return new Promise<STTResult>((resolve, reject) => {
      const ws = new WebSocket(wsUrl);
      let resolved = false;

      const timer = setTimeout(() => {
        if (!resolved) {
          resolved = true;
          ws.close();
          reject(new Error("Wispr Flow transcription timeout (30s)"));
        }
      }, 30_000);

      ws.addEventListener("open", () => {
        ws.send(
          JSON.stringify({
            type: "auth",
            language: ["en"],
            context: { app: { name: "VoiceLayer", type: "ai" } },
          }),
        );
      });

      ws.addEventListener("message", (event) => {
        if (resolved) return;
        try {
          const msg = JSON.parse(String(event.data));

          if (msg.status === "auth") {
            // Auth confirmed — send audio in 1-second chunks
            // Skip WAV header (44 bytes) to get raw PCM for chunking
            const CHUNK_SIZE = 32000; // 1 second of 16kHz 16-bit mono
            const pcmData = audioBytes.slice(44);
            let packetIndex = 0;
            for (
              let offset = 0;
              offset < pcmData.length;
              offset += CHUNK_SIZE
            ) {
              const chunk = pcmData.slice(offset, offset + CHUNK_SIZE);
              const rms = calculateRMS(chunk);
              ws.send(
                JSON.stringify({
                  type: "append",
                  position: packetIndex++,
                  audio_packets: {
                    packets: [Buffer.from(chunk).toString("base64")],
                    volumes: [rms],
                    packet_duration: 1,
                    audio_encoding: "wav",
                    byte_encoding: "base64",
                  },
                }),
              );
            }
            // Commit — signal end of audio
            ws.send(
              JSON.stringify({
                type: "commit",
                total_packets: packetIndex,
              }),
            );
          }

          if (msg.status === "text" && msg.body?.text) {
            const text = msg.body.text.trim();
            if (text) {
              resolved = true;
              clearTimeout(timer);
              ws.close();
              resolve({
                text,
                backend: "wispr-flow",
                durationMs: Date.now() - start,
              });
            }
          } else if (msg.status === "error") {
            resolved = true;
            clearTimeout(timer);
            ws.close();
            reject(
              new Error(`Wispr API error: ${msg.error || JSON.stringify(msg)}`),
            );
          }
        } catch {
          // Ignore non-JSON messages
        }
      });

      ws.addEventListener("error", () => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timer);
          reject(
            new Error(
              "Wispr WebSocket connection failed. Check QA_VOICE_WISPR_KEY.",
            ),
          );
        }
      });

      ws.addEventListener("close", () => {
        if (!resolved) {
          resolved = true;
          clearTimeout(timer);
          reject(
            new Error("Wispr WebSocket closed before transcription completed"),
          );
        }
      });
    });
  }
}

// --- Backend Detection ---

let cachedBackend: STTBackend | null = null;

/**
 * Detect and return the best available STT backend.
 * Result is cached for the lifetime of the process.
 */
export async function getBackend(): Promise<STTBackend> {
  if (cachedBackend) return cachedBackend;

  const preference = (process.env.QA_VOICE_STT_BACKEND || "auto").toLowerCase();

  if (preference === "whisper") {
    const backend = new WhisperCppBackend();
    if (await backend.isAvailable()) {
      cachedBackend = backend;
      return backend;
    }
    throw new Error(
      "whisper backend requested but not available. " +
        "Install whisper-cpp (macOS: brew install whisper-cpp) and download a model to ~/.cache/whisper/",
    );
  }

  if (preference === "whisper-server" || preference === "resident") {
    const backend = new WhisperServerBackend();
    if (await backend.isAvailable()) {
      cachedBackend = backend;
      return backend;
    }
    throw new Error(
      "whisper-server backend requested but not available. " +
        "Install whisper-cpp with whisper-server and download a model to ~/.cache/whisper/",
    );
  }

  if (preference === "wispr") {
    const backend = new WisprFlowBackend();
    if (await backend.isAvailable()) {
      cachedBackend = backend;
      return backend;
    }
    throw new Error("wispr backend requested but QA_VOICE_WISPR_KEY not set.");
  }

  // Auto-detect: prefer resident whisper-server, then whisper.cpp CLI,
  // then Wispr Flow. Resident requests still fall back to CLI per request
  // if the sidecar dies during inference.
  const resident = new WhisperServerBackend();
  if (await resident.isAvailable()) {
    cachedBackend = resident;
    console.error("[voicelayer] STT backend: whisper-server (resident)");
    return resident;
  }

  const whisper = new WhisperCppBackend();
  if (await whisper.isAvailable()) {
    cachedBackend = whisper;
    console.error(
      `[voicelayer] STT backend: whisper.cpp (${whisper.getModelInfo().model})`,
    );
    return whisper;
  }

  const wispr = new WisprFlowBackend();
  if (await wispr.isAvailable()) {
    cachedBackend = wispr;
    console.error("[voicelayer] STT backend: Wispr Flow (cloud fallback)");
    return wispr;
  }

  throw new Error(
    "No STT backend available. Options:\n" +
      "  1. Install whisper.cpp:\n" +
      "     macOS: brew install whisper-cpp\n" +
      "     Linux: build from source — https://github.com/ggerganov/whisper.cpp\n" +
      "     Download model: curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \\\n" +
      "       https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin\n" +
      "  2. Set QA_VOICE_WISPR_KEY for cloud STT (Wispr Flow)",
  );
}

/**
 * Reset cached backend (for testing).
 */
export function resetBackendCache(): void {
  cachedBackend = null;
  cachedBrewPrefix = undefined;
}

export class VoiceLayerSTTBackendSelector implements SpeechToTextBackendSelector {
  getBackend(): Promise<STTBackend> {
    return getBackend();
  }

  resetBackendCache(): void {
    resetBackendCache();
  }
}
