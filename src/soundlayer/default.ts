import {
  consumeCancelSignalForRecording,
  startMicChunkStream,
  SoxMicCapture,
} from "../input";
import { VoiceLayerSTTBackendSelector } from "../stt";
import {
  QueuedPlaybackController,
  stopPlayback,
  VoiceLayerTextToSpeechBackend,
} from "../tts";
import { SileroVoiceActivityDetector } from "../vad";
import { createBargeInMonitor } from "./barge-in";
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
  constructor(private readonly soundLayer: Pick<SoundLayer, "vad" | "clock">) {}

  monitorDuringPlayback(options: BargeInMonitorOptions): BargeInMonitor {
    const monitor = createBargeInMonitor(
      this.soundLayer.vad,
      options,
      () => this.soundLayer.clock?.nowMs() ?? Date.now(),
    );
    try {
      const stream = startMicChunkStream({
        onChunk: async (chunk, capturedAtMs) => {
          const decision = await monitor.pushAudioChunk(chunk, capturedAtMs);
          return decision.speechStarted;
        },
      });
      return {
        ...monitor,
        exited: stream.exited,
        stop() {
          monitor.stop();
          stream.stop();
        },
      };
    } catch (error) {
      console.error(
        `[voicelayer] Barge-in mic monitor unavailable: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return monitor;
    }
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
