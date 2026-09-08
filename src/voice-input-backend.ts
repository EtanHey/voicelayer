import { waitForInput } from "./input";
import type { SilenceMode } from "./vad";

export type VoiceInputBackend = "local" | "spokenly" | "auto";
export type VoiceInputSource = "local" | "spokenly";

type EnvLike = Record<string, string | undefined>;

type FetchLike = (
  url: string | URL | Request,
  init?: RequestInit,
) => Promise<Response>;

type LocalWaitForInput = (
  timeoutMs: number,
  silenceMode: SilenceMode,
  pressToTalk: boolean,
) => Promise<string | null>;

export interface AskSpokenlyDictationOptions {
  question: string;
  timeoutMs: number;
  url?: string;
  fetchImpl?: FetchLike;
}

export interface CollectVoiceInputOptions {
  question: string;
  timeoutMs: number;
  silenceMode: SilenceMode;
  pressToTalk: boolean;
  env?: EnvLike;
  localWaitForInput?: LocalWaitForInput;
  fetchImpl?: FetchLike;
}

export interface CollectedVoiceInput {
  source: VoiceInputSource;
  transcript: string | null;
}

export function getConfiguredVoiceInputBackend(
  env: EnvLike = process.env,
): VoiceInputBackend {
  const raw = (
    env.VOICELAYER_INPUT_BACKEND ??
    env.QA_VOICE_INPUT_BACKEND ??
    "local"
  )
    .trim()
    .toLowerCase();

  if (raw === "spokenly" || raw === "auto") return raw;
  return "local";
}

export function getSpokenlyMcpUrl(env: EnvLike = process.env): string {
  return (
    env.VOICELAYER_SPOKENLY_MCP_URL ??
    env.QA_VOICE_SPOKENLY_MCP_URL ??
    "http://localhost:51089"
  ).trim();
}

export async function askSpokenlyDictation({
  question,
  timeoutMs,
  url = getSpokenlyMcpUrl(),
  fetchImpl = fetch,
}: AskSpokenlyDictationOptions): Promise<string | null> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
          name: "ask_user_dictation",
          arguments: {
            questions: [question],
          },
        },
      }),
      signal: controller.signal,
    });

    if (!response.ok) {
      throw new Error(
        `Spokenly MCP request failed: HTTP ${response.status} ${response.statusText}`.trim(),
      );
    }

    const payload = await response.json();
    return extractSpokenlyTranscript(payload);
  } catch (err) {
    if (err instanceof Error && err.name === "AbortError") {
      throw new Error(`Spokenly dictation timed out after ${timeoutMs}ms`);
    }
    throw err;
  } finally {
    clearTimeout(timeout);
  }
}

export async function collectVoiceInput(
  options: CollectVoiceInputOptions,
): Promise<string | null> {
  return (await collectVoiceInputWithSource(options)).transcript;
}

export async function collectVoiceInputWithSource({
  question,
  timeoutMs,
  silenceMode,
  pressToTalk,
  env = process.env,
  localWaitForInput = waitForInput,
  fetchImpl = fetch,
}: CollectVoiceInputOptions): Promise<CollectedVoiceInput> {
  const backend = getConfiguredVoiceInputBackend(env);
  if (backend === "local") {
    return {
      source: "local",
      transcript: await localWaitForInput(timeoutMs, silenceMode, pressToTalk),
    };
  }

  try {
    return {
      source: "spokenly",
      transcript: await askSpokenlyDictation({
        question,
        timeoutMs,
        url: getSpokenlyMcpUrl(env),
        fetchImpl,
      }),
    };
  } catch (err) {
    if (backend === "auto") {
      console.error(
        `[voicelayer] Spokenly input unavailable; falling back to local STT: ${
          err instanceof Error ? err.message : String(err)
        }`,
      );
      return {
        source: "local",
        transcript: await localWaitForInput(
          timeoutMs,
          silenceMode,
          pressToTalk,
        ),
      };
    }
    throw err;
  }
}

function extractSpokenlyTranscript(payload: unknown): string | null {
  if (!payload || typeof payload !== "object") {
    throw new Error("Spokenly MCP response was not a JSON object");
  }

  const envelope = payload as {
    error?: { message?: unknown };
    result?: {
      isError?: unknown;
      content?: Array<{ type?: unknown; text?: unknown }>;
    };
  };

  if (envelope.error) {
    throw new Error(
      typeof envelope.error.message === "string"
        ? envelope.error.message
        : "Spokenly MCP returned an error",
    );
  }

  const result = envelope.result;
  const text = result?.content
    ?.filter((item) => item?.type === "text" && typeof item.text === "string")
    .map((item) => item.text as string)
    .join("\n")
    .trim();

  if (result?.isError) {
    throw new Error(text || "Spokenly dictation failed");
  }

  return text ? text : null;
}
