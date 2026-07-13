import { randomUUID } from "crypto";
import { existsSync } from "fs";
import { appendFile, mkdir } from "fs/promises";
import { homedir } from "os";
import { dirname, join } from "path";

export type STTPolishMode = "off" | "shadow" | "on";
export type STTPolishStatus =
  | "skipped"
  | "unavailable"
  | "shadowed"
  | "applied"
  | "rejected"
  | "failed";
export type STTPolishSurface = "dictation" | "voice_ask";

export interface STTPolishEnv {
  [key: string]: string | undefined;
  QA_VOICE_STT_POLISH?: string;
  QA_VOICE_STT_POLISH_SOCKET?: string;
  QA_VOICE_STT_POLISH_ENDPOINT?: string;
  QA_VOICE_STT_POLISH_MODEL?: string;
  QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS?: string;
  QA_VOICE_STT_POLISH_TIMEOUT_MS?: string;
  QA_VOICE_STT_POLISH_LOG_PATH?: string;
  VOICELAYER_STT_POLISH_WARMUP?: string;
  VOICELAYER_STT_POLISH_WARMUP_TIMEOUT_MS?: string;
}

export interface STTPolishInput {
  rawText: string;
  cleanedText: string;
  surface?: STTPolishSurface;
  env?: STTPolishEnv;
}

export interface STTPolishResult {
  inputText: string;
  text: string;
  polishedText: string | null;
  mode: STTPolishMode;
  status: STTPolishStatus;
  surface: STTPolishSurface;
  changed: boolean;
  retried: boolean;
  latencyMs: number;
  polished: boolean;
  reason?: string;
  error?: string;
}

export type STTPolishWarmupStatus = "skipped" | "warmed" | "failed";

export interface STTPolishWarmupResult {
  status: STTPolishWarmupStatus;
  latencyMs: number;
  error?: string;
}

interface STTPolishSocketRequest {
  id: string;
  raw_text: string;
  cleaned_text: string;
  surface: STTPolishSurface;
}

interface STTPolishSocketResponse {
  text?: unknown;
  error?: unknown;
}

const DEFAULT_POLISH_HEALTH_TIMEOUT_MS = 1_200;
const DEFAULT_POLISH_TIMEOUT_MS = 18_000;
const DEFAULT_POLISH_WARMUP_TIMEOUT_MS = 1_500;
const DEFAULT_POLISH_SOCKET_TIMEOUT_MS = 1_200;
const DEFAULT_POLISH_MAX_TOKENS = 512;
const MAX_POLISH_COMPLETION_TOKENS = 4_096;
const MAX_HTTP_NOOP_POLISH_ATTEMPTS = 3;
const RUN_ON_PUNCTUATION_FLOOR_MIN_WORDS = 18;
const MIN_QUESTION_BOUNDARY_TRANSITIONS = 2;
const QUESTION_STARTER_WORDS =
  "(?:did|do|does|is|are|can|could|would|should|what|why|how|when|where|who)";
const QUESTION_STARTER_PATTERN = new RegExp(
  `^${QUESTION_STARTER_WORDS}\\b`,
  "iu",
);
const QUESTION_BOUNDARY_PATTERN = new RegExp(
  `\\s+(?=(${QUESTION_STARTER_WORDS})\\b)`,
  "giu",
);
const AUXILIARY_QUESTION_STARTERS = new Set([
  "did",
  "do",
  "does",
  "is",
  "are",
  "can",
  "could",
  "would",
  "should",
]);
const WH_QUESTION_STARTERS = new Set([
  "what",
  "why",
  "how",
  "when",
  "where",
  "who",
]);
const QUESTION_SUBJECT_WORDS = new Set([
  "i",
  "you",
  "he",
  "she",
  "it",
  "we",
  "they",
  "this",
  "that",
  "there",
  "the",
  "your",
  "my",
  "our",
  "their",
  "his",
  "her",
  "anyone",
  "someone",
]);
const EMBEDDED_WH_PREDECESSORS = new Set([
  "and",
  "or",
  "me",
  "tell",
  "show",
  "explain",
  "know",
  "understand",
  "wonder",
  "remember",
  "decide",
  "see",
  "that",
  "because",
  "about",
]);
export const DEFAULT_POLISH_MODEL = "mlx-community/Qwen3-4B-Instruct-2507-4bit";
export const DEFAULT_POLISH_ENDPOINT = "http://127.0.0.1:8080/v1/chat/completions";
const DEFAULT_POLISH_SOCKET = join(homedir(), ".voicelayer", "polish.sock");
const DEFAULT_POLISH_LOG_PATH = join(
  homedir(),
  ".voicelayer",
  "eval",
  "polish-shadow.jsonl",
);

export function getSTTPolishMode(
  env: STTPolishEnv = process.env,
): STTPolishMode {
  const raw = env.QA_VOICE_STT_POLISH?.trim().toLowerCase();
  if (raw === "off") return "off";
  if (raw === "shadow" || raw === "on") return raw;
  return "on";
}

export function getSTTPolishSocketPath(
  env: STTPolishEnv = process.env,
): string {
  return env.QA_VOICE_STT_POLISH_SOCKET?.trim() || DEFAULT_POLISH_SOCKET;
}

export function getSTTPolishEndpoint(env: STTPolishEnv = process.env): string | null {
  const configured = env.QA_VOICE_STT_POLISH_ENDPOINT?.trim();
  if (configured) return configured;
  if (env.QA_VOICE_STT_POLISH_SOCKET !== undefined) return null;
  return DEFAULT_POLISH_ENDPOINT;
}

function getSTTPolishModel(env: STTPolishEnv = process.env): string {
  return env.QA_VOICE_STT_POLISH_MODEL?.trim() || DEFAULT_POLISH_MODEL;
}

export function getSTTPolishTimeoutMs(
  env: STTPolishEnv = process.env,
): number {
  const raw = Number(env.QA_VOICE_STT_POLISH_TIMEOUT_MS);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_POLISH_TIMEOUT_MS;
  return Math.min(Math.max(raw, 50), 60_000);
}

export function getSTTPolishHealthTimeoutMs(
  env: STTPolishEnv = process.env,
): number {
  const raw = Number(env.QA_VOICE_STT_POLISH_HEALTH_TIMEOUT_MS);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_POLISH_HEALTH_TIMEOUT_MS;
  return Math.min(Math.max(raw, 50), 5_000);
}

function isSTTPolishWarmupEnabled(env: STTPolishEnv = process.env): boolean {
  const raw = env.VOICELAYER_STT_POLISH_WARMUP?.trim().toLowerCase();
  return raw !== "0" && raw !== "false" && raw !== "no" && raw !== "off";
}

function getSTTPolishWarmupTimeoutMs(
  env: STTPolishEnv = process.env,
): number {
  const raw = Number(env.VOICELAYER_STT_POLISH_WARMUP_TIMEOUT_MS);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_POLISH_WARMUP_TIMEOUT_MS;
  return Math.min(Math.max(raw, 50), 5_000);
}

export function getSTTPolishSocketTimeoutMs(
  env: STTPolishEnv = process.env,
): number {
  const raw = Number(env.QA_VOICE_STT_POLISH_TIMEOUT_MS);
  if (!Number.isFinite(raw) || raw <= 0) return DEFAULT_POLISH_SOCKET_TIMEOUT_MS;
  return Math.min(Math.max(raw, 50), 60_000);
}

function getSTTPolishLogPath(env: STTPolishEnv = process.env): string {
  return env.QA_VOICE_STT_POLISH_LOG_PATH?.trim() || DEFAULT_POLISH_LOG_PATH;
}

type STTPolishRetryReason = "noop" | "rejected";

function buildPolishSystemPrompt(retryReason?: STTPolishRetryReason): string {
  const lines = [
    "You are a dictation finalizer for local VoiceLayer voice dictation.",
    "Input is raw Whisper output after deterministic VoiceLayer cleanup.",
    "Fix obvious transcript artifacts: missing sentence punctuation, duplicate punctuation, missing sentence-start capitalization, high-confidence recognition errors, code identifier formatting, slash-command spacing, chunk-boundary duplicates, and Hebrew/English spacing.",
    "Be decisive. When one of the dictation-finalizer patterns below appears, apply it instead of leaving the text unchanged.",
    "Format ANY ordinal sequence into numbered markdown lists. Ordinal cues include first, first of all, second, second of all, third, third of all, fourth, number one, number two, and similar spoken ordering. This applies even with conversational framing such as so, okay, and then, or third without 'of all'.",
    "Collapse ANY mid-sentence self-correction when the speaker replaces an earlier phrase with a later phrase. Explicit cues include well no, well, no, no wait, sorry, I mean, actually, rather, or scratch that. Also collapse semantic correction patterns such as 'did X ... no/actually Y', 'went to X ... no ... went to Y', or longer clause replacements. Keep the corrected later phrase and drop only the immediately superseded phrase.",
    "Preserve literal/code/path tokens exactly, including leading-dot tokens like .env, .at, and .gitignore. Do not attach a leading-dot token to the previous word.",
    "Remove low-value disfluencies only when they are clearly process speech or discarded correction scaffolding, not semantic content.",
    "Never summarize, translate, add content, change tone, or invent code identifiers.",
    "Do not delete wanted content: keep every clause that is not clearly superseded by a self-correction or converted into a numbered list item.",
    "Preserve Hebrew as Hebrew and English/code terms as English.",
    "For already-good dictation with no applicable rule, output the cleaned text with only minimal punctuation/capitalization fixes.",
    "Output only the corrected text.",
    "",
    "Examples:",
    "Input: Also, do / what's new and output that as your summary.",
    "Output: Also, do /whats-new and output that as your summary.",
    "Input: ask c mux whether brain layer is ready",
    "Output: Ask cmux whether BrainLayer is ready",
    "Input: תרים את ה handle socket command",
    "Output: תרים את ה-handleSocketCommand",
    "Input: Okay, let's do Gemini deep, well no, Claude deep research.",
    "Output: Okay, let's do Claude deep research.",
    "Input: Okay, let's do Gemini Deep, well, no, Claude Deep Research.",
    "Output: Okay, let's do Claude Deep Research.",
    "Input: Okay let's do a Claude well no not Claude let's do a Gemini deep research.",
    "Output: Okay, let's do a Gemini deep research.",
    "Input: Okay, let's do a Claude deep, well, Gemini deep research.",
    "Output: Okay, let's do Gemini deep research.",
    "Input: Okay, so I just went to the gym and, well, no, I just went to the supermarket and I now came back.",
    "Output: Okay, so I just went to the supermarket and I now came back.",
    "Input: I started a build, actually I started the test suite and then came back.",
    "Output: I started the test suite and then came back.",
    "Input: First of all, I wanted to do x, y, and z, and then second of all, I wanted to talk to him, and third of all, I wanted to go home.",
    "Output:\n1. I wanted to do x, y, and z.\n2. I wanted to talk to him.\n3. I wanted to go home.",
    "Input: So first of all, I came back home right now, and then second of all, you've been paused, third, I'm very frustrated.",
    "Output:\n1. I came back home right now.\n2. You've been paused.\n3. I'm very frustrated.",
    "Input: Or if I say, okay, first of all, I want to do x, y, z, and then second of all, I want to do the other thing, and then third of all, I want to do this, that, and this.",
    "Output: Okay:\n1. I want to do x, y, z.\n2. I want to do the other thing.\n3. I want to do this, that, and this.",
    "Input: Also, if I say the .at file. Thank you.",
    "Output: Also, if I say the .at file. Thank you.",
    "Input: This is already good.",
    "Output: This is already good.",
    "Input: why did it do that i am confused",
    "Output: Why did it do that? I am confused.",
    "Forbidden rewrite:",
    "Input: I think this might work.",
    "Output: This solution should work.",
  ];
  if (retryReason === "noop") {
    lines.push(
      "",
      "Retry instruction: the previous response copied the input unchanged. Add sentence punctuation and split obvious run-on questions without changing meaning.",
    );
  } else if (retryReason === "rejected") {
    lines.push(
      "",
      "Retry instruction: the previous response was rejected. Return the full corrected text, not a summary or partial prefix. Preserve all content, only adding punctuation, sentence boundaries, casing, and safe dictation cleanup.",
    );
  }
  return lines.join("\n");
}

function buildPolishUserPrompt(rawText: string, cleanedText: string): string {
  return [
    "Raw Whisper text:",
    rawText,
    "",
    "VoiceLayer cleaned text to fix:",
    cleanedText,
  ].join("\n");
}

interface OpenAIChatCompletionResponse {
  choices?: Array<{
    message?:
      | string
      | {
          content?: unknown;
        };
  }>;
  error?: unknown;
}

function extractPolishResponseText(payload: OpenAIChatCompletionResponse): string {
  const message = payload.choices?.[0]?.message;
  if (typeof message === "string") return message.trim();
  const content = message?.content;
  if (typeof content === "string") return content.trim();
  throw new Error("polish endpoint response missing message content");
}

function countWords(text: string): number {
  return text.trim().split(/\s+/).filter(Boolean).length;
}

function normalizeZeroQuantifierNegation(text: string): string {
  return text.replace(
    /(?<![\p{L}\p{N}_])(?:0|zero)\s+(?=[\p{L}])/giu,
    "no ",
  );
}

function normalizedSimilarityText(text: string): string {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "");
}

function levenshteinDistance(a: string, b: string): number {
  if (a === b) return 0;
  if (!a) return b.length;
  if (!b) return a.length;

  const previous = Array.from({ length: b.length + 1 }, (_, index) => index);
  const current = new Array<number>(b.length + 1);

  for (let i = 1; i <= a.length; i++) {
    current[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const substitutionCost = a[i - 1] === b[j - 1] ? 0 : 1;
      current[j] = Math.min(
        previous[j] + 1,
        current[j - 1] + 1,
        previous[j - 1] + substitutionCost,
      );
    }
    for (let j = 0; j <= b.length; j++) {
      previous[j] = current[j];
    }
  }

  return previous[b.length];
}

function normalizedSimilarity(a: string, b: string): number {
  const left = normalizedSimilarityText(a);
  const right = normalizedSimilarityText(b);
  if (!left && !right) return 1;
  const maxLength = Math.max(left.length, right.length);
  if (maxLength === 0) return 1;
  return 1 - levenshteinDistance(left, right) / maxLength;
}

const NEGATION_TOKENS = new Set([
  "no",
  "not",
  "never",
  "without",
  "cannot",
  "cant",
  "can't",
  "dont",
  "don't",
  "doesnt",
  "doesn't",
  "didnt",
  "didn't",
  "isnt",
  "isn't",
  "arent",
  "aren't",
  "wasnt",
  "wasn't",
  "werent",
  "weren't",
  "wont",
  "won't",
  "couldnt",
  "couldn't",
  "shouldnt",
  "shouldn't",
  "wouldnt",
  "wouldn't",
  "havent",
  "haven't",
  "hasnt",
  "hasn't",
  "hadnt",
  "hadn't",
  "לא",
  "בלי",
  "אין",
]);

const POLISH_REJECTION_REASONS = {
  SELF_CORRECTION_UNGROUNDED:
    "polish response self-correction introduced new content",
  PROTECTED_TOKENS_CHANGED: "polish response changed protected tokens",
  DROPPED_TOO_MUCH_TEXT: "polish response dropped too much text",
  DROPPED_TOO_MANY_WORDS: "polish response dropped too many words",
} as const;

const RETRYABLE_POLISH_REJECTION_REASONS = new Set<string>([
  POLISH_REJECTION_REASONS.SELF_CORRECTION_UNGROUNDED,
  POLISH_REJECTION_REASONS.PROTECTED_TOKENS_CHANGED,
  POLISH_REJECTION_REASONS.DROPPED_TOO_MUCH_TEXT,
  POLISH_REJECTION_REASONS.DROPPED_TOO_MANY_WORDS,
]);

function negationCount(text: string): number {
  return (
    normalizeZeroQuantifierNegation(text)
      .normalize("NFKC")
      .toLowerCase()
      .match(/[\p{L}\p{N}'’]+/gu)
      ?.filter((token) =>
        NEGATION_TOKENS.has(token.replace(/’/g, "'")),
      ).length ?? 0
  );
}

function countMatches(text: string, pattern: RegExp): number {
  return text.match(pattern)?.length ?? 0;
}

function shouldRetryNoopPolish(cleanedText: string): boolean {
  const words = countWords(cleanedText);
  if (words < 12) return false;

  const trimmed = cleanedText.trim();
  const withoutTerminal = trimmed.replace(/[.?!]+$/u, "");
  const internalPunctuation = countMatches(withoutTerminal, /[.,;:?!]/gu);
  return internalPunctuation / words <= 0.04;
}

function shouldRetryRejectedPolish(
  cleanedText: string,
  result: STTPolishResult,
): boolean {
  if (result.status !== "rejected") return false;
  if (!shouldRetryNoopPolish(cleanedText)) return false;
  return RETRYABLE_POLISH_REJECTION_REASONS.has(result.error ?? "");
}

function getSTTPolishMaxTokens(cleanedText: string): number {
  const wordBudget = Math.ceil(countWords(cleanedText) * 2.2);
  return Math.min(
    Math.max(DEFAULT_POLISH_MAX_TOKENS, wordBudget),
    MAX_POLISH_COMPLETION_TOKENS,
  );
}

function capitalizeRunOnSegmentStart(segment: string): string {
  if (!QUESTION_STARTER_PATTERN.test(segment)) return segment;
  return segment.replace(/^\p{Ll}/u, (char) => char.toUpperCase());
}

function questionBoundaryIndices(text: string): number[] {
  const indices: number[] = [];
  for (const match of text.matchAll(QUESTION_BOUNDARY_PATTERN)) {
    if (match.index === undefined) continue;
    const starter = match[1]?.toLocaleLowerCase();
    if (!starter) continue;

    const prefix = text.slice(0, match.index).trimEnd();
    const previousWord = prefix
      .match(/([\p{L}\p{N}'’-]+)$/u)?.[1]
      ?.toLocaleLowerCase();
    const suffix = text
      .slice(match.index + match[0].length + starter.length)
      .trimStart();
    const nextWord = suffix
      .match(/^([\p{L}\p{N}'’-]+)/u)?.[1]
      ?.toLocaleLowerCase();

    if (
      AUXILIARY_QUESTION_STARTERS.has(starter) &&
      (!nextWord ||
        !QUESTION_SUBJECT_WORDS.has(nextWord) ||
        (previousWord !== undefined &&
          WH_QUESTION_STARTERS.has(previousWord)))
    ) {
      continue;
    }
    if (
      !AUXILIARY_QUESTION_STARTERS.has(starter) &&
      previousWord &&
      EMBEDDED_WH_PREDECESSORS.has(previousWord)
    ) {
      continue;
    }
    indices.push(match.index);
  }
  return indices;
}

function splitAtQuestionBoundaries(text: string, indices: number[]): string[] {
  const segments: string[] = [];
  let segmentStart = 0;
  for (const boundaryIndex of indices) {
    segments.push(text.slice(segmentStart, boundaryIndex).trim());
    segmentStart = boundaryIndex;
  }
  segments.push(text.slice(segmentStart).trim());
  return segments.filter(Boolean);
}

function deterministicRunOnPunctuationFloor(cleanedText: string): string {
  const words = countWords(cleanedText);
  const compactText = cleanedText.trim().replace(/\s+/gu, " ");
  const boundaryIndices = questionBoundaryIndices(compactText);
  if (
    words < RUN_ON_PUNCTUATION_FLOOR_MIN_WORDS ||
    !shouldRetryNoopPolish(cleanedText) ||
    !QUESTION_STARTER_PATTERN.test(compactText) ||
    boundaryIndices.length < MIN_QUESTION_BOUNDARY_TRANSITIONS
  ) {
    return cleanedText;
  }

  const normalized = compactText.replace(/[.?!]+$/u, "");
  const questionSegments = splitAtQuestionBoundaries(
    normalized,
    boundaryIndices,
  );

  return questionSegments
    .map((segment) => {
      const normalizedSegment = segment
        .replace(/\s+([,.?!])/gu, "$1")
        .replace(/,+$/u, "");
      const sentence = capitalizeRunOnSegmentStart(normalizedSegment);
      const fallback = QUESTION_STARTER_PATTERN.test(normalizedSegment)
        ? "?"
        : ".";
      return withTerminalPunctuation(sentence, fallback);
    })
    .join(" ");
}

function protectedCodePunctuationCounts(text: string): Map<string, number> {
  const normalized = text.normalize("NFKC");
  const counts = new Map<string, number>();
  for (const char of normalized.match(/[\/\-_`$@#\\]/gu) ?? []) {
    counts.set(char, (counts.get(char) ?? 0) + 1);
  }

  const codeDotCount = countMatches(
    normalized,
    /(?:(?<=[\p{L}\p{N}])\.(?=[\p{L}\p{N}])|(?<!\S)\.(?=[\p{L}_]))/gu,
  );
  if (codeDotCount > 0) counts.set(".", codeDotCount);

  return counts;
}

function removedProtectedCodePunctuation(
  cleanedText: string,
  candidate: string,
): boolean {
  const cleanedCounts = protectedCodePunctuationCounts(cleanedText);
  if (cleanedCounts.size === 0) return false;

  const candidateCounts = protectedCodePunctuationCounts(candidate);
  for (const [char, count] of cleanedCounts.entries()) {
    if ((candidateCounts.get(char) ?? 0) < count) return true;
  }
  return false;
}

function protectedSlashTokens(text: string): string[] {
  return (
    text
      .normalize("NFKC")
      .match(/\/[A-Za-z0-9][A-Za-z0-9._-]*/g)
      ?.map((token) => token.toLowerCase()) ?? []
  );
}

const UNIT_NUMBER_WORD_VALUES: Record<string, number> = {
  zero: 0,
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
};

const TEEN_NUMBER_WORD_VALUES: Record<string, number> = {
  ten: 10,
  eleven: 11,
  twelve: 12,
  thirteen: 13,
  fourteen: 14,
  fifteen: 15,
  sixteen: 16,
  seventeen: 17,
  eighteen: 18,
  nineteen: 19,
};

const TENS_NUMBER_WORD_VALUES: Record<string, number> = {
  twenty: 20,
  thirty: 30,
  forty: 40,
  fifty: 50,
  sixty: 60,
  seventy: 70,
  eighty: 80,
  ninety: 90,
};

const NUMBER_WORD_VALUES: Record<string, number> = {
  ...UNIT_NUMBER_WORD_VALUES,
  ...TEEN_NUMBER_WORD_VALUES,
  ...TENS_NUMBER_WORD_VALUES,
};

const NUMBER_WORD_PATTERN = Object.keys(NUMBER_WORD_VALUES).join("|");
const PROTECTED_NUMERIC_TOKEN_PATTERN = new RegExp(
  `(?<![\\p{L}\\p{N}_])(?:\\d+(?:[.,:]\\d+)*(?:%|[A-Za-z]+)?|${NUMBER_WORD_PATTERN})(?![\\p{L}\\p{N}_])`,
  "giu",
);

function normalizeProtectedNumericToken(token: string): string {
  const lower = token.toLowerCase();
  return String(NUMBER_WORD_VALUES[lower] ?? lower);
}

function canJoinNumberWordTokens(
  left: string,
  right: string,
  separator: string,
): boolean {
  return (
    TENS_NUMBER_WORD_VALUES[left] !== undefined &&
    UNIT_NUMBER_WORD_VALUES[right] !== undefined &&
    UNIT_NUMBER_WORD_VALUES[right] > 0 &&
    /^[\s-]+$/u.test(separator)
  );
}

function protectedNumericTokens(text: string): string[] {
  const normalized = normalizeZeroQuantifierNegation(text).normalize("NFKC");
  const matches = Array.from(normalized.matchAll(PROTECTED_NUMERIC_TOKEN_PATTERN));
  const tokens: string[] = [];

  for (let index = 0; index < matches.length; index++) {
    const match = matches[index];
    const token = match[0];
    const lower = token.toLowerCase();
    const next = matches[index + 1];
    const nextLower = next?.[0].toLowerCase();

    if (
      next &&
      nextLower &&
      canJoinNumberWordTokens(
        lower,
        nextLower,
        normalized.slice((match.index ?? 0) + token.length, next.index ?? 0),
      )
    ) {
      tokens.push(
        String(TENS_NUMBER_WORD_VALUES[lower] + UNIT_NUMBER_WORD_VALUES[nextLower]),
      );
      index++;
      continue;
    }

    tokens.push(normalizeProtectedNumericToken(token));
  }

  return tokens;
}

function sameTokenSequence(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  return left.every((token, index) => token === right[index]);
}

function hasSlashPunctuation(text: string): boolean {
  return text.normalize("NFKC").includes("/");
}

function changedProtectedTokens(cleanedText: string, candidate: string): boolean {
  const cleanedSlashTokens = protectedSlashTokens(cleanedText);
  const candidateSlashTokens = protectedSlashTokens(candidate);
  if (candidateSlashTokens.length > 0 && !hasSlashPunctuation(cleanedText)) {
    return true;
  }
  if (
    cleanedSlashTokens.length > 0 &&
    !sameTokenSequence(cleanedSlashTokens, candidateSlashTokens)
  ) {
    return true;
  }

  return !sameTokenSequence(
    protectedNumericTokens(cleanedText),
    protectedNumericTokens(candidate),
  );
}

function codeStyleIdentifierTokens(text: string): string[] {
  return (
    text
      .normalize("NFKC")
      .match(/[A-Za-z_$][A-Za-z0-9_$.-]*/g)
      ?.map((token) => token.replace(/[.!?;:]+$/u, ""))
      .filter((token) => /(?:[a-z][A-Z]|[A-Z][a-z]+[A-Z])/u.test(token)) ?? []
  );
}

const KNOWN_CODE_IDENTIFIER_POLISH_ALLOWLIST = new Set([
  "brainlayer",
  "handlesocketcommand",
]);

function introducedCodeStyleIdentifier(
  cleanedText: string,
  candidate: string,
): string | null {
  const cleanedIdentifiers = new Set(
    codeStyleIdentifierTokens(cleanedText).map((token) => token.toLowerCase()),
  );
  for (const token of codeStyleIdentifierTokens(candidate)) {
    const normalizedToken = token.toLowerCase();
    if (
      !cleanedIdentifiers.has(normalizedToken) &&
      !KNOWN_CODE_IDENTIFIER_POLISH_ALLOWLIST.has(normalizedToken)
    ) {
      return token;
    }
  }
  return null;
}

const SELF_CORRECTION_SIMILARITY_FLOOR = 0.58;
const SPOKEN_LIST_SIMILARITY_FLOOR = 0.45;

// AIDEV-NOTE: Broadening these cues weakens length/similarity/negation guards
// for dictation rewrites, so keep the list limited to explicit correction speech.
const SELF_CORRECTION_CUE_PATTERN =
  /\b(?:well[\s,]+no|no[\s,]+wait|sorry|i\s+mean|scratch\s+that)\b/iu;
const LETS_DO_REPEATED_NEGATED_CORRECTION_PATTERN =
  /^(?<prefix>.*?\blet(?:'|’)s\s+do\s+a\s+)(?<old>[\p{L}\p{N}][\p{L}\p{N}\s'’-]*?)\s+well[\s,]+no[\s,]+not\s+\k<old>\s+let(?:'|’)s\s+do\s+a\s+(?<replacement>[^.?!]+)(?<ending>[.?!]?)$/iu;
const LETS_DO_WELL_REPLACEMENT_PATTERN =
  /^(?<prefix>.*?\blet(?:'|’)s\s+do\s+)(?:a\s+)?(?<old>[^,.?!]+?)(?:,\s*)?\bwell\s*,\s*(?<replacement>[^.?!]+)(?<ending>[.?!]?)$/iu;

const SPOKEN_LIST_CUE_PATTERN =
  /\b(?:first\s+of\s+all|second\s+of\s+all|third\s+of\s+all|number\s+(?:one|two|three|four|five)|firstly|secondly|thirdly)\b/iu;

function hasExplicitSelfCorrectionCue(text: string): boolean {
  return (
    SELF_CORRECTION_CUE_PATTERN.test(text) ||
    LETS_DO_REPEATED_NEGATED_CORRECTION_PATTERN.test(text) ||
    LETS_DO_WELL_REPLACEMENT_PATTERN.test(text)
  );
}

function hasSpokenListCue(text: string): boolean {
  return SPOKEN_LIST_CUE_PATTERN.test(text);
}

function hasNumberedMarkdownList(text: string): boolean {
  return /(?:^|\n)\s*1\.\s+\S/u.test(text) && /(?:^|\n)\s*2\.\s+\S/u.test(text);
}

function isAllowedSelfCorrectionRewrite(
  cleanedText: string,
  candidate: string,
): boolean {
  if (!hasExplicitSelfCorrectionCue(cleanedText)) return false;
  if (countWords(candidate) >= countWords(cleanedText)) return false;
  if (hasUngroundedContent(cleanedText, candidate)) return false;
  return (
    normalizedSimilarity(cleanedText, candidate) >=
      SELF_CORRECTION_SIMILARITY_FLOOR ||
    countWords(candidate) >= 4
  );
}

function normalizeContentToken(token: string): string {
  const lower = token.toLowerCase().replace(/’/g, "'");
  return NUMBER_WORD_VALUES[lower] !== undefined
    ? String(NUMBER_WORD_VALUES[lower])
    : lower;
}

function contentTokens(text: string): string[] {
  return (
    normalizeZeroQuantifierNegation(text)
      .normalize("NFKC")
      .match(/[\p{L}\p{N}'’]+/gu)
      ?.map(normalizeContentToken) ?? []
  );
}

function hasUngroundedContent(cleanedText: string, candidate: string): boolean {
  const cleanedCounts = new Map<string, number>();
  for (const token of contentTokens(cleanedText)) {
    cleanedCounts.set(token, (cleanedCounts.get(token) ?? 0) + 1);
  }

  for (const token of contentTokens(candidate)) {
    const available = cleanedCounts.get(token) ?? 0;
    if (available <= 0) return true;
    cleanedCounts.set(token, available - 1);
  }

  return false;
}

function withTerminalPunctuation(text: string, fallback: string): string {
  const trimmed = text.trim().replace(/\s+([,.?!])/gu, "$1");
  return /[.?!]$/u.test(trimmed) ? trimmed : `${trimmed}${fallback || "."}`;
}

function deterministicSelfCorrectionCandidate(cleanedText: string): string | null {
  const repeatedNegated = cleanedText.match(
    LETS_DO_REPEATED_NEGATED_CORRECTION_PATTERN,
  );
  if (repeatedNegated?.groups) {
    return withTerminalPunctuation(
      `${repeatedNegated.groups.prefix}${repeatedNegated.groups.replacement}`,
      repeatedNegated.groups.ending ?? ".",
    );
  }

  const wellReplacement = cleanedText.match(LETS_DO_WELL_REPLACEMENT_PATTERN);
  if (wellReplacement?.groups) {
    return withTerminalPunctuation(
      `${wellReplacement.groups.prefix}${wellReplacement.groups.replacement}`,
      wellReplacement.groups.ending ?? ".",
    );
  }

  return null;
}

function isAllowedSpokenListRewrite(
  cleanedText: string,
  candidate: string,
): boolean {
  if (!hasSpokenListCue(cleanedText) || !hasNumberedMarkdownList(candidate)) {
    return false;
  }
  return normalizedSimilarity(cleanedText, candidate) >= SPOKEN_LIST_SIMILARITY_FLOOR;
}

function validatePolishCandidate(
  cleanedText: string,
  polishedText: string,
): string | null {
  const candidate = polishedText.trim();
  const allowedSelfCorrectionRewrite = isAllowedSelfCorrectionRewrite(
    cleanedText,
    candidate,
  );
  const allowedSpokenListRewrite = isAllowedSpokenListRewrite(
    cleanedText,
    candidate,
  );
  const allowsStructuredRewrite =
    allowedSelfCorrectionRewrite || allowedSpokenListRewrite;
  const isShorterSelfCorrectionCandidate =
    hasExplicitSelfCorrectionCue(cleanedText) &&
    countWords(candidate) < countWords(cleanedText);
  const selfCorrectionHasUngroundedContent =
    isShorterSelfCorrectionCandidate && hasUngroundedContent(cleanedText, candidate);
  const isLowSimilaritySelfCorrectionRewrite =
    isShorterSelfCorrectionCandidate &&
    !allowedSelfCorrectionRewrite &&
    !allowedSpokenListRewrite;
  if (!candidate) return "empty polish response";
  if (/Raw Whisper text:|VoiceLayer cleaned text to fix:/i.test(candidate)) {
    return "polish response echoed the prompt";
  }
  if (selfCorrectionHasUngroundedContent) {
    return POLISH_REJECTION_REASONS.SELF_CORRECTION_UNGROUNDED;
  }
  if (isLowSimilaritySelfCorrectionRewrite) {
    return "polish response self-correction rewrite changed too much text";
  }
  if (
    negationCount(cleanedText) !== negationCount(candidate) &&
    !allowedSelfCorrectionRewrite
  ) {
    return "polish response changed negation";
  }
  if (removedProtectedCodePunctuation(cleanedText, candidate)) {
    return "polish response removed code punctuation";
  }
  const inventedIdentifier = introducedCodeStyleIdentifier(cleanedText, candidate);
  if (inventedIdentifier) {
    return `polish response invented code identifier: ${inventedIdentifier}`;
  }
  if (changedProtectedTokens(cleanedText, candidate) && !allowedSpokenListRewrite) {
    return POLISH_REJECTION_REASONS.PROTECTED_TOKENS_CHANGED;
  }

  const cleanedChars = cleanedText.trim().length;
  const candidateChars = candidate.length;
  if (cleanedChars >= 80 && !allowsStructuredRewrite) {
    if (candidateChars < cleanedChars * 0.72) {
      return POLISH_REJECTION_REASONS.DROPPED_TOO_MUCH_TEXT;
    }
    if (candidateChars > cleanedChars * 1.35) return "polish response added too much text";
  }

  const cleanedWords = countWords(cleanedText);
  const candidateWords = countWords(candidate);
  if (cleanedWords >= 12 && !allowsStructuredRewrite) {
    if (candidateWords < cleanedWords * 0.72) {
      return POLISH_REJECTION_REASONS.DROPPED_TOO_MANY_WORDS;
    }
    if (candidateWords > cleanedWords * 1.35) return "polish response added too many words";
    if (normalizedSimilarity(cleanedText, candidate) < 0.62) {
      return "polish response changed too much text";
    }
  } else if (!allowsStructuredRewrite && normalizedSimilarity(cleanedText, candidate) < 0.72) {
    return "short polish response changed too much text";
  }

  return null;
}

function applyPolishCandidate(
  cleanedText: string,
  polishedText: string,
  mode: STTPolishMode,
  buildResult: (
    text: string,
    polishedText: string | null,
    status: STTPolishStatus,
    error?: string,
    retried?: boolean,
  ) => STTPolishResult,
  retried = false,
): STTPolishResult {
  const trimmedPolishedText = polishedText.trim();
  const deterministicCandidate =
    normalizedSimilarityText(cleanedText) ===
    normalizedSimilarityText(trimmedPolishedText)
      ? deterministicSelfCorrectionCandidate(cleanedText)
      : null;
  const candidateText = deterministicCandidate ?? trimmedPolishedText;
  const rejectionReason = validatePolishCandidate(cleanedText, candidateText);
  if (mode === "shadow") {
    return buildResult(
      cleanedText,
      candidateText,
      "shadowed",
      rejectionReason ?? undefined,
      retried,
    );
  }
  if (rejectionReason) {
    return buildResult(
      cleanedText,
      candidateText,
      "rejected",
      rejectionReason,
      retried,
    );
  }
  return buildResult(candidateText, candidateText, "applied", undefined, retried);
}

function getPolishHealthEndpoint(endpoint: string): string {
  const url = new URL(endpoint);
  const originalPathname = url.pathname;
  url.pathname = url.pathname.replace(/\/chat\/completions\/?$/u, "/models");
  if (url.pathname === originalPathname) {
    url.pathname = "/v1/models";
  }
  url.hash = "";
  return url.toString();
}

async function checkPolishEndpointHealth(
  endpoint: string,
  timeoutMs: number,
): Promise<{ ok: true } | { ok: false; error: string }> {
  let healthEndpoint: string;
  try {
    healthEndpoint = getPolishHealthEndpoint(endpoint);
  } catch (err) {
    return {
      ok: false,
      error: `polish health check endpoint invalid: ${
        err instanceof Error ? err.message : String(err)
      }`,
    };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(healthEndpoint, {
      method: "GET",
      signal: controller.signal,
    });
    if (!response.ok) {
      return {
        ok: false,
        error: `polish health check failed: ${response.status} ${response.statusText}`,
      };
    }
    return { ok: true };
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      return {
        ok: false,
        error: `polish health check timed out after ${timeoutMs}ms`,
      };
    }
    return {
      ok: false,
      error: `polish health check failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    };
  } finally {
    clearTimeout(timeout);
  }
}

async function requestPolishOverHttp(
  endpoint: string,
  rawText: string,
  cleanedText: string,
  env: STTPolishEnv,
  timeoutMs: number,
  options: { retryReason?: STTPolishRetryReason } = {},
): Promise<string> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        model: getSTTPolishModel(env),
        messages: [
          {
            role: "system",
            content: buildPolishSystemPrompt(options.retryReason),
          },
          { role: "user", content: buildPolishUserPrompt(rawText, cleanedText) },
        ],
        temperature: 0,
        top_p: 1,
        max_tokens: getSTTPolishMaxTokens(cleanedText),
        repetition_penalty: 0,
        stream: false,
        stop: ["\nRaw Whisper text:", "\nVoiceLayer cleaned text to fix:"],
      }),
    });
    if (!response.ok) {
      throw new Error(`polish endpoint failed: ${response.status} ${response.statusText}`);
    }
    const payload = (await response.json()) as OpenAIChatCompletionResponse;
    if (payload.error) {
      throw new Error(
        `polish endpoint error: ${
          typeof payload.error === "string" ? payload.error : JSON.stringify(payload.error)
        }`,
      );
    }
    return extractPolishResponseText(payload);
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      throw new Error(`polish request timed out after ${timeoutMs}ms`);
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }
}

async function requestPolishWarmupOverHttp(
  endpoint: string,
  env: STTPolishEnv,
  timeoutMs: number,
): Promise<void> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      signal: controller.signal,
      body: JSON.stringify({
        model: getSTTPolishModel(env),
        messages: [
          { role: "system", content: "You are warming up for VoiceLayer dictation polish. Reply with one punctuation mark." },
          { role: "user", content: "Warm up." },
        ],
        temperature: 0,
        top_p: 1,
        max_tokens: 1,
        stream: false,
      }),
    });
    if (!response.ok) {
      throw new Error(`polish warmup failed: ${response.status} ${response.statusText}`);
    }
    const payload = (await response.json()) as OpenAIChatCompletionResponse;
    if (payload.error) {
      throw new Error(
        `polish warmup error: ${
          typeof payload.error === "string" ? payload.error : JSON.stringify(payload.error)
        }`,
      );
    }
    extractPolishResponseText(payload);
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      throw new Error(`polish warmup timed out after ${timeoutMs}ms`);
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }
}

export async function warmPolishEndpoint(
  env: STTPolishEnv = process.env,
): Promise<STTPolishWarmupResult> {
  const startedAt = performance.now();
  const buildResult = (
    status: STTPolishWarmupStatus,
    error?: string,
  ): STTPolishWarmupResult => ({
    status,
    latencyMs: performance.now() - startedAt,
    error,
  });

  if (!isSTTPolishWarmupEnabled(env)) {
    return buildResult("skipped");
  }

  const endpoint = getSTTPolishEndpoint(env);
  if (!endpoint) {
    return buildResult("skipped", "polish HTTP endpoint unavailable");
  }

  const health = await checkPolishEndpointHealth(
    endpoint,
    getSTTPolishHealthTimeoutMs(env),
  );
  if (!health.ok) {
    return buildResult("failed", health.error);
  }

  try {
    await requestPolishWarmupOverHttp(
      endpoint,
      env,
      getSTTPolishWarmupTimeoutMs(env),
    );
    return buildResult("warmed");
  } catch (err) {
    return buildResult(
      "failed",
      err instanceof Error ? err.message : String(err),
    );
  }
}

async function requestPolishOverSocket(
  socketPath: string,
  request: STTPolishSocketRequest,
  timeoutMs: number,
): Promise<string> {
  return new Promise((resolve, reject) => {
    let settled = false;
    let connection: { write: (data: string) => void; end?: () => void } | null =
      null;
    let buffer = "";

    const cleanup = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        connection?.end?.();
      } catch {}
    };

    const finishResolve = (value: string) => {
      cleanup();
      resolve(value);
    };

    const finishReject = (error: Error) => {
      cleanup();
      reject(error);
    };

    const timer = setTimeout(() => {
      finishReject(new Error(`polish request timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    Bun.connect<{ buffer: string }>({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.data = { buffer: "" };
          connection = socket;
          socket.write(`${JSON.stringify(request)}\n`);
        },
        data(_socket, raw) {
          buffer += raw.toString("utf-8");
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              const response = JSON.parse(line) as STTPolishSocketResponse;
              if (typeof response.error === "string" && response.error) {
                finishReject(new Error(response.error));
                return;
              }
              if (typeof response.text !== "string") {
                finishReject(new Error("polish response missing text"));
                return;
              }
              finishResolve(response.text.trim());
              return;
            } catch (err) {
              finishReject(
                new Error(
                  `invalid polish response: ${err instanceof Error ? err.message : String(err)}`,
                ),
              );
              return;
            }
          }
        },
        close() {
          if (!settled) finishReject(new Error("polish socket closed"));
        },
        error(_socket, error) {
          finishReject(error);
        },
        connectError(_socket, error) {
          finishReject(error);
        },
        drain() {},
      },
    }).catch((err) => {
      finishReject(err instanceof Error ? err : new Error(String(err)));
    });
  });
}

function writePolishLog(
  result: STTPolishResult,
  rawText: string,
  cleanedText: string,
  env: STTPolishEnv,
): void {
  const path = getSTTPolishLogPath(env);
  const row = `${JSON.stringify({
    created_at: new Date().toISOString(),
    mode: result.mode,
    status: result.status,
    surface: result.surface,
    raw_text: rawText,
    cleaned_text: cleanedText,
    polished_text: result.polishedText,
    final_text: result.text,
    changed: result.changed,
    retried: result.retried,
    latency_ms: result.latencyMs,
    polished: result.polished,
    reason: result.reason,
    error: result.error,
  })}\n`;

  void mkdir(dirname(path), { recursive: true, mode: 0o700 })
    .then(() => appendFile(path, row, { mode: 0o600 }))
    .catch((err) => {
      console.error(
        `[voicelayer] Failed to write STT polish log: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
    });
}

export async function polishTranscriptionText(
  input: STTPolishInput,
): Promise<STTPolishResult> {
  const env = input.env ?? process.env;
  const mode = getSTTPolishMode(env);
  const surface = input.surface ?? "dictation";
  const startedAt = performance.now();

  const buildResult = (
    text: string,
    polishedText: string | null,
    status: STTPolishStatus,
    error?: string,
    retried = false,
  ): STTPolishResult => {
    const polished = status === "applied";
    return {
      inputText: input.cleanedText,
      text,
      polishedText,
      mode,
      status,
      surface,
      changed: text !== input.cleanedText,
      retried,
      latencyMs: performance.now() - startedAt,
      polished,
      reason: polished ? undefined : error ?? status,
      error,
    };
  };

  const punctuationFloorFallbackText = (): string =>
    mode === "shadow"
      ? input.cleanedText
      : deterministicRunOnPunctuationFloor(input.cleanedText);

  if (mode === "off" || !input.cleanedText.trim()) {
    return buildResult(input.cleanedText, null, "skipped");
  }

  const endpoint = getSTTPolishEndpoint(env);
  if (endpoint) {
    const health = await checkPolishEndpointHealth(
      endpoint,
      getSTTPolishHealthTimeoutMs(env),
    );
    if (!health.ok) {
      const result = buildResult(
        punctuationFloorFallbackText(),
        null,
        "failed",
        health.error,
      );
      writePolishLog(result, input.rawText, input.cleanedText, env);
      return result;
    }

    try {
      const polishedText = await requestPolishOverHttp(
        endpoint,
        input.rawText,
        input.cleanedText,
        env,
        getSTTPolishTimeoutMs(env),
      );
      const result = applyPolishCandidate(
        input.cleanedText,
        polishedText,
        mode,
        buildResult,
      );
      const retryReason =
        result.status === "applied" &&
        !result.changed &&
        shouldRetryNoopPolish(input.cleanedText)
          ? "noop"
          : shouldRetryRejectedPolish(input.cleanedText, result)
            ? "rejected"
            : null;
      if (retryReason) {
        if (retryReason === "noop") {
          let latestResult = result;
          for (
            let attempt = 2;
            attempt <= MAX_HTTP_NOOP_POLISH_ATTEMPTS;
            attempt += 1
          ) {
            try {
              const retryPolishedText = await requestPolishOverHttp(
                endpoint,
                input.rawText,
                input.cleanedText,
                env,
                getSTTPolishTimeoutMs(env),
                { retryReason },
              );
              latestResult = applyPolishCandidate(
                input.cleanedText,
                retryPolishedText,
                mode,
                buildResult,
                true,
              );
              if (
                latestResult.status !== "applied" ||
                latestResult.changed ||
                !shouldRetryNoopPolish(input.cleanedText)
              ) {
                writePolishLog(
                  latestResult,
                  input.rawText,
                  input.cleanedText,
                  env,
                );
                return latestResult;
              }
            } catch (retryErr) {
              const retryFailedResult = buildResult(
                punctuationFloorFallbackText(),
                latestResult.polishedText,
                "failed",
                retryErr instanceof Error ? retryErr.message : String(retryErr),
                true,
              );
              writePolishLog(
                retryFailedResult,
                input.rawText,
                input.cleanedText,
                env,
              );
              return retryFailedResult;
            }
          }
          const flooredResult = buildResult(
            punctuationFloorFallbackText(),
            latestResult.polishedText,
            latestResult.status,
            latestResult.error,
            true,
          );
          writePolishLog(
            flooredResult,
            input.rawText,
            input.cleanedText,
            env,
          );
          return flooredResult;
        }

        try {
          const retryPolishedText = await requestPolishOverHttp(
            endpoint,
            input.rawText,
            input.cleanedText,
            env,
            getSTTPolishTimeoutMs(env),
            { retryReason },
          );
          const retryResult = applyPolishCandidate(
            input.cleanedText,
            retryPolishedText,
            mode,
            buildResult,
            true,
          );
          writePolishLog(retryResult, input.rawText, input.cleanedText, env);
          return retryResult;
        } catch (retryErr) {
          const retryFailedResult = buildResult(
            result.text,
            result.polishedText,
            result.status,
            retryErr instanceof Error ? retryErr.message : String(retryErr),
            true,
          );
          writePolishLog(
            retryFailedResult,
            input.rawText,
            input.cleanedText,
            env,
          );
          return retryFailedResult;
        }
      }
      writePolishLog(result, input.rawText, input.cleanedText, env);
      return result;
    } catch (err) {
      const result = buildResult(
        punctuationFloorFallbackText(),
        null,
        "failed",
        err instanceof Error ? err.message : String(err),
      );
      writePolishLog(result, input.rawText, input.cleanedText, env);
      return result;
    }
  }

  const socketPath = getSTTPolishSocketPath(env);
  if (!existsSync(socketPath)) {
    const result = buildResult(input.cleanedText, null, "unavailable");
    writePolishLog(result, input.rawText, input.cleanedText, env);
    return result;
  }

  try {
    const polishedText = await requestPolishOverSocket(
      socketPath,
      {
        id: randomUUID(),
        raw_text: input.rawText,
        cleaned_text: input.cleanedText,
        surface,
      },
      getSTTPolishSocketTimeoutMs(env),
    );
    const result = applyPolishCandidate(
      input.cleanedText,
      polishedText,
      mode,
      buildResult,
    );
    writePolishLog(result, input.rawText, input.cleanedText, env);
    return result;
  } catch (err) {
    const result = buildResult(
      punctuationFloorFallbackText(),
      null,
      "failed",
      err instanceof Error ? err.message : String(err),
    );
    writePolishLog(result, input.rawText, input.cleanedText, env);
    return result;
  }
}
