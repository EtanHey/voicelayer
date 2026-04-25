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
 *   1. User stop signal (touch ~/.local/state/voicelayer/stop-{TOKEN}) — PRIMARY
 *   2. Silero VAD silence detection (configurable mode) — only in VAD mode
 *   3. Timeout — SAFETY NET
 *
 * Prerequisites:
 *   brew install sox
 *   brew install whisper-cpp (or set QA_VOICE_WISPR_KEY for cloud fallback)
 */

import { existsSync, unlinkSync, writeFileSync } from "fs";
import {
  hasStopSignal,
  clearStopSignal,
  hasCancelSignal,
  clearCancelSignal,
} from "./session-booking";
import { getBackend } from "./stt";
import { recordingFilePath, MIC_DISABLED_FILE } from "./paths";
import {
  processVADChunk,
  isSpeech,
  resetVAD,
  silenceChunksForMode,
  evaluateChunkBoundary,
  VAD_CHUNK_BYTES,
  VAD_CHUNK_SAMPLES,
  type SilenceMode,
} from "./vad";
import { broadcast } from "./socket-client";
import {
  calculateRMS,
  detectNativeInputFormat,
  downmixPCM16ToMono,
  resamplePCM16,
} from "./audio-utils";
import { applyRules } from "./rules-engine";
import { resolveBinary } from "./resolve-binary";
import {
  buildChunkPrompt,
  mergeChunkTranscripts,
  type STTBackend,
} from "./stt";

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;
// AIDEV-TODO: expose these no-speech gate thresholds in VoiceBar Settings.
const MIN_TRANSCRIBE_DURATION_MS = 600;
const MIN_TRANSCRIBE_DBFS = -40;

/**
 * Pre-speech timeout: if no speech is detected within this many seconds,
 * stop recording early and return null. Prevents long silent waits.
 * Only applies to VAD mode (not PTT).
 */
const PRE_SPEECH_TIMEOUT_SECONDS = 15;

let recordingState: "idle" | "recording" | "transcribing" = "idle";
// Re-export for backward compat (used by stt.ts Wispr Flow volume data only)
export { calculateRMS };

export function isChunkedSTTEnabled(): boolean {
  const raw = process.env.QA_VOICE_CHUNKED_STT?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

export interface NoSpeechGateResult {
  allowed: boolean;
  durationMs: number;
  rms: number;
  dbfs: number;
  reason?: "too-short" | "too-quiet";
}

export function evaluateNoSpeechGate(
  pcmData: Uint8Array,
  sampleRate = SAMPLE_RATE,
): NoSpeechGateResult {
  const samples = Math.floor(pcmData.byteLength / BYTES_PER_SAMPLE);
  const durationMs = Math.round((samples / sampleRate) * 1000);
  const rms = calculateRMS(pcmData);
  const dbfs = rms > 0 ? 20 * Math.log10(rms / 32768) : -Infinity;

  if (durationMs < MIN_TRANSCRIBE_DURATION_MS) {
    return { allowed: false, durationMs, rms, dbfs, reason: "too-short" };
  }
  if (dbfs < MIN_TRANSCRIBE_DBFS) {
    return { allowed: false, durationMs, rms, dbfs, reason: "too-quiet" };
  }
  return { allowed: true, durationMs, rms, dbfs };
}

function flattenChunks(chunks: Uint8Array[]): Uint8Array {
  const totalBytes = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const flat = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    flat.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return flat;
}

export class ChunkedRecordingSession {
  private readonly sampleRate: number;
  private readonly silenceMode: SilenceMode;
  private activeChunks: Uint8Array[] = [];
  private activeBytes = 0;
  private completedSegments: Uint8Array[] = [];
  private overlapBuffer = new Uint8Array(0);
  private hasSpeech = false;
  private silenceChunks = 0;

  constructor(sampleRate = SAMPLE_RATE, silenceMode: SilenceMode = "standard") {
    this.sampleRate = sampleRate;
    this.silenceMode = silenceMode;
  }

  pushChunk(chunk: Uint8Array, speechDetected: boolean): void {
    this.activeChunks.push(chunk);
    this.activeBytes += chunk.byteLength;

    if (speechDetected) {
      this.hasSpeech = true;
      this.silenceChunks = 0;
    } else {
      this.silenceChunks += 1;
    }

    const decision = evaluateChunkBoundary({
      hasSpeech: this.hasSpeech,
      silenceChunks: this.silenceChunks,
      silenceMode: this.silenceMode,
      chunkDurationSeconds:
        this.activeBytes / (this.sampleRate * BYTES_PER_SAMPLE),
      sampleRate: this.sampleRate,
    });

    if (decision.shouldCloseChunk && this.activeBytes > 0) {
      const flat = flattenChunks(this.activeChunks);
      this.completedSegments.push(flat);
      this.overlapBuffer = flat.slice(
        -Math.min(decision.overlapBytes, flat.byteLength),
      );
      this.activeChunks =
        this.overlapBuffer.byteLength > 0 ? [this.overlapBuffer] : [];
      this.activeBytes = this.overlapBuffer.byteLength;
      this.hasSpeech = this.overlapBuffer.byteLength > 0;
      this.silenceChunks = 0;
    }
  }

  finalize(): void {
    if (this.activeBytes === 0) return;
    const flat = flattenChunks(this.activeChunks);
    const lastCompleted =
      this.completedSegments[this.completedSegments.length - 1];
    if (
      lastCompleted &&
      lastCompleted.byteLength >= flat.byteLength &&
      flat.every(
        (byte, index) =>
          lastCompleted[lastCompleted.byteLength - flat.byteLength + index] ===
          byte,
      )
    ) {
      return;
    }
    this.completedSegments.push(flat);
  }

  consumeSegments(): Uint8Array[] {
    const segments = this.completedSegments;
    this.completedSegments = [];
    return segments;
  }

  currentOverlapBytes(): number {
    return this.overlapBuffer.byteLength;
  }
}

export async function transcribeChunkSequence(
  chunks: Uint8Array[],
  transcribeChunk: (chunk: Uint8Array, prompt: string) => Promise<string>,
): Promise<string> {
  const transcripts: string[] = [];

  for (const chunk of chunks) {
    const prompt =
      transcripts.length === 0
        ? ""
        : buildChunkPrompt(mergeChunkTranscripts(transcripts), 24);
    const text = (await transcribeChunk(chunk, prompt)).trim();
    if (text) {
      transcripts.push(text);
    }
  }

  return applyRules(mergeChunkTranscripts(transcripts));
}

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
  chunkedSession?: ChunkedRecordingSession,
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

  // Resolve rec (sox) binary — probes Homebrew paths for daemon/LaunchAgent context
  const recPath = resolveBinary("rec", [
    "/opt/homebrew/bin/rec",
    "/usr/local/bin/rec",
  ]);
  if (!recPath) {
    throw new Error(
      "sox not installed. Install:\n" +
        "  macOS: brew install sox\n" +
        "  Linux: apt install sox / dnf install sox\n" +
        "Also grant microphone access to your terminal app (macOS: System Settings > Privacy > Microphone).",
    );
  }

  // Detect native device sample rate to avoid sox resampling during pipe
  // AIDEV-NOTE: Sox buffer-overruns when resampling during streaming (e.g., AirPods at 24kHz → 16kHz).
  // Recording at native rate and resampling in our code avoids this entirely.
  const nativeInputFormat = detectNativeInputFormat();
  const nativeRate = nativeInputFormat.sampleRate;
  const nativeChannels = nativeInputFormat.channels;
  const needsResample = nativeRate !== SAMPLE_RATE;
  const needsDownmix = nativeChannels !== CHANNELS;
  // Native chunk size: how many bytes at native rate correspond to one VAD chunk (512 samples at 16kHz)
  const nativeChunkFrames = Math.ceil(
    VAD_CHUNK_SAMPLES * (nativeRate / SAMPLE_RATE),
  );
  const nativeChunkBytes =
    nativeChunkFrames * nativeChannels * BYTES_PER_SAMPLE;

  if (needsResample || needsDownmix) {
    console.error(
      `[voicelayer] Device input format: ${nativeChannels}ch @ ${nativeRate}Hz — ${needsDownmix ? "downmixing to mono, " : ""}${needsResample ? `resampling to ${SAMPLE_RATE}Hz` : "keeping native rate"}`,
    );
  }

  // Reset VAD state for fresh recording (skip in PTT mode — no VAD needed)
  if (!pressToTalk) {
    await resetVAD();
  }

  // Clear any leftover stop/cancel signals from previous recording
  clearStopSignal();
  clearCancelSignal();

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
      recordingState = "idle";
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
      // Start mic recording via sox — raw PCM to stdout at device's native rate
      // AIDEV-NOTE: We record at native rate (not 16kHz) to avoid sox buffer overruns
      // when the device rate differs (e.g., AirPods at 24kHz). Resampling happens in JS.
      recorder = Bun.spawn(
        [
          recPath,
          "-r",
          String(nativeRate),
          "-c",
          String(nativeChannels),
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

      // Broadcast recording state to Voice Bar
      recordingState = "recording";
      broadcast({
        type: "state",
        state: "recording",
        mode: pressToTalk ? "ptt" : "vad",
        silence_mode: silenceMode,
      });

      console.error(
        pressToTalk
          ? "[voicelayer] Push-to-talk: recording... touch ~/.local/state/voicelayer/stop-{TOKEN} to end"
          : "[voicelayer] Listening... speak now (Silero VAD active)",
      );

      const reader = (
        recorder.stdout as ReadableStream<Uint8Array>
      ).getReader();

      // R66 Fix 1: Decouple pipe reading from VAD processing.
      // ONNX inference (5-50ms) in processVADChunk blocks reader.read(),
      // causing Bun to recycle pipe buffers before JS consumes them → rms=0.
      // Split into: pipeReader (tight loop, no ONNX awaits) + chunkProcessor (VAD).
      const chunkQueue: Uint8Array[] = [];
      let readerDone = false;

      // pipeReader: reads sox stdout as fast as possible, extracts 16kHz chunks
      const pipeReader = async () => {
        while (!resolved) {
          const { value, done } = await reader.read();
          if (done || resolved) break;
          if (!value || value.length === 0) continue;

          // Defensive copy: Bun may recycle the underlying ArrayBuffer (R65)
          const safeCopy = new Uint8Array(value);
          readBuffer.push(safeCopy);
          readBufferLen += safeCopy.length;

          // Extract native-rate chunks and resample to 16kHz — NO async here
          while (readBufferLen >= nativeChunkBytes) {
            const flat = new Uint8Array(readBufferLen);
            let off = 0;
            for (const buf of readBuffer) {
              flat.set(buf, off);
              off += buf.length;
            }
            const nativeChunk = flat.slice(0, nativeChunkBytes);
            const remainder = flat.slice(nativeChunkBytes);
            readBuffer = remainder.length > 0 ? [remainder] : [];
            readBufferLen = remainder.length;

            const monoChunk = needsDownmix
              ? downmixPCM16ToMono(nativeChunk, nativeChannels)
              : nativeChunk;
            const chunk = needsResample
              ? resamplePCM16(monoChunk, nativeRate, SAMPLE_RATE)
              : monoChunk;
            chunkQueue.push(chunk);
          }
        }
        readerDone = true;
      };

      // chunkProcessor: runs VAD on queued chunks (can take its time)
      const chunkProcessor = async () => {
        while (!resolved) {
          if (chunkQueue.length === 0) {
            if (readerDone) break;
            await Bun.sleep(1);
            continue;
          }
          const chunk = chunkQueue.shift()!;

          pcmChunks.push(chunk);
          totalPcmBytes += chunk.byteLength;
          totalChunksProcessed++;

          // Broadcast audio level every ~100ms (3 chunks × 32ms)
          if (totalChunksProcessed % 3 === 0) {
            const rmsRaw = calculateRMS(chunk);
            const rmsNormalized = Math.min(1.0, rmsRaw / 8000);
            broadcast({
              type: "audio_level",
              rms: Math.round(rmsNormalized * 100) / 100,
            });
          }

          if (pressToTalk) {
            chunkedSession?.pushChunk(chunk, true);
            if (hasStopSignal()) {
              clearStopSignal();
              console.error(
                "[voicelayer] Stop signal received — ending PTT recording",
              );
              finish();
              return;
            }
          } else {
            // VAD: ONNX inference happens here, decoupled from pipe reader
            const speechProb = await processVADChunk(chunk);
            const speechDetected = isSpeech(speechProb);
            chunkedSession?.pushChunk(chunk, speechDetected);

            // Log first 3 chunks for diagnostics
            if (totalChunksProcessed <= 3) {
              const rms = calculateRMS(chunk);
              console.error(
                `[voicelayer] VAD chunk #${totalChunksProcessed}: prob=${speechProb.toFixed(4)} rms=${rms.toFixed(0)}`,
              );
            }

            if (speechDetected) {
              if (!hasSpeech) {
                broadcast({ type: "speech", detected: true });
              }
              hasSpeech = true;
              consecutiveSilentChunks = 0;
            } else {
              consecutiveSilentChunks++;
            }

            if (hasStopSignal()) {
              clearStopSignal();
              console.error(
                "[voicelayer] Stop signal received — ending recording",
              );
              finish();
              return;
            }

            if (hasSpeech && consecutiveSilentChunks >= silenceChunksNeeded) {
              console.error(
                `[voicelayer] Silence detected (${silenceMode} mode) — ending recording`,
              );
              finish();
              return;
            }

            if (!hasSpeech && totalChunksProcessed >= preSpeechChunks) {
              console.error(
                `[voicelayer] No speech detected within ${PRE_SPEECH_TIMEOUT_SECONDS}s — ending recording`,
              );
              finish();
              return;
            }
          }
        }
      };

      // Run reader and processor concurrently
      Promise.all([
        pipeReader().catch((err) =>
          finish(err instanceof Error ? err : new Error(String(err))),
        ),
        chunkProcessor().catch((err) =>
          finish(err instanceof Error ? err : new Error(String(err))),
        ),
      ]);
    } catch (err) {
      finish(err instanceof Error ? err : new Error(String(err)));
    }
  });
}

/**
 * Wait for user voice input via mic recording + STT transcription.
 * Returns the transcribed text, or null on timeout / no speech.
 *
 * THREAD-SAFETY: Callers must ensure only one recording is active at a time.
 * Use session booking (isVoiceBooked) before calling this function.
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
  if (recordingState !== "idle") {
    throw new Error(`Recording already in progress (state: ${recordingState})`);
  }

  // Record audio to buffer
  let pcmData: Uint8Array | null;
  const chunkedSession = isChunkedSTTEnabled()
    ? new ChunkedRecordingSession(SAMPLE_RATE, silenceMode)
    : undefined;
  try {
    pcmData = await recordToBuffer(
      timeoutMs,
      silenceMode,
      pressToTalk,
      chunkedSession,
    );
  } catch (err) {
    // H4 fix: broadcast error + idle so Voice Bar doesn't get stuck
    broadcast({
      type: "error",
      message: `Recording failed: ${err instanceof Error ? err.message : String(err)}`,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle" });
    throw err;
  }
  if (!pcmData) {
    clearCancelSignal();
    broadcast({ type: "state", state: "idle" });
    return null;
  }

  // Check if recording was cancelled (X button) — discard audio, don't transcribe
  if (hasCancelSignal()) {
    clearCancelSignal();
    console.error("[voicelayer] Recording cancelled — discarding audio");
    broadcast({ type: "state", state: "idle" });
    return null;
  }

  const noSpeechGate = evaluateNoSpeechGate(pcmData);
  console.error(
    `[voicelayer] Recording gate: duration=${noSpeechGate.durationMs}ms, ` +
      `rms=${noSpeechGate.rms.toFixed(0)}, ` +
      `dbfs=${Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs.toFixed(1) : "-inf"}, ` +
      `allowed=${noSpeechGate.allowed}`,
  );
  if (!noSpeechGate.allowed) {
    console.error(
      `[voicelayer] Dropping recording before STT: ${noSpeechGate.reason} ` +
        `(duration=${noSpeechGate.durationMs}ms, rms=${noSpeechGate.rms.toFixed(0)}, ` +
        `dbfs=${Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs.toFixed(1) : "-inf"})`,
    );
    clearCancelSignal();
    broadcast({ type: "state", state: "idle" });
    return null;
  }

  // Broadcast transcribing state to Voice Bar
  recordingState = "transcribing";
  broadcast({ type: "state", state: "transcribing" });

  // Save as WAV to temp file
  const wavPath = recordingFilePath(process.pid, Date.now());
  try {
    // Transcribe with selected backend
    const backend = await getBackend();
    console.error(
      `[voicelayer] Transcribing with ${backend.name}${chunkedSession ? " (chunked)" : ""}...`,
    );
    let text = "";

    if (chunkedSession) {
      chunkedSession.finalize();
      const segments = chunkedSession.consumeSegments();
      text = await transcribeChunkSequence(segments, async (chunk, prompt) => {
        const chunkPath = recordingFilePath(
          process.pid,
          Date.now() + Math.random(),
        );
        try {
          writeFileSync(chunkPath, createWavBuffer(chunk));
          const result = await backend.transcribe(chunkPath, {
            promptOverride: prompt,
          });
          return result.text;
        } finally {
          try {
            if (existsSync(chunkPath)) unlinkSync(chunkPath);
          } catch {}
        }
      });
    } else {
      const wavData = createWavBuffer(pcmData);
      writeFileSync(wavPath, wavData);
      const result = await backend.transcribe(wavPath);
      text = result.text;
    }
    console.error(`[voicelayer] Transcription: ${text}`);

    // Broadcast transcription result + idle state to Voice Bar
    if (text) {
      broadcast({ type: "transcription", text });
    }
    recordingState = "idle";
    broadcast({ type: "state", state: "idle" });

    return text || null;
  } catch (err) {
    recordingState = "idle";
    broadcast({
      type: "error",
      message: `Transcription failed: ${err instanceof Error ? err.message : String(err)}`,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle" });
    throw err;
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

export function getRecordingState(): "idle" | "recording" | "transcribing" {
  return recordingState;
}
