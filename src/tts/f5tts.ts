/**
 * F5-TTS MLX bridge — zero-shot voice cloning on Apple Silicon.
 *
 * Uses f5-tts-mlx (400MB) for local voice cloning from 5-15s reference clips.
 * Runs as a subprocess (no daemon needed) via the permanent venv at ~/.voicelayer/venv/.
 *
 * This is Tier 1b — used when the voice profile specifies engine: "f5-tts-mlx"
 * or when the Qwen3-TTS daemon is unavailable.
 */

import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

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
  options?: { steps?: number; speed?: number },
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

  // Truncate text to avoid OOM (F5-TTS struggles with very long text)
  const truncatedText = text.length > 300 ? text.slice(0, 300) : text;

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
    const proc = Bun.spawn([VENV_PYTHON, "-c", script], {
      stdout: "pipe",
      stderr: "pipe",
      timeout: 60_000, // 60s timeout
    });

    const exitCode = await proc.exited;
    if (exitCode !== 0) {
      const stderr = await new Response(proc.stderr).text();
      console.error(
        `[voicelayer] F5-TTS failed (exit ${exitCode}): ${stderr.slice(-200)}`,
      );
      return null;
    }

    if (!existsSync(outputPath)) {
      console.error("[voicelayer] F5-TTS produced no output file");
      return null;
    }

    return outputPath;
  } catch (err) {
    console.error(`[voicelayer] F5-TTS error: ${err}`);
    return null;
  }
}
