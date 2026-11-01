/** Private diagnostic alternatives for a full-audio Whisper retry. */
import { mkdirSync, writeFileSync } from "fs";
import { join } from "path";
import { randomUUID } from "crypto";
import { getStateDir } from "./paths";
import type { STTOutcome } from "./soundlayer/contracts";

export interface ParakeetFallbackAttempt {
  audioPath: string;
  inputSha256?: string | null;
  reason: string;
  parakeet: unknown;
  whisper: { text: string; backend: string; durationMs: number } | null;
  errorType: string | null;
  deliveryText?: string;
  outcome?: STTOutcome;
  parakeetErrorStatus?: string;
  parakeetCleanupFailure?: { name: string; message: string };
  speechEvidence?: import("./parakeet-vad").ParakeetSpeechEvidence;
  languageEvidence?: import("./parakeet-lid").ParakeetLanguageEvidence;
  whisperStatus?: "NOT_RUN";
  whisperErrorAttempt?: unknown;
  stage?: "native-or-input-boundary" | "fallback-terminal" | "native-terminal" | "vad-boundary";
  previousAttemptPath?: string;
  submittedPath?: string;
}

/** Missing/failed provider responses stay null, never manufactured EMPTY text. */
export function retainParakeetFallback(attempt: ParakeetFallbackAttempt): string {
  const root = join(getStateDir(), "parakeet-fallbacks");
  mkdirSync(root, { recursive: true, mode: 0o700 });
  const path = join(root, `${Date.now()}-${randomUUID()}.json`);
  writeFileSync(path, JSON.stringify({ at: new Date().toISOString(), ...attempt }) + "\n", { flag: "wx", mode: 0o600 });
  return path;
}
