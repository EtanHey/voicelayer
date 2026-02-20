/**
 * Input module — mic recording + STT transcription.
 *
 * Records audio via sox `rec` command (16kHz 16-bit mono PCM),
 * saves to WAV, then transcribes with the selected STT backend
 * (whisper.cpp local or Wispr Flow cloud).
 *
 * Stops recording on:
 *   1. User stop signal (touch /tmp/voicelayer-stop) — PRIMARY
 *   2. Silence detection (configurable seconds of silence) — FALLBACK
 *   3. Timeout — SAFETY NET
 *
 * Prerequisites:
 *   brew install sox
 *   brew install whisper-cpp (or set QA_VOICE_WISPR_KEY for cloud fallback)
 */

import { existsSync, unlinkSync, writeFileSync } from "fs";
import { hasStopSignal, clearStopSignal } from "./session-booking";
import { getBackend } from "./stt";

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;
const CHUNK_DURATION_S = 1;
const CHUNK_SIZE = SAMPLE_RATE * BYTES_PER_SAMPLE * CHUNK_DURATION_S; // 32000 bytes

const SILENCE_THRESHOLD = Number(process.env.QA_VOICE_SILENCE_THRESHOLD) || 500;
const DEFAULT_SILENCE_SECONDS = Number(process.env.QA_VOICE_SILENCE_SECONDS) || 2;

/**
 * Calculate RMS energy of a 16-bit signed PCM audio buffer.
 * Used for voice activity / silence detection.
 */
export function calculateRMS(buffer: Uint8Array): number {
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  const numSamples = Math.floor(buffer.byteLength / BYTES_PER_SAMPLE);
  if (numSamples === 0) return 0;

  let sumSquares = 0;
  for (let i = 0; i < numSamples; i++) {
    const sample = view.getInt16(i * BYTES_PER_SAMPLE, true); // little-endian
    sumSquares += sample * sample;
  }

  return Math.sqrt(sumSquares / numSamples);
}

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

/**
 * Record audio from mic to a PCM buffer.
 * Returns the raw PCM data as a Uint8Array.
 * Handles stop signal, silence detection, and timeout.
 */
export async function recordToBuffer(
  timeoutMs: number,
  silenceSeconds?: number,
): Promise<Uint8Array | null> {
  const effectiveSilence = silenceSeconds ?? DEFAULT_SILENCE_SECONDS;

  // Check that rec (sox) is available
  const which = Bun.spawnSync(["which", "rec"]);
  if (which.exitCode !== 0) {
    throw new Error(
      "sox not installed. Run: brew install sox\n" +
      "Also grant microphone access to your terminal app in System Settings > Privacy > Microphone."
    );
  }

  // Clear any leftover stop signal from previous recording
  clearStopSignal();

  return new Promise<Uint8Array | null>((resolve, reject) => {
    let silentChunks = 0;
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

      console.error("[qa-voice] Listening... speak now");

      const reader = (recorder.stdout as ReadableStream<Uint8Array>).getReader();

      const processAudio = async () => {
        while (!resolved) {
          const { value, done } = await reader.read();
          if (done || resolved) break;
          if (!value || value.length === 0) continue;

          // Append incoming bytes to read buffer (O(1) push, not O(n) concat)
          readBuffer.push(value);
          readBufferLen += value.length;

          // Process complete 1-second chunks
          while (readBufferLen >= CHUNK_SIZE && !resolved) {
            // Flatten only when needed
            const flat = new Uint8Array(readBufferLen);
            let off = 0;
            for (const buf of readBuffer) {
              flat.set(buf, off);
              off += buf.length;
            }
            const chunk = flat.slice(0, CHUNK_SIZE);
            const remainder = flat.slice(CHUNK_SIZE);
            readBuffer = remainder.length > 0 ? [remainder] : [];
            readBufferLen = remainder.length;

            const rms = calculateRMS(chunk);

            if (rms >= SILENCE_THRESHOLD) {
              hasSpeech = true;
              silentChunks = 0;
            } else {
              silentChunks++;
            }

            // Always accumulate audio data
            pcmChunks.push(chunk);
            totalPcmBytes += chunk.byteLength;

            // Check for user-initiated stop signal
            if (hasSpeech && hasStopSignal()) {
              clearStopSignal();
              console.error("[qa-voice] Stop signal received — ending recording");
              finish();
              return;
            }

            // Silence-based stop (only after speech was detected)
            if (hasSpeech && silentChunks >= effectiveSilence) {
              console.error("[qa-voice] Silence detected — ending recording");
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
 * @param silenceSeconds - Seconds of silence before auto-stop (default from env or 2)
 */
export async function waitForInput(
  timeoutMs: number,
  silenceSeconds?: number,
): Promise<string | null> {
  // Record audio to buffer
  const pcmData = await recordToBuffer(timeoutMs, silenceSeconds);
  if (!pcmData) return null;

  // Save as WAV to temp file
  const wavPath = `/tmp/voicelayer-recording-${process.pid}-${Date.now()}.wav`;
  try {
    const wavData = createWavBuffer(pcmData);
    writeFileSync(wavPath, wavData);

    // Transcribe with selected backend
    const backend = await getBackend();
    console.error(`[qa-voice] Transcribing with ${backend.name}...`);
    const result = await backend.transcribe(wavPath);
    console.error(`[qa-voice] Transcription (${result.durationMs}ms): ${result.text}`);

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
