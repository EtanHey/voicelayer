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
import { resolveBinary } from "./resolve-binary";
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
  let result = text.replace(
    /([\p{L}\p{N}])"(?=\p{L}[^"]*")/gu,
    "$1 \"",
  );
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
    if (overlapKey(words.slice(index, index + sequence.length)) === sequenceKey) {
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
    if (!containsEarlierWordSequence(currentWords, suffix, currentWords.length)) {
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
    dropWords <= Math.min(MAX_ORPHANED_TAIL_FRAGMENT_WORDS, currentWords.length);
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
    insertedWords <= Math.min(MAX_LEADING_PUNCTUATION_INSERTED_WORDS, headWords.length);
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
  if (readAscii(wavData, 0, 4) !== "RIFF" || readAscii(wavData, 8, 4) !== "WAVE") {
    return null;
  }

  let dataOffset = -1;
  let dataSize = 0;
  let byteRate = 0;
  let blockAlign = 0;

  for (let offset = 12; offset + 8 <= wavData.byteLength; ) {
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
    wavData.slice(
      info.dataOffset + segmentStart,
      info.dataOffset + segmentEnd,
    ),
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

export function mergeChunkTranscripts(chunks: string[]): string {
  const merged: string[] = [];

  for (const chunk of chunks) {
    const nextWords = normalizeChunkWords(chunk);
    if (nextWords.length === 0) continue;

    if (merged.length === 0) {
      merged.push(...nextWords);
      continue;
    }

    const { overlap, skipPrefix } = findChunkOverlap(merged, nextWords);

    if (overlap > 0) {
      for (let index = 0; index < overlap; index++) {
        const mergedIndex = merged.length - overlap + index;
        merged[mergedIndex] = preferPunctuatedOverlapWord(
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

function hasChunkBoundaryOverlap(currentText: string, nextText: string): boolean {
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
  if (containsWordSequence(unpromptedWords, promptedWords)) return true;
  if (!containsWordSequence(promptedWords, unpromptedWords)) return false;

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
    const searchStart = Math.max(
      0,
      tailStart - MAX_ECHOED_TAIL_LOOKBACK_WORDS,
    );

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
      const repeatedPhraseBridge = isRepeatedPhraseBridge(
        bridgeWords,
        phraseWords,
        tailKey,
      ) || containsWordSequence(bridgeWords, candidate);
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
    if (overlapKey(bridgeWords.slice(offset, offset + phraseWords)) !== phraseKey) {
      return false;
    }
  }
  return true;
}

function containsWordSequence(words: string[], sequence: string[]): boolean {
  if (sequence.length === 0 || words.length < sequence.length) return false;
  const sequenceKey = overlapKey(sequence);
  for (let index = 0; index + sequence.length <= words.length; index++) {
    if (overlapKey(words.slice(index, index + sequence.length)) === sequenceKey) {
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
  return !!info && info.durationSeconds >= WAV_ADJACENT_ECHO_CLEANUP_MIN_SECONDS;
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
        const backendParts = [this.name, "chunks"];
        if (chunkedResult.headChanged) backendParts.push("head");
        if (chunkedResult.cleaned) backendParts.push("clean");
        return {
          text: chunkedResult.text,
          backend: backendParts.join("+"),
          durationMs: Date.now() - start,
        };
      }

      const text = await this.transcribeResident(
        wavData,
        buildWhisperServerOptions(options),
      );
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
      const backendParts = [this.name];
      if (headResult.changed) {
        backendParts.push(headResult.backendSuffix ?? "head");
      }
      if (verifiedText !== headResult.text) backendParts.push("tail");
      if (cleanedText !== verifiedText) backendParts.push("clean");
      return {
        text: cleanedText,
        backend: backendParts.join("+"),
        durationMs: Date.now() - start,
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
      const fallback = await this.fallbackBackend.transcribe(audioPath, options);
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

    try {
      const tailText = await this.transcribeResident(
        tailWav,
        buildWhisperServerOptions({
          promptOverride: combinePromptOverride(options?.promptOverride, fullText),
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
  ): Promise<{ text: string; headChanged: boolean; cleaned: boolean } | null> {
    const info = parseWavPcmInfo(wavData);
    if (!info || info.durationSeconds < WAV_CHUNKED_DECODE_MIN_SECONDS) {
      return null;
    }

    const transcripts: string[] = [];
    const stepSeconds = WAV_CHUNK_SECONDS - WAV_CHUNK_OVERLAP_SECONDS;
    for (
      let startSeconds = 0;
      startSeconds < info.durationSeconds;
      startSeconds += stepSeconds
    ) {
      const isVeryShortFinalChunk =
        startSeconds + WAV_CHUNK_SECONDS >= info.durationSeconds &&
        info.durationSeconds - startSeconds < WAV_TAIL_VERIFY_MIN_SECONDS;
      const segment = sliceWavSegment(
        wavData,
        startSeconds,
        WAV_CHUNK_SECONDS,
      );
      if (!segment) continue;

      const mergedSoFar = mergeChunkTranscripts(transcripts);
      const text = await this.transcribeResident(
        segment,
        buildWhisperServerOptions({
          promptOverride: mergedSoFar
            ? combinePromptOverride(options?.promptOverride, mergedSoFar)
            : options?.promptOverride,
        }),
      );
      if (!text.trim()) return null;
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
      transcripts.push(text);

      if (startSeconds + WAV_CHUNK_SECONDS >= info.durationSeconds) {
        break;
      }
    }

    const mergedText = mergeChunkTranscripts(transcripts);
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
