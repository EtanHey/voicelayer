/**
 * Silero VAD (Voice Activity Detection) module.
 *
 * Uses Silero VAD v5 ONNX model for real speech detection.
 * Replaces energy/amplitude-based silence detection with actual neural network
 * voice activity detection — handles background noise, typing, etc. much better.
 *
 * Model: silero_vad.onnx (~2.3MB, <1% CPU on M1)
 * Chunk size: 512 samples (32ms at 16kHz)
 *
 * AIDEV-NOTE: The ONNX model requires a 64-sample context window prepended to each
 * 512-sample chunk. The actual ONNX input is [1, 576] = 64 context + 512 audio.
 * Without context, the model returns ~0.001 for all inputs (looks like a bug but
 * is actually how Silero VAD v5 ONNX export works — confirmed by reading their
 * OnnxWrapper source in the silero-vad PyPI package).
 */

import { existsSync } from "fs";
import { join, dirname } from "path";

// AIDEV-NOTE: onnxruntime-node uses native C++ addon (N-API). Works with Bun 1.3+.
// If Bun drops support, switch to onnxruntime-web (WASM, same API).
const ort = require("onnxruntime-node");

/** VAD chunk size — 512 samples = 32ms at 16kHz. Silero VAD v5 requirement. */
export const VAD_CHUNK_SAMPLES = 512;
export const VAD_CHUNK_BYTES = VAD_CHUNK_SAMPLES * 2; // 16-bit = 2 bytes per sample

/**
 * Context size for Silero VAD ONNX model.
 * The model needs 64 samples of context from the end of the previous chunk
 * prepended to each 512-sample audio chunk, making the ONNX input 576 samples.
 */
const VAD_CONTEXT_SAMPLES = 64;

/** Speech probability threshold (0-1). Above = speech, below = silence. */
const SPEECH_THRESHOLD = 0.5;

/** Silence modes: how long VAD must report "no speech" before stopping. */
export type SilenceMode = "quick" | "standard" | "thoughtful";

export const SILENCE_MODE_SECONDS: Record<SilenceMode, number> = {
  quick: 0.5,
  standard: 1.5,
  thoughtful: 2.5,
};

/** Number of VAD chunks per second at 16kHz with 512-sample chunks. */
const CHUNKS_PER_SECOND = 16000 / VAD_CHUNK_SAMPLES; // ~31.25

/** Convert silence seconds to number of consecutive silent chunks needed. */
export function silenceChunksForMode(mode: SilenceMode): number {
  return Math.ceil(SILENCE_MODE_SECONDS[mode] * CHUNKS_PER_SECOND);
}

// --- Model paths ---

/** Find the Silero VAD model file. */
function findModelPath(): string {
  // 1. Same directory as this module's source (models/ in repo root)
  const repoModel = join(dirname(import.meta.dir), "models", "silero_vad.onnx");
  if (existsSync(repoModel)) return repoModel;

  // 2. Installed as npm package — model in package's models/ dir
  const pkgModel = join(import.meta.dir, "..", "models", "silero_vad.onnx");
  if (existsSync(pkgModel)) return pkgModel;

  // 3. User cache directory
  const cacheModel = join(
    process.env.HOME || "~",
    ".cache",
    "voicelayer",
    "silero_vad.onnx",
  );
  if (existsSync(cacheModel)) return cacheModel;

  throw new Error(
    "Silero VAD model not found. Expected at:\n" +
      `  ${repoModel}\n` +
      "Download: curl -L -o models/silero_vad.onnx https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx",
  );
}

// --- VAD Session ---

interface VADSession {
  session: InstanceType<typeof ort.InferenceSession>;
  state: InstanceType<typeof ort.Tensor>;
  sr: InstanceType<typeof ort.Tensor>;
  context: Float32Array;
}

let cachedSession: VADSession | null = null;

/** Initialize or return cached VAD session. */
async function getVADSession(): Promise<VADSession> {
  if (cachedSession) return cachedSession;

  const modelPath = findModelPath();
  const session = await ort.InferenceSession.create(modelPath);

  // Initial hidden state: zeros [2, 1, 128]
  const state = new ort.Tensor(
    "float32",
    new Float32Array(2 * 1 * 128),
    [2, 1, 128],
  );
  // Sample rate: 16kHz
  const sr = new ort.Tensor("int64", BigInt64Array.from([BigInt(16000)]), []);
  // Initial context: zeros (64 samples)
  const context = new Float32Array(VAD_CONTEXT_SAMPLES);

  cachedSession = { session, state, sr, context };
  console.error("[voicelayer] Silero VAD model loaded");
  return cachedSession;
}

/**
 * Process a single chunk of 16-bit PCM audio through Silero VAD.
 *
 * AIDEV-NOTE: The ONNX model requires context + audio = 576 samples per call.
 * Context is the last 64 samples from the previous padded input. Without this
 * context window, the model always returns ~0.001 regardless of input.
 *
 * @param pcmChunk - Exactly VAD_CHUNK_BYTES (1024) bytes of 16-bit signed PCM
 * @returns Speech probability (0.0 - 1.0). > SPEECH_THRESHOLD = speech detected.
 */
export async function processVADChunk(pcmChunk: Uint8Array): Promise<number> {
  const vad = await getVADSession();

  // Convert 16-bit signed PCM to float32 [-1, 1]
  const view = new DataView(
    pcmChunk.buffer,
    pcmChunk.byteOffset,
    pcmChunk.byteLength,
  );
  const audioFloats = new Float32Array(VAD_CHUNK_SAMPLES);
  for (let i = 0; i < VAD_CHUNK_SAMPLES; i++) {
    audioFloats[i] = view.getInt16(i * 2, true) / 32768.0;
  }

  // Prepend context (64 samples) to audio (512 samples) = 576 samples total
  const totalSamples = VAD_CONTEXT_SAMPLES + VAD_CHUNK_SAMPLES;
  const padded = new Float32Array(totalSamples);
  padded.set(vad.context, 0);
  padded.set(audioFloats, VAD_CONTEXT_SAMPLES);

  const input = new ort.Tensor("float32", padded, [1, totalSamples]);

  const result = await vad.session.run({
    input,
    state: vad.state,
    sr: vad.sr,
  });

  // Update state for next call (RNN hidden state carries forward)
  vad.state = result.stateN;

  // Save last 64 samples of padded input as context for next chunk
  vad.context = padded.slice(padded.length - VAD_CONTEXT_SAMPLES);

  return result.output.data[0] as number;
}

/**
 * Check if a VAD probability indicates speech.
 */
export function isSpeech(probability: number): boolean {
  return probability >= SPEECH_THRESHOLD;
}

/**
 * Reset VAD state (e.g., between recordings).
 * Clears the RNN hidden state and context so next recording starts fresh.
 */
export async function resetVAD(): Promise<void> {
  if (cachedSession) {
    cachedSession.state = new ort.Tensor(
      "float32",
      new Float32Array(2 * 1 * 128),
      [2, 1, 128],
    );
    cachedSession.context = new Float32Array(VAD_CONTEXT_SAMPLES);
  }
}
