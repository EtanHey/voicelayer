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
    if (stopped || triggered) {
      return { speechStarted: false, rejectedReason: "not-speech" };
    }
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

/** Owns one monitor stream; the caller must await exited before reusing capture. */
export function createOwnedBargeInMonitor(
  vad: VoiceActivityDetector,
  options: BargeInMonitorOptions,
  startStream: (options: {
    onChunk: (chunk: Uint8Array, at: number) => Promise<boolean | void>;
  }) => { exited: Promise<void>; stop(): void },
  nowMs?: () => number,
): BargeInMonitor {
  const monitor = createBargeInMonitor(vad, options, nowMs);
  let terminal = false;
  let failed = false;
  let failure: unknown;
  let stream: ReturnType<typeof startStream> | undefined;
  const pending = new Set<Promise<BargeInDecision>>();
  let finish!: () => void;
  const ended = new Promise<void>(resolve => { finish = resolve; });

  function stop(): void {
    if (terminal) return;
    terminal = true;
    monitor.stop();
    options.signal?.removeEventListener("abort", abort);
    try { stream?.stop(); }
    catch (error) { fail(error); }
  }
  function fail(error: unknown): void {
    if (!failed) { failed = true; failure = error; }
    stop();
  }
  function abort(): void {
    fail(options.signal?.reason ?? new Error("Barge-in owner aborted"));
  }
  function pushAudioChunk(chunk: Uint8Array, at?: number): Promise<BargeInDecision> {
    if (terminal) return Promise.resolve({ speechStarted: false, rejectedReason: "not-speech" });
    const work = monitor.pushAudioChunk(chunk, at);
    pending.add(work);
    void work.then(() => { pending.delete(work); }, error => {
      fail(error);
      pending.delete(work);
    });
    return work;
  }

  const exited = ended.then(async () => {
    await Promise.allSettled([...pending]);
    if (failed) throw failure;
  });
  // The owner may await later, after playback exits. Keep early failures observed.
  void exited.catch(() => {});
  options.signal?.addEventListener("abort", abort, { once: true });
  if (options.signal?.aborted) { abort(); finish(); }
  if (!terminal) {
    try {
      stream = startStream({ onChunk: async (chunk, at) => {
        const decision = await pushAudioChunk(chunk, at);
        if (decision.speechStarted) stop();
        return decision.speechStarted;
      } });
    } catch (error) { fail(error); finish(); }
    if (stream) {
      void stream.exited.then(() => { stop(); finish(); }, error => {
        fail(error); finish();
      });
      if (terminal) {
        try { stream.stop(); } catch (error) { fail(error); }
      }
    }
  }
  return { exited, pushAudioChunk, stop, getMetrics: monitor.getMetrics };
}
