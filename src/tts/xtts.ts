/**
 * XTTS-v2 inference bridge — fine-tuned voice synthesis with learned cadence.
 *
 * Uses fine-tuned XTTS-v2 checkpoints for high-quality voice cloning that captures
 * not just timbre but pacing, emphasis, and speaking style.
 *
 * Runs as a subprocess via the XTTS finetune venv (separate from main venv due to
 * heavy PyTorch + Coqui TTS dependencies).
 *
 * This is Tier 0 — the highest quality engine, used when a fine-tuned model exists.
 * Falls through to F5-TTS (zero-shot) or edge-tts if unavailable.
 */

import { existsSync, readdirSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";

const VOICES_DIR = join(process.env.HOME || "~", ".voicelayer", "voices");

// XTTS venv is separate from the main VoiceLayer venv due to heavy deps
const XTTS_VENV_PYTHON = join("/tmp", "xtts-finetune-env", "bin", "python3");

/** Find the best XTTS checkpoint for a voice. Returns paths or null if unavailable. */
export function findXTTSCheckpoint(voiceName: string): {
  checkpointPath: string;
  configPath: string;
  vocabPath: string;
  trainingDir: string;
} | null {
  const ftDir = join(
    VOICES_DIR,
    voiceName,
    "fine-tuned-model",
    "run",
    "training",
  );
  if (!existsSync(ftDir)) return null;

  // Find the training run directory (GPT_XTTS_*/)
  let runDir: string | null = null;
  try {
    const entries = readdirSync(ftDir);
    const gptDirs = entries.filter((e) => e.startsWith("GPT_XTTS_"));
    if (gptDirs.length === 0) return null;
    // Use the most recent run (sorted alphabetically — timestamp in name)
    runDir = join(ftDir, gptDirs.sort().pop()!);
  } catch {
    return null;
  }

  const checkpointPath = join(runDir, "best_model.pth");
  const configPath = join(runDir, "config.json");

  // Original model files (vocab, dvae, mel_stats) are in a subdirectory
  const origDir = join(ftDir, "XTTS_v2.0_original_model_files");
  const vocabPath = join(origDir, "vocab.json");

  if (
    !existsSync(checkpointPath) ||
    !existsSync(configPath) ||
    !existsSync(vocabPath)
  ) {
    return null;
  }

  return { checkpointPath, configPath, vocabPath, trainingDir: runDir };
}

/**
 * Check if XTTS-v2 inference is available for a voice.
 *
 * Requires:
 *   1. XTTS venv with TTS library installed
 *   2. Fine-tuned model checkpoint exists
 */
export function isXTTSAvailable(voiceName: string): boolean {
  if (!existsSync(XTTS_VENV_PYTHON)) return false;
  return findXTTSCheckpoint(voiceName) !== null;
}

/**
 * Synthesize speech using XTTS-v2 fine-tuned model.
 *
 * @param text - Text to speak
 * @param voiceName - Voice name (must have fine-tuned model)
 * @param referenceAudio - Path to reference WAV for speaker conditioning
 * @returns Path to generated WAV file, or null on failure
 */
export async function synthesizeXTTS(
  text: string,
  voiceName: string,
  referenceAudio: string,
): Promise<string | null> {
  const checkpoint = findXTTSCheckpoint(voiceName);
  if (!checkpoint) {
    console.error(`[voicelayer] XTTS checkpoint not found for "${voiceName}"`);
    return null;
  }

  if (!existsSync(XTTS_VENV_PYTHON)) {
    console.error(
      "[voicelayer] XTTS venv not found at /tmp/xtts-finetune-env/",
    );
    return null;
  }

  const refPath = referenceAudio.replace(/^~/, process.env.HOME || "~");
  if (!existsSync(refPath)) {
    console.error(`[voicelayer] XTTS reference audio not found: ${refPath}`);
    return null;
  }

  const outputPath = join(
    tmpdir(),
    `voicelayer-xtts-${process.pid}-${Date.now()}.wav`,
  );

  // Truncate text to avoid issues (XTTS has a 250 char limit for best quality)
  const truncatedText = text.length > 240 ? text.slice(0, 240) : text;

  // Build inline Python script for XTTS inference
  const script = `
import torch
import torchaudio
from TTS.tts.configs.xtts_config import XttsConfig
from TTS.tts.models.xtts import Xtts

config = XttsConfig()
config.load_json(${JSON.stringify(checkpoint.configPath)})

model = Xtts.init_from_config(config)
model.load_checkpoint(
    config,
    checkpoint_path=${JSON.stringify(checkpoint.checkpointPath)},
    vocab_path=${JSON.stringify(checkpoint.vocabPath)},
    use_deepspeed=False,
)
model.eval()

gpt_cond_latent, speaker_embedding = model.get_conditioning_latents(
    audio_path=[${JSON.stringify(refPath)}],
)

out = model.inference(
    text=${JSON.stringify(truncatedText)},
    language="en",
    gpt_cond_latent=gpt_cond_latent,
    speaker_embedding=speaker_embedding,
    temperature=0.65,
    repetition_penalty=5.0,
    top_k=50,
    top_p=0.85,
)

wav = torch.tensor(out["wav"]).unsqueeze(0)
torchaudio.save(${JSON.stringify(outputPath)}, wav, 24000)
print("OK")
`;

  try {
    const proc = Bun.spawn([XTTS_VENV_PYTHON, "-c", script], {
      stdout: "pipe",
      stderr: "pipe",
      timeout: 120_000, // 2 min timeout (XTTS on CPU is slow)
    });

    const exitCode = await proc.exited;
    if (exitCode !== 0) {
      const stderr = await new Response(proc.stderr).text();
      console.error(
        `[voicelayer] XTTS inference failed (exit ${exitCode}): ${stderr.slice(-300)}`,
      );
      return null;
    }

    if (!existsSync(outputPath)) {
      console.error("[voicelayer] XTTS produced no output file");
      return null;
    }

    return outputPath;
  } catch (err) {
    console.error(`[voicelayer] XTTS error: ${err}`);
    return null;
  }
}
