import {
  consumeCancelSignalForRecording,
  SoxMicCapture,
} from "../input";
import { VoiceLayerSTTBackendSelector } from "../stt";
import {
  QueuedPlaybackController,
  stopPlayback,
  VoiceLayerTextToSpeechBackend,
} from "../tts";
import { SileroVoiceActivityDetector } from "../vad";
import type {
  CancellationController,
  SoundLayer,
  TranscriptEvent,
  TranscriptEventSink,
} from "./contracts";

class VoiceLayerCancellationController implements CancellationController {
  stopPlayback(): boolean {
    return stopPlayback();
  }

  consumeRecordingCancel(): boolean {
    return consumeCancelSignalForRecording();
  }
}

class VoiceLayerTranscriptEventSink implements TranscriptEventSink {
  emitTranscript(_event: TranscriptEvent): void {
    // Existing VoiceLayer transcript events are still emitted through socket-client.
    // VoiceSDK can supply a durable sink without coupling SoundLayer to sessions.
  }
}

export function createDefaultSoundLayer(): SoundLayer {
  return {
    micCapture: new SoxMicCapture(),
    playback: new QueuedPlaybackController(),
    vad: new SileroVoiceActivityDetector(),
    cancellation: new VoiceLayerCancellationController(),
    transcriptEvents: new VoiceLayerTranscriptEventSink(),
    tts: new VoiceLayerTextToSpeechBackend(),
    stt: new VoiceLayerSTTBackendSelector(),
  };
}

export const defaultSoundLayer: SoundLayer = createDefaultSoundLayer();
