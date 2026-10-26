import { runSpeechGeneration } from "./generation-process";
import { throwIfAbortedSafe } from "../abort";
/**
 * F5-TTS MLX bridge — zero-shot voice cloning on Apple Silicon.
 *
 * Uses f5-tts-mlx (400MB) for local voice cloning from 5-15s reference clips.
 * Runs as a subprocess (no daemon needed) via the permanent venv at ~/.voicelayer/venv/.
 *
 * This is Tier 1b — used when the voice profile specifies engine: "f5-tts-mlx"
 * or when the Qwen3-TTS daemon is unavailable.
 */

import { existsSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { truncateAtWordBoundary } from "./truncate";

const VENV_PYTHON = join(
  process.env.HOME || "~",
  ".voicelayer",
  "venv",
  "bin",
  "python3",
);

/**
 * Check if F5-TTS MLX is available (venv exists with f5-tts-mlx installed).
 */
export function isF5TTSAvailable(): boolean {
  return existsSync(VENV_PYTHON);
}

/**
 * Synthesize speech using F5-TTS MLX zero-shot voice cloning.
 *
 * @param text - Text to speak
 * @param referenceAudio - Path to reference WAV file (5-15s, 24kHz mono)
 * @param referenceText - Transcript of the reference audio
 * @param options.steps - Inference steps (default: 16, higher = better quality)
 * @param options.speed - Speed multiplier (default: 0.9)
 * @returns Path to generated WAV file, or null on failure
 */
export async function synthesizeF5TTS(
  text: string,
  referenceAudio: string,
  referenceText: string,
  options?: { steps?: number; speed?: number; signal?: AbortSignal },
): Promise<string | null> {
  if (!isF5TTSAvailable()) {
    console.error(
      "[voicelayer] F5-TTS not available — venv missing at ~/.voicelayer/venv/",
    );
    return null;
  }

  // Expand ~ in paths
  const refPath = referenceAudio.replace(/^~/, process.env.HOME || "~");
  if (!existsSync(refPath)) {
    console.error(`[voicelayer] F5-TTS reference audio not found: ${refPath}`);
    return null;
  }

  const steps = options?.steps ?? 16;
  const speed = options?.speed ?? 0.9;
  const outputPath = join(
    tmpdir(),
    `voicelayer-f5tts-${process.pid}-${Date.now()}.wav`,
  );

  // Truncate at word boundary to avoid OOM and garbled speech
  const truncatedText = truncateAtWordBoundary(text, 300);

  // Build inline Python script for F5-TTS generation
  const script = `
import sys
sys.path.insert(0, "${join(process.env.HOME || "~", ".voicelayer", "venv", "lib")}")
from f5_tts_mlx.generate import generate
generate(
    generation_text=${JSON.stringify(truncatedText)},
    ref_audio_path=${JSON.stringify(refPath)},
    ref_audio_text=${JSON.stringify(referenceText)},
    output_path=${JSON.stringify(outputPath)},
    steps=${steps},
    speed=${speed},
)
print("OK")
`;

  try {
    const exitCode = await runSpeechGeneration([VENV_PYTHON, "-c", script], options?.signal, 60000);
    if (exitCode !== 0) return null;

    if (!existsSync(outputPath)) {
      console.error("[voicelayer] F5-TTS produced no output file");
      return null;
    }

    return outputPath;
  } catch (err) {
    if (options?.signal?.aborted) {
      try { unlinkSync(outputPath); } catch {}
      throwIfAbortedSafe(options?.signal);
    }
    console.error(`[voicelayer] F5-TTS error: ${err}`);
    return null;
  }
}
