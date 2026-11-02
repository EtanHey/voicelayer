/** Independent mic ownership and FIFO transcription/delivery for bar dictation. */
export interface RecordingTake<Target> {
  readonly id: string;
  readonly kind: "live" | "history";
  readonly target: Target;
  readonly signal: AbortSignal;
}

interface TakeEntry<Target> {
  take: RecordingTake<Target>;
  cancellation: AbortController;
  phase: "capturing" | "draining" | "queued" | "processing";
}

export interface RecordingTakeWork<Archive, Text, Target> {
  /** Must settle only when the recorder process no longer owns the microphone. */
  recorderExited: Promise<void>;
  /** Persist the complete recording even when this take was cancelled. */
  archive: () => Promise<Archive>;
  transcribe: (archive: Archive, signal: AbortSignal) => Promise<Text>;
  /** Resolve after paste delivery settles, so the next take cannot overtake it. */
  deliver: (text: Text, take: RecordingTake<Target>) => Promise<void>;
}

export class RecordingTakeQueue<Target> {
  private capture: TakeEntry<Target> | undefined;
  private readonly entries = new Map<RecordingTake<Target>, TakeEntry<Target>>();
  private readonly usedIds = new Set<string>();
  private tail: Promise<void> = Promise.resolve();

  constructor(private readonly changed: () => void = () => {}) {}

  get jobs() {
    return [...this.entries.values()].map(({ take, phase }) => ({ take, phase }));
  }

  get snapshot(): { microphone: "free" | "capturing" | "draining"; processingCount: number } {
    return {
      microphone: this.capture?.phase === "capturing" ? "capturing"
        : this.capture ? "draining" : "free",
      processingCount: [...this.entries.values()].filter(
        entry => entry.phase === "queued" || entry.phase === "processing",
      ).length,
    };
  }

  beginCapture(id: string, target: Target): RecordingTake<Target> {
    if (!id.trim() || this.usedIds.has(id)) throw new Error("Take identity must be new and nonempty");
    if (this.capture) throw new Error("Recording already in progress");
    const cancellation = new AbortController();
    const take: RecordingTake<Target> = Object.freeze({ id, kind: "live", target, signal: cancellation.signal });
    const entry: TakeEntry<Target> = { take, cancellation, phase: "capturing" };
    this.capture = entry;
    this.entries.set(take, entry);
    this.usedIds.add(id);
    this.changed();
    return take;
  }

  cancel(take: RecordingTake<Target>): boolean {
    const entry = this.entries.get(take);
    if (!entry) return false;
    entry.cancellation.abort();
    return true;
  }

  async finishCapture<Archive, Text>(
    take: RecordingTake<Target>,
    work: RecordingTakeWork<Archive, Text, Target>,
  ): Promise<void> {
    const entry = this.entries.get(take);
    if (!entry || this.capture !== entry || entry.phase !== "capturing") {
      throw new Error("Take does not own capture finalization");
    }
    entry.phase = "draining";
    // Keep captured evidence even when termination failed. Neither failure releases admission.
    const [exit] = await Promise.allSettled([work.recorderExited]);
    const archive = await work.archive();
    if (exit.status === "rejected") throw exit.reason;
    this.capture = undefined;
    entry.phase = "queued";
    this.changed();
    await this.process(entry, archive, work);
  }

  async runHistory<Archive, Text>(id: string, target: Target, archive: Archive,
    work: Pick<RecordingTakeWork<Archive, Text, Target>, "transcribe" | "deliver">): Promise<void> {
    if (!id.trim() || this.usedIds.has(id)) throw new Error("Take identity must be new and nonempty");
    const cancellation = new AbortController();
    const take: RecordingTake<Target> = Object.freeze({ id, kind: "history", target, signal: cancellation.signal });
    const entry: TakeEntry<Target> = { take, cancellation, phase: "queued" };
    this.entries.set(take, entry);
    this.usedIds.add(id);
    this.changed();
    await this.process(entry, archive, work);
  }

  private async process<Archive, Text>(entry: TakeEntry<Target>, archive: Archive,
    work: Pick<RecordingTakeWork<Archive, Text, Target>, "transcribe" | "deliver">): Promise<void> {
    const { take } = entry;
    const settled = this.tail.then(async () => {
      entry.phase = "processing";
      this.changed();
      if (take.signal.aborted) return;
      const text = await work.transcribe(archive, take.signal);
      if (!take.signal.aborted) await work.deliver(text, take);
    });
    this.tail = settled.catch(() => {});
    try { await settled; }
    finally { this.entries.delete(take); this.changed(); }
  }
}
