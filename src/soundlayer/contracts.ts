import type { SilenceMode } from "../vad";
import type { PlaybackPriority, WordBoundary } from "../socket-protocol";

export interface TranscriptionResult {
  text: string;
  backend: string;
  durationMs: number;
}

export interface TranscribeAudioOptions {
  promptOverride?: string;
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
  rate?: string;
  mode?: string;
  voice?: string;
  waitForPlayback?: boolean;
  onPlaybackStart?: (startedAtMs: number) => void;
}

export interface TextToSpeechResult {
  warning?: string;
}

export interface TextToSpeechBackend {
  speak(text: string, options?: TextToSpeechOptions): Promise<TextToSpeechResult>;
}

export interface PlaybackMetadata {
  text: string;
  voice: string;
  wordBoundaries?: WordBoundary[];
  priority?: PlaybackPriority;
  durationMs?: number;
  collapseKey?: string;
  clipMarker?: {
    id: string;
    label: string;
    source?: "tts" | "command";
  };
  onStarted?: (startedAtMs: number) => void;
}

export interface PlaybackHandle {
  exited: Promise<void>;
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
  playbackStartedAtMs: number;
  settleMs?: number;
  minSpeechChunks?: number;
  onSpeechStart: (onset: BargeInSpeechOnset) => void | Promise<void>;
}

export interface BargeInMonitor {
  exited: Promise<void>;
  pushAudioChunk(
    pcmChunk: Uint8Array,
    capturedAtMs?: number,
  ): Promise<BargeInDecision>;
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
    pressToTalk?: boolean,
  ): Promise<Uint8Array | null>;
  waitForInput(
    timeoutMs: number,
    silenceMode?: SilenceMode,
    pressToTalk?: boolean,
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
