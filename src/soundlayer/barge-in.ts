import type {
  BargeInDecision,
  BargeInMonitor,
  BargeInMonitorMetrics,
  BargeInMonitorOptions,
  VoiceActivityDetector,
} from "./contracts";

const DEFAULT_SETTLE_MS = 120;
const DEFAULT_MIN_SPEECH_CHUNKS = 2;

export function createBargeInMonitor(
  vad: VoiceActivityDetector,
  options: BargeInMonitorOptions,
  nowMs: () => number = () => Date.now(),
): BargeInMonitor {
  const settleMs = options.settleMs ?? DEFAULT_SETTLE_MS;
  const minSpeechChunks = Math.max(
    1,
    options.minSpeechChunks ?? DEFAULT_MIN_SPEECH_CHUNKS,
  );
  let stopped = false;
  let consecutiveSpeechChunks = 0;
  let firstSpeechCapturedAtMs: number | null = null;
  let triggered = false;
  const metrics: BargeInMonitorMetrics = {
    processed_chunks: 0,
    false_interrupts: 0,
    confirmed_interrupts: 0,
    false_interrupt_rate: 0,
  };

  function refreshFalseInterruptRate(): void {
    const total = metrics.false_interrupts + metrics.confirmed_interrupts;
    metrics.false_interrupt_rate =
      total === 0 ? 0 : metrics.false_interrupts / total;
  }

  async function pushAudioChunk(
    pcmChunk: Uint8Array,
    capturedAtMs = nowMs(),
  ): Promise<BargeInDecision> {
    if (stopped || triggered) {
      return { speechStarted: false, rejectedReason: "not-speech" };
    }

    metrics.processed_chunks += 1;
    const probability = await vad.processChunk(pcmChunk);
    if (!vad.isSpeech(probability)) {
      consecutiveSpeechChunks = 0;
      firstSpeechCapturedAtMs = null;
      return { speechStarted: false, rejectedReason: "not-speech" };
    }

    const sincePlaybackStartMs = Math.max(
      0,
      capturedAtMs - options.playbackStartedAtMs,
    );
    if (sincePlaybackStartMs < settleMs) {
      consecutiveSpeechChunks = 0;
      firstSpeechCapturedAtMs = null;
      metrics.false_interrupts += 1;
      refreshFalseInterruptRate();
      return { speechStarted: false, rejectedReason: "settle-window" };
    }

    firstSpeechCapturedAtMs ??= capturedAtMs;
    consecutiveSpeechChunks += 1;
    if (consecutiveSpeechChunks < minSpeechChunks) {
      return { speechStarted: false, rejectedReason: "confirmation-window" };
    }

    triggered = true;
    metrics.confirmed_interrupts += 1;
    refreshFalseInterruptRate();
    const onsetMs = Math.max(
      0,
      firstSpeechCapturedAtMs - options.playbackStartedAtMs,
    );
    await options.onSpeechStart({
      onset_ms: onsetMs,
      probability,
      speech_chunks: consecutiveSpeechChunks,
      captured_at_ms: firstSpeechCapturedAtMs,
    });
    return {
      speechStarted: true,
      onset_ms: onsetMs,
      probability,
    };
  }

  return {
    exited: Promise.resolve(),
    pushAudioChunk,
    stop() {
      stopped = true;
    },
    getMetrics() {
      return { ...metrics };
    },
  };
}
