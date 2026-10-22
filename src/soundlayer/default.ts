import {
  consumeCancelSignalForRecording,
  startMicChunkStream,
  SoxMicCapture,
} from "../input";
import { VoiceLayerSTTBackendSelector } from "../stt";
import {
  QueuedPlaybackController,
  stopPlayback,
  cancelPlayback,
  VoiceLayerTextToSpeechBackend,
} from "../tts";
import {
  IsolatedSileroVoiceActivityDetector,
  SileroVoiceActivityDetector,
} from "../vad";
import { createOwnedBargeInMonitor } from "./barge-in";
import type {
  BargeInController,
  BargeInMonitor,
  BargeInMonitorOptions,
  CancellationController,
  SoundLayer,
  TranscriptEvent,
  TranscriptEventSink,
} from "./contracts";

class VoiceLayerCancellationController implements CancellationController {
  cancelPlayback(scope: Parameters<typeof cancelPlayback>[0]): boolean { return cancelPlayback(scope); }

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

class VoiceLayerBargeInController implements BargeInController {
  constructor(private readonly soundLayer: Pick<SoundLayer, "clock">) {}

  monitorDuringPlayback(options: BargeInMonitorOptions): BargeInMonitor {
    return createOwnedBargeInMonitor(
      new IsolatedSileroVoiceActivityDetector(), options, startMicChunkStream,
      () => this.soundLayer.clock?.nowMs() ?? Date.now(),
    );
  }
}

export function createDefaultSoundLayer(): SoundLayer {
  const layer: SoundLayer = {
    micCapture: new SoxMicCapture(),
    playback: new QueuedPlaybackController(),
    vad: new SileroVoiceActivityDetector(),
    cancellation: new VoiceLayerCancellationController(),
    transcriptEvents: new VoiceLayerTranscriptEventSink(),
    tts: new VoiceLayerTextToSpeechBackend(),
    stt: new VoiceLayerSTTBackendSelector(),
    clock: {
      nowMs: () => Date.now(),
    },
  };
  layer.bargeIn = new VoiceLayerBargeInController(layer);
  return layer;
}

export const defaultSoundLayer: SoundLayer = createDefaultSoundLayer();
