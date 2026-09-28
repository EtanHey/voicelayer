import { getSTTPolishMode } from "./stt-polish";
import { outroGateEnabled } from "./stt-outro-gate";
import { isSmartWavChunkingEnabled } from "./stt";
import { smartBoundariesEnabled } from "./stt-sentence-boundaries";
import {
  PROCESSING_ENV_VARS,
  processingEnv,
  readProcessingSettings,
  type ProcessingKey,
} from "./processing-settings";

type Setting<T> = {
  source: "default" | "settings" | "environment";
  raw: string | null;
  effective: T;
};

export type PolishControlsStatus = {
  model_polish: Setting<"off" | "shadow" | "on">;
  outro_gate: Setting<boolean>;
  smart_chunks: Setting<boolean>;
  smart_boundaries: Setting<boolean>;
};

function setting<T>(
  env: Record<string, string | undefined>,
  inFile: boolean,
  key: ProcessingKey,
  effective: T,
): Setting<T> {
  const raw = env[PROCESSING_ENV_VARS[key]];
  return {
    source: raw !== undefined ? "environment" : inFile ? "settings" : "default",
    raw: raw ?? null,
    effective,
  };
}

/** What the pipeline will use: env (when set) > processing-settings.json > default. */
export function readPolishControlsStatus(
  env: Record<string, string | undefined> = process.env,
): PolishControlsStatus {
  const file = readProcessingSettings(env);
  const effective = processingEnv(env);
  return {
    model_polish: setting(env, "model_polish" in file, "model_polish", getSTTPolishMode(effective)),
    outro_gate: setting(env, "outro_gate" in file, "outro_gate", outroGateEnabled(effective)),
    smart_chunks: setting(env, "smart_chunks" in file, "smart_chunks", isSmartWavChunkingEnabled(effective)),
    smart_boundaries: setting(env, "smart_boundaries" in file, "smart_boundaries", smartBoundariesEnabled(effective)),
  };
}
