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

// --- Types ---

export interface STTResult {
  text: string;
  backend: string;
  durationMs: number;
}

export interface STTTranscribeOptions {
  promptOverride?: string;
}

export interface STTBackend {
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
const MAX_ECHOED_TAIL_WORDS = 6;
const MAX_ECHOED_TAIL_LOOKBACK_WORDS = 18;
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
): { overlap: number; skipPrefix: number } {
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
    prefix <= Math.min(MAX_PREFIX_SHIFTED_SKIP_WORDS, nextWords.length - 1);
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

function hasMeaningfulTranscriptOverlap(current: string, next: string): boolean {
  const currentWords = normalizeChunkWords(current);
  const nextWords = normalizeChunkWords(next);
  return (
    findChunkOverlap(currentWords, nextWords).overlap >=
    MIN_MEANINGFUL_TAIL_OVERLAP_WORDS
  );
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

interface WavPcmInfo {
  durationSeconds: number;
  dataOffset: number;
  dataSize: number;
  byteRate: number;
  blockAlign: number;
}

const WAV_TAIL_VERIFY_MIN_SECONDS = 20;
const WAV_TAIL_VERIFY_SECONDS = 12;
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

  return merged.join(" ").trim();
}

function stripTailVerificationArtifact(text: string, fullText: string): string {
  if (TRAILING_FILLER_AFTER_QUESTION.test(fullText.trim())) return text;
  return text.replace(TRAILING_FILLER_AFTER_QUESTION, "?");
}

function trimEchoedTrailingPhrase(text: string): string {
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
      if (interveningWords >= 2 && overlapKey(candidate) === tailKey) {
        return words.slice(0, tailStart).join(" ").trim();
      }
    }
  }

  return text.trim();
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
      const chunkedText = await this.transcribeChunkedLongRecording(
        wavData,
        options,
      );
      if (chunkedText) {
        return {
          text: chunkedText,
          backend: `${this.name}+chunks`,
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
      const cleanedText = trimEchoedTrailingPhrase(verifiedText);
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
      if (!hasMeaningfulTranscriptOverlap(fullText, tailText)) {
        return fullText;
      }
      const merged = mergeChunkTranscripts([fullText, tailText]);
      return merged ? stripTailVerificationArtifact(merged, fullText) : fullText;
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
  ): Promise<string | null> {
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
      transcripts.push(text);

      if (startSeconds + WAV_CHUNK_SECONDS >= info.durationSeconds) {
        break;
      }
    }

    return mergeChunkTranscripts(transcripts) || null;
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
  if (languageConfig.mode !== "auto") {
    result.language = languageConfig.whisperLang;
  }
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
