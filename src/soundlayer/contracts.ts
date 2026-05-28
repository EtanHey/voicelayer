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
  vad: VoiceActivityDetector;
  cancellation: CancellationController;
  transcriptEvents: TranscriptEventSink;
  tts: TextToSpeechBackend;
  stt: SpeechToTextBackendSelector;
}
