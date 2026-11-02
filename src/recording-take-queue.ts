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
  phase: "capturing" | "draining" | "queued" | "processing" | "delivering" | "failed";
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
  private blockedCapture: TakeEntry<Target> | undefined;
  private tail: Promise<void> = Promise.resolve();

  constructor(private readonly changed: () => void = () => {}) {}

  get jobs() {
    return [...this.entries.values()].map(({ take, phase }) => ({ take, phase }));
  }

  get snapshot(): { microphone: "free" | "capturing" | "draining" | "blocked"; processingCount: number } {
    return {
      microphone: this.blockedCapture ? "blocked" : this.capture?.phase === "capturing" ? "capturing"
        : this.capture ? "draining" : "free",
      processingCount: [...this.entries.values()].filter(
        entry => entry.phase === "queued" || entry.phase === "processing" || entry.phase === "delivering",
      ).length,
    };
  }

  beginCapture(id: string, target: Target): RecordingTake<Target> {
    if (!id.trim() || this.usedIds.has(id)) throw new Error("Take identity must be new and nonempty");
    if (this.capture || this.blockedCapture) throw new Error("Recording already in progress");
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

  beginDelivery(take: RecordingTake<Target>): void {
    const entry = this.entries.get(take);
    if (!entry || entry.phase !== "processing") return;
    entry.phase = "delivering";
    this.changed();
  }

  beginDrain(take: RecordingTake<Target>): void {
    if (this.capture?.take !== take || this.capture.phase !== "capturing") return;
    this.capture.phase = "draining";
    this.changed();
  }

  ownsCapture(take: RecordingTake<Target>): boolean { return this.capture?.take === take; }

  /** Failed work never continues to advertise recording. Unknown physical exit blocks new admission visibly. */
  async failCapture(take: RecordingTake<Target>, exit: Promise<void>, timeoutMs: number): Promise<void> {
    const entry = this.capture;
    if (!entry || entry.take !== take) return;
    entry.phase = "failed";
    entry.cancellation.abort();
    this.capture = undefined;
    this.blockedCapture = entry;
    this.changed();
    const clear = () => {
      if (this.blockedCapture !== entry) return;
      this.blockedCapture = undefined;
      this.entries.delete(take);
      this.changed();
    };
    void exit.then(clear, () => {});
    try { await boundedSettlement(exit, timeoutMs); clear(); } catch { /* explicit failed snapshot remains until exit proof */ }
  }

  async finishCapture<Archive, Text>(
    take: RecordingTake<Target>,
    work: RecordingTakeWork<Archive, Text, Target>,
  ): Promise<void> {
    const entry = this.entries.get(take);
    if (!entry || this.capture !== entry || !["capturing", "draining"].includes(entry.phase)) {
      throw new Error("Take does not own capture finalization");
    }
    entry.phase = "draining";
    // Keep captured evidence even when termination failed. Neither failure releases admission.
    const [exit] = await Promise.allSettled([boundedSettlement(work.recorderExited, 5000)]);
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

/** No ownership wait can depend forever on a missing completion callback. */
export async function boundedSettlement<T>(work: Promise<T>, timeoutMs: number): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([work, new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error("Recording completion could not be confirmed")), timeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}
