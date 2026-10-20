/**
 * QUEUE1 (Etan, 2026-10-20): Option+F5 on a different selection while VoiceBar reads one appends it here.
 * Only the user's Option+F5 reads live in this queue; agent voice_speak keeps the tts.ts priority queue.
 * Queued text is held in memory only and never logged or published: the pill sees a count.
 */
export const SELECTION_READ_QUEUE_LIMIT = 10;

export interface QueuedSelectionRead {
  requestId: string;
  text: string;
  textHash: string;
  profile: "auto" | "short" | "long";
}

export interface SelectionReadQueueState {
  count: number;
  /** The read the Next button acts on; null unless this chain has queued something. */
  current_request_id: string | null;
}

export class SelectionReadQueue {
  private items: QueuedSelectionRead[] = [];
  /** The user's read that owns playback (speaking, preparing or paused) and therefore the queue. */
  private current?: string;
  private session = false;

  constructor(
    /** Starts a read; throws when it cannot (recording, Ask, TTS off). */
    private readonly start: (read: QueuedSelectionRead) => void,
    private readonly publish: (state: SelectionReadQueueState) => void,
    private readonly limit = SELECTION_READ_QUEUE_LIMIT,
  ) {}

  get pendingCount(): number { return this.items.length; }

  /** `append` reads queue behind the user's live read; anything else replaces it and forgets the queue. */
  submit(read: QueuedSelectionRead, append: boolean): "started" | "queued" | "full" {
    if (append && this.current !== undefined) {
      if (this.items.length >= this.limit) return "full";
      this.items.push(read);
      this.session = true;
      this.emit();
      return "queued";
    }
    this.clear();
    this.launch(read);
    return "started";
  }

  /** Next acts only on the read it was shown for; on the last item it stops (the caller stops playback). */
  next(requestId?: string): "advanced" | "stopped" | "stale" {
    if (this.current === undefined || (requestId !== undefined && requestId !== this.current)) return "stale";
    const following = this.items.shift();
    if (!following) { this.clear(); return "stopped"; }
    try { this.launch(following); } catch { this.clear(); return "stopped"; }
    return "advanced";
  }

  /** A read ended. A natural end advances; Stop, preemption or failure ends the whole queue. */
  settled(requestId: string, stopped: boolean): void {
    if (requestId !== this.current) return;
    this.current = undefined;
    const following = stopped ? undefined : this.items.shift();
    if (!following) { this.clear(); return; }
    try { this.launch(following); } catch { this.clear(); }
  }

  /** Stop means stop: forget every queued read and the current owner. */
  clear(): void {
    const changed = this.session || this.items.length > 0;
    this.items = [];
    this.current = undefined;
    this.session = false;
    if (changed) this.emit();
  }

  private launch(read: QueuedSelectionRead): void {
    // Own the queue before starting: the start preempts the old read, whose settle is then stale.
    this.current = read.requestId;
    try { this.start(read); } catch (error) { this.current = undefined; throw error; }
    if (this.session) this.emit();
  }

  private emit(): void {
    this.publish({ count: this.items.length, current_request_id: this.session ? this.current ?? null : null });
  }
}
