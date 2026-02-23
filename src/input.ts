/**
 * Input module — mic recording + STT transcription.
 *
 * Records audio via sox `rec` command (16kHz 16-bit mono PCM),
 * saves to WAV, then transcribes with the selected STT backend
 * (whisper.cpp local or Wispr Flow cloud).
 *
 * Two recording modes:
 *   - VAD mode (default): Silero VAD neural network detects speech/silence
 *   - Push-to-talk (PTT): User explicitly controls start/stop via stop signal
 *
 * AIDEV-NOTE: Energy-based VAD (amplitude threshold) removed in Phase 2.
 * False positives in noisy environments. Use Silero VAD or PTT instead.
 * calculateRMS() in audio-utils.ts is retained only for Wispr Flow volume data.
 *
 * Stops recording on:
 *   1. User stop signal (touch /tmp/voicelayer-stop) — PRIMARY
 *   2. Silero VAD silence detection (configurable mode) — only in VAD mode
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

/**
 * Pre-speech timeout: if no speech is detected within this many seconds,
 * stop recording early and return null. Prevents long silent waits.
 * Only applies to VAD mode (not PTT).
 */
const PRE_SPEECH_TIMEOUT_SECONDS = 15;

// Re-export calculateRMS from audio-utils for backward compat (used by stt.ts Wispr Flow volume data only)
export { calculateRMS } from "./audio-utils";

/**
 * Create a WAV file buffer from raw PCM data.
 * Writes standard 44-byte RIFF/WAV header + PCM payload.
 */
export function createWavBuffer(pcmData: Uint8Array): Uint8Array {
  const byteRate = (SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE) / 8;
  const blockAlign = (CHANNELS * BITS_PER_SAMPLE) / 8;
  const dataSize = pcmData.byteLength;

  const header = new ArrayBuffer(44);
  const view = new DataView(header);

  // RIFF header
  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeString(view, 8, "WAVE");

  // fmt sub-chunk
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true); // sub-chunk size (PCM = 16)
  view.setUint16(20, 1, true); // audio format (1 = PCM)
  view.setUint16(22, CHANNELS, true); // channels
  view.setUint32(24, SAMPLE_RATE, true); // sample rate
  view.setUint32(28, byteRate, true); // byte rate
  view.setUint16(32, blockAlign, true); // block align
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
 *
 * Two modes:
 * - VAD mode (default): Silero VAD detects speech/silence, auto-stops on silence
 * - PTT mode (pressToTalk=true): Records until stop signal or timeout, no VAD
 *
 * @param timeoutMs - Maximum recording time in milliseconds
 * @param silenceMode - VAD silence threshold (ignored in PTT mode)
 * @param pressToTalk - If true, skip VAD — only stop on user signal or timeout
 */
export async function recordToBuffer(
  timeoutMs: number,
  silenceMode: SilenceMode = "standard",
  pressToTalk: boolean = false,
): Promise<Uint8Array | null> {
  // Check mic disabled flag
  if (isMicDisabled()) {
    console.error(
      "[voicelayer] Mic disabled via flag file — skipping recording",
    );
    return null;
  }

  const silenceChunksNeeded = pressToTalk
    ? Infinity
    : silenceChunksForMode(silenceMode);

  // Pre-speech timeout: max chunks before giving up if no speech detected
  const preSpeechChunks = pressToTalk
    ? Infinity
    : Math.ceil(PRE_SPEECH_TIMEOUT_SECONDS * (SAMPLE_RATE / VAD_CHUNK_SAMPLES));

  // Check that rec (sox) is available
  const which = Bun.spawnSync(["which", "rec"]);
  if (which.exitCode !== 0) {
    throw new Error(
      "sox not installed. Install:\n" +
        "  macOS: brew install sox\n" +
        "  Linux: apt install sox / dnf install sox\n" +
        "Also grant microphone access to your terminal app (macOS: System Settings > Privacy > Microphone).",
    );
  }

  // Reset VAD state for fresh recording (skip in PTT mode — no VAD needed)
  if (!pressToTalk) {
    await resetVAD();
  }

  // Clear any leftover stop signal from previous recording
  clearStopSignal();

  return new Promise<Uint8Array | null>((resolve, reject) => {
    let consecutiveSilentChunks = 0;
    let totalChunksProcessed = 0;
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
        try {
          recorder.kill();
        } catch {}
        recorder = null;
      }

      if (error) {
        reject(error);
      } else if (totalPcmBytes === 0 || (!pressToTalk && !hasSpeech)) {
        resolve(null); // No speech detected (PTT mode always returns audio)
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
          "-r",
          String(SAMPLE_RATE),
          "-c",
          "1",
          "-b",
          "16",
          "-e",
          "signed",
          "-t",
          "raw",
          "-q", // quiet (no progress)
          "-", // output to stdout
        ],
        { stdout: "pipe", stderr: "pipe" },
      );

      if (!recorder.stdout) {
        finish(new Error("rec: stdout not available"));
        return;
      }

      // Capture stderr for diagnostics — rec errors (permissions, no device) go here
      if (recorder.stderr) {
        const stderrReader = (
          recorder.stderr as ReadableStream<Uint8Array>
        ).getReader();
        (async () => {
          const chunks: Uint8Array[] = [];
          try {
            while (true) {
              const { value, done } = await stderrReader.read();
              if (done) break;
              if (value) chunks.push(value);
            }
          } catch {}
          if (chunks.length > 0) {
            const text = Buffer.concat(chunks).toString("utf-8").trim();
            if (text) {
              console.error(`[voicelayer] rec stderr: ${text}`);
            }
          }
        })();
      }

      console.error(
        pressToTalk
          ? "[voicelayer] Push-to-talk: recording... touch /tmp/voicelayer-stop to end"
          : "[voicelayer] Listening... speak now (Silero VAD active)",
      );

      const reader = (
        recorder.stdout as ReadableStream<Uint8Array>
      ).getReader();

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

            // Always accumulate audio data
            pcmChunks.push(chunk);
            totalPcmBytes += chunk.byteLength;
            totalChunksProcessed++;

            if (pressToTalk) {
              // PTT mode: no VAD, only stop on user signal or timeout
              if (hasStopSignal()) {
                clearStopSignal();
                console.error(
                  "[voicelayer] Stop signal received — ending PTT recording",
                );
                finish();
                return;
              }
            } else {
              // VAD mode: run Silero VAD on this chunk
              const speechProb = await processVADChunk(chunk);
              const speechDetected = isSpeech(speechProb);

              if (speechDetected) {
                hasSpeech = true;
                consecutiveSilentChunks = 0;
              } else {
                consecutiveSilentChunks++;
              }

              // Check for user-initiated stop signal — ALWAYS, regardless of speech state
              // AIDEV-NOTE: Previously gated on hasSpeech, which meant user couldn't
              // stop recording before speaking. Fixed: stop signal is unconditional.
              if (hasStopSignal()) {
                clearStopSignal();
                console.error(
                  "[voicelayer] Stop signal received — ending recording",
                );
                finish();
                return;
              }

              // VAD-based silence stop (only after speech was detected)
              if (hasSpeech && consecutiveSilentChunks >= silenceChunksNeeded) {
                console.error(
                  `[voicelayer] Silence detected (${silenceMode} mode) — ending recording`,
                );
                finish();
                return;
              }

              // Pre-speech timeout: if no speech detected within N seconds, give up
              if (!hasSpeech && totalChunksProcessed >= preSpeechChunks) {
                console.error(
                  `[voicelayer] No speech detected within ${PRE_SPEECH_TIMEOUT_SECONDS}s — ending recording`,
                );
                finish();
                return;
              }
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
 * @param pressToTalk - If true, use PTT mode (no VAD, stop on signal only)
 */
export async function waitForInput(
  timeoutMs: number,
  silenceMode: SilenceMode = "standard",
  pressToTalk: boolean = false,
): Promise<string | null> {
  // Record audio to buffer
  const pcmData = await recordToBuffer(timeoutMs, silenceMode, pressToTalk);
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
    console.error(
      `[voicelayer] Transcription (${result.durationMs}ms): ${result.text}`,
    );

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
