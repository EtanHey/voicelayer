import { readFileSync } from "fs";
import { join } from "path";
import { STATE_DIR, safeWriteFileSync } from "./paths";

export type WhisperPerformanceEffort = "fast" | "balanced" | "accurate";

const CONFIG_OVERRIDE_ENV = "QA_VOICE_WHISPER_PERFORMANCE_PATH";
const DEFAULT_EFFORT: WhisperPerformanceEffort = "accurate";

let restartWhisperServer: () => void = () => {};

export function whisperPerformanceConfigPath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  const override = env[CONFIG_OVERRIDE_ENV]?.trim();
  return override || join(STATE_DIR, "whisper-performance.json");
}

export function parseWhisperPerformanceEffort(
  value: unknown,
): WhisperPerformanceEffort | null {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (
    normalized === "fast" ||
    normalized === "balanced" ||
    normalized === "accurate"
  ) {
    return normalized;
  }
  return null;
}

export function whisperPerformanceArgsForEffort(
  effort: WhisperPerformanceEffort,
): string[] {
  switch (effort) {
    case "fast":
      return ["-bo", "1", "-bs", "1"];
    case "balanced":
      return ["-bo", "3", "-bs", "3"];
    case "accurate":
      return ["-bo", "5", "-bs", "5"];
  }
}

export function getWhisperPerformanceEffort(
  env: NodeJS.ProcessEnv = process.env,
): WhisperPerformanceEffort {
  const envEffort = parseWhisperPerformanceEffort(
    env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT,
  );
  if (envEffort) return envEffort;

  try {
    const raw = readFileSync(whisperPerformanceConfigPath(env), "utf8");
    const parsed = JSON.parse(raw) as { effort?: unknown };
    return parseWhisperPerformanceEffort(parsed.effort) ?? DEFAULT_EFFORT;
  } catch {
    return DEFAULT_EFFORT;
  }
}

export function setWhisperPerformanceEffort(
  effort: WhisperPerformanceEffort,
  env: NodeJS.ProcessEnv = process.env,
): void {
  safeWriteFileSync(
    whisperPerformanceConfigPath(env),
    JSON.stringify(
      {
        effort,
        updated_at: new Date().toISOString(),
      },
      null,
      2,
    ) + "\n",
  );
}

export function configureWhisperPerformanceRestart(callback: () => void): void {
  restartWhisperServer = callback;
}

export function restartWhisperServerForPerformanceChange(): void {
  restartWhisperServer();
}
