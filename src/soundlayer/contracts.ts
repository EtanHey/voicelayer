import type { SilenceMode } from "../vad";
import type { SpeakArchiveContext } from "../speak-archive";
import type { PlaybackScope, QueuedPlaybackHandle } from "../tts/playback-lifecycle";
import type {
  PlaybackOutcomeEvent,
  PlaybackPriority,
  WordBoundary,
} from "../socket-protocol";

export interface TranscriptionResult {
  text: string;
  backend: string;
  durationMs: number;
  /** Provider/transport facts, separate from acoustic accuracy. */
  attemptEvidence?: STTAttemptEvidence;
  outcome?: STTOutcome;
}

export interface STTAttemptEvidence {
  status?: "RETURNED" | "EMPTY_RESPONSE" | "ERROR" | "TIMEOUT" | "PARTIAL" | "INVALID";
  processExitCode?: number | null;
  inputSha256?: string;
  inputPath?: string;
  decodeCoverage?: "FULL_INPUT" | "PARTIAL" | "UNKNOWN";
  tail?: "UNKNOWN" | "KNOWN_MISSING" | "VERIFIED_BY_EXTERNAL_EVIDENCE";
  timesValid?: boolean;
}

export type STTOutcome =
  | "NATIVE_NONEMPTY_COMPLETENESS_UNKNOWN"
  | "FALLBACK_NONEMPTY_COMPLETENESS_UNKNOWN"
  | "FALLBACK_NONEMPTY_CAPTURE_TRUNCATED"
  | "FALLBACK_NONEMPTY_TAIL_VERIFIED"
  | "FALLBACK_NONEMPTY_INVALID_TIMESTAMPS"
  | "UNRESOLVED_BOTH_EMPTY"
  | "UNRESOLVED_FALLBACK_EMPTY"
  | "UNRESOLVED_FALLBACK_FAILED"
  | "UNRESOLVED_FALLBACK_INCOMPLETE"
  | "REFUSED_AUDIO_IDENTITY_MISMATCH"
  | "VERIFIED_ZERO_PCM"
  | "VAD_NO_SPEECH";

export interface TranscribeAudioOptions {
  promptOverride?: string;
  /** Explicit language selection, or trusted audio-LID result; never guessed from script. */
  language?: string;
  detectedLanguage?: string;
}

export interface SpeechToTextBackend {
  name: string;
  isAvailable(): Promise<boolean>;
  transcribe(
    audioPath: string,
    options?: TranscribeAudioOptions,
  ): Promise<TranscriptionResult>;
}

export interface SpeechToTextBackendSelector {
  getBackend(): Promise<SpeechToTextBackend>;
  resetBackendCache?(): void;
}

export interface TextToSpeechOptions {
  /** Private ingress receipt, carried explicitly for future generation writers. */
  archiveContext?: SpeakArchiveContext;
  /** Default SHORT for MCP; long-read callers can opt into automatic selection. */
  profile?: "short" | "long" | "auto";
  /** Attribution for the measured request-to-player latency. */
  measurementOrigin?: "preview" | "speak";
  rate?: string;
  mode?: string;
  voice?: string;
  waitForPlayback?: boolean;
  onPlaybackStart?: (startedAtMs: number) => void;
  /** Called before decoder/player admission, including for blocking prompts. */
  onPlaybackQueued?: (handle: QueuedPlaybackHandle) => void;
  onPlaybackComplete?: (outcome: PlaybackOutcomeEvent) => void;
  /**
   * Fail-closed gate: when true, a requested cloned voice that is not a
   * registered profile or that fails synthesis raises VoiceProfileUnavailableError
   * instead of silently downgrading to a preset/system TTS voice. Used by the
   * render/narration path; default (false) keeps the resilient fallback.
   */
  requireClonedVoice?: boolean;
  /** Return an immutable copy of the synthesized audio for paired archives. */
  captureAudioArtifact?: boolean;
}

export interface TextToSpeechResult {
  warning?: string;
  /** Sanitized human-readable text paired with the synthesized audio. */
  displayText?: string;
  /** Synthesis engine that actually produced the returned/played audio. */
  engine?: TextToSpeechEngine;
  /** Resolved clone profile or concrete engine voice actually used. */
  voice?: string;
  audioArtifact?: {
    bytes: Uint8Array;
    format: "mp3";
  };
  playbackId?: string;
  playbackOutcome?: PlaybackOutcomeEvent;
}

export type TextToSpeechEngine =
  | "xtts-v2"
  | "f5-tts-mlx"
  | "qwen3-tts"
  | "edge-tts";

export interface TextToSpeechBackend {
  speak(
    text: string,
    options?: TextToSpeechOptions,
  ): Promise<TextToSpeechResult>;
}

export interface PlaybackMetadata {
  text: string;
  voice: string;
  wordBoundaries?: WordBoundary[];
  priority?: PlaybackPriority;
  durationMs?: number;
  collapseKey?: string;
  /** State that immediately follows a successfully completed playback item. */
  nextState?: "recording";
  clipMarker?: {
    id: string;
    label: string;
    source?: "tts" | "command";
  };
  onStarted?: (startedAtMs: number) => void;
  onQueued?: (handle: QueuedPlaybackHandle) => void;
  onCompleted?: (outcome: PlaybackOutcomeEvent) => void;
}

export interface PlaybackHandle {
  id: string;
  exited: Promise<PlaybackOutcomeEvent>;
}

export interface PlaybackController {
  play(audioFile: string, metadata?: PlaybackMetadata): PlaybackHandle;
  waitForIdle(): Promise<void>;
  stop(): boolean;
  getQueueDepth(): number;
}

export interface BargeInSpeechOnset {
  onset_ms: number;
  probability: number;
  speech_chunks: number;
  captured_at_ms: number;
}

export interface BargeInMonitorMetrics {
  processed_chunks: number;
  false_interrupts: number;
  confirmed_interrupts: number;
  false_interrupt_rate: number;
}

export interface BargeInDecision {
  speechStarted: boolean;
  onset_ms?: number;
  probability?: number;
  rejectedReason?: "not-speech" | "settle-window" | "confirmation-window";
}

export interface BargeInMonitorOptions {
  /** Request owner cancellation, including disconnect. No capture transfer implied. */
  signal?: AbortSignal;
  playbackStartedAtMs: number;
  settleMs?: number;
  minSpeechChunks?: number;
  onSpeechStart: (onset: BargeInSpeechOnset) => void | Promise<void>;
}

export interface BargeInMonitor {
  /** Owned adapters settle after stream exit and in-flight work; reject on failure/abort. */
  exited: Promise<void>;
  pushAudioChunk(
    pcmChunk: Uint8Array,
    capturedAtMs?: number,
  ): Promise<BargeInDecision>;
  /** Terminal, idempotent stop request. Await exited before releasing capture ownership. */
  stop(): void;
  getMetrics(): BargeInMonitorMetrics;
}

export interface BargeInController {
  monitorDuringPlayback(options: BargeInMonitorOptions): BargeInMonitor;
}

export interface SoundLayerClock {
  nowMs(): number;
}

export interface MicCapture {
  recordToBuffer(
    timeoutMs: number,
    silenceMode?: SilenceMode,
    pushToEnd?: boolean,
  ): Promise<Uint8Array | null>;
  waitForInput(
    timeoutMs: number,
    silenceMode?: SilenceMode,
    pushToEnd?: boolean,
    options?: MicCaptureOptions,
  ): Promise<string | null>;
  clear(): void;
  getState(): "idle" | "recording" | "transcribing";
}

export interface MicCaptureOptions {
  archiveRecording?: boolean;
}

export interface CancellationController {
  stopPlayback(): boolean;
  /** Legacy adapters without scoped cancellation cannot enable barge-in. */
  cancelPlayback?(scope: PlaybackScope): boolean;
  consumeRecordingCancel(): boolean;
}

export type TranscriptEvent =
  | {
      type: "transcript.partial";
      text: string;
      confidence?: number;
    }
  | {
      type: "transcript.final";
      rawText: string;
      cleanedText?: string;
      sttBackend: string;
      cleanupBackend?: string;
    };

export interface TranscriptEventSink {
  emitTranscript(event: TranscriptEvent): void;
}

export interface VoiceActivityDetector {
  processChunk(pcmChunk: Uint8Array): Promise<number>;
  isSpeech(probability: number): boolean;
  silenceChunksForMode(mode: SilenceMode): number;
  reset(): Promise<void>;
}

export interface SoundLayer {
  micCapture: MicCapture;
  playback: PlaybackController;
  bargeIn?: BargeInController;
  clock?: SoundLayerClock;
  vad: VoiceActivityDetector;
  cancellation: CancellationController;
  transcriptEvents: TranscriptEventSink;
  tts: TextToSpeechBackend;
  stt: SpeechToTextBackendSelector;
}
