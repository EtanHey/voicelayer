import { cleanupTranscriptionText } from "./stt-cleanup";

export type STTCorrectorMode = "off" | "identity" | "rules";
export interface STTCorrectorEnv {
  [key: string]: string | undefined;
  QA_VOICE_CORRECTOR?: string;
}

export interface STTCorrectorResult {
  inputText: string;
  text: string;
  mode: STTCorrectorMode;
  changed: boolean;
  latencyMs: number;
}

export interface STTCorrectorOptions {
  mode?: STTCorrectorMode;
  env?: STTCorrectorEnv;
}

export function getSTTCorrectorMode(
  env: STTCorrectorEnv = process.env,
): STTCorrectorMode {
  const raw = env.QA_VOICE_CORRECTOR?.trim().toLowerCase();
  if (raw === "identity" || raw === "rules") return raw;
  return "off";
}

export function correctTranscriptionText(
  text: string,
  options: STTCorrectorOptions = {},
): STTCorrectorResult {
  const mode = options.mode ?? getSTTCorrectorMode(options.env);
  const start = performance.now();
  const corrected = mode === "rules" ? cleanupTranscriptionText(text) : text;
  const latencyMs = performance.now() - start;

  return {
    inputText: text,
    text: corrected,
    mode,
    changed: corrected !== text,
    latencyMs,
  };
}
