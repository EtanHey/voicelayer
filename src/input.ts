/**
 * Input module — mic recording + STT transcription.
 *
 * Records audio via sox `rec` command (16kHz 16-bit mono PCM),
 * saves to WAV, then transcribes with the selected STT backend
 * (whisper.cpp local or Wispr Flow cloud).
 *
 * Two recording modes:
 *   - VAD mode (default): Silero VAD neural network detects speech/silence
 *   - Push-to-end (manual stop): User explicitly controls the stop signal
 *
 * AIDEV-NOTE: Energy-based VAD (amplitude threshold) removed in Phase 2.
 * False positives in noisy environments. Use Silero VAD or push-to-end instead.
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
  fstatSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readFileSync,
  readSync,
  realpathSync,
  renameSync,
  rmSync,
  unlinkSync,
  writeSync,
  writeFileSync,
} from "fs";
import { homedir } from "os";
import { basename, dirname, isAbsolute, join, relative, resolve } from "path";
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
  retainedRecordingMetadataFilePath,
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
import type { TextToSpeechEngine } from "./soundlayer";
import { restoreSentencePunctuation } from "./stt-punctuation";
import {
  correctTranscriptionText,
  getSTTCorrectorMode,
  type STTCorrectorEnv,
} from "./stt-corrector";
import {
  polishTranscriptionText,
  warmPolishEndpoint,
  type STTPolishEnv,
  type STTPolishWarmupResult,
  type STTPolishSurface,
  type STTPolishStatus,
} from "./stt-polish";
import { recoverDefaultSTTPolishServerAfterFailure } from "./stt-polish-server";
import { resolveBinary } from "./resolve-binary";
import {
  buildChunkPrompt,
  mergeChunkTranscripts,
  type STTBackend,
} from "./stt";
import { getLanguageModeFromEnv } from "./language-config";
import type { MicCapture, MicCaptureOptions } from "./soundlayer";
import {
  getEffectiveRecordingState,
  isRecordingConflictError,
  setRecordingState,
} from "./recording-state";
import { appendControlLayerEvent } from "./control-layer-journal";
import {
  RecordingSilenceAutoClosePolicy,
  clearRecordingHold,
  isRecordingHoldEngaged,
} from "./recording-hold";

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;
// AIDEV-TODO: expose these no-speech gate thresholds in VoiceBar Settings.
const MIN_TRANSCRIBE_DURATION_MS = 600;
const MIN_TRANSCRIBE_DBFS = -55;
const MIN_PUSH_TO_END_SPEECH_CHUNKS = 2;
const MIN_LOW_ENERGY_TRANSCRIBE_DURATION_MS = 1500;
const TRAILING_SILENCE_TRIM_WINDOW_MS = 250;
const TRAILING_SILENCE_TRIM_THRESHOLD_RMS = 300;
const TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_RMS = 100;
const TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_PEAK = 350;
const TRAILING_SILENCE_TRIM_SPEECHLIKE_MAX_ZCR = 0.12;
const TRAILING_SILENCE_TRIM_QUIET_SPEECHLIKE_MIN_RMS = 30;
const TRAILING_SILENCE_TRIM_QUIET_SPEECHLIKE_MIN_PEAK = 400;
const PUSH_TO_END_STOP_CAPTURE_DRAIN_MS = 250;
const TRAILING_SILENCE_TRIM_MIN_QUIET_MS = 4000;
const TRAILING_SILENCE_TRIM_PAD_MS = 1000;
const PRE_ROLL_MS = 500;
const PRE_ROLL_CHUNKS = Math.ceil(
  (PRE_ROLL_MS / 1000) * (SAMPLE_RATE / VAD_CHUNK_SAMPLES),
);

/**
 * Pre-speech timeout: if no speech is detected within this many seconds,
 * stop recording early and return null. Prevents long silent waits.
 * Only applies to VAD mode (not push-to-end).
 */
const PRE_SPEECH_TIMEOUT_SECONDS = 15;

// Re-export for backward compat (used by stt.ts Wispr Flow volume data only)
export { calculateRMS };

interface RetainedRecordingMetadata {
  schema_version: 1;
  polish_surface: STTPolishSurface;
  audio_sha256: string;
  archive_audio_path?: string;
}

function clearRetainedRecordingMetadata(): void {
  const metadataPath = retainedRecordingMetadataFilePath();
  try {
    if (existsSync(metadataPath)) unlinkSync(metadataPath);
  } catch (err) {
    console.error(
      `[voicelayer] Failed to clear retained recording metadata: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

function persistRetainedPolishSurface(
  surface: STTPolishSurface | null,
  wavData: Uint8Array,
): void {
  if (!surface) return;
  const metadata: RetainedRecordingMetadata = {
    schema_version: 1,
    polish_surface: surface,
    audio_sha256: createHash("sha256").update(wavData).digest("hex"),
  };
  try {
    atomicWriteFile(
      retainedRecordingMetadataFilePath(),
      `${JSON.stringify(metadata, null, 2)}\n`,
    );
  } catch (err) {
    console.error(
      `[voicelayer] Failed to persist retained recording metadata: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

function retainedPolishSurfaceForRetranscription(): STTPolishSurface {
  const metadataPath = retainedRecordingMetadataFilePath();
  if (!existsSync(metadataPath)) return "dictation";

  try {
    const metadata: unknown = JSON.parse(readFileSync(metadataPath, "utf8"));
    if (
      metadata &&
      typeof metadata === "object" &&
      "schema_version" in metadata &&
      "polish_surface" in metadata &&
      "audio_sha256" in metadata &&
      metadata.schema_version === 1 &&
      (metadata.polish_surface === "dictation" ||
        metadata.polish_surface === "voice_ask") &&
      metadata.audio_sha256 ===
        createHash("sha256")
          .update(readFileSync(retainedRecordingFilePath()))
          .digest("hex")
    ) {
      return metadata.polish_surface;
    }
  } catch (err) {
    console.error(
      `[voicelayer] Failed to read retained recording metadata: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  return "dictation";
}

function retainedRecordingAudioSha256(): string {
  return createHash("sha256")
    .update(readFileSync(retainedRecordingFilePath()))
    .digest("hex");
}

function readRetainedRecordingMetadata(): RetainedRecordingMetadata | null {
  const metadataPath = retainedRecordingMetadataFilePath();
  if (!existsSync(metadataPath)) return null;

  try {
    const metadata: unknown = JSON.parse(readFileSync(metadataPath, "utf8"));
    if (
      metadata &&
      typeof metadata === "object" &&
      "schema_version" in metadata &&
      "polish_surface" in metadata &&
      "audio_sha256" in metadata &&
      metadata.schema_version === 1 &&
      (metadata.polish_surface === "dictation" ||
        metadata.polish_surface === "voice_ask") &&
      typeof metadata.audio_sha256 === "string" &&
      (!("archive_audio_path" in metadata) ||
        typeof metadata.archive_audio_path === "string")
    ) {
      return metadata as RetainedRecordingMetadata;
    }
  } catch (err) {
    console.error(
      `[voicelayer] Failed to read retained recording metadata: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  return null;
}

export function linkRetainedCaptureToArchive(archiveAudioPath: string): void {
  const trimmedPath = archiveAudioPath.trim();
  if (!trimmedPath || !existsSync(retainedRecordingFilePath())) return;

  try {
    const audioSha256 = retainedRecordingAudioSha256();
    const existing = readRetainedRecordingMetadata();
    const metadata: RetainedRecordingMetadata = {
      schema_version: 1,
      polish_surface:
        existing?.audio_sha256 === audioSha256
          ? existing.polish_surface
          : "dictation",
      audio_sha256: audioSha256,
      archive_audio_path: trimmedPath,
    };
    atomicWriteFile(
      retainedRecordingMetadataFilePath(),
      `${JSON.stringify(metadata, null, 2)}\n`,
    );
  } catch (err) {
    console.error(
      `[voicelayer] Failed to link retained capture to archive: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

function retainedArchiveAudioPath(): string | null {
  const metadata = readRetainedRecordingMetadata();
  if (!metadata?.archive_audio_path?.trim()) return null;
  if (metadata.audio_sha256 !== retainedRecordingAudioSha256()) return null;
  try {
    requireArchivedRecordingAudioPath(metadata.archive_audio_path);
    return metadata.archive_audio_path;
  } catch (err) {
    console.error(
      `[voicelayer] Ignoring invalid linked archive audio path: ${err instanceof Error ? err.message : String(err)}`,
    );
    return null;
  }
}

function pushToEndForArchivedAudio(audioPath: string): boolean {
  const metadataPath = join(dirname(audioPath), "metadata.json");
  if (!existsSync(metadataPath)) return true;

  try {
    const metadata: unknown = JSON.parse(readFileSync(metadataPath, "utf8"));
    if (
      metadata &&
      typeof metadata === "object" &&
      "mode" in metadata &&
      metadata.mode === "vad"
    ) {
      return false;
    }
  } catch (err) {
    console.error(
      `[voicelayer] Failed to read archived recording mode: ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  return true;
}

function readWavPcmData(wavPath: string): Uint8Array {
  const wavData = readFileSync(wavPath);
  const validationError = wavHeaderValidationError(
    wavPath,
    wavData,
    wavData.byteLength,
  );
  if (validationError) {
    throw new Error(validationError);
  }
  return new Uint8Array(wavData.subarray(44));
}

function prepareRetranscribeWavForSTT(
  sourceWavPath: string,
  pushToEnd: boolean,
): {
  sttWavPath: string;
  cleanup: () => void;
  transcribedDurationMs: number;
} {
  const sttTrim = trimTrailingSilenceForSTT(
    readWavPcmData(sourceWavPath),
    pushToEnd,
  );
  if (!sttTrim.trimmed) {
    return {
      sttWavPath: sourceWavPath,
      cleanup: () => {},
      transcribedDurationMs: sttTrim.transcribedDurationMs,
    };
  }

  const tempPath = recordingFilePath(process.pid, Date.now());
  writeFileSync(tempPath, createWavBuffer(sttTrim.pcmData));
  console.error(
    `[voicelayer] Trimmed trailing silence before retranscription: raw=${sttTrim.rawDurationMs}ms, transcribed=${sttTrim.transcribedDurationMs}ms`,
  );
  return {
    sttWavPath: tempPath,
    cleanup: () => {
      try {
        if (existsSync(tempPath)) unlinkSync(tempPath);
      } catch {}
    },
    transcribedDurationMs: sttTrim.transcribedDurationMs,
  };
}

export function retainLastCaptureForRecovery(
  wavData: Uint8Array,
  polishSurface: STTPolishSurface | null,
): void {
  atomicWriteFile(retainedRecordingFilePath(), wavData);
  clearRetainedRecordingMetadata();
  persistRetainedPolishSurface(polishSurface, wavData);
}

export function isChunkedSTTEnabled(): boolean {
  const raw = process.env.QA_VOICE_CHUNKED_STT?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

export function finalizeTranscriptionText(
  text: string,
  env: STTCorrectorEnv = process.env,
): string {
  const mode = getSTTCorrectorMode(env);
  // identity mode is the baseline-eval escape hatch: return raw text untouched,
  // with no cleanup AND no punctuation restoration, so eval baselines stay pure.
  if (mode === "identity") return correctTranscriptionText(text, { mode }).text;
  const cleaned =
    mode === "off"
      ? cleanupTranscriptionText(text, env)
      : correctTranscriptionText(text, { mode, env }).text;
  // Deterministic terminal-punctuation floor — guarantees punctuation-rich
  // output even when the optional LLM polish server is unavailable. See
  // src/stt-punctuation.ts for the regression this closes.
  return restoreSentencePunctuation(cleaned);
}

export async function finalizeTranscriptionTextForSurface(
  rawText: string,
  surface: STTPolishSurface | null,
  env: STTFinalizeEnv = process.env,
): Promise<string> {
  return (await finalizeTranscriptionResultForSurface(rawText, surface, env))
    .text;
}

export interface FinalizedTranscriptionResult {
  text: string;
  polished?: boolean;
  polishStatus?: STTPolishStatus;
  polishReason?: string;
}

export async function finalizeTranscriptionResultForSurface(
  rawText: string,
  surface: STTPolishSurface | null,
  env: STTFinalizeEnv = process.env,
): Promise<FinalizedTranscriptionResult> {
  const cleanedText = finalizeTranscriptionText(rawText, env);
  if (!surface) return { text: cleanedText };
  const polished = await polishTranscriptionText({
    rawText,
    cleanedText,
    surface,
    env,
  });
  appendControlLayerEvent(
    "transcription.polish",
    {
      mode: polished.mode,
      status: polished.status,
      surface: polished.surface,
      changed: polished.changed,
      retried: polished.retried,
      latency_ms: Math.round(polished.latencyMs),
      raw_chars: rawText.length,
      cleaned_chars: cleanedText.length,
      polished_chars: polished.polishedText?.length ?? null,
      final_chars: polished.text.length,
      polished: polished.polished,
      reason: polished.reason ?? null,
      error: polished.error ?? null,
    },
    { topic: "voice.transcription" },
  );
  if (polished.status === "failed") {
    recoverDefaultSTTPolishServerAfterFailure(env);
  }
  return {
    text: polished.text,
    polished: polished.polished,
    polishStatus: polished.status,
    ...(polished.reason ? { polishReason: polished.reason } : {}),
  };
}

function transcriptionPolishMetadata(
  result: FinalizedTranscriptionResult,
): Pick<
  import("./socket-protocol").TranscriptionEvent,
  "polished" | "polish_status" | "polish_reason"
> {
  if (result.polished === undefined) return {};
  return {
    polished: result.polished,
    ...(result.polishStatus ? { polish_status: result.polishStatus } : {}),
    ...(result.polishReason ? { polish_reason: result.polishReason } : {}),
  };
}

export function polishSurfaceForWaitOptions(
  options: WaitForInputOptions,
): STTPolishSurface | null {
  if (options.archiveSource === "voicebar") return "dictation";
  if (options.archiveSource === "voice_ask") return "voice_ask";
  return null;
}

export function warmPolishEndpointAtRecordingStart(
  options: {
    env?: STTPolishEnv;
    warm?: (env: STTPolishEnv) => Promise<STTPolishWarmupResult>;
    appendEvent?: typeof appendControlLayerEvent;
  } = {},
): void {
  const env = options.env ?? process.env;
  const warm = options.warm ?? warmPolishEndpoint;
  const appendEvent = options.appendEvent ?? appendControlLayerEvent;

  void warm(env).then(
    (result) => {
      appendEvent(
        "transcription.polish.warmup",
        {
          status: result.status,
          latency_ms: Math.round(result.latencyMs),
          error: result.error ?? null,
        },
        { topic: "voice.transcription" },
      );
    },
    (err) => {
      appendEvent(
        "transcription.polish.warmup",
        {
          status: "failed",
          latency_ms: null,
          error: err instanceof Error ? err.message : String(err),
        },
        { topic: "voice.transcription" },
      );
    },
  );
}

export interface NoSpeechGateResult {
  allowed: boolean;
  durationMs: number;
  rms: number;
  dbfs: number;
  reason?: "invalid-sample-rate" | "too-short" | "too-quiet";
}

export interface RecordingCaptureState {
  vadSpeechDetected?: boolean;
  onCaptureStart?: () => void;
  /**
   * Who owns this capture. Forwarded to Voice Bar on the `recording` state event.
   * AIDEV-NOTE: Voice Bar cannot otherwise distinguish a voice_ask capture from a dropped-ack
   * F5 press, so its late-record-start recovery claims the ask and auto-pastes the answer into
   * the frontmost app instead of returning it to the blocked caller.
   */
  archiveSource?: "voicebar" | "voice_ask";
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
  pushToEnd: boolean;
  durationMs: number;
  transcribedDurationMs?: number;
  backend: string;
}

export interface VoiceBarUntranscribedRecordingArchiveInput extends Omit<
  VoiceBarRecordingArchiveInput,
  "transcript" | "transcribedDurationMs"
> {
  reason: "cancelled";
}

export interface WaitForInputOptions {
  archiveSource?: "voicebar" | "voice_ask";
  voiceAskArtifacts?: {
    agentAudioBytes: Uint8Array;
    agentAudioFormat: "mp3";
    agentTranscript: string;
    agentTtsEngine: TextToSpeechEngine;
    agentTtsVoice: string;
    createdAt?: Date;
  };
  onCaptureStart?: () => void;
  onArchiveCreated?: (archivePath: string) => void;
  onCaptureEnd?: () => void;
  onPhaseChange?: (phase: "transcribing") => void;
  onNoSpeech?: () => void;
  signal?: AbortSignal;
}

function invokeCaptureObserver(
  observerName: "capture_start" | "no_speech" | "phase_change",
  observer: (() => void) | undefined,
): void {
  if (!observer) return;
  try {
    observer();
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(
      `[voicelayer] Capture ${observerName} observer failed: ${detail}`,
    );
    appendControlLayerEvent("capture.observer_failed", {
      observer: observerName,
      error: detail,
    });
  }
}

function invokeArchiveCreatedObserver(
  archivePath: string,
  observer: ((archivePath: string) => void) | undefined,
): void {
  if (!observer) return;
  try {
    observer(archivePath);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    console.error(
      `[voicelayer] Capture archive_created observer failed: ${detail}`,
    );
    appendControlLayerEvent("capture.observer_failed", {
      observer: "archive_created",
      error: detail,
      archive_path: archivePath,
    });
  }
}

function waitForInputAbortError(signal: AbortSignal): Error {
  if (signal.reason instanceof Error) return signal.reason;
  const error = new Error("voice input aborted");
  error.name = "AbortError";
  return error;
}

function throwIfWaitForInputAborted(signal?: AbortSignal): void {
  if (signal?.aborted) throw waitForInputAbortError(signal);
}

class RecordingFailureWithCapturedPcm extends Error {
  constructor(
    readonly originalError: Error,
    readonly pcmData: Uint8Array,
  ) {
    super(originalError.message);
    this.name = originalError.name;
    this.stack = originalError.stack;
  }
}

type STTFinalizeEnv = STTCorrectorEnv & STTPolishEnv;

interface WaitForInputArchiveInput {
  options: WaitForInputOptions;
  audioBytes: Uint8Array;
  transcript: string | null;
  silenceMode: SilenceMode;
  pushToEnd: boolean;
  durationMs: number;
  transcribedDurationMs?: number;
  backend: string;
}

export interface VoiceAskCaptureArchiveInput {
  options: WaitForInputOptions;
  audioBytes: Uint8Array;
  silenceMode: SilenceMode;
  pushToEnd: boolean;
  durationMs: number;
  transcribedDurationMs?: number;
}

export interface VoiceAskArchiveFinalizationInput {
  transcript: string;
  backend: string;
  transcribedDurationMs?: number;
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
  transcription_status: "transcribed" | "cancelled";
  audio_sha256: string;
  app_version: string | null;
  schema_version: number;
}

const VOICE_ASK_ARTIFACT_NAMES = {
  agent_audio: "agent-audio.mp3",
  agent_transcript: "agent-transcript.txt",
  user_audio: "audio.wav",
  user_transcript: "voicelayer-transcript.txt",
} as const;

interface VoiceAskRecordingMetadata {
  id: string;
  created_at: string;
  source: "voice_ask";
  mode: "vad" | "ptt";
  silence_mode: SilenceMode;
  duration_ms: number;
  raw_duration_ms: number;
  transcribed_duration_ms: number;
  sample_rate: number;
  channels: number;
  backend: string | null;
  agent_tts_engine: TextToSpeechEngine;
  agent_tts_voice: string;
  language_mode: string;
  transcription_status: "captured" | "transcribed";
  retention_policy: "indefinite";
  voicelayer_transcript_chars: number;
  agent_transcript_chars: number;
  user_transcript_chars: number;
  audio_sha256: string;
  agent_audio_sha256: string;
  user_audio_sha256: string;
  artifacts: typeof VOICE_ASK_ARTIFACT_NAMES;
  app_version: null;
  schema_version: 3;
}

function recordingsArchiveRoot(): string {
  return (
    process.env.QA_VOICE_RECORDINGS_DIR ||
    join(homedir(), ".local", "share", "voicelayer", "recordings")
  );
}

function resolvedRecordingsArchiveRoot(): string {
  const root = recordingsArchiveRoot();
  try {
    return realpathSync(root);
  } catch {
    return resolve(root);
  }
}

function requireArchivedRecordingAudioPath(audioPath: string): string {
  const trimmed = audioPath.trim();
  if (!trimmed) {
    throw new Error("Archived recording audio path is required.");
  }

  let resolvedAudioPath: string;
  try {
    resolvedAudioPath = realpathSync(trimmed);
  } catch (err) {
    throw new Error(
      `Archived recording audio does not exist: ${trimmed} (${err instanceof Error ? err.message : String(err)}).`,
    );
  }

  if (basename(resolvedAudioPath) !== "audio.wav") {
    throw new Error(
      `Archived recording path must point to an audio.wav file: ${trimmed}`,
    );
  }

  const archiveRoot = resolvedRecordingsArchiveRoot();
  const relativePath = relative(archiveRoot, resolvedAudioPath);
  if (
    !relativePath ||
    relativePath.startsWith("..") ||
    isAbsolute(relativePath)
  ) {
    throw new Error(
      `Archived recording path must be inside ${archiveRoot}: ${trimmed}`,
    );
  }

  return resolvedAudioPath;
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

function readAscii(data: Uint8Array, start: number, end: number): string {
  return Buffer.from(data.subarray(start, end)).toString("ascii");
}

function wavHeaderValidationError(
  path: string,
  header: Uint8Array,
  fileSize: number,
): string | null {
  if (fileSize < 44 || header.byteLength < 44) {
    return `Retained recording is not a valid WAV: ${path} is ${fileSize} bytes, expected at least a 44-byte RIFF/WAVE header. The file was kept so you can inspect or replace it.`;
  }
  if (
    readAscii(header, 0, 4) !== "RIFF" ||
    readAscii(header, 8, 12) !== "WAVE"
  ) {
    return `Retained recording is not a valid WAV: ${path} is missing the RIFF/WAVE header. The file was kept so you can inspect or replace it.`;
  }
  if (readAscii(header, 36, 40) !== "data") {
    return `Retained recording is not a valid WAV: ${path} is missing the PCM data chunk. The file was kept so you can inspect or replace it.`;
  }

  const view = new DataView(
    header.buffer,
    header.byteOffset,
    header.byteLength,
  );
  const dataSize = view.getUint32(40, true);
  if (dataSize === 0) {
    return `Retained recording is not a valid WAV: ${path} contains no audio data. The file was kept so you can retry after making a new recording.`;
  }
  if (dataSize > fileSize - 44) {
    return `Retained recording is not a valid WAV: ${path} is truncated (${fileSize - 44} audio bytes on disk, header expects ${dataSize}). The file was kept so you can inspect or replace it.`;
  }

  return null;
}

function repairRetainedWavHeader(
  path: string,
  data: Buffer,
  dataSize: number,
): void {
  if (dataSize > 0xffffffff - 36) {
    throw new Error(
      `Retained recording is too large to repair as WAV: ${path} has ${dataSize} audio bytes on disk.`,
    );
  }
  const repaired = Buffer.from(data);
  repaired.writeUInt32LE(36 + dataSize, 4);
  repaired.writeUInt32LE(dataSize, 40);
  atomicWriteFile(path, repaired);
}

function requireValidRetainedWav(path: string): void {
  let data: Buffer;
  try {
    data = readFileSync(path);
  } catch (err) {
    throw new Error(
      `Retained recording is not a valid WAV: could not read ${path} (${err instanceof Error ? err.message : String(err)}).`,
    );
  }

  const validationError = wavHeaderValidationError(path, data, data.byteLength);
  if (validationError) {
    throw new Error(validationError);
  }

  const headerDataSize = data.readUInt32LE(40);
  const audioBytesOnDisk = data.byteLength - 44;
  if (audioBytesOnDisk > headerDataSize) {
    repairRetainedWavHeader(path, data, audioBytesOnDisk);
  }
}

function retainedRetranscriptionError(path: string, err: unknown): Error {
  const detail = err instanceof Error ? err.message : String(err);
  return new Error(
    `Could not retranscribe the retained recording. The retained WAV was kept at ${path}; retry "transcribe last recording" after the speech backend is available. Backend error: ${detail}`,
  );
}

function writeAllSync(fd: number, data: Uint8Array, position: number): void {
  let writtenTotal = 0;
  while (writtenTotal < data.byteLength) {
    const written = writeSync(
      fd,
      data,
      writtenTotal,
      data.byteLength - writtenTotal,
      position + writtenTotal,
    );
    if (written <= 0) {
      throw new Error("Failed to write retained recording data");
    }
    writtenTotal += written;
  }
}

function readWavDataSizeFromFd(fd: number, path: string): number {
  const header = Buffer.alloc(44);
  const bytesRead = readSync(fd, header, 0, header.byteLength, 0);
  if (bytesRead < header.byteLength) {
    throw new Error(
      `Retained recording is not a valid WAV: ${path} is missing a complete header`,
    );
  }
  const validationError = wavHeaderValidationError(
    path,
    header,
    fstatSync(fd).size,
  );
  if (validationError) {
    throw new Error(validationError);
  }
  return header.readUInt32LE(40);
}

function writeWavSizeHeader(fd: number, dataSize: number): void {
  const riffSize = Buffer.alloc(4);
  riffSize.writeUInt32LE(36 + dataSize, 0);
  const dataSizeBytes = Buffer.alloc(4);
  dataSizeBytes.writeUInt32LE(dataSize, 0);
  writeAllSync(fd, riffSize, 4);
  writeAllSync(fd, dataSizeBytes, 40);
}

function appendPcmChunkToRetainedWav(
  path: string,
  chunk: Uint8Array,
  shouldFsync: boolean,
): void {
  let fd: number | undefined;
  try {
    fd = openSync(path, "r+");
    const fileSize = fstatSync(fd).size;
    let previousDataSize = readWavDataSizeFromFd(fd, path);
    const logicalSize = 44 + previousDataSize;
    if (fileSize < logicalSize) {
      throw new Error(
        `Retained recording is not a valid WAV: ${path} is truncated (${fileSize - 44} audio bytes on disk, header expects ${previousDataSize})`,
      );
    }
    if (fileSize > logicalSize) {
      previousDataSize = fileSize - 44;
    }

    const nextDataSize = previousDataSize + chunk.byteLength;
    writeAllSync(fd, chunk, 44 + previousDataSize);
    writeWavSizeHeader(fd, nextDataSize);
    if (shouldFsync) {
      fsyncSync(fd);
    }
  } finally {
    if (fd !== undefined) closeSync(fd);
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

  return writeVoiceBarRecordingArchive({
    ...input,
    transcript: input.transcript,
    transcriptionStatus: "transcribed",
  });
}

export function archiveVoiceBarUntranscribedRecording(
  input: VoiceBarUntranscribedRecordingArchiveInput,
): string {
  return writeVoiceBarRecordingArchive({
    ...input,
    transcript: null,
    transcriptionStatus: input.reason,
  });
}

function writeVoiceBarRecordingArchive(
  input: VoiceBarRecordingArchiveInput & {
    transcriptionStatus: VoiceBarRecordingMetadata["transcription_status"];
  },
): string {
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
    mode: input.pushToEnd ? "ptt" : "vad",
    silence_mode: input.silenceMode,
    duration_ms: input.durationMs,
    raw_duration_ms: input.durationMs,
    transcribed_duration_ms: input.transcribedDurationMs ?? input.durationMs,
    sample_rate: SAMPLE_RATE,
    channels: CHANNELS,
    backend: input.backend,
    language_mode: getLanguageModeFromEnv(),
    voicelayer_transcript_chars: input.transcript?.length ?? 0,
    transcription_status: input.transcriptionStatus,
    audio_sha256: createHash("sha256").update(input.audioBytes).digest("hex"),
    app_version: null,
    schema_version: 1,
  };

  try {
    mkdirSync(dayDir, { recursive: true, mode: 0o700 });
    fsyncPath(archiveRoot);
    mkdirSync(stagingDir, { mode: 0o700 });
    atomicWriteFile(join(stagingDir, "audio.wav"), input.audioBytes);
    if (input.transcript) {
      atomicWriteFile(
        join(stagingDir, "voicelayer-transcript.txt"),
        input.transcript,
      );
    }
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

function requireVoiceAskArtifacts(options: WaitForInputOptions) {
  const artifacts = options.voiceAskArtifacts;
  if (
    options.archiveSource !== "voice_ask" ||
    !artifacts ||
    artifacts.agentAudioFormat !== "mp3" ||
    artifacts.agentAudioBytes.byteLength === 0 ||
    !artifacts.agentTranscript.trim()
  ) {
    throw new Error(
      "voice_ask archive requires immutable agent audio and transcript artifacts",
    );
  }
  if (!artifacts.agentTtsEngine || !artifacts.agentTtsVoice.trim()) {
    throw new Error(
      "voice_ask archive requires actual-used TTS engine and voice",
    );
  }
  return artifacts;
}

export function archiveVoiceAskCapture(
  input: VoiceAskCaptureArchiveInput,
): string {
  const artifacts = requireVoiceAskArtifacts(input.options);

  const createdAt = artifacts.createdAt ?? new Date();
  const createdAtIso = createdAt.toISOString();
  const id = archiveId(createdAt);
  const archiveRoot = recordingsArchiveRoot();
  const dayDir = join(archiveRoot, createdAtIso.slice(0, 10));
  const stagingDir = join(dayDir, `.tmp-${id}`);
  const finalDir = join(dayDir, id);
  const agentAudioBytes = artifacts.agentAudioBytes;
  const userAudioSha256 = createHash("sha256")
    .update(input.audioBytes)
    .digest("hex");
  const metadata: VoiceAskRecordingMetadata = {
    id,
    created_at: createdAtIso,
    source: "voice_ask",
    mode: input.pushToEnd ? "ptt" : "vad",
    silence_mode: input.silenceMode,
    duration_ms: input.durationMs,
    raw_duration_ms: input.durationMs,
    transcribed_duration_ms: input.transcribedDurationMs ?? input.durationMs,
    sample_rate: SAMPLE_RATE,
    channels: CHANNELS,
    backend: null,
    agent_tts_engine: artifacts.agentTtsEngine,
    agent_tts_voice: artifacts.agentTtsVoice,
    language_mode: getLanguageModeFromEnv(),
    transcription_status: "captured",
    retention_policy: "indefinite",
    voicelayer_transcript_chars: 0,
    agent_transcript_chars: artifacts.agentTranscript.length,
    user_transcript_chars: 0,
    audio_sha256: userAudioSha256,
    agent_audio_sha256: createHash("sha256")
      .update(agentAudioBytes)
      .digest("hex"),
    user_audio_sha256: userAudioSha256,
    artifacts: VOICE_ASK_ARTIFACT_NAMES,
    app_version: null,
    schema_version: 3,
  };

  let stagingCreated = false;
  try {
    mkdirSync(dayDir, { recursive: true, mode: 0o700 });
    fsyncPath(archiveRoot);
    mkdirSync(stagingDir, { mode: 0o700 });
    stagingCreated = true;
    atomicWriteFile(
      join(stagingDir, VOICE_ASK_ARTIFACT_NAMES.agent_audio),
      agentAudioBytes,
    );
    atomicWriteFile(
      join(stagingDir, VOICE_ASK_ARTIFACT_NAMES.agent_transcript),
      artifacts.agentTranscript,
    );
    atomicWriteFile(
      join(stagingDir, VOICE_ASK_ARTIFACT_NAMES.user_audio),
      input.audioBytes,
    );
    atomicWriteFile(
      join(stagingDir, "metadata.json"),
      `${JSON.stringify(metadata, null, 2)}\n`,
    );
    renameSync(stagingDir, finalDir);
    fsyncPath(dayDir);
  } catch (err) {
    if (stagingCreated) {
      try {
        rmSync(stagingDir, { recursive: true, force: true });
      } catch {}
    }
    throw err;
  }

  return finalDir;
}

function requireVoiceAskArchiveDirectory(archivePath: string): {
  path: string;
  metadata: VoiceAskRecordingMetadata;
} {
  const resolvedPath = realpathSync(archivePath);
  const archiveRoot = resolvedRecordingsArchiveRoot();
  const relativePath = relative(archiveRoot, resolvedPath);
  if (
    !relativePath ||
    relativePath.startsWith("..") ||
    isAbsolute(relativePath)
  ) {
    throw new Error(
      `voice_ask archive path must be inside ${archiveRoot}: ${archivePath}`,
    );
  }

  const metadata = JSON.parse(
    readFileSync(join(resolvedPath, "metadata.json"), "utf8"),
  ) as VoiceAskRecordingMetadata;
  if (
    metadata.source !== "voice_ask" ||
    metadata.schema_version !== 3 ||
    metadata.id !== basename(resolvedPath)
  ) {
    throw new Error(`Invalid voice_ask archive metadata: ${archivePath}`);
  }
  return { path: resolvedPath, metadata };
}

export function finalizeVoiceAskArchive(
  archivePath: string,
  input: VoiceAskArchiveFinalizationInput,
): string {
  if (!input.transcript.trim()) {
    throw new Error("voice_ask archive transcript must not be empty");
  }
  if (!input.backend.trim()) {
    throw new Error("voice_ask archive backend must not be empty");
  }

  const archive = requireVoiceAskArchiveDirectory(archivePath);
  if (archive.metadata.transcription_status !== "captured") {
    throw new Error(`voice_ask archive is already finalized: ${archivePath}`);
  }
  atomicWriteFile(
    join(archive.path, VOICE_ASK_ARTIFACT_NAMES.user_transcript),
    input.transcript,
  );
  const metadata: VoiceAskRecordingMetadata = {
    ...archive.metadata,
    ...(input.transcribedDurationMs === undefined
      ? {}
      : { transcribed_duration_ms: input.transcribedDurationMs }),
    backend: input.backend,
    transcription_status: "transcribed",
    voicelayer_transcript_chars: input.transcript.length,
    user_transcript_chars: input.transcript.length,
  };
  atomicWriteFile(
    join(archive.path, "metadata.json"),
    `${JSON.stringify(metadata, null, 2)}\n`,
  );
  fsyncPath(archive.path);
  return archivePath;
}

export function archiveWaitForInputRecording(
  input: WaitForInputArchiveInput,
): string | null {
  if (input.options.archiveSource === "voicebar") {
    throwIfWaitForInputAborted(input.options.signal);
    return archiveVoiceBarRecording({
      audioBytes: input.audioBytes,
      transcript: input.transcript,
      source: input.options.archiveSource,
      silenceMode: input.silenceMode,
      pushToEnd: input.pushToEnd,
      durationMs: input.durationMs,
      transcribedDurationMs: input.transcribedDurationMs,
      backend: input.backend,
    });
  }

  if (input.options.archiveSource !== "voice_ask") return null;
  if (!input.transcript?.trim()) return null;
  const archivePath = archiveVoiceAskCapture({
    options: input.options,
    audioBytes: input.audioBytes,
    silenceMode: input.silenceMode,
    pushToEnd: input.pushToEnd,
    durationMs: input.durationMs,
    transcribedDurationMs: input.transcribedDurationMs,
  });
  return finalizeVoiceAskArchive(archivePath, {
    transcript: input.transcript,
    backend: input.backend,
    transcribedDurationMs: input.transcribedDurationMs,
  });
}

export interface CaptureFailure {
  type: "broken-mic";
  message: string;
}

export interface PushToEndSpeechGateResult {
  detected: boolean;
  speechChunks: number;
  totalChunks: number;
}

interface PushToEndSpeechGateOptions {
  processChunk?: (chunk: Uint8Array) => Promise<number>;
  reset?: () => Promise<void>;
  isSpeechPredicate?: (probability: number) => boolean;
  minSpeechChunks?: number;
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
  if (
    dbfs < MIN_TRANSCRIBE_DBFS &&
    (rms === 0 || durationMs < MIN_LOW_ENERGY_TRANSCRIBE_DURATION_MS)
  ) {
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

type TrimWindowKind = "inactive" | "speech" | "quiet-speechlike";

function classifyTrimWindow(pcmData: Uint8Array): TrimWindowKind {
  const sampleCount = Math.floor(pcmData.byteLength / BYTES_PER_SAMPLE);
  if (sampleCount === 0) return "inactive";

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
  if (rms >= TRAILING_SILENCE_TRIM_THRESHOLD_RMS) return "speech";

  const zeroCrossingRate = zeroCrossings / sampleCount;
  const speechlikeZeroCrossing =
    zeroCrossingRate <= TRAILING_SILENCE_TRIM_SPEECHLIKE_MAX_ZCR;
  if (
    rms >= TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_RMS &&
    peak >= TRAILING_SILENCE_TRIM_SPEECHLIKE_MIN_PEAK &&
    speechlikeZeroCrossing
  ) {
    return "speech";
  }

  if (
    rms >= TRAILING_SILENCE_TRIM_QUIET_SPEECHLIKE_MIN_RMS &&
    peak >= TRAILING_SILENCE_TRIM_QUIET_SPEECHLIKE_MIN_PEAK &&
    speechlikeZeroCrossing
  ) {
    return "quiet-speechlike";
  }

  return "inactive";
}

function isActiveTrimWindow(pcmData: Uint8Array): boolean {
  return classifyTrimWindow(pcmData) !== "inactive";
}

export function trimTrailingSilenceForSTT(
  pcmData: Uint8Array,
  pushToEnd: boolean,
  sampleRate = SAMPLE_RATE,
): STTTrimResult {
  const rawDurationMs = pcmDurationMs(pcmData, sampleRate);
  // Manual-stop captures can contain a long quiet tail before the explicit
  // stop signal; VAD captures already end at their silence boundary.
  if (!pushToEnd || pcmData.byteLength === 0) {
    return {
      pcmData,
      trimmed: false,
      rawDurationMs,
      transcribedDurationMs: rawDurationMs,
    };
  }

  const windowBytes = Math.floor(
    (sampleRate * TRAILING_SILENCE_TRIM_WINDOW_MS * BYTES_PER_SAMPLE) / 1000,
  );
  const alignedWindowBytes = Math.max(
    BYTES_PER_SAMPLE,
    Math.floor(windowBytes / BYTES_PER_SAMPLE) * BYTES_PER_SAMPLE,
  );

  let lastActiveEnd = 0;
  const windows: Array<{ start: number; end: number; kind: TrimWindowKind }> =
    [];
  for (
    let offset = 0;
    offset < pcmData.byteLength;
    offset += alignedWindowBytes
  ) {
    const windowEnd = Math.min(offset + alignedWindowBytes, pcmData.byteLength);
    const window = pcmData.slice(offset, windowEnd);
    windows.push({
      start: offset,
      end: windowEnd,
      kind: classifyTrimWindow(window),
    });
  }

  for (let index = 0; index < windows.length; index++) {
    const current = windows[index];
    if (current.kind === "inactive") continue;
    if (current.kind === "speech") {
      lastActiveEnd = current.end;
      continue;
    }

    const previousActive = index > 0 && windows[index - 1].kind !== "inactive";
    const nextActive =
      index + 1 < windows.length && windows[index + 1].kind !== "inactive";
    if (previousActive || nextActive) {
      lastActiveEnd = current.end;
      continue;
    }

    const gapMs = pcmDurationMs(
      pcmData.slice(lastActiveEnd, current.start),
      sampleRate,
    );
    if (lastActiveEnd === 0 || gapMs < TRAILING_SILENCE_TRIM_MIN_QUIET_MS) {
      lastActiveEnd = current.end;
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

  const padBytes = Math.floor(
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
    gate.rms === 0 &&
    gate.durationMs >= MIN_TRANSCRIBE_DURATION_MS
  ) {
    return {
      type: "broken-mic",
      message: "Microphone returned silence",
    };
  }
  return null;
}

export async function evaluatePushToEndSpeechGate(
  pcmData: Uint8Array,
  options: PushToEndSpeechGateOptions = {},
): Promise<PushToEndSpeechGateResult> {
  const processChunk = options.processChunk ?? processVADChunk;
  const reset = options.reset ?? resetVAD;
  const isSpeechPredicate = options.isSpeechPredicate ?? isSpeech;
  const minSpeechChunks =
    options.minSpeechChunks ?? MIN_PUSH_TO_END_SPEECH_CHUNKS;

  if (pcmData.byteLength === 0) {
    return { detected: false, speechChunks: 0, totalChunks: 0 };
  }

  await reset();

  let speechChunks = 0;
  let totalChunks = 0;
  for (let offset = 0; offset < pcmData.byteLength; offset += VAD_CHUNK_BYTES) {
    const chunk = new Uint8Array(VAD_CHUNK_BYTES);
    chunk.set(
      pcmData.subarray(
        offset,
        Math.min(offset + VAD_CHUNK_BYTES, pcmData.byteLength),
      ),
    );
    const probability = await processChunk(chunk);
    totalChunks++;
    if (!isSpeechPredicate(probability)) continue;

    speechChunks++;
    if (speechChunks >= minSpeechChunks) {
      return { detected: true, speechChunks, totalChunks };
    }
  }

  return { detected: false, speechChunks, totalChunks };
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

class IncrementalRecoveryWavWriter {
  private static readonly fsyncChunkInterval = 10;
  private initialized = false;
  private chunksSinceFsync = 0;

  constructor(private readonly polishSurface: STTPolishSurface | null) {}

  appendCapturedChunk(chunk: Uint8Array, allChunks: Uint8Array[]): void {
    if (chunk.byteLength === 0) return;
    if (!this.initialized || !existsSync(retainedRecordingFilePath())) {
      this.flushSnapshot(allChunks);
      this.initialized = true;
      return;
    }

    try {
      const shouldFsync =
        this.chunksSinceFsync + 1 >=
        IncrementalRecoveryWavWriter.fsyncChunkInterval;
      appendPcmChunkToRetainedWav(
        retainedRecordingFilePath(),
        chunk,
        shouldFsync,
      );
      this.chunksSinceFsync = shouldFsync ? 0 : this.chunksSinceFsync + 1;
    } catch {
      this.flushSnapshot(allChunks);
    }
  }

  flushSnapshot(chunks: Uint8Array[]): void {
    const pcmData = flattenChunks(chunks);
    if (pcmData.byteLength === 0) return;
    retainLastCaptureForRecovery(createWavBuffer(pcmData), this.polishSurface);
    this.initialized = true;
    this.chunksSinceFsync = 0;
  }
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

    for (
      let offset = 0;
      offset < pcmData.byteLength;
      offset += VAD_CHUNK_BYTES
    ) {
      this.pushChunk(
        pcmData.slice(offset, offset + VAD_CHUNK_BYTES),
        speechDetected,
      );
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

export interface MicChunkStreamHandle {
  exited: Promise<void>;
  stop(): void;
}

export function startMicChunkStream(options: {
  onChunk: (chunk: Uint8Array, capturedAtMs: number) => Promise<boolean | void>;
}): MicChunkStreamHandle {
  const recPath = resolveBinary("rec", [
    "/opt/homebrew/bin/rec",
    "/usr/local/bin/rec",
  ]);
  if (!recPath) {
    throw new Error("sox not installed. Install: brew install sox");
  }

  const nativeInputFormat = detectNativeInputFormat();
  const nativeRate = nativeInputFormat.sampleRate;
  const nativeChannels = nativeInputFormat.channels;
  const needsResample = nativeRate !== SAMPLE_RATE;
  const needsDownmix = nativeChannels !== CHANNELS;
  const nativeChunkFrames = Math.ceil(
    VAD_CHUNK_SAMPLES * (nativeRate / SAMPLE_RATE),
  );
  const nativeChunkBytes =
    nativeChunkFrames * nativeChannels * BYTES_PER_SAMPLE;

  const recorder = Bun.spawn(
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
      "-q",
      "-",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );

  let stopped = false;
  let readBuffer: Uint8Array[] = [];
  let readBufferLen = 0;
  const chunkQueue: Uint8Array[] = [];
  let readerDone = false;

  const stop = () => {
    if (stopped) return;
    stopped = true;
    void terminateRecorderProcess(recorder);
  };

  const drainStderr = async () => {
    if (!recorder.stderr) return;
    const reader = (recorder.stderr as ReadableStream<Uint8Array>).getReader();
    const chunks: Uint8Array[] = [];
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        if (value) chunks.push(new Uint8Array(value));
      }
    } catch {}
    if (chunks.length === 0) return;
    const text = Buffer.concat(chunks).toString("utf-8").trim();
    if (text) console.error(`[voicelayer] barge-in rec stderr: ${text}`);
  };

  const pipeReader = async () => {
    if (!recorder.stdout) {
      throw new Error("rec: stdout not available");
    }
    const reader = (recorder.stdout as ReadableStream<Uint8Array>).getReader();
    while (!stopped) {
      const { value, done } = await reader.read();
      if (done || stopped) break;
      if (!value || value.length === 0) continue;

      const safeCopy = new Uint8Array(value);
      readBuffer.push(safeCopy);
      readBufferLen += safeCopy.length;

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

  const chunkProcessor = async () => {
    while (!stopped) {
      if (chunkQueue.length === 0) {
        if (readerDone) break;
        await Bun.sleep(1);
        continue;
      }
      const chunk = chunkQueue.shift()!;
      const shouldStop = await options.onChunk(chunk, Date.now());
      if (shouldStop) {
        stop();
        break;
      }
    }
  };

  const exited = Promise.all([
    drainStderr(),
    pipeReader(),
    chunkProcessor(),
    recorder.exited.then(
      () => undefined,
      () => undefined,
    ),
  ]).then(() => undefined);

  return { exited, stop };
}

export function isPushToEndStopDrainComplete(
  stopRequestedAtMs: number,
  nowMs: number,
  drainMs = PUSH_TO_END_STOP_CAPTURE_DRAIN_MS,
): boolean {
  return nowMs - stopRequestedAtMs >= drainMs;
}

/**
 * Record audio from mic to a PCM buffer.
 * Returns the raw PCM data as a Uint8Array.
 *
 * Two modes:
 * - VAD mode (default): Silero VAD detects speech/silence, auto-stops on silence
 * - push-to-end mode (pushToEnd=true): Records until stop signal or timeout, no VAD
 *
 * @param timeoutMs - Maximum recording time in milliseconds
 * @param silenceMode - VAD silence threshold (ignored in push-to-end mode)
 * @param pushToEnd - If true, skip VAD — only stop on user signal or timeout
 */
export async function recordToBuffer(
  timeoutMs: number,
  silenceMode: SilenceMode = "standard",
  pushToEnd: boolean = false,
  chunkedSession?: ChunkedRecordingSession,
  signal?: AbortSignal,
  preserveNoSpeechCapture = false,
  captureState?: RecordingCaptureState,
): Promise<Uint8Array | null> {
  throwIfWaitForInputAborted(signal);
  // Check mic disabled flag
  if (isMicDisabled()) {
    console.error(
      "[voicelayer] Mic disabled via flag file — skipping recording",
    );
    return null;
  }

  const currentRecordingState = getEffectiveRecordingState();
  if (currentRecordingState !== "idle") {
    throw new Error(
      `Recording already in progress (state: ${currentRecordingState})`,
    );
  }
  // Clear stale cross-process HOLD before exposing the new recording state.
  // If secure-state cleanup fails, the daemon remains truthfully idle.
  clearRecordingHold();
  setRecordingState("recording");

  const silenceChunksNeeded = pushToEnd
    ? Infinity
    : silenceChunksForMode(silenceMode);

  // Pre-speech timeout: max chunks before giving up if no speech detected
  const preSpeechChunks = pushToEnd
    ? Infinity
    : Math.ceil(PRE_SPEECH_TIMEOUT_SECONDS * (SAMPLE_RATE / VAD_CHUNK_SAMPLES));

  // Resolve rec (sox) binary — probes Homebrew paths for daemon/LaunchAgent context
  const recPath = resolveBinary("rec", [
    "/opt/homebrew/bin/rec",
    "/usr/local/bin/rec",
  ]);
  if (!recPath) {
    setRecordingState("idle");
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

  // Reset VAD state for fresh recording (skip in push-to-end mode — no VAD needed)
  if (!pushToEnd) {
    try {
      await resetVAD();
    } catch (err) {
      setRecordingState("idle");
      throw err;
    }
  }
  if (signal?.aborted) setRecordingState("idle");
  throwIfWaitForInputAborted(signal);

  // Clear any leftover stop/cancel signals from previous recording
  clearStopSignal();
  clearCancelSignal();

  return new Promise<Uint8Array | null>((resolve, reject) => {
    let totalChunksProcessed = 0;
    let hasSpeech = false;
    let firstSpeechChunkIndex = -1;
    let readBuffer: Uint8Array[] = [];
    let readBufferLen = 0;
    const pcmChunks: Uint8Array[] = [];
    const chunkQueue: Uint8Array[] = [];
    let resolved = false;
    let recorder: RecorderProcess | null = null;
    let stopSignalPoll: ReturnType<typeof setInterval> | undefined;
    let abortHandler: (() => void) | undefined;
    let pushToEndStopRequestedAtMs: number | null = null;
    const recoveryWriter = new IncrementalRecoveryWavWriter(null);
    const silencePolicy = new RecordingSilenceAutoClosePolicy({
      preSpeechChunks,
      postSpeechSilenceChunks: silenceChunksNeeded,
    });

    const drainPendingCapturedPcm = (): Uint8Array[] => {
      const pendingChunks = chunkQueue.splice(0);
      if (readBufferLen === 0) return pendingChunks;

      const pendingNativePcm = flattenChunks(readBuffer);
      readBuffer = [];
      readBufferLen = 0;
      const nativeFrameBytes = nativeChannels * BYTES_PER_SAMPLE;
      const alignedBytes =
        Math.floor(pendingNativePcm.byteLength / nativeFrameBytes) *
        nativeFrameBytes;
      if (alignedBytes === 0) return pendingChunks;

      const nativeTail = pendingNativePcm.slice(0, alignedBytes);
      const monoTail = needsDownmix
        ? downmixPCM16ToMono(nativeTail, nativeChannels)
        : nativeTail;
      const normalizedTail = needsResample
        ? resamplePCM16(monoTail, nativeRate, SAMPLE_RATE)
        : monoTail;
      if (normalizedTail.byteLength > 0) pendingChunks.push(normalizedTail);
      return pendingChunks;
    };

    const beginPushToEndStopDrain = () => {
      if (pushToEndStopRequestedAtMs !== null) return;
      pushToEndStopRequestedAtMs = Date.now();
      console.error(
        `[voicelayer] Stop signal received — capturing ${PUSH_TO_END_STOP_CAPTURE_DRAIN_MS}ms push-to-end tail before ending recording`,
      );
    };

    const finishIfPushToEndStopDrainComplete = () => {
      if (
        pushToEndStopRequestedAtMs !== null &&
        isPushToEndStopDrainComplete(pushToEndStopRequestedAtMs, Date.now())
      ) {
        console.error(
          "[voicelayer] push-to-end tail capture complete — ending recording",
        );
        finish();
        return true;
      }
      return false;
    };

    const finish = (error?: Error) => {
      if (resolved) return;
      resolved = true;
      setRecordingState("idle");
      try {
        clearRecordingHold();
      } catch (err) {
        console.error(
          `[voicelayer] Failed to clear recording HOLD: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
      clearTimeout(timer);
      if (stopSignalPoll) clearInterval(stopSignalPoll);
      if (abortHandler && signal) {
        signal.removeEventListener("abort", abortHandler);
      }

      if (recorder) {
        void terminateRecorderProcess(recorder).catch((err) => {
          console.error(
            `[voicelayer] Failed to terminate recorder: ${err instanceof Error ? err.message : String(err)}`,
          );
        });
        recorder = null;
      }

      let finishError = error;
      const capturedChunks = [...pcmChunks, ...drainPendingCapturedPcm()];
      const capturedPcmBytes = capturedChunks.reduce(
        (sum, chunk) => sum + chunk.byteLength,
        0,
      );
      if (capturedPcmBytes > 0) {
        try {
          recoveryWriter.flushSnapshot(capturedChunks);
        } catch (err) {
          console.error(
            `[voicelayer] Failed to flush retained recovery WAV: ${err instanceof Error ? err.message : String(err)}`,
          );
          if (!finishError) {
            finishError = err instanceof Error ? err : new Error(String(err));
          }
        }
      }

      if (finishError) {
        reject(
          capturedPcmBytes > 0
            ? new RecordingFailureWithCapturedPcm(
                finishError,
                flattenChunks(capturedChunks),
              )
            : finishError,
        );
      } else if (capturedPcmBytes === 0) {
        resolve(null);
      } else if (!pushToEnd && !hasSpeech && !preserveNoSpeechCapture) {
        resolve(null);
      } else {
        if (!pushToEnd && captureState) {
          captureState.vadSpeechDetected = hasSpeech;
        }
        const selectedChunks =
          !pushToEnd && hasSpeech && firstSpeechChunkIndex >= 0
            ? selectChunksWithPreRoll(capturedChunks, firstSpeechChunkIndex)
            : capturedChunks;
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
    if (signal) {
      abortHandler = () => finish(waitForInputAbortError(signal));
      if (signal.aborted) {
        abortHandler();
        return;
      }
      signal.addEventListener("abort", abortHandler, { once: true });
    }
    stopSignalPoll = setInterval(() => {
      if (pushToEnd && finishIfPushToEndStopDrainComplete()) return;
      if (!hasStopSignal()) return;
      clearStopSignal();
      if (pushToEnd) {
        beginPushToEndStopDrain();
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

      invokeCaptureObserver("capture_start", captureState?.onCaptureStart);
      if (resolved) return;

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
      setRecordingState("recording");
      broadcast({
        type: "state",
        state: "recording",
        mode: pushToEnd ? "ptt" : "vad",
        silence_mode: silenceMode,
        // AIDEV-NOTE: Tells Voice Bar who owns this capture. Without it, a remote MCP capture is
        // indistinguishable from a dropped-ack F5 press and gets claimed by late-record-start
        // recovery, auto-pasting the remote caller's answer into the frontmost app.
        ...(captureState?.archiveSource
          ? { bar_owned: captureState.archiveSource === "voicebar" }
          : {}),
      });

      console.error(
        pushToEnd
          ? "[voicelayer] Push-to-end: recording... touch ~/.local/state/voicelayer/stop-{TOKEN} to end"
          : "[voicelayer] Listening... speak now (Silero VAD active)",
      );

      const reader = (
        spawnedRecorder.stdout as ReadableStream<Uint8Array>
      ).getReader();

      // R66 Fix 1: Decouple pipe reading from VAD processing.
      // ONNX inference (5-50ms) in processVADChunk blocks reader.read(),
      // causing Bun to recycle pipe buffers before JS consumes them → rms=0.
      // Split into: pipeReader (tight loop, no ONNX awaits) + chunkProcessor (VAD).
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
          totalChunksProcessed++;
          recoveryWriter.appendCapturedChunk(chunk, pcmChunks);

          // Broadcast audio level every ~100ms (3 chunks × 32ms)
          if (totalChunksProcessed % 3 === 0) {
            const rmsRaw = calculateRMS(chunk);
            const rmsNormalized = Math.min(1.0, rmsRaw / 8000);
            broadcast({
              type: "audio_level",
              rms: Math.round(rmsNormalized * 100) / 100,
            });
          }

          if (pushToEnd) {
            chunkedSession?.pushChunk(chunk, true);
            if (hasStopSignal()) {
              clearStopSignal();
              beginPushToEndStopDrain();
            }
            if (finishIfPushToEndStopDrainComplete()) {
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

            const hadSpeech = hasSpeech;
            const silenceObservation = silencePolicy.observe({
              speechDetected,
              holdEngaged: isRecordingHoldEngaged(),
            });
            hasSpeech = silenceObservation.hasSpeech;

            if (speechDetected) {
              if (!hadSpeech) {
                firstSpeechChunkIndex = pcmChunks.length - 1;
                broadcast({ type: "speech", detected: true });
              }
            }

            if (hasStopSignal()) {
              clearStopSignal();
              console.error(
                "[voicelayer] Stop signal received — ending recording",
              );
              finish();
              return;
            }

            if (
              silenceObservation.shouldClose &&
              silenceObservation.reason === "post-speech-silence"
            ) {
              console.error(
                `[voicelayer] Silence detected (${silenceMode} mode) — ending recording`,
              );
              finish();
              return;
            }

            if (
              silenceObservation.shouldClose &&
              silenceObservation.reason === "pre-speech-silence"
            ) {
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
 * @param pushToEnd - If true, use push-to-end mode (no VAD, stop on signal only)
 */
export async function waitForInput(
  timeoutMs: number,
  silenceMode: SilenceMode = "standard",
  pushToEnd: boolean = false,
  options: WaitForInputOptions = {},
): Promise<string | null> {
  throwIfWaitForInputAborted(options.signal);
  const currentRecordingState = getEffectiveRecordingState();
  if (currentRecordingState !== "idle") {
    throw new Error(
      `Recording already in progress (state: ${currentRecordingState})`,
    );
  }
  appendControlLayerEvent("capture.started", {
    silence_mode: silenceMode,
    push_to_end: pushToEnd,
    timeout_ms: timeoutMs,
    archive_source: options.archiveSource ?? null,
  });
  if (polishSurfaceForWaitOptions(options)) {
    warmPolishEndpointAtRecordingStart();
  }

  // Record audio to buffer
  let pcmData: Uint8Array | null;
  const captureState: RecordingCaptureState = {
    archiveSource: options.archiveSource,
    onCaptureStart: options.onCaptureStart,
  };
  const chunkedSession = isChunkedSTTEnabled()
    ? new ChunkedRecordingSession(SAMPLE_RATE, silenceMode)
    : undefined;
  try {
    pcmData = await recordToBuffer(
      timeoutMs,
      silenceMode,
      pushToEnd,
      chunkedSession,
      options.signal,
      options.archiveSource === "voice_ask",
      captureState,
    );
  } catch (err) {
    if (
      err instanceof RecordingFailureWithCapturedPcm &&
      options.archiveSource === "voice_ask"
    ) {
      const retainedWavData = createWavBuffer(err.pcmData);
      const durationMs = pcmDurationMs(err.pcmData);
      try {
        const archivePath = archiveVoiceAskCapture({
          options,
          audioBytes: retainedWavData,
          silenceMode,
          pushToEnd,
          durationMs,
          transcribedDurationMs: durationMs,
        });
        invokeArchiveCreatedObserver(archivePath, options.onArchiveCreated);
      } catch (archiveErr) {
        const detail =
          archiveErr instanceof Error ? archiveErr.message : String(archiveErr);
        appendControlLayerEvent("capture.archive_failed", {
          archive_source: "voice_ask",
          duration_ms: durationMs,
          error: detail,
          recording_error: err.originalError.message,
        });
        throw new Error(
          `voice_ask archive failed after capture abort: ${detail}`,
        );
      }
    }
    appendControlLayerEvent("capture.recording_failed", {
      error: err instanceof Error ? err.message : String(err),
      recording_state: getEffectiveRecordingState(),
      silence_mode: silenceMode,
      push_to_end: pushToEnd,
      archive_source: options.archiveSource ?? null,
    });
    if (options.signal?.aborted) throw err;
    // H4 fix: broadcast error + idle so Voice Bar doesn't get stuck
    broadcast({
      type: "error",
      message: `Recording failed: ${err instanceof Error ? err.message : String(err)}`,
      recoverable: true,
    });
    if (
      !isRecordingConflictError(err) &&
      getEffectiveRecordingState() === "idle"
    ) {
      broadcast({ type: "state", state: "idle", source: "recording" });
    }
    throw err;
  }
  if (!pcmData) {
    throwIfWaitForInputAborted(options.signal);
    clearCancelSignal();
    broadcast({ type: "state", state: "idle", source: "recording" });
    return null;
  }

  const retainedWavData = createWavBuffer(pcmData);
  const sttTrim = trimTrailingSilenceForSTT(pcmData, pushToEnd);
  let voiceAskArchivePath: string | null = null;
  if (options.archiveSource === "voice_ask") {
    try {
      voiceAskArchivePath = archiveVoiceAskCapture({
        options,
        audioBytes: retainedWavData,
        silenceMode,
        pushToEnd,
        durationMs: sttTrim.rawDurationMs,
        transcribedDurationMs: sttTrim.transcribedDurationMs,
      });
      invokeArchiveCreatedObserver(
        voiceAskArchivePath,
        options.onArchiveCreated,
      );
    } catch (err) {
      const detail = err instanceof Error ? err.message : String(err);
      console.error(
        `[voicelayer] Failed to archive voice_ask capture: ${detail}`,
      );
      const archiveError = `voice_ask archive failed: ${detail}`;
      appendControlLayerEvent("capture.archive_failed", {
        archive_source: "voice_ask",
        duration_ms: sttTrim.rawDurationMs,
        error: detail,
      });
      setRecordingState("idle");
      broadcast({
        type: "error",
        message: archiveError,
        recoverable: true,
      });
      broadcast({ type: "state", state: "idle", source: "recording" });
      throw new Error(archiveError);
    }
  }
  try {
    options.onCaptureEnd?.();
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    appendControlLayerEvent("capture.completion_callback_failed", {
      archive_source: options.archiveSource ?? null,
      duration_ms: sttTrim.rawDurationMs,
      error: detail,
    });
    setRecordingState("idle");
    broadcast({
      type: "error",
      message: `Capture completion failed: ${detail}`,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw err;
  }
  throwIfWaitForInputAborted(options.signal);

  // Check if recording was cancelled (X button) — keep a recovery WAV but don't transcribe.
  if (consumeCancelSignalForRecording()) {
    retainLastCaptureForRecovery(
      retainedWavData,
      polishSurfaceForWaitOptions(options),
    );
    if (options.archiveSource === "voicebar") {
      try {
        const cancelledArchivePath = archiveVoiceBarUntranscribedRecording({
          audioBytes: retainedWavData,
          source: options.archiveSource,
          silenceMode,
          pushToEnd,
          durationMs: pcmDurationMs(pcmData),
          backend: "not-transcribed",
          reason: "cancelled",
        });
        linkRetainedCaptureToArchive(join(cancelledArchivePath, "audio.wav"));
      } catch (err) {
        console.error(
          `[voicelayer] Failed to archive cancelled recording: ${err instanceof Error ? err.message : String(err)}`,
        );
      }
    }
    console.error(
      "[voicelayer] Recording cancelled — retained audio for recovery",
    );
    appendControlLayerEvent("capture.cancelled", {
      duration_ms: pcmDurationMs(pcmData),
      silence_mode: silenceMode,
      push_to_end: pushToEnd,
      archive_source: options.archiveSource ?? null,
      retained_recording: true,
    });
    broadcast({ type: "state", state: "idle" });
    return null;
  }

  if (sttTrim.trimmed) {
    console.error(
      `[voicelayer] Trimmed trailing silence before STT: raw=${sttTrim.rawDurationMs}ms, transcribed=${sttTrim.transcribedDurationMs}ms`,
    );
    appendControlLayerEvent("capture.stt_trim", {
      raw_duration_ms: sttTrim.rawDurationMs,
      transcribed_duration_ms: sttTrim.transcribedDurationMs,
      trimmed_ms: sttTrim.rawDurationMs - sttTrim.transcribedDurationMs,
      silence_mode: silenceMode,
      push_to_end: pushToEnd,
      archive_source: options.archiveSource ?? null,
    });
  }

  const noSpeechGate = evaluateNoSpeechGate(sttTrim.pcmData);
  const vadNoSpeech = !pushToEnd && captureState.vadSpeechDetected === false;
  const transcriptionAllowed = noSpeechGate.allowed && !vadNoSpeech;
  console.error(
    `[voicelayer] Recording gate: duration=${noSpeechGate.durationMs}ms, ` +
      `rms=${noSpeechGate.rms.toFixed(0)}, ` +
      `dbfs=${Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs.toFixed(1) : "-inf"}, ` +
      `vad_speech=${captureState.vadSpeechDetected ?? "unknown"}, ` +
      `allowed=${transcriptionAllowed}` +
      (sttTrim.trimmed ? `, raw_duration=${sttTrim.rawDurationMs}ms` : ""),
  );
  if (!transcriptionAllowed) {
    const noSpeechReason = vadNoSpeech ? "vad-no-speech" : noSpeechGate.reason;
    const captureFailure = vadNoSpeech
      ? null
      : classifyCaptureFailure(noSpeechGate);
    console.error(
      `[voicelayer] Dropping recording before STT: ${noSpeechReason} ` +
        `(duration=${noSpeechGate.durationMs}ms, rms=${noSpeechGate.rms.toFixed(0)}, ` +
        `dbfs=${Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs.toFixed(1) : "-inf"})`,
    );
    clearCancelSignal();
    invokeCaptureObserver("no_speech", options.onNoSpeech);
    appendControlLayerEvent("capture.no_speech", {
      reason: noSpeechReason ?? null,
      duration_ms: noSpeechGate.durationMs,
      raw_duration_ms: sttTrim.rawDurationMs,
      transcribed_duration_ms: sttTrim.transcribedDurationMs,
      rms: noSpeechGate.rms,
      dbfs: Number.isFinite(noSpeechGate.dbfs) ? noSpeechGate.dbfs : null,
      trimmed: sttTrim.trimmed,
      silence_mode: silenceMode,
      push_to_end: pushToEnd,
      archive_source: options.archiveSource ?? null,
      vad_speech_detected: captureState.vadSpeechDetected ?? null,
      capture_failure: captureFailure?.type ?? null,
    });
    if (captureFailure) {
      broadcast({
        type: "error",
        message: captureFailure.message,
        recoverable: true,
        show_during_bar_recording: true,
        capture_failure: captureFailure.type,
      });
      return null;
    }
    broadcast({ type: "state", state: "idle", source: "recording" });
    return null;
  }

  if (pushToEnd) {
    try {
      const pushToEndSpeechGate = await evaluatePushToEndSpeechGate(
        sttTrim.pcmData,
      );
      throwIfWaitForInputAborted(options.signal);
      console.error(
        `[voicelayer] push-to-end speech gate: detected=${pushToEndSpeechGate.detected} ` +
          `(speech-chunks=${pushToEndSpeechGate.speechChunks}/${pushToEndSpeechGate.totalChunks})`,
      );
      if (!pushToEndSpeechGate.detected) {
        clearCancelSignal();
        invokeCaptureObserver("no_speech", options.onNoSpeech);
        broadcast({ type: "state", state: "idle", source: "recording" });
        return null;
      }
    } catch (err) {
      if (options.signal?.aborted) throw err;
      console.error(
        `[voicelayer] push-to-end speech gate skipped: ${err instanceof Error ? err.message : String(err)}`,
      );
    }
  }

  throwIfWaitForInputAborted(options.signal);
  // Broadcast transcribing state to Voice Bar
  invokeCaptureObserver(
    "phase_change",
    options.onPhaseChange
      ? () => options.onPhaseChange?.("transcribing")
      : undefined,
  );
  setRecordingState("transcribing");
  broadcast({ type: "state", state: "transcribing" });
  broadcast({
    type: "transcription_status",
    status: "warming",
    message: "Loading speech model",
  });

  // Save as WAV to temp file
  const wavPath = recordingFilePath(process.pid, Date.now());
  try {
    const sttWavData = sttTrim.trimmed
      ? createWavBuffer(sttTrim.pcmData)
      : retainedWavData;
    if (chunkedSession && sttTrim.trimmed) {
      chunkedSession.replaceWithPCM(sttTrim.pcmData, true);
    }
    const useChunkedTranscription = !!chunkedSession;
    retainLastCaptureForRecovery(
      retainedWavData,
      polishSurfaceForWaitOptions(options),
    );
    writeFileSync(wavPath, sttWavData);

    // Transcribe with selected backend
    const backend = await getBackend();
    throwIfWaitForInputAborted(options.signal);
    broadcast({
      type: "transcription_status",
      status: "transcribing",
      message: "Transcribing",
    });
    console.error(
      `[voicelayer] Transcribing with ${backend.name}${useChunkedTranscription ? " (chunked)" : ""}...`,
    );
    let finalized: FinalizedTranscriptionResult;

    if (useChunkedTranscription) {
      chunkedSession.finalize();
      const segments = chunkedSession.consumeSegments();
      const rawText = await transcribeChunkSequenceRaw(
        segments,
        async (chunk, prompt) => {
          const chunkPath = recordingFilePath(
            process.pid,
            Date.now() + Math.random(),
          );
          try {
            throwIfWaitForInputAborted(options.signal);
            writeFileSync(chunkPath, createWavBuffer(chunk));
            const result = await backend.transcribe(chunkPath, {
              promptOverride: prompt,
            });
            throwIfWaitForInputAborted(options.signal);
            return result.text;
          } finally {
            try {
              if (existsSync(chunkPath)) unlinkSync(chunkPath);
            } catch {}
          }
        },
      );
      throwIfWaitForInputAborted(options.signal);
      finalized = await finalizeTranscriptionResultForSurface(
        rawText,
        polishSurfaceForWaitOptions(options),
      );
    } else {
      const result = await backend.transcribe(wavPath);
      throwIfWaitForInputAborted(options.signal);
      finalized = await finalizeTranscriptionResultForSurface(
        result.text,
        polishSurfaceForWaitOptions(options),
      );
      if (result.text.trim() && !finalized.text) {
        console.error(
          `[voicelayer] Suppressed non-meaningful transcription: ${JSON.stringify(result.text)}`,
        );
      }
    }
    throwIfWaitForInputAborted(options.signal);
    const text = finalized.text;
    console.error(`[voicelayer] Transcription: ${text}`);

    retainLastCaptureForRecovery(
      sttWavData,
      polishSurfaceForWaitOptions(options),
    );

    if (consumeCancelSignalForRecording()) {
      console.error(
        "[voicelayer] Recording cancelled during transcription — discarding transcript",
      );
      setRecordingState("idle");
      broadcast({ type: "state", state: "idle", source: "recording" });
      return null;
    }

    throwIfWaitForInputAborted(options.signal);
    let archivedRecordingPath: string | null = null;
    if (text) {
      try {
        archivedRecordingPath = voiceAskArchivePath
          ? finalizeVoiceAskArchive(voiceAskArchivePath, {
              transcript: text,
              backend: backend.name,
              transcribedDurationMs: sttTrim.transcribedDurationMs,
            })
          : archiveWaitForInputRecording({
              options,
              audioBytes: retainedWavData,
              transcript: text,
              silenceMode,
              pushToEnd,
              durationMs: sttTrim.rawDurationMs,
              transcribedDurationMs: sttTrim.transcribedDurationMs,
              backend: backend.name,
            });
      } catch (err) {
        const detail = err instanceof Error ? err.message : String(err);
        console.error(`[voicelayer] Failed to archive recording: ${detail}`);
        if (options.archiveSource === "voice_ask") {
          throw new Error(`voice_ask archive failed: ${detail}`);
        }
      }
      if (archivedRecordingPath) {
        linkRetainedCaptureToArchive(join(archivedRecordingPath, "audio.wav"));
      }
    }

    throwIfWaitForInputAborted(options.signal);
    // Broadcast transcription result + idle state to Voice Bar
    if (text) {
      broadcast({
        type: "transcription",
        text,
        ...transcriptionPolishMetadata(finalized),
        ...(archivedRecordingPath
          ? { recording_path: join(archivedRecordingPath, "audio.wav") }
          : {}),
      });
    }
    setRecordingState("idle");
    broadcast({ type: "state", state: "idle", source: "recording" });

    return text || null;
  } catch (err) {
    setRecordingState("idle");
    if (options.signal?.aborted) {
      throw err;
    }
    const errorMessage = err instanceof Error ? err.message : String(err);
    broadcast({
      type: "error",
      message: errorMessage.startsWith("voice_ask archive failed:")
        ? errorMessage
        : `Transcription failed: ${errorMessage}`,
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
  return getEffectiveRecordingState();
}

export class SoxMicCapture implements MicCapture {
  recordToBuffer(
    timeoutMs: number,
    silenceMode: SilenceMode = "standard",
    pushToEnd = false,
  ): Promise<Uint8Array | null> {
    return recordToBuffer(timeoutMs, silenceMode, pushToEnd);
  }

  waitForInput(
    timeoutMs: number,
    silenceMode: SilenceMode = "standard",
    pushToEnd = false,
    options: MicCaptureOptions = {},
  ): Promise<string | null> {
    return waitForInput(
      timeoutMs,
      silenceMode,
      pushToEnd,
      options.archiveRecording ? { archiveSource: "voicebar" } : {},
    );
  }

  clear(): void {
    clearInput();
  }

  getState(): "idle" | "recording" | "transcribing" {
    return getRecordingState();
  }
}

export function hasRetainedRecording(): boolean {
  return existsSync(retainedRecordingFilePath());
}

// AIDEV-NOTE: `transcribed_duration_ms` is the slice of audio STT actually saw,
// which is shorter than `duration_ms`/`raw_duration_ms` (mic-on time) whenever the
// trailing-silence trim fires. Retranscribing recomputes that slice, so the field
// must be rewritten here or the archive keeps reporting the original capture's
// value forever — which is what happened before this was threaded through.
export function updateArchivedTranscript(
  audioPath: string,
  text: string,
  transcription: {
    backend: string;
    languageMode: string;
    transcribedDurationMs?: number;
  },
): void {
  const transcriptPath = join(dirname(audioPath), "voicelayer-transcript.txt");
  atomicWriteFile(transcriptPath, text);

  updateArchivedRecordingMetadata(audioPath, (metadata) => {
    metadata.backend = transcription.backend;
    metadata.language_mode = transcription.languageMode;
    metadata.transcription_status = "transcribed";
    if (transcription.transcribedDurationMs !== undefined) {
      metadata.transcribed_duration_ms = transcription.transcribedDurationMs;
    }
    metadata.voicelayer_transcript_chars = text.length;
    if (metadata.source === "voice_ask") {
      metadata.user_transcript_chars = text.length;
    }
    metadata.audio_sha256 = archivedAudioSha256(audioPath);
  });
}

function archivedAudioSha256(audioPath: string): string {
  return createHash("sha256").update(readFileSync(audioPath)).digest("hex");
}

function updateArchivedRecordingMetadata(
  audioPath: string,
  applyUpdates: (metadata: Record<string, unknown>) => void,
): void {
  const metadataPath = join(dirname(audioPath), "metadata.json");
  if (!existsSync(metadataPath)) return;

  try {
    const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
    applyUpdates(metadata);
    atomicWriteFile(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
  } catch (err) {
    console.error(
      `[voicelayer] Failed to update archived recording metadata: ${err instanceof Error ? err.message : String(err)}`,
    );
  }
}

function refreshArchivedAudioChecksum(audioPath: string): void {
  updateArchivedRecordingMetadata(audioPath, (metadata) => {
    metadata.audio_sha256 = archivedAudioSha256(audioPath);
  });
}

export async function retranscribeRecordingCapture(
  audioPath: string,
): Promise<string | null> {
  const eventAudioPath = audioPath.trim();
  let wavPath: string;
  try {
    wavPath = requireArchivedRecordingAudioPath(audioPath);
    requireValidRetainedWav(wavPath);
    refreshArchivedAudioChecksum(wavPath);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    broadcast({
      type: "error",
      message,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw err;
  }

  setRecordingState("transcribing");
  broadcast({ type: "state", state: "transcribing" });
  broadcast({
    type: "transcription_status",
    status: "warming",
    message: "Loading speech model",
  });

  try {
    const backend = await getBackend();
    broadcast({
      type: "transcription_status",
      status: "transcribing",
      message: "Transcribing",
    });
    console.error(
      `[voicelayer] Retranscribing archived recording with ${backend.name}: ${wavPath}`,
    );
    const { sttWavPath, cleanup, transcribedDurationMs } =
      prepareRetranscribeWavForSTT(
        wavPath,
        pushToEndForArchivedAudio(wavPath),
      );
    try {
      const result = await backend.transcribe(sttWavPath);
      const finalized = await finalizeTranscriptionResultForSurface(
        result.text,
        "dictation",
      );
      const text = finalized.text;
      if (result.text.trim() && !text) {
        console.error(
          `[voicelayer] Suppressed non-meaningful archived retranscription: ${JSON.stringify(result.text)}`,
        );
      }
      console.error(`[voicelayer] Archived retranscription: ${text}`);

      if (text) {
        updateArchivedTranscript(wavPath, text, {
          backend: backend.name,
          languageMode: getLanguageModeFromEnv(),
          transcribedDurationMs,
        });
        broadcast({
          type: "transcription",
          text,
          recording_path: eventAudioPath,
          ...transcriptionPolishMetadata(finalized),
        });
      }
      setRecordingState("idle");
      broadcast({ type: "state", state: "idle", source: "recording" });
      return text || null;
    } finally {
      cleanup();
    }
  } catch (err) {
    setRecordingState("idle");
    const detail = err instanceof Error ? err.message : String(err);
    const retryableError = new Error(
      `Could not retranscribe archived recording ${wavPath}. The audio was kept; retry after the speech backend is available. Backend error: ${detail}`,
    );
    broadcast({
      type: "error",
      message: retryableError.message,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw retryableError;
  }
}

export async function retranscribeLastCapture(): Promise<string | null> {
  const wavPath = retainedRecordingFilePath();
  if (!existsSync(wavPath)) {
    return null;
  }
  try {
    requireValidRetainedWav(wavPath);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    broadcast({
      type: "error",
      message,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw err;
  }

  setRecordingState("transcribing");
  broadcast({ type: "state", state: "transcribing" });
  broadcast({
    type: "transcription_status",
    status: "warming",
    message: "Loading speech model",
  });

  try {
    const backend = await getBackend();
    broadcast({
      type: "transcription_status",
      status: "transcribing",
      message: "Transcribing",
    });
    console.error(
      `[voicelayer] Retranscribing last capture with ${backend.name}...`,
    );
    const archivedAudioPath = retainedArchiveAudioPath();
    const sourceWavPath = archivedAudioPath ?? wavPath;
    const pushToEnd = archivedAudioPath
      ? pushToEndForArchivedAudio(archivedAudioPath)
      : false;
    const { sttWavPath, cleanup, transcribedDurationMs } =
      prepareRetranscribeWavForSTT(sourceWavPath, pushToEnd);
    try {
      const result = await backend.transcribe(sttWavPath);
      const finalized = await finalizeTranscriptionResultForSurface(
        result.text,
        retainedPolishSurfaceForRetranscription(),
      );
      const text = finalized.text;
      if (result.text.trim() && !text) {
        console.error(
          `[voicelayer] Suppressed non-meaningful retranscription: ${JSON.stringify(result.text)}`,
        );
      }
      console.error(`[voicelayer] Retranscription: ${text}`);

      if (text) {
        if (archivedAudioPath) {
          updateArchivedTranscript(archivedAudioPath, text, {
            backend: backend.name,
            languageMode: getLanguageModeFromEnv(),
            transcribedDurationMs,
          });
        }
        broadcast({
          type: "transcription",
          text,
          ...(archivedAudioPath ? { recording_path: archivedAudioPath } : {}),
          ...transcriptionPolishMetadata(finalized),
        });
      }
      setRecordingState("idle");
      broadcast({ type: "state", state: "idle", source: "recording" });
      return text || null;
    } finally {
      cleanup();
    }
  } catch (err) {
    setRecordingState("idle");
    const retryableError = retainedRetranscriptionError(wavPath, err);
    broadcast({
      type: "error",
      message: retryableError.message,
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle", source: "recording" });
    throw retryableError;
  }
}
