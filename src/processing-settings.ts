import { readFileSync } from "fs";
import { join } from "path";
import { STATE_DIR, safeWriteFileSync } from "./paths";

/**
 * Settings → Models → Processing toggles, persisted for the daemon (P1).
 *
 * AIDEV-NOTE: precedence is env (when DEFINED, even empty) > this file >
 * built-in default. The pipeline's parsers stay pure and env-shaped;
 * `processingEnv()` overlays the file under the environment, so every read
 * site must pass `processingEnv()` instead of `process.env` (a source-scan
 * test enforces it). Only keys the user set are written, so an untouched
 * toggle follows future default changes.
 */
export type ProcessingKey =
  | "model_polish"
  | "outro_gate"
  | "smart_chunks"
  | "smart_boundaries";

export const PROCESSING_KEYS: readonly ProcessingKey[] = [
  "model_polish",
  "outro_gate",
  "smart_chunks",
  "smart_boundaries",
];

export const PROCESSING_ENV_VARS: Record<ProcessingKey, string> = {
  model_polish: "QA_VOICE_STT_POLISH",
  outro_gate: "VOICELAYER_STT_OUTRO_GATE",
  smart_chunks: "VOICELAYER_STT_SMART_CHUNKS",
  smart_boundaries: "VOICELAYER_STT_SMART_BOUNDARIES",
};

type Env = Record<string, string | undefined>;
export type ProcessingSettings = Partial<Record<ProcessingKey, boolean>>;

export function processingSettingsPath(env: Env = process.env): string {
  return env.VOICELAYER_PROCESSING_SETTINGS_PATH?.trim() ||
    join(STATE_DIR, "processing-settings.json");
}

function readFile(env: Env): Record<string, unknown> {
  try {
    const parsed: unknown = JSON.parse(readFileSync(processingSettingsPath(env), "utf8"));
    return parsed && typeof parsed === "object" ? (parsed as Record<string, unknown>) : {};
  } catch {
    return {};
  }
}

/** The toggles the user set. A value of the wrong type is ignored (that key keeps its default). */
export function readProcessingSettings(env: Env = process.env): ProcessingSettings {
  const raw = readFile(env);
  const settings: ProcessingSettings = {};
  for (const key of PROCESSING_KEYS) {
    const value = raw[key];
    if (key === "model_polish") {
      if (value === "on" || value === "off") settings[key] = value === "on";
    } else if (typeof value === "boolean") {
      settings[key] = value;
    }
  }
  return settings;
}

export function setProcessingSetting(
  key: ProcessingKey,
  value: boolean,
  env: Env = process.env,
): void {
  const raw = readFile(env);
  const next: Record<string, unknown> = { version: 1 };
  for (const known of PROCESSING_KEYS) {
    if (known in raw) next[known] = raw[known];
  }
  next[key] = key === "model_polish" ? (value ? "on" : "off") : value;
  next.updated_at = new Date().toISOString();
  safeWriteFileSync(processingSettingsPath(env), JSON.stringify(next, null, 2) + "\n");
}

/** `base`, with each file setting filled in as the env string its parser reads, where `base` leaves it unset. */
export function processingEnv(base: Env = process.env): Env {
  const settings = readProcessingSettings(base);
  const overlay: Env = {};
  for (const key of PROCESSING_KEYS) {
    const value = settings[key];
    if (value === undefined || base[PROCESSING_ENV_VARS[key]] !== undefined) continue;
    overlay[PROCESSING_ENV_VARS[key]] = key === "model_polish"
      ? (value ? "on" : "off")
      : (value ? "1" : "0");
  }
  return { ...base, ...overlay };
}
