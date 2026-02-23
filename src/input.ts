/**
 * Input module — mic recording + STT transcription.
 *
 * Records audio via sox `rec` command (16kHz 16-bit mono PCM),
 * saves to WAV, then transcribes with the selected STT backend
 * (whisper.cpp local or Wispr Flow cloud).
 *
 * Voice activity detection uses Silero VAD (neural network) — NOT energy/amplitude.
 *
 * Stops recording on:
 *   1. User stop signal (touch /tmp/voicelayer-stop) — PRIMARY
 *   2. Silero VAD silence detection (configurable mode) — FALLBACK
 *   3. Timeout — SAFETY NET
 *
 * Prerequisites:
 *   brew install sox
 *   brew install whisper-cpp (or set QA_VOICE_WISPR_KEY for cloud fallback)
 */

import { existsSync, unlinkSync, writeFileSync } from "fs";
import { hasStopSignal, clearStopSignal } from "./session-booking";
import { getBackend } from "./stt";
import { recordingFilePath, MIC_DISABLED_FILE } from "./paths";
import {
  processVADChunk,
  isSpeech,
  resetVAD,
  silenceChunksForMode,
  VAD_CHUNK_BYTES,
  VAD_CHUNK_SAMPLES,
  type SilenceMode,
} from "./vad";

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;

// Re-export calculateRMS from audio-utils for backward compat (used by stt.ts Wispr backend)
export { calculateRMS } from "./audio-utils";

/**
 * Create a WAV file buffer from raw PCM data.
 * Writes standard 44-byte RIFF/WAV header + PCM payload.
 */
export function createWavBuffer(pcmData: Uint8Array): Uint8Array {
  const byteRate = SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE / 8;
  const blockAlign = CHANNELS * BITS_PER_SAMPLE / 8;
  const dataSize = pcmData.byteLength;

  const header = new ArrayBuffer(44);
  const view = new DataView(header);

  // RIFF header
  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeString(view, 8, "WAVE");

  // fmt sub-chunk
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true);              // sub-chunk size (PCM = 16)
  view.setUint16(20, 1, true);               // audio format (1 = PCM)
  view.setUint16(22, CHANNELS, true);        // channels
  view.setUint32(24, SAMPLE_RATE, true);     // sample rate
  view.setUint32(28, byteRate, true);        // byte rate
  view.setUint16(32, blockAlign, true);      // block align
  view.setUint16(34, BITS_PER_SAMPLE, true); // bits per sample

  // data sub-chunk
  writeString(view, 36, "data");
  view.setUint32(40, dataSize, true);

  const wav = new Uint8Array(44 + dataSize);
  wav.set(new Uint8Array(header));
  wav.set(pcmData, 44);
  return wav;
}

function writeString(view: DataView, offset: number, str: string): void {
  for (let i = 0; i < str.length; i++) {
    view.setUint8(offset + i, str.charCodeAt(i));
  }
}

/** Check if mic recording is disabled via flag file. */
function isMicDisabled(): boolean {
  return existsSync(MIC_DISABLED_FILE);
}

/**
 * Record audio from mic to a PCM buffer.
 * Returns the raw PCM data as a Uint8Array.
 * Handles stop signal, Silero VAD silence detection, and timeout.
 */
export async function recordToBuffer(
  timeoutMs: number,
  silenceMode: SilenceMode = "standard",
): Promise<Uint8Array | null> {
  // Check mic disabled flag
  if (isMicDisabled()) {
    console.error("[voicelayer] Mic disabled via flag file — skipping recording");
    return null;
  }

  const silenceChunksNeeded = silenceChunksForMode(silenceMode);

  // Check that rec (sox) is available
  const which = Bun.spawnSync(["which", "rec"]);
  if (which.exitCode !== 0) {
    throw new Error(
      "sox not installed. Install:\n" +
      "  macOS: brew install sox\n" +
      "  Linux: apt install sox / dnf install sox\n" +
      "Also grant microphone access to your terminal app (macOS: System Settings > Privacy > Microphone)."
    );
  }

  // Reset VAD state for fresh recording
  await resetVAD();

  // Clear any leftover stop signal from previous recording
  clearStopSignal();

  return new Promise<Uint8Array | null>((resolve, reject) => {
    let consecutiveSilentChunks = 0;
    let hasSpeech = false;
    let readBuffer: Uint8Array[] = [];
    let readBufferLen = 0;
    const pcmChunks: Uint8Array[] = [];
    let totalPcmBytes = 0;
    let resolved = false;
    let recorder: ReturnType<typeof Bun.spawn> | null = null;

    const finish = (error?: Error) => {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);

      // Kill recorder
      if (recorder) {
        try { recorder.kill(); } catch {}
        recorder = null;
      }

      if (error) {
        reject(error);
      } else if (totalPcmBytes === 0 || !hasSpeech) {
        resolve(null); // No speech detected
      } else {
        // Concatenate all PCM chunks
        const result = new Uint8Array(totalPcmBytes);
        let offset = 0;
        for (const chunk of pcmChunks) {
          result.set(chunk, offset);
          offset += chunk.byteLength;
        }
        resolve(result);
      }
    };

    // Timeout handler
    const timer = setTimeout(() => finish(), timeoutMs);

    try {
      // Start mic recording via sox — raw 16kHz 16-bit mono PCM to stdout
      recorder = Bun.spawn(
        [
          "rec",
          "-r", String(SAMPLE_RATE),
          "-c", "1",
          "-b", "16",
          "-e", "signed",
          "-t", "raw",
          "-q",  // quiet (no progress)
          "-",   // output to stdout
        ],
        { stdout: "pipe", stderr: "ignore" },
      );

      if (!recorder.stdout) {
        finish(new Error("rec: stdout not available"));
        return;
      }

      console.error("[voicelayer] Listening... speak now (Silero VAD active)");

      const reader = (recorder.stdout as ReadableStream<Uint8Array>).getReader();

      const processAudio = async () => {
        while (!resolved) {
          const { value, done } = await reader.read();
          if (done || resolved) break;
          if (!value || value.length === 0) continue;

          // Append incoming bytes to read buffer
          readBuffer.push(value);
          readBufferLen += value.length;

          // Process VAD-sized chunks (512 samples = 1024 bytes = 32ms)
          while (readBufferLen >= VAD_CHUNK_BYTES && !resolved) {
            // Flatten only when needed
            const flat = new Uint8Array(readBufferLen);
            let off = 0;
            for (const buf of readBuffer) {
              flat.set(buf, off);
              off += buf.length;
            }
            const chunk = flat.slice(0, VAD_CHUNK_BYTES);
            const remainder = flat.slice(VAD_CHUNK_BYTES);
            readBuffer = remainder.length > 0 ? [remainder] : [];
            readBufferLen = remainder.length;

            // Run Silero VAD on this chunk
            const speechProb = await processVADChunk(chunk);
            const speechDetected = isSpeech(speechProb);

            if (speechDetected) {
              hasSpeech = true;
              consecutiveSilentChunks = 0;
            } else {
              consecutiveSilentChunks++;
            }

            // Always accumulate audio data
            pcmChunks.push(chunk);
            totalPcmBytes += chunk.byteLength;

            // Check for user-initiated stop signal
            if (hasSpeech && hasStopSignal()) {
              clearStopSignal();
              console.error("[voicelayer] Stop signal received — ending recording");
              finish();
              return;
            }

            // VAD-based silence stop (only after speech was detected)
            if (hasSpeech && consecutiveSilentChunks >= silenceChunksNeeded) {
              console.error(`[voicelayer] Silence detected (${silenceMode} mode) — ending recording`);
              finish();
              return;
            }
          }
        }
      };

      processAudio().catch((err) => {
        finish(err instanceof Error ? err : new Error(String(err)));
      });
    } catch (err) {
      finish(err instanceof Error ? err : new Error(String(err)));
    }
  });
}

/**
 * Wait for user voice input via mic recording + STT transcription.
 * Returns the transcribed text, or null on timeout / no speech.
 *
 * @param timeoutMs - Max wait time in milliseconds
 * @param silenceMode - VAD silence mode: quick (0.5s), standard (1.5s), thoughtful (2.5s)
 */
export async function waitForInput(
  timeoutMs: number,
  silenceMode: SilenceMode = "standard",
): Promise<string | null> {
  // Record audio to buffer
  const pcmData = await recordToBuffer(timeoutMs, silenceMode);
  if (!pcmData) return null;

  // Save as WAV to temp file
  const wavPath = recordingFilePath(process.pid, Date.now());
  try {
    const wavData = createWavBuffer(pcmData);
    writeFileSync(wavPath, wavData);

    // Transcribe with selected backend
    const backend = await getBackend();
    console.error(`[voicelayer] Transcribing with ${backend.name}...`);
    const result = await backend.transcribe(wavPath);
    console.error(`[voicelayer] Transcription (${result.durationMs}ms): ${result.text}`);

    return result.text || null;
  } finally {
    // Clean up temp file
    try {
      if (existsSync(wavPath)) unlinkSync(wavPath);
    } catch {}
  }
}

/**
 * Clear input state — no-op in current architecture.
 * Kept for API compatibility with mcp-server.ts.
 */
export function clearInput(): void {
  // No persistent state to clear — recordings are ephemeral
}
