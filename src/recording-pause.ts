/**
 * Recording pause (Etan, 2026-11-08): read something aloud mid-dictation without it being captured, then
 * continue the same take. The gate sits where the recorder's PCM enters the take, so the recorder keeps
 * running and nothing is restarted. Model: formal/ptt-silence-timeout (NoPausedAudio, UnpausedRetained,
 * NoTimeoutDuringPause, StopCancelFromPaused, PausedSpansClosed).
 */

const SAMPLE_RATE = 16000;
const BYTES_PER_SAMPLE = 2;
const BYTES_PER_MS = (SAMPLE_RATE * BYTES_PER_SAMPLE) / 1000;

/** Audio kept after a Pause click so the word being spoken at the click is not clipped. */
export const RECORDING_PAUSE_TAIL_MS = 200;
export const RECORDING_PAUSE_TAIL_BYTES = RECORDING_PAUSE_TAIL_MS * BYTES_PER_MS;

/**
 * One paused span, for the archive's `paused_spans`. `start_ms`/`end_ms` are wall time since the recorder
 * opened; `audio_offset_ms` is where in the kept audio the cut sits; `dropped_ms` is how much audio was not
 * kept. A span with `dropped_ms: 0` was resumed inside the click tail.
 */
export interface RecordingPauseSpan {
  start_ms: number;
  end_ms: number;
  audio_offset_ms: number;
  dropped_ms: number;
}

const toMs = (bytes: number) => Math.round(bytes / BYTES_PER_MS);

export class RecordingPauseGate {
  private paused = false;
  private tailLeftBytes = 0;
  private admittedBytes = 0;
  private pausedAtMs: number | null = null;
  private pausedTotalMs = 0;
  private open: { startMs: number; cutAtBytes: number | null; droppedBytes: number } | null = null;
  private readonly closed: RecordingPauseSpan[] = [];

  constructor(
    private readonly startedAtMs: number,
    private readonly tailBytes = RECORDING_PAUSE_TAIL_BYTES,
  ) {}

  isPaused(): boolean {
    return this.paused;
  }

  /** True once the click tail is spent: from here on the take gets no audio until resume. */
  isDropping(): boolean {
    return this.paused && this.tailLeftBytes <= 0;
  }

  pause(nowMs: number): boolean {
    if (this.paused) return false;
    this.paused = true;
    this.tailLeftBytes = this.tailBytes;
    this.pausedAtMs = nowMs;
    this.open = { startMs: nowMs, cutAtBytes: null, droppedBytes: 0 };
    return true;
  }

  resume(nowMs: number): boolean {
    if (!this.paused) return false;
    this.closeSpan(nowMs);
    this.paused = false;
    this.tailLeftBytes = 0;
    return true;
  }

  /** Whether a normalized PCM chunk joins the take. Called in capture order, once per chunk. */
  admit(bytes: number): boolean {
    if (!this.paused || this.tailLeftBytes > 0) {
      if (this.paused) this.tailLeftBytes -= bytes;
      this.admittedBytes += bytes;
      return true;
    }
    if (this.open) {
      this.open.cutAtBytes ??= this.admittedBytes;
      this.open.droppedBytes += bytes;
    }
    return false;
  }

  /** Wall time minus time spent paused; it stands still during a pause. Silence deadlines use this clock. */
  activeNow(nowMs: number): number {
    const current = this.pausedAtMs === null ? 0 : Math.max(0, nowMs - this.pausedAtMs);
    return nowMs - this.pausedTotalMs - current;
  }

  /** Every span, an open one closed at `nowMs` (a take that ends while paused). */
  spans(nowMs: number): RecordingPauseSpan[] {
    if (this.open) this.closeSpan(nowMs);
    return [...this.closed];
  }

  private closeSpan(nowMs: number): void {
    if (this.pausedAtMs !== null) this.pausedTotalMs += Math.max(0, nowMs - this.pausedAtMs);
    this.pausedAtMs = null;
    if (!this.open) return;
    this.closed.push({
      start_ms: Math.max(0, this.open.startMs - this.startedAtMs),
      end_ms: Math.max(0, nowMs - this.startedAtMs),
      audio_offset_ms: toMs(this.open.cutAtBytes ?? this.admittedBytes),
      dropped_ms: toMs(this.open.droppedBytes),
    });
    this.open = null;
  }
}
