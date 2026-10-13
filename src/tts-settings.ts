import { readFileSync, renameSync, rmSync } from "fs";
import { join } from "path";
import { hasClonedProfile } from "./tts/qwen3";
import { STATE_DIR, safeWriteFileSync } from "./paths";

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
  if (key.endsWith(".voice")) return "QA_VOICE_TTS_VOICE";
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
    if (validTTSSetting("short_limit_chars", raw.short_limit_chars)) settings.short_limit_chars = raw.short_limit_chars;
    return settings;
  } catch { return {}; }
}
export function setTTSSetting(key: TTSSettingKey, value: string | number, env: TTSEnv = process.env): void {
  if (!validTTSSetting(key, value)) throw new Error("Invalid TTS setting");
  const variable = ttsSettingEnvVar(key);
  if (variable && env[variable] !== undefined) throw new Error(`Set by ${variable}`);
  const next = readTTSSettings(env);
  if (key === "short_limit_chars") next.short_limit_chars = value as number;
  else {
    const [kind, field] = key.split(".") as [SpeakProfileKind, keyof TTSProfile];
    next.profiles ??= {};
    next.profiles[kind] ??= {};
    Object.assign(next.profiles[kind]!, { [field]: value });
  }
  const path = ttsSettingsPath(env), tmp = `${path}.${process.pid}.tmp`;
  safeWriteFileSync(tmp, JSON.stringify({ version: 1, ...next, updated_at: new Date().toISOString() }, null, 2) + "\n");
  try { renameSync(tmp, path); } catch (error) { rmSync(tmp, { force: true }); throw error; }
}

/** Re-read on every call. Empty legacy env values lock the field but keep its historical fallback. */
export function resolveSpeakProfile(kind: SpeakProfileKind | "auto", text: string, env: TTSEnv = process.env) {
  const file = readTTSSettings(env);
  const selected = kind === "auto" ? (text.length > (file.short_limit_chars ?? 400) ? "long" : "short") : kind;
  const profile = file.profiles?.[selected];
  const voice = env.QA_VOICE_TTS_VOICE !== undefined ? env.QA_VOICE_TTS_VOICE || TTS_DEFAULTS.voice : profile?.voice ?? TTS_DEFAULTS.voice;
  return {
    kind: selected,
    engine: profile?.engine ?? (hasClonedProfile(voice) ? "clone" : TTS_DEFAULTS.engine),
    voice,
    rate: env.QA_VOICE_TTS_RATE !== undefined ? env.QA_VOICE_TTS_RATE || TTS_DEFAULTS.rate : profile?.rate ?? TTS_DEFAULTS.rate,
    rateSource: env.QA_VOICE_TTS_RATE !== undefined ? "environment" : profile?.rate !== undefined ? "settings" : "default",
    // An untouched engine retains legacy voice-based clone detection (including env overrides).
    engineSource: profile?.engine !== undefined ? "settings" : "default",
  } as const;
}
