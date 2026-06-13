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
  QA_VOICE_STT_POLISH_TIMEOUT_MS?: string;
  QA_VOICE_STT_POLISH_LOG_PATH?: string;
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

const DEFAULT_POLISH_TIMEOUT_MS = 5_000;
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
  return Math.min(Math.max(raw, 50), 5_000);
}

function getSTTPolishLogPath(env: STTPolishEnv = process.env): string {
  return env.QA_VOICE_STT_POLISH_LOG_PATH?.trim() || DEFAULT_POLISH_LOG_PATH;
}

function buildPolishSystemPrompt(): string {
  return [
    "You are a transcript fixer for local voice dictation.",
    "Input is raw Whisper output after deterministic VoiceLayer cleanup.",
    "Fix only obvious transcript artifacts: missing sentence punctuation, duplicate punctuation, missing sentence-start capitalization, high-confidence recognition errors, code identifier formatting, slash-command spacing, chunk-boundary duplicates, and Hebrew/English spacing.",
    "Use light punctuation: add periods or question marks when sentence boundaries are clear from the text, but do not over-polish.",
    "Never summarize, paraphrase, translate, add content, delete meaningful content, change tone, or invent code identifiers.",
    "Preserve Hebrew as Hebrew and English/code terms as English.",
    "If unsure, return the input unchanged.",
    "Output only the corrected text.",
    "",
    "Examples:",
    "Input: Also, do / what's new and output that as your summary.",
    "Output: Also, do /whats-new and output that as your summary.",
    "Input: ask c mux whether brain layer is ready",
    "Output: Ask cmux whether BrainLayer is ready",
    "Input: תרים את ה handle socket command",
    "Output: תרים את ה-handleSocketCommand",
    "Input: This is already good.",
    "Output: This is already good.",
    "Input: why did it do that i am confused",
    "Output: Why did it do that? I am confused.",
    "Forbidden rewrite:",
    "Input: I think this might work.",
    "Output: This solution should work.",
  ].join("\n");
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

function negationCount(text: string): number {
  return (
    text
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

function protectedCodePunctuationCounts(text: string): Map<string, number> {
  const normalized = text.normalize("NFKC");
  const counts = new Map<string, number>();
  for (const char of normalized.match(/[\/\-_`$@#\\]/gu) ?? []) {
    counts.set(char, (counts.get(char) ?? 0) + 1);
  }

  const codeDotCount = countMatches(
    normalized,
    /(?<=[\p{L}\p{N}])\.(?=[\p{L}\p{N}])/gu,
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

function protectedNumericTokens(text: string): string[] {
  return (
    text
      .normalize("NFKC")
      .match(/(?<![\p{L}\p{N}_])\d+(?:[.,:]\d+)*(?:%|[A-Za-z]+)?(?![\p{L}\p{N}_])/gu)
      ?.map((token) => token.toLowerCase()) ?? []
  );
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

function validatePolishCandidate(
  cleanedText: string,
  polishedText: string,
): string | null {
  const candidate = polishedText.trim();
  if (!candidate) return "empty polish response";
  if (/Raw Whisper text:|VoiceLayer cleaned text to fix:/i.test(candidate)) {
    return "polish response echoed the prompt";
  }
  if (negationCount(cleanedText) !== negationCount(candidate)) {
    return "polish response changed negation";
  }
  if (removedProtectedCodePunctuation(cleanedText, candidate)) {
    return "polish response removed code punctuation";
  }
  if (changedProtectedTokens(cleanedText, candidate)) {
    return "polish response changed protected tokens";
  }

  const cleanedChars = cleanedText.trim().length;
  const candidateChars = candidate.length;
  if (cleanedChars >= 80) {
    if (candidateChars < cleanedChars * 0.72) return "polish response dropped too much text";
    if (candidateChars > cleanedChars * 1.35) return "polish response added too much text";
  }

  const cleanedWords = countWords(cleanedText);
  const candidateWords = countWords(candidate);
  if (cleanedWords >= 12) {
    if (candidateWords < cleanedWords * 0.72) return "polish response dropped too many words";
    if (candidateWords > cleanedWords * 1.35) return "polish response added too many words";
    if (normalizedSimilarity(cleanedText, candidate) < 0.62) {
      return "polish response changed too much text";
    }
  } else if (normalizedSimilarity(cleanedText, candidate) < 0.72) {
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
  ) => STTPolishResult,
): STTPolishResult {
  const trimmedPolishedText = polishedText.trim();
  const rejectionReason = validatePolishCandidate(cleanedText, trimmedPolishedText);
  if (mode === "shadow") {
    return buildResult(cleanedText, trimmedPolishedText, "shadowed", rejectionReason ?? undefined);
  }
  if (rejectionReason) {
    return buildResult(cleanedText, trimmedPolishedText, "rejected", rejectionReason);
  }
  return buildResult(trimmedPolishedText, trimmedPolishedText, "applied");
}

async function requestPolishOverHttp(
  endpoint: string,
  rawText: string,
  cleanedText: string,
  env: STTPolishEnv,
  timeoutMs: number,
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
          { role: "system", content: buildPolishSystemPrompt() },
          { role: "user", content: buildPolishUserPrompt(rawText, cleanedText) },
        ],
        temperature: 0,
        top_p: 1,
        max_tokens: 512,
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
    latency_ms: result.latencyMs,
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
  ): STTPolishResult => ({
    inputText: input.cleanedText,
    text,
    polishedText,
    mode,
    status,
    surface,
    changed: text !== input.cleanedText,
    latencyMs: performance.now() - startedAt,
    error,
  });

  if (mode === "off" || !input.cleanedText.trim()) {
    return buildResult(input.cleanedText, null, "skipped");
  }

  const endpoint = getSTTPolishEndpoint(env);
  if (endpoint) {
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
      writePolishLog(result, input.rawText, input.cleanedText, env);
      return result;
    } catch (err) {
      const result = buildResult(
        input.cleanedText,
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
      getSTTPolishTimeoutMs(env),
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
      input.cleanedText,
      null,
      "failed",
      err instanceof Error ? err.message : String(err),
    );
    writePolishLog(result, input.rawText, input.cleanedText, env);
    return result;
  }
}
