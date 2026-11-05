import { AsyncLocalStorage } from "node:async_hooks";

export type TakeStage = "decode" | "dictionary_rules" | "polish" | "gates" | "delivery";

/** Milliseconds of wall time, exclusive of nested stages. Zero means skipped or below the clock resolution. */
export class TakeStageTimings {
  private readonly values = { capture_end_to_decode: 0, decode: 0, dictionary_rules: 0, polish: 0, gates: 0, delivery: 0 };
  private captureEnd: number | undefined;
  private decodeStarted = false;

  constructor(private readonly now: () => number = () => performance.now()) {}

  captureEnded(): void { this.captureEnd ??= this.now(); }

  begin(stage: TakeStage): number {
    const start = this.now();
    if (stage === "decode" && !this.decodeStarted) {
      this.decodeStarted = true;
      this.values.capture_end_to_decode = Math.max(0, start - (this.captureEnd ?? start) - this.values.gates);
    }
    return start;
  }

  finish(stage: TakeStage, start: number, nested: number): number {
    const elapsed = Math.max(0, this.now() - start);
    this.values[stage] += Math.max(0, elapsed - nested);
    return elapsed;
  }

  snapshot() {
    const total = Math.max(0, this.now() - (this.captureEnd ?? this.now()));
    return { ...this.values,
      capture_end_to_decode: this.decodeStarted ? this.values.capture_end_to_decode : Math.max(0, total - this.values.gates),
      total };
  }
}

type Frame = { take: TakeStageTimings; nested: number };
const context = new AsyncLocalStorage<Frame>();

export function withTakeStageTimings<T>(take: TakeStageTimings, run: () => T): T {
  return context.run({ take, nested: 0 }, run);
}

export function measureTakeStage<T>(stage: TakeStage, run: () => T): T {
  const parent = context.getStore();
  if (!parent) return run();
  const frame: Frame = { take: parent.take, nested: 0 };
  const start = frame.take.begin(stage);
  try { return context.run(frame, run); }
  finally { parent.nested += frame.take.finish(stage, start, frame.nested); }
}

export async function measureTakeStageAsync<T>(stage: TakeStage, run: () => Promise<T>): Promise<T> {
  const parent = context.getStore();
  if (!parent) return run();
  const frame: Frame = { take: parent.take, nested: 0 };
  const start = frame.take.begin(stage);
  try { return await context.run(frame, run); }
  finally { parent.nested += frame.take.finish(stage, start, frame.nested); }
}
