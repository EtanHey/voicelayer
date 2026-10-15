import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { buildDaemonRequestHeaders } from "./tts/qwen3";
import { readTTSSettings, resolveSpeakProfile, ttsSettingEnvVar, type TTSEnv, type SpeakProfileKind, type TTSProfile } from "./tts-settings";

type Setting<T> = { source: "default" | "settings" | "environment"; raw: string | number | null; effective: T; locked?: string };
export type FirstAudioMeasurement = { engine: string; origin: "preview" | "speak"; fallback: boolean };
const measurement: Record<SpeakProfileKind, FirstAudioMeasurement | null> = { short: null, long: null };
let previewActive = false;
export function setTTSPreviewActive(active: boolean): void { previewActive = active; }
const latency: Record<SpeakProfileKind, number | null> = { short: null, long: null };
export function recordFirstAudio(kind: SpeakProfileKind, ms: number, details?: FirstAudioMeasurement): void {
  latency[kind] = ms;
  measurement[kind] = details ? {...details} : null;
}
let cloneState: "up" | "down" = "down";
let checkedAt = -Infinity;
let pending: Promise<"up" | "down"> | undefined;

/** Cached, coalesced, bounded health-only probe: never starts or loads a daemon/model. */
export async function probeCloneDaemon(fetcher: typeof fetch = fetch, now = Date.now()): Promise<"up" | "down"> {
  if (pending) return pending;
  if (now - checkedAt < 5_000) return cloneState;
  pending = (async () => {
    try {
      const headers = buildDaemonRequestHeaders();
      const healthy = headers ? await fetcher("http://127.0.0.1:8880/health", {
        headers, signal: AbortSignal.timeout(500),
      }).then(async response => {
        if (!response.ok) return false;
        const data = await response.json() as { status?: string; model_loaded?: boolean };
        return data.status === "ok" && data.model_loaded === true;
      }) : false;
      cloneState = healthy ? "up" : "down";
    } catch { cloneState = "down"; }
    checkedAt = now;
    return cloneState;
  })();
  try { return await pending; } finally { pending = undefined; }
}

export function availableTTSVoices(env: TTSEnv = process.env): Array<{engine: "edge" | "clone"; voice: string}> {
  const voices = new Map<string, {engine: "edge" | "clone"; voice: string}>();
  const add = (engine: "edge" | "clone", voice: string) => voices.set(`${engine}:${voice}`, {engine, voice});
  for (const voice of ["en-US-GuyNeural", "en-US-JennyNeural", "en-US-AndrewNeural", "en-US-BrianMultilingualNeural", "en-US-AvaNeural", "en-US-AriaNeural"]) add("edge", voice);
  const root = join(env.HOME || homedir(), ".voicelayer");
  try {
    const presets = JSON.parse(readFileSync(join(root, "voices.json"), "utf8"));
    for (const [name, profile] of Object.entries(presets)) {
      const p = profile as {engine?: string; voice?: unknown} | null;
      if (p?.engine === "edge-tts" && typeof p.voice === "string") add("edge", name);
    }
  } catch {}
  try {
    // P7 owns Ben readiness; a directory alone must never advertise Ben as runnable.
    if (existsSync(join(root, "voices", "theo-c4s", "profile.yaml"))) add("clone", "theo-c4s");
  } catch {}
  return [...voices.values()].sort((a, b) => a.engine.localeCompare(b.engine) || a.voice.localeCompare(b.voice));
}

export function readTTSControlsStatus(env: TTSEnv = process.env) {
  const file = readTTSSettings(env);
  function profile(kind: SpeakProfileKind) {
    const resolved = resolveSpeakProfile(kind, "", env);
    function field<K extends keyof TTSProfile>(key: K): Setting<TTSProfile[K]> {
      const variable = ttsSettingEnvVar(`${kind}.${key}`);
      const raw = variable ? env[variable] : undefined;
      const stored = file.profiles?.[kind]?.[key];
      return { source: raw !== undefined ? "environment" : stored !== undefined ? "settings" : "default", raw: raw !== undefined && key === "engine" ? resolved.engine : raw ?? stored ?? null, effective: resolved[key], ...(raw !== undefined ? {locked: `Set by ${variable}`} : {}) };
    }
    return {engine: field("engine"), voice: field("voice"), rate: field("rate"), last_first_audio_ms: latency[kind], last_first_audio: measurement[kind]};
  }
  // Health responses stay synchronous; the next poll observes this cached refresh.
  void probeCloneDaemon();
  return {
    profiles: {short: profile("short"), long: profile("long")},
    short_limit_chars: {source: file.short_limit_chars !== undefined ? "settings" : "default", raw: file.short_limit_chars ?? null, effective: file.short_limit_chars ?? 400} as Setting<number>,
    available_voices: availableTTSVoices(env),
    clone_daemon: cloneState,
    preview_active: previewActive,
  };
}
export type TTSControlsStatus = ReturnType<typeof readTTSControlsStatus>;
