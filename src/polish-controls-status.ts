import { getSTTPolishMode } from "./stt-polish";
import { outroGateEnabled } from "./stt-outro-gate";
import { isSmartWavChunkingEnabled } from "./stt";
import { smartBoundariesEnabled } from "./stt-sentence-boundaries";

type Setting<T> = {
  source: "default" | "environment";
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
  key: string,
  effective: T,
): Setting<T> {
  const raw = env[key];
  return {
    source: raw === undefined ? "default" : "environment",
    raw: raw ?? null,
    effective,
  };
}

/** Read only: the STT pipeline still reads process.env during transcription. */
export function readPolishControlsStatus(
  env: Record<string, string | undefined> = process.env,
): PolishControlsStatus {
  return {
    model_polish: setting(env, "QA_VOICE_STT_POLISH", getSTTPolishMode(env)),
    outro_gate: setting(env, "VOICELAYER_STT_OUTRO_GATE", outroGateEnabled(env)),
    smart_chunks: setting(env, "VOICELAYER_STT_SMART_CHUNKS", isSmartWavChunkingEnabled(env)),
    smart_boundaries: setting(env, "VOICELAYER_STT_SMART_BOUNDARIES", smartBoundariesEnabled(env)),
  };
}
