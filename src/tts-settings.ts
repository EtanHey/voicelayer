import { existsSync, readFileSync, renameSync, rmSync, mkdtempSync, writeFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { hasClonedProfile, readReadyClonedProfile } from "./tts/qwen3";
import { STATE_DIR } from "./paths";

export type TTSEnv = Record<string, string | undefined>;
export type SpeakProfileKind = "short" | "long";
export type TTSProfile = { engine: "edge" | "clone"; voice: string; rate: string };
export type TTSSettingKey = "short_limit_chars" | `${SpeakProfileKind}.${keyof TTSProfile}`;
export type TTSSettings = { profiles?: Partial<Record<SpeakProfileKind, Partial<TTSProfile>>>; short_limit_chars?: number };
export const TTS_DEFAULTS: TTSProfile = { engine: "edge", voice: "en-US-JennyNeural", rate: "+0%" };
export const TTS_SETTING_KEYS: readonly TTSSettingKey[] = ["short.engine", "short.voice", "short.rate", "long.engine", "long.voice", "long.rate", "short_limit_chars"];

export function ttsSettingsPath(env: TTSEnv = process.env): string {
  return env.VOICELAYER_TTS_SETTINGS_PATH?.trim() || join(STATE_DIR, "tts-settings.json");
}
export function ttsSettingEnvVar(key: TTSSettingKey): string | undefined {
  if (key.endsWith(".voice") || key.endsWith(".engine")) return "QA_VOICE_TTS_VOICE";
  if (key.endsWith(".rate")) return "QA_VOICE_TTS_RATE";
  return undefined;
}
export function validTTSSetting(key: unknown, value: unknown): key is TTSSettingKey {
  if (!(TTS_SETTING_KEYS as readonly unknown[]).includes(key)) return false;
  if (key === "short_limit_chars") return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
  if (String(key).endsWith(".engine")) return value === "edge" || value === "clone";
  if (String(key).endsWith(".rate")) return typeof value === "string" && /^[+-]\d{1,3}%$/.test(value) && parseInt(value, 10) > -100 && parseInt(value, 10) <= 100;
  return typeof value === "string" && value.trim().length > 0 && value.length <= 200 && !/[\x00-\x1f/\\]/.test(value);
}
export function readTTSSettings(env: TTSEnv = process.env): TTSSettings {
  try {
    const raw = JSON.parse(readFileSync(ttsSettingsPath(env), "utf8"));
    const settings: TTSSettings = {};
    if (!raw || typeof raw !== "object") return settings;
    for (const kind of ["short", "long"] as const) {
      for (const field of ["engine", "voice", "rate"] as const) {
        const value = raw.profiles?.[kind]?.[field];
        if (!validTTSSetting(`${kind}.${field}`, value)) continue;
        settings.profiles ??= {};
        settings.profiles[kind] ??= {};
        Object.assign(settings.profiles[kind]!, { [field]: value });
      }
    }
    // D9 uses one selected engine/voice pair, retaining the v1 file/wire format.
    // Normalize removed clone choices on read; the next explicit write persists it.
    // Never rewrite a user's file during a health poll or delete their private assets.
    for (const kind of ["short", "long"] as const) {
      const profile = settings.profiles?.[kind];
      if (profile?.voice && /^(?:ben|ben-c1)$/i.test(profile.voice) && profile.engine !== "edge"
          && readReadyClonedProfile("ben-c1", env.HOME || homedir())) {
        Object.assign(profile, {engine: "clone", voice: "ben-c1"});
        continue;
      }
      if (profile?.voice && /^(?:theo(?:[-_].*)?|huberman(?:[-_].*)?|ben(?:[-_].*)?)$/i.test(profile.voice)
          && profile.voice !== "theo-c4s" && profile.engine !== "edge") {
        const theoInstalled = existsSync(join(env.HOME || homedir(), ".voicelayer", "voices", "theo-c4s", "profile.yaml"));
        Object.assign(profile, theoInstalled ? {engine: "clone", voice: "theo-c4s"} : {engine: TTS_DEFAULTS.engine, voice: TTS_DEFAULTS.voice});
      }
    }
    if (validTTSSetting("short_limit_chars", raw.short_limit_chars)) settings.short_limit_chars = raw.short_limit_chars;
    return settings;
  } catch { return {}; }
}
function assertUnlocked(key: TTSSettingKey, env: TTSEnv): void {
  const variable = ttsSettingEnvVar(key);
  if (variable && env[variable] !== undefined) throw new Error(`Set by ${variable}`);
}

function assertConsistent(kind: SpeakProfileKind, settings: TTSSettings, env: TTSEnv): void {
  const pair = resolveProfile(kind, settings, env);
  if ((pair.engine === "clone") !== hasClonedProfile(pair.voice)) {
    throw new Error(`Inconsistent TTS engine/voice pair for ${kind}`);
  }
}

function writeTTSSettings(next: TTSSettings, env: TTSEnv): void {
  const path = ttsSettingsPath(env);
  const staging = mkdtempSync(`${path}.`);
  const tmp = join(staging, "settings.json");
  try {
    writeFileSync(tmp, JSON.stringify({ version: 1, ...next, updated_at: new Date().toISOString() }, null, 2) + "\n", { flag: "wx", mode: 0o600 });
    renameSync(tmp, path);
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

export function setTTSSetting(key: TTSSettingKey, value: string | number, env: TTSEnv = process.env): void {
  if (!validTTSSetting(key, value)) throw new Error("Invalid TTS setting");
  assertUnlocked(key, env);
  const next = readTTSSettings(env);
  if (key === "short_limit_chars") next.short_limit_chars = value as number;
  else {
    const [kind, field] = key.split(".") as [SpeakProfileKind, keyof TTSProfile];
    next.profiles ??= {};
    next.profiles[kind] ??= {};
    Object.assign(next.profiles[kind]!, { [field]: field === "voice" ? (value as string).trim() : value });
    assertConsistent(kind, next, env);
  }
  writeTTSSettings(next, env);
}

/** Switch engine and voice in a single validated atomic write; preserve an omitted rate. */
export function setTTSProfile(kind: SpeakProfileKind, value: Pick<TTSProfile, "engine" | "voice"> & Partial<Pick<TTSProfile, "rate">>, env: TTSEnv = process.env): void {
  if (kind !== "short" && kind !== "long") throw new Error("Invalid TTS profile");
  for (const field of ["engine", "voice", "rate"] as const) {
    if (field === "rate" && value.rate === undefined) continue;
    if (!validTTSSetting(`${kind}.${field}`, value[field])) throw new Error("Invalid TTS setting");
    assertUnlocked(`${kind}.${field}`, env);
  }
  const next = readTTSSettings(env);
  next.profiles ??= {};
  next.profiles[kind] = { ...next.profiles[kind], engine: value.engine, voice: value.voice.trim(), ...(value.rate !== undefined ? {rate: value.rate} : {}) };
  assertConsistent(kind, next, env);
  writeTTSSettings(next, env);
}

function resolveProfile(selected: SpeakProfileKind, file: TTSSettings, env: TTSEnv) {
  const profile = file.profiles?.[selected];
  const envVoice = env.QA_VOICE_TTS_VOICE !== undefined;
  const voice = envVoice ? env.QA_VOICE_TTS_VOICE || TTS_DEFAULTS.voice : profile?.voice ?? TTS_DEFAULTS.voice;
  const engine = envVoice || profile?.engine === undefined
    ? (hasClonedProfile(voice) ? "clone" : TTS_DEFAULTS.engine)
    : profile.engine;
  return {
    kind: selected,
    engine,
    voice,
    rate: env.QA_VOICE_TTS_RATE !== undefined ? env.QA_VOICE_TTS_RATE || TTS_DEFAULTS.rate : profile?.rate ?? TTS_DEFAULTS.rate,
    rateSource: env.QA_VOICE_TTS_RATE !== undefined ? "environment" : profile?.rate !== undefined ? "settings" : "default",
    engineSource: envVoice ? "environment" : profile?.engine !== undefined ? "settings" : "default",
  } as const;
}

/** Re-read on every call. Empty legacy env values lock the field but keep its historical fallback. */
export function resolveSpeakProfile(kind: SpeakProfileKind | "auto", text: string, env: TTSEnv = process.env) {
  const file = readTTSSettings(env);
  const selected = kind === "auto" ? (text.length > (file.short_limit_chars ?? 400) ? "long" : "short") : kind;
  return resolveProfile(selected, file, env);
}
