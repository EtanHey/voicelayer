import { randomUUID } from "crypto";

export interface AndroidApplianceConfig {
  enabled: boolean;
  baseUrl: string;
  timeoutMs: number;
}

export interface AndroidApplianceBridgeOptions {
  baseUrl: string;
  timeoutMs: number;
  sessionIdFactory?: () => string;
}

export interface AndroidStartOptions {
  timeoutMs: number;
  pressToTalk: boolean;
}

export type AndroidUnavailableReason =
  | "disabled"
  | "unhealthy"
  | "busy"
  | "timeout"
  | "network"
  | "protocol";

export type AndroidHealthResult =
  | { ok: true; state: string }
  | { ok: false; reason: AndroidUnavailableReason };

export type AndroidStartResult =
  | { ok: true; sessionId: string; source: "android" }
  | { ok: false; reason: AndroidUnavailableReason };

export type AndroidStopResult =
  | { ok: true; durationMs: number | null }
  | { ok: false; reason: AndroidUnavailableReason };

export type AndroidCancelResult =
  | { ok: true }
  | { ok: false; reason: AndroidUnavailableReason };

function envEnabled(value: string | undefined): boolean {
  return value?.trim() === "1";
}

function normalizeBaseUrl(value: string): string {
  return value.replace(/\/+$/, "");
}

function timeoutFromEnv(value: string | undefined): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : 5000;
}

export function resolveAndroidApplianceConfig(
  env: NodeJS.ProcessEnv = process.env,
): AndroidApplianceConfig {
  return {
    enabled: envEnabled(env.QA_VOICE_ANDROID_APPLIANCE),
    baseUrl: normalizeBaseUrl(
      env.QA_VOICE_ANDROID_APPLIANCE_URL ?? "http://127.0.0.1:8765",
    ),
    timeoutMs: timeoutFromEnv(env.QA_VOICE_ANDROID_APPLIANCE_TIMEOUT_MS),
  };
}

function classifyFetchError(err: unknown): AndroidUnavailableReason {
  if (err instanceof DOMException && err.name === "AbortError") {
    return "timeout";
  }
  return "network";
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

export class AndroidApplianceBridge {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly sessionIdFactory: () => string;

  constructor(options: AndroidApplianceBridgeOptions) {
    this.baseUrl = normalizeBaseUrl(options.baseUrl);
    this.timeoutMs = options.timeoutMs;
    this.sessionIdFactory = options.sessionIdFactory ?? randomUUID;
  }

  async checkHealth(): Promise<AndroidHealthResult> {
    let response: Response;
    try {
      response = await this.fetchWithTimeout("/health", { method: "GET" });
    } catch (err) {
      return { ok: false, reason: classifyFetchError(err) };
    }

    if (!response.ok) {
      return { ok: false, reason: response.status === 409 ? "busy" : "unhealthy" };
    }

    const body = await response.json().catch(() => null);
    if (!isObject(body) || body.ok !== true) {
      return { ok: false, reason: "unhealthy" };
    }

    const state = typeof body.state === "string" ? body.state : "unknown";
    if (state === "busy" || state === "recording" || state === "transcribing") {
      return { ok: false, reason: "busy" };
    }

    return { ok: true, state };
  }

  async startRecording(options: AndroidStartOptions): Promise<AndroidStartResult> {
    const health = await this.checkHealth();
    if (!health.ok) return health;

    const sessionId = this.sessionIdFactory();
    let response: Response;
    try {
      response = await this.fetchWithTimeout("/start", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          session_id: sessionId,
          mode: options.pressToTalk ? "ptt" : "vad",
          sample_rate: 16000,
          channels: 1,
          encoding: "pcm_s16le",
          timeout_seconds: Math.ceil(options.timeoutMs / 1000),
        }),
      });
    } catch (err) {
      return { ok: false, reason: classifyFetchError(err) };
    }

    if (!response.ok) {
      return {
        ok: false,
        reason: response.status === 409 ? "busy" : "protocol",
      };
    }

    const body = await response.json().catch(() => null);
    if (!isObject(body) || body.ok !== true) {
      return { ok: false, reason: "protocol" };
    }

    const returnedSessionId =
      typeof body.session_id === "string" ? body.session_id : sessionId;
    return { ok: true, sessionId: returnedSessionId, source: "android" };
  }

  async stopRecording(sessionId: string): Promise<AndroidStopResult> {
    let response: Response;
    try {
      response = await this.fetchWithTimeout("/stop", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ session_id: sessionId }),
      });
    } catch (err) {
      return { ok: false, reason: classifyFetchError(err) };
    }

    if (!response.ok) {
      return {
        ok: false,
        reason: response.status === 409 ? "busy" : "protocol",
      };
    }

    const body = await response.json().catch(() => null);
    if (!isObject(body) || body.ok !== true) {
      return { ok: false, reason: "protocol" };
    }

    return {
      ok: true,
      durationMs:
        typeof body.duration_ms === "number" ? body.duration_ms : null,
    };
  }

  async pullAudio(sessionId: string): Promise<Uint8Array | null> {
    let response: Response;
    try {
      response = await this.fetchWithTimeout(
        `/pull_audio?session_id=${encodeURIComponent(sessionId)}`,
        { method: "GET" },
      );
    } catch {
      return null;
    }

    if (!response.ok) return null;
    const bytes = new Uint8Array(await response.arrayBuffer());
    return bytes.length > 0 ? bytes : null;
  }

  async cancelRecording(sessionId: string): Promise<AndroidCancelResult> {
    let response: Response;
    try {
      response = await this.fetchWithTimeout("/cancel", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ session_id: sessionId }),
      });
    } catch (err) {
      return { ok: false, reason: classifyFetchError(err) };
    }

    if (!response.ok) {
      return {
        ok: false,
        reason: response.status === 409 ? "busy" : "protocol",
      };
    }

    const body = await response.json().catch(() => null);
    if (!isObject(body) || body.ok !== true) {
      return { ok: false, reason: "protocol" };
    }
    return { ok: true };
  }

  private fetchWithTimeout(
    path: string,
    init: RequestInit,
  ): Promise<Response> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    return fetch(`${this.baseUrl}${path}`, {
      ...init,
      signal: controller.signal,
    }).finally(() => clearTimeout(timer));
  }
}
