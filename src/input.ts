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

import { createHash, randomBytes } from "crypto";
import {
  closeSync,
  existsSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { homedir } from "os";
import { dirname, join } from "path";
import {
  hasStopSignal,
  clearStopSignal,
  hasCancelSignal,
  clearCancelSignal,
} from "./session-booking";
import { getBackend } from "./stt";
import {
  recordingFilePath,
  retainedRecordingFilePath,
  MIC_DISABLED_FILE,
} from "./paths";
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
import { cleanupTranscriptionText } from "./stt-cleanup";
import {
  correctTranscriptionText,
  getSTTCorrectorMode,
  type STTCorrectorEnv,
} from "./stt-corrector";
import {
  polishTranscriptionText,
  type STTPolishEnv,
  type STTPolishSurface,
} from "./stt-polish";
import { resolveBinary } from "./resolve-binary";
import {
  buildChunkPrompt,
  mergeChunkTranscripts,
  type STTBackend,
} from "./stt";
import { getLanguageModeFromEnv } from "./language-config";

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;
// AIDEV-TODO: expose these no-speech gate thresholds in VoiceBar Settings.
const MIN_TRANSCRIBE_DURATION_MS = 600;
const MIN_TRANSCRIBE_DBFS = -55;
const BROKEN_MIC_MIN_DURATION_MS = 1500;
const BROKEN_MIC_MAX_RMS = 1;
const BROKEN_MIC_MAX_DBFS = -90;
const TRAILING_SILENCE_TRIM_WINDOW_MS = 250;
const TRAILING_SILENCE_TRIM_THRESHOLD_RMS = 300;
const TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_RMS = 100;
const TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_PEAK = 350;
const TRAILING_SILENCE_TRIM_SPEECHLIKE_MAX_ZCR = 0.12;
const PTT_STOP_CAPTURE_DRAIN_MS = 250;
const TRAILING_SILENCE_TRIM_MIN_QUIET_MS = 4000;
const TRAILING_SILENCE_TRIM_PAD_MS = 1000;
const PRE_ROLL_MS = 500;
const PRE_ROLL_CHUNKS = Math.ceil(
  (PRE_ROLL_MS / 1000) * (SAMPLE_RATE / VAD_CHUNK_SAMPLES),
);
const BROKEN_MIC_MESSAGE =
  "Microphone input looks silent. Check VoiceBar > Microphone and macOS microphone access.";

/**
 * Pre-speech timeout: if no speech is detected within this many seconds,
 * stop recording early and return null. Prevents long silent waits.
 * Only applies to VAD mode (not PTT).
 */
const PRE_SPEECH_TIMEOUT_SECONDS = 15;

let recordingState: "idle" | "recording" | "transcribing" = "idle";
let retainedPolishSurface: STTPolishSurface | null = null;
// Re-export for backward compat (used by stt.ts Wispr Flow volume data only)
export { calculateRMS };

export function isChunkedSTTEnabled(): boolean {
  const raw = process.env.QA_VOICE_CHUNKED_STT?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

export function finalizeTranscriptionText(
  text: string,
  env: STTCorrectorEnv = process.env,
): string {
  const mode = getSTTCorrectorMode(env);
  if (mode === "off") return cleanupTranscriptionText(text);
  return correctTranscriptionText(text, { mode }).text;
}

export async function finalizeTranscriptionTextForSurface(
  rawText: string,
  surface: STTPolishSurface | null,
  env: STTFinalizeEnv = process.env,
): Promise<string> {
  const cleanedText = finalizeTranscriptionText(rawText, env);
  if (!surface) return cleanedText;
  const polished = await polishTranscriptionText({
    rawText,
    cleanedText,
    surface,
    env,
  });
  return polished.text;
}

function polishSurfaceForWaitOptions(
  options: WaitForInputOptions,
): STTPolishSurface | null {
  return options.archiveSource === "voicebar" ? "dictation" : null;
}

export interface NoSpeechGateResult {
  allowed: boolean;
  durationMs: number;
  rms: number;
  dbfs: number;
  reason?: "invalid-sample-rate" | "too-short" | "too-quiet";
}

export function consumeCancelSignalForRecording(): boolean {
  if (!hasCancelSignal()) return false;
  clearCancelSignal();
  return true;
}

export interface VoiceBarRecordingArchiveInput {
  audioBytes: Uint8Array;
  transcript: string | null;
  createdAt?: Date;
  source: "voicebar";
  silenceMode: SilenceMode;
  pressToTalk: boolean;
  durationMs: number;
  transcribedDurationMs?: number;
  backend: string;
}

export interface WaitForInputOptions {
  archiveSource?: "voicebar";
}

type STTFinalizeEnv = STTCorrectorEnv & STTPolishEnv;

interface WaitForInputArchiveInput {
  options: WaitForInputOptions;
  audioBytes: Uint8Array;
  transcript: string | null;
  silenceMode: SilenceMode;
  pressToTalk: boolean;
  durationMs: number;
  transcribedDurationMs?: number;
  backend: string;
}

interface VoiceBarRecordingMetadata {
  id: string;
  created_at: string;
  source: "voicebar";
  mode: "vad" | "ptt";
  silence_mode: SilenceMode;
  duration_ms: number;
  raw_duration_ms: number;
  transcribed_duration_ms: number;
  sample_rate: number;
  channels: number;
  backend: string;
  language_mode: string;
  voicelayer_transcript_chars: number;
  audio_sha256: string;
  app_version: string | null;
  schema_version: number;
}

function recordingsArchiveRoot(): string {
  return (
    process.env.QA_VOICE_RECORDINGS_DIR ||
    join(homedir(), ".local", "share", "voicelayer", "recordings")
  );
}

function fsyncPath(path: string): void {
  let fd: number | undefined;
  try {
    fd = openSync(path, "r");
    fsyncSync(fd);
  } catch {
    // Directory fsync is best-effort across platforms and filesystems.
  } finally {
    if (fd !== undefined) {
      try {
        closeSync(fd);
      } catch {}
    }
  }
}

function atomicWriteFile(path: string, data: string | Uint8Array): void {
  const tmpPath = `${path}.tmp-${process.pid}-${Date.now()}-${randomBytes(4).toString("hex")}`;
  let fd: number | undefined;
  let completed = false;
  try {
    try {
      fd = openSync(tmpPath, "w", 0o600);
      writeFileSync(fd, data);
      fsyncSync(fd);
    } finally {
      if (fd !== undefined) closeSync(fd);
    }
    renameSync(tmpPath, path);
    fsyncPath(dirname(path));
    completed = true;
  } finally {
    if (!completed) {
      try {
        if (existsSync(tmpPath)) unlinkSync(tmpPath);
      } catch {}
    }
  }
}

function archiveId(createdAt: Date): string {
  return `${createdAt.toISOString().replace(/[:.]/g, "-")}-${randomBytes(4).toString("hex")}`;
}

export function archiveVoiceBarRecording(
  input: VoiceBarRecordingArchiveInput,
): string | null {
  if (!input.transcript || input.transcript.trim().length === 0) {
    return null;
  }

  const createdAt = input.createdAt ?? new Date();
  const createdAtIso = createdAt.toISOString();
  const id = archiveId(createdAt);
  const archiveRoot = recordingsArchiveRoot();
  const dayDir = join(archiveRoot, createdAtIso.slice(0, 10));
  const stagingDir = join(dayDir, `.tmp-${id}`);
  const finalDir = join(dayDir, id);
  const metadata: VoiceBarRecordingMetadata = {
    id,
    created_at: createdAtIso,
    source: input.source,
    mode: input.pressToTalk ? "ptt" : "vad",
    silence_mode: input.silenceMode,
    duration_ms: input.durationMs,
    raw_duration_ms: input.durationMs,
    transcribed_duration_ms: input.transcribedDurationMs ?? input.durationMs,
    sample_rate: SAMPLE_RATE,
    channels: CHANNELS,
    backend: input.backend,
    language_mode: getLanguageModeFromEnv(),
    voicelayer_transcript_chars: input.transcript.length,
    audio_sha256: createHash("sha256").update(input.audioBytes).digest("hex"),
    app_version: null,
    schema_version: 1,
  };

  try {
    mkdirSync(dayDir, { recursive: true, mode: 0o700 });
    fsyncPath(archiveRoot);
    mkdirSync(stagingDir, { mode: 0o700 });
    atomicWriteFile(join(stagingDir, "audio.wav"), input.audioBytes);
    atomicWriteFile(
      join(stagingDir, "voicelayer-transcript.txt"),
      input.transcript,
    );
    atomicWriteFile(
      join(stagingDir, "metadata.json"),
      `${JSON.stringify(metadata, null, 2)}\n`,
    );
    renameSync(stagingDir, finalDir);
    fsyncPath(dayDir);
  } catch (err) {
    try {
      rmSync(stagingDir, { recursive: true, force: true });
    } catch {}
    throw err;
  }

  return finalDir;
}

export function archiveWaitForInputRecording(
  input: WaitForInputArchiveInput,
): string | null {
  if (input.options.archiveSource !== "voicebar") {
    return null;
  }

  return archiveVoiceBarRecording({
    audioBytes: input.audioBytes,
    transcript: input.transcript,
    source: input.options.archiveSource,
    silenceMode: input.silenceMode,
    pressToTalk: input.pressToTalk,
    durationMs: input.durationMs,
    transcribedDurationMs: input.transcribedDurationMs,
    backend: input.backend,
  });
}

export interface CaptureFailure {
  type: "broken-mic";
  message: string;
}

export function evaluateNoSpeechGate(
  pcmData: Uint8Array,
  sampleRate = SAMPLE_RATE,
): NoSpeechGateResult {
  const rms = calculateRMS(pcmData);
  const dbfs = rms > 0 ? 20 * Math.log10(rms / 32768) : -Infinity;
  if (!Number.isFinite(sampleRate) || sampleRate <= 0) {
    return {
      allowed: false,
      durationMs: 0,
      rms,
      dbfs,
      reason: "invalid-sample-rate",
    };
  }

  const samples = Math.floor(pcmData.byteLength / BYTES_PER_SAMPLE);
  const durationMs = Math.round((samples / sampleRate) * 1000);

  if (durationMs < MIN_TRANSCRIBE_DURATION_MS) {
    return { allowed: false, durationMs, rms, dbfs, reason: "too-short" };
  }
  if (dbfs < MIN_TRANSCRIBE_DBFS) {
    return { allowed: false, durationMs, rms, dbfs, reason: "too-quiet" };
  }
  return { allowed: true, durationMs, rms, dbfs };
}

export interface STTTrimResult {
  pcmData: Uint8Array;
  trimmed: boolean;
  rawDurationMs: number;
  transcribedDurationMs: number;
}

function pcmDurationMs(pcmData: Uint8Array, sampleRate = SAMPLE_RATE): number {
  const samples = Math.floor(pcmData.byteLength / BYTES_PER_SAMPLE);
  return Math.round((samples / sampleRate) * 1000);
}

function isActiveTrimWindow(pcmData: Uint8Array): boolean {
  const sampleCount = Math.floor(pcmData.byteLength / BYTES_PER_SAMPLE);
  if (sampleCount === 0) return false;

  const view = new DataView(
    pcmData.buffer,
    pcmData.byteOffset,
    pcmData.byteLength,
  );
  let sumSquares = 0;
  let peak = 0;
  let zeroCrossings = 0;
  let previousSign = 0;
  let hasPreviousSign = false;

  for (let i = 0; i < sampleCount; i++) {
    const sample = view.getInt16(i * BYTES_PER_SAMPLE, true);
    const absSample = Math.abs(sample);
    sumSquares += sample * sample;
    peak = Math.max(peak, absSample);

    const sign = sample > 0 ? 1 : sample < 0 ? -1 : 0;
    if (sign !== 0) {
      if (hasPreviousSign && sign !== previousSign) {
        zeroCrossings += 1;
      }
      previousSign = sign;
      hasPreviousSign = true;
    }
  }

  const rms = Math.sqrt(sumSquares / sampleCount);
  if (rms >= TRAILING_SILENCE_TRIM_THRESHOLD_RMS) return true;

  const zeroCrossingRate = zeroCrossings / sampleCount;
  return (
    rms >= TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_RMS &&
    peak >= TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_PEAK &&
    zeroCrossingRate <= TRAILING_SILENCE_TRIM_SPEECHLIKE_MAX_ZCR
  );
}

export function trimTrailingSilenceForSTT(
  pcmData: Uint8Array,
  pressToTalk: boolean,
  sampleRate = SAMPLE_RATE,
): STTTrimResult {
  const rawDurationMs = pcmDurationMs(pcmData, sampleRate);
  if (!pressToTalk || pcmData.byteLength === 0) {
    return {
      pcmData,
      trimmed: false,
      rawDurationMs,
      transcribedDurationMs: rawDurationMs,
    };
  }

  const windowBytes =
    Math.floor(
      (sampleRate * TRAILING_SILENCE_TRIM_WINDOW_MS * BYTES_PER_SAMPLE) / 1000,
    );
  const alignedWindowBytes = Math.max(
    BYTES_PER_SAMPLE,
    Math.floor(windowBytes / BYTES_PER_SAMPLE) * BYTES_PER_SAMPLE,
  );

  let lastActiveEnd = 0;
  for (let offset = 0; offset < pcmData.byteLength; offset += alignedWindowBytes) {
    const windowEnd = Math.min(offset + alignedWindowBytes, pcmData.byteLength);
    const window = pcmData.slice(offset, windowEnd);
    if (isActiveTrimWindow(window)) {
      lastActiveEnd = windowEnd;
    }
  }

  if (lastActiveEnd === 0) {
    return {
      pcmData,
      trimmed: false,
      rawDurationMs,
      transcribedDurationMs: rawDurationMs,
    };
  }

  const padBytes =
    Math.floor(
      (sampleRate * TRAILING_SILENCE_TRIM_PAD_MS * BYTES_PER_SAMPLE) / 1000,
    );
  const trimEnd = Math.min(pcmData.byteLength, lastActiveEnd + padBytes);
  const quietTailMs = pcmDurationMs(pcmData.slice(trimEnd), sampleRate);
  if (quietTailMs < TRAILING_SILENCE_TRIM_MIN_QUIET_MS) {
    return {
      pcmData,
      trimmed: false,
      rawDurationMs,
      transcribedDurationMs: rawDurationMs,
    };
  }

  const trimmedPcm = pcmData.slice(0, trimEnd);
  return {
    pcmData: trimmedPcm,
    trimmed: true,
    rawDurationMs,
    transcribedDurationMs: pcmDurationMs(trimmedPcm, sampleRate),
  };
}

export function classifyCaptureFailure(
  gate: NoSpeechGateResult,
): CaptureFailure | null {
  if (
    gate.reason === "too-quiet" &&
    gate.durationMs >= BROKEN_MIC_MIN_DURATION_MS &&
    gate.rms <= BROKEN_MIC_MAX_RMS &&
    gate.dbfs <= BROKEN_MIC_MAX_DBFS
  ) {
    return {
      type: "broken-mic",
      message: BROKEN_MIC_MESSAGE,
    };
  }

  return null;
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

export function selectChunksWithPreRoll(
  chunks: Uint8Array[],
  firstSpeechChunkIndex: number,
  preRollChunks = PRE_ROLL_CHUNKS,
): Uint8Array[] {
  if (chunks.length === 0) return [];
  if (firstSpeechChunkIndex <= 0) return [...chunks];

  const startIndex = Math.max(0, firstSpeechChunkIndex - preRollChunks);
  return chunks.slice(startIndex);
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

  replaceWithPCM(pcmData: Uint8Array, speechDetected: boolean): void {
    this.activeChunks = [];
    this.activeBytes = 0;
    this.completedSegments = [];
    this.overlapBuffer = new Uint8Array(0);
    this.hasSpeech = false;
    this.silenceChunks = 0;

    for (let offset = 0; offset < pcmData.byteLength; offset += VAD_CHUNK_BYTES) {
      this.pushChunk(pcmData.slice(offset, offset + VAD_CHUNK_BYTES), speechDetected);
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
  const rawText = await transcribeChunkSequenceRaw(chunks, transcribeChunk);
  return finalizeTranscriptionText(rawText);
}

async function transcribeChunkSequenceRaw(
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

  return mergeChunkTranscripts(transcripts);
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

type RecorderKillSignal = Parameters<ReturnType<typeof Bun.spawn>["kill"]>[0];

interface RecorderProcess {
  stdout?: ReadableStream<Uint8Array> | null;
  stderr?: ReadableStream<Uint8Array> | null;
  kill(signal?: RecorderKillSignal): void;
  exited: Promise<unknown>;
}

export async function terminateRecorderProcess(
  recorder: RecorderProcess,
  graceMs = 300,
): Promise<void> {
  const waitForExit = async () =>
    Promise.race([
      recorder.exited.then(
        () => true,
        () => true,
      ),
      Bun.sleep(graceMs).then(() => false),
    ]);

  try {
    recorder.kill("SIGTERM");
  } catch {}

  if (await waitForExit()) return;

  try {
    recorder.kill("SIGKILL");
  } catch {}

  await waitForExit();
}

export function isPttStopDrainComplete(
  stopRequestedAtMs: number,
  nowMs: number,
  drainMs = PTT_STOP_CAPTURE_DRAIN_MS,
): boolean {
  return nowMs - stopRequestedAtMs >= drainMs;
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
    let firstSpeechChunkIndex = -1;
    let readBuffer: Uint8Array[] = [];
    let readBufferLen = 0;
    const pcmChunks: Uint8Array[] = [];
    let totalPcmBytes = 0;
    let resolved = false;
    let recorder: RecorderProcess | null = null;
    let stopSignalPoll: ReturnType<typeof setInterval> | undefined;
    let pttStopRequestedAtMs: number | null = null;

    const beginPttStopDrain = () => {
      if (pttStopRequestedAtMs !== null) return;
      pttStopRequestedAtMs = Date.now();
      console.error(
        `[voicelayer] Stop signal received — capturing ${PTT_STOP_CAPTURE_DRAIN_MS}ms PTT tail before ending recording`,
      );
    };

    const finishIfPttStopDrainComplete = () => {
      if (
        pttStopRequestedAtMs !== null &&
        isPttStopDrainComplete(pttStopRequestedAtMs, Date.now())
      ) {
        console.error("[voicelayer] PTT tail capture complete — ending recording");
        finish();
        return true;
      }
      return false;
    };

    const finish = (error?: Error) => {
      if (resolved) return;
      resolved = true;
      recordingState = "idle";
      clearTimeout(timer);
      if (stopSignalPoll) clearInterval(stopSignalPoll);

      if (recorder) {
        void terminateRecorderProcess(recorder).catch((err) => {
          console.error(
            `[voicelayer] Failed to terminate recorder: ${err instanceof Error ? err.message : String(err)}`,
          );
        });
        recorder = null;
      }

      if (error) {
        reject(error);
      } else if (totalPcmBytes === 0 || (!pressToTalk && !hasSpeech)) {
        resolve(null); // No speech detected (PTT mode always returns audio)
      } else {
        const selectedChunks =
          !pressToTalk && firstSpeechChunkIndex >= 0
            ? selectChunksWithPreRoll(pcmChunks, firstSpeechChunkIndex)
            : pcmChunks;
        const selectedPcmBytes = selectedChunks.reduce(
          (sum, chunk) => sum + chunk.byteLength,
          0,
        );
        // Concatenate all PCM chunks
        const result = new Uint8Array(selectedPcmBytes);
        let offset = 0;
        for (const chunk of selectedChunks) {
          result.set(chunk, offset);
          offset += chunk.byteLength;
        }
        resolve(result);
      }
    };

    // Timeout handler
    const timer = setTimeout(() => finish(), timeoutMs);
    stopSignalPoll = setInterval(() => {
      if (pressToTalk && finishIfPttStopDrainComplete()) return;
      if (!hasStopSignal()) return;
      clearStopSignal();
      if (pressToTalk) {
        beginPttStopDrain();
        return;
      }
      console.error("[voicelayer] Stop signal received — ending recording");
      finish();
    }, 50);
    stopSignalPoll.unref?.();

    try {
      // Start mic recording via sox — raw PCM to stdout at device's native rate
      // AIDEV-NOTE: We record at native rate (not 16kHz) to avoid sox buffer overruns
      // when the device rate differs (e.g., AirPods at 24kHz). Resampling happens in JS.
      const spawnedRecorder = Bun.spawn(
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
      recorder = spawnedRecorder;

      if (!spawnedRecorder.stdout) {
        finish(new Error("rec: stdout not available"));
        return;
      }

      // Capture stderr for diagnostics — rec errors (permissions, no device) go here
      if (spawnedRecorder.stderr) {
        const stderrReader = (
          spawnedRecorder.stderr as ReadableStream<Uint8Array>
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
        spawnedRecorder.stdout as ReadableStream<Uint8Array>
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
              beginPttStopDrain();
            }
            if (finishIfPttStopDrainComplete()) {
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
                firstSpeechChunkIndex = pcmChunks.length - 1;
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
  options: WaitForInputOptions = {},
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
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw err;
  }
  if (!pcmData) {
    clearCancelSignal();
    broadcast({ type: "state", state: "idle", source: "recording" });
    return null;
  }

  // Check if recording was cancelled (X button) — discard audio, don't transcribe
  if (consumeCancelSignalForRecording()) {
    console.error("[voicelayer] Recording cancelled — discarding audio");
    broadcast({ type: "state", state: "idle" });
    return null;
  }

  const sttTrim = trimTrailingSilenceForSTT(pcmData, pressToTalk);
  if (sttTrim.trimmed) {
    console.error(
      `[voicelayer] Trimmed trailing silence before STT: raw=${sttTrim.rawDurationMs}ms, transcribed=${sttTrim.transcribedDurationMs}ms`,
    );
  }

  const noSpeechGate = evaluateNoSpeechGate(sttTrim.pcmData);
  console.error(
    `[voicelayer] Recording gate: duration=${noSpeechGate.durationMs}ms, ` +
      `rms=${noSpeechGate.rms.toFixed(0)}, ` +
      `dbfs=${Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs.toFixed(1) : "-inf"}, ` +
      `allowed=${noSpeechGate.allowed}` +
      (sttTrim.trimmed ? `, raw_duration=${sttTrim.rawDurationMs}ms` : ""),
  );
  if (!noSpeechGate.allowed) {
    console.error(
      `[voicelayer] Dropping recording before STT: ${noSpeechGate.reason} ` +
        `(duration=${noSpeechGate.durationMs}ms, rms=${noSpeechGate.rms.toFixed(0)}, ` +
        `dbfs=${Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs.toFixed(1) : "-inf"})`,
    );
    clearCancelSignal();
    const captureFailure = classifyCaptureFailure(noSpeechGate);
    if (captureFailure) {
      console.error(
        `[voicelayer] Surfacing capture failure: ${captureFailure.type}`,
      );
      broadcast({
        type: "error",
        message: captureFailure.message,
        recoverable: true,
        show_during_bar_recording: true,
      });
    } else {
      broadcast({ type: "state", state: "idle", source: "recording" });
    }
    return null;
  }

  // Broadcast transcribing state to Voice Bar
  recordingState = "transcribing";
  broadcast({ type: "state", state: "transcribing" });

  // Save as WAV to temp file
  const wavPath = recordingFilePath(process.pid, Date.now());
  try {
    const retainedWavData = createWavBuffer(pcmData);
    const sttWavData = sttTrim.trimmed
      ? createWavBuffer(sttTrim.pcmData)
      : retainedWavData;
    if (chunkedSession && sttTrim.trimmed) {
      chunkedSession.replaceWithPCM(sttTrim.pcmData, true);
    }
    const useChunkedTranscription = !!chunkedSession;
    writeFileSync(wavPath, sttWavData);

    // Transcribe with selected backend
    const backend = await getBackend();
    console.error(
      `[voicelayer] Transcribing with ${backend.name}${useChunkedTranscription ? " (chunked)" : ""}...`,
    );
    let text = "";

    if (useChunkedTranscription) {
      chunkedSession.finalize();
      const segments = chunkedSession.consumeSegments();
      const rawText = await transcribeChunkSequenceRaw(segments, async (chunk, prompt) => {
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
      text = await finalizeTranscriptionTextForSurface(
        rawText,
        polishSurfaceForWaitOptions(options),
      );
    } else {
      const result = await backend.transcribe(wavPath);
      text = await finalizeTranscriptionTextForSurface(
        result.text,
        polishSurfaceForWaitOptions(options),
      );
      if (result.text.trim() && !text) {
        console.error(
          `[voicelayer] Suppressed non-meaningful transcription: ${JSON.stringify(result.text)}`,
        );
      }
    }
    console.error(`[voicelayer] Transcription: ${text}`);

    writeFileSync(retainedRecordingFilePath(), sttWavData);
    retainedPolishSurface = polishSurfaceForWaitOptions(options);

    if (consumeCancelSignalForRecording()) {
      console.error(
        "[voicelayer] Recording cancelled during transcription — discarding transcript",
      );
      recordingState = "idle";
      broadcast({ type: "state", state: "idle", source: "recording" });
      return null;
    }

    if (text) {
      try {
        archiveWaitForInputRecording({
          options,
          audioBytes: retainedWavData,
          transcript: text,
          silenceMode,
          pressToTalk,
          durationMs: sttTrim.rawDurationMs,
          transcribedDurationMs: sttTrim.transcribedDurationMs,
          backend: backend.name,
        });
      } catch (err) {
        console.error(
          `[voicelayer] Failed to archive recording: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }

    // Broadcast transcription result + idle state to Voice Bar
    if (text) {
      broadcast({ type: "transcription", text });
    }
    recordingState = "idle";
    broadcast({ type: "state", state: "idle", source: "recording" });

    return text || null;
  } catch (err) {
    recordingState = "idle";
    broadcast({
      type: "error",
      message: `Transcription failed: ${err instanceof Error ? err.message : String(err)}`,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
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

export function hasRetainedRecording(): boolean {
  return existsSync(retainedRecordingFilePath());
}

export async function retranscribeLastCapture(): Promise<string | null> {
  const wavPath = retainedRecordingFilePath();
  if (!existsSync(wavPath)) {
    return null;
  }

  recordingState = "transcribing";
  broadcast({ type: "state", state: "transcribing" });

  try {
    const backend = await getBackend();
    console.error(`[voicelayer] Retranscribing last capture with ${backend.name}...`);
    const result = await backend.transcribe(wavPath);
    const text = await finalizeTranscriptionTextForSurface(
      result.text,
      retainedPolishSurface,
    );
    if (result.text.trim() && !text) {
      console.error(
        `[voicelayer] Suppressed non-meaningful retranscription: ${JSON.stringify(result.text)}`,
      );
    }
    console.error(`[voicelayer] Retranscription: ${text}`);

    if (text) {
      broadcast({ type: "transcription", text });
    }
    recordingState = "idle";
    broadcast({ type: "state", state: "idle", source: "recording" });
    return text || null;
  } catch (err) {
    recordingState = "idle";
    broadcast({
      type: "error",
      message: `Retranscription failed: ${err instanceof Error ? err.message : String(err)}`,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw err;
  }
}
