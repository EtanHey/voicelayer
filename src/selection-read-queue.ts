import { cancelQueuedSpeech } from "./speech-archive-live";
/**
 * QUEUE1 (Etan, 2026-10-20): Option+F5 on a different selection while VoiceBar reads one appends it here.
 * Only the user's Option+F5 reads live in this queue; agent voice_speak keeps the tts.ts priority queue.
 * Queued text and its private ingress context are never published: the pill sees a count.
 */
import type { StructuredSpeech } from "./tts/structured-speech";
import type { SpeakArchiveContext } from "./speak-archive";

export const SELECTION_READ_QUEUE_LIMIT = 10;

export interface QueuedSelectionRead {
  requestId: string;
  text: string;
  textHash: string;
  profile: "auto" | "short" | "long";
  selectionIdentity?: string;
  archiveContext?: SpeakArchiveContext;
  structuredDisplay?: StructuredSpeech;
}

/** How a read ended. Only `completed` advances; Stop, preemption and player failure never do. */
export type SelectionReadOutcome = "completed" | "stopped" | "failed";

export interface SelectionReadQueueState {
  count: number;
  /** The read the Next button acts on; null unless this chain has queued something. */
  current_request_id: string | null;
}

/** QPRE1: a prepared start (the queue head's first chunk). It is disposed exactly once unless it was
 * transferred into the read's start, which then owns it. */
export interface PreparedSelectionRead { dispose(): void }

/** QPRE1: optional background preparation of the queue head. Speculative only: no playback, no events. */
export interface SelectionReadPreparation<L extends PreparedSelectionRead> {
  /** `owner` is the read now playing; preparation must not compete with its synthesis. */
  prepare(read: QueuedSelectionRead, signal: AbortSignal, owner: string): Promise<L>;
}

interface HeadPreparation<L> {
  requestId: string;
  generation: number;
  controller: AbortController;
  state: "preparing" | "ready" | "failed";
  lease?: L;
}

export class SelectionReadQueue<L extends PreparedSelectionRead = PreparedSelectionRead> {
  private items: QueuedSelectionRead[] = [];
  /** The user's read that owns playback (speaking, preparing or paused) and therefore the queue. */
  private current?: string;
  private currentIdentity?: string;
  private session = false;
  /** F5 interrupted the owner: its queued reads wait for Next, never auto-start. */
  private suspended = false;
  /** QPRE1: only items[0] may own a preparation; the generation fences late results. */
  private preparation?: HeadPreparation<L>;
  private preparationGeneration = 0;

  constructor(
    /** Starts a read, taking over a ready prepared start; throws when it cannot (recording, Ask, TTS off). */
    private readonly start: (read: QueuedSelectionRead, prepared?: L) => void,
    private readonly publish: (state: SelectionReadQueueState) => void,
    private readonly limit = SELECTION_READ_QUEUE_LIMIT,
    private readonly preparer?: SelectionReadPreparation<L>,
  ) {}

  get hasRead(): boolean { return this.current !== undefined; }

  get pendingCount(): number { return this.items.length; }

  admission(identity: string): { kind: "playing"; requestId: string } | { kind: "queued" } | { kind: "new" } {
    if (!this.suspended && this.current && this.currentIdentity === identity) return { kind: "playing", requestId: this.current };
    return { kind: this.items.some(read => read.selectionIdentity === identity) ? "queued" : "new" };
  }

  /** `append` reads queue behind the user's live read; anything else replaces it and forgets the queue.
   * After an F5 interruption a new selection plays now and the retained reads stay queued behind it. */
  submit(read: QueuedSelectionRead, append: boolean): "started" | "queued" | "full" {
    if (this.suspended) {
      this.suspended = false;
      this.launch(read);
      return "started";
    }
    if (append && this.current !== undefined) {
      if (this.items.length >= this.limit) return "full";
      this.items.push(read);
      this.session = true;
      this.emit();
      this.prepareHead();
      return "queued";
    }
    this.clear();
    this.launch(read);
    return "started";
  }

  /** Next acts only on the read it was shown for; on the last item it stops (the caller stops playback). */
  next(requestId: string): "advanced" | "stopped" | "stale" {
    if (!requestId || requestId !== this.current) return "stale";
    this.suspended = false;
    const following = this.items.shift();
    if (!following) { this.clear(); return "stopped"; }
    try { this.launch(following); } catch { this.clear(); return "stopped"; }
    return "advanced";
  }

  /** A direct (non-queue) Option+F5 start owns the queue. It replaces the chain, except after F5, when the
   * retained reads stay queued behind it. The caller starts the read itself. */
  own(requestId: string, identity?: string): void {
    if (this.suspended) this.suspended = false;
    else this.clear();
    this.current = requestId;
    this.currentIdentity = identity;
    if (this.session) this.emit();
    // Deferred: the caller starts this read right after own() returns.
    this.prepareHead();
  }

  /** F5 over the playing owner: the caller stops it; queued reads are kept for an explicit Next.
   * Speculative preparation is dropped (the text stays) and resumes only with a user read. */
  suspend(): void {
    if (this.current === undefined || !this.items.length) { this.clear(); return; }
    this.suspended = true;
    this.discardPreparation();
  }

  /** A read ended. A natural end advances; Stop, preemption or failure ends the whole queue. */
  settled(requestId: string, outcome: SelectionReadOutcome): void {
    if (requestId !== this.current || this.suspended) return;
    this.current = undefined;
    const following = outcome === "completed" ? this.items.shift() : undefined;
    if (!following) { this.clear(); return; }
    try { this.launch(following); } catch { this.clear(); }
  }

  /** Stop means stop: forget every queued read and the current owner. */
  clear(): void {
    const changed = this.session || this.items.length > 0;
    this.discardPreparation();
    for (const read of this.items) {
      if (!read.archiveContext) continue;
      cancelQueuedSpeech(read.archiveContext);
    }
    this.items = [];
    this.current = undefined;
    this.currentIdentity = undefined;
    this.session = false;
    this.suspended = false;
    if (changed) this.emit();
  }

  private launch(read: QueuedSelectionRead): void {
    // Own the queue before starting: the start preempts the old read, whose settle is then stale.
    this.current = read.requestId;
    this.currentIdentity = read.selectionIdentity;
    const prepared = this.takePrepared(read);
    try { prepared ? this.start(read, prepared) : this.start(read); } catch (error) {
      prepared?.dispose();
      this.current = undefined;
      throw error;
    }
    if (this.session) this.emit();
    this.prepareHead();
  }

  /** Transfer a READY preparation for exactly this read; anything else is aborted and disposed.
   * A start never waits on preparation still in flight: it synthesizes normally. */
  private takePrepared(read: QueuedSelectionRead): L | undefined {
    const preparation = this.preparation;
    if (preparation?.requestId === read.requestId && preparation.state === "ready" && preparation.lease) {
      this.preparation = undefined;
      return preparation.lease;
    }
    this.discardPreparation();
    return undefined;
  }

  private discardPreparation(): void {
    const preparation = this.preparation;
    this.preparation = undefined;
    if (!preparation) return;
    preparation.controller.abort();
    preparation.lease?.dispose();
  }

  /** Prepare items[0] only (never C), once the current owner is established and not suspended. */
  private prepareHead(): void {
    const head = this.items[0];
    const owner = this.current;
    if (!this.preparer || !head || owner === undefined || this.suspended) return;
    if (this.preparation?.requestId === head.requestId) return;
    this.discardPreparation();
    const preparation: HeadPreparation<L> = { requestId: head.requestId, generation: ++this.preparationGeneration,
      controller: new AbortController(), state: "preparing" };
    this.preparation = preparation;
    const { signal } = preparation.controller;
    const live = () => this.preparation === preparation && preparation.generation === this.preparationGeneration && !signal.aborted;
    void (async () => {
      await Promise.resolve(); // Never inside submit/own/launch: the owner's start happens first.
      if (!live()) return;
      try {
        const lease = await this.preparer!.prepare(head, signal, owner);
        // Generation fence: a result after clear/suspend/replacement is disposed, never transferred.
        if (!live()) { lease.dispose(); return; }
        preparation.lease = lease;
        preparation.state = "ready";
      } catch {
        if (this.preparation === preparation) preparation.state = "failed";
      }
    })();
  }

  private emit(): void {
    this.publish({ count: this.items.length, current_request_id: this.session ? this.current ?? null : null });
  }
}
