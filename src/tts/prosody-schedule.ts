import { PROSODY_SYNTH_CONCURRENCY, type ProsodyPlan, type ProsodySegment } from "./prosody";

export interface SegmentSchedulerOptions<T> {
  signal: AbortSignal;
  concurrency?: number;
  /** Chunks after the requested one whose segments are queued at the same time. */
  lookahead?: number;
  /** Releases a result that was synthesized but never handed out. */
  dispose?(result: T): void;
}
export interface SegmentScheduler<T> {
  /** Chunk `index`'s segment results, in order. Also queues the next `lookahead` chunks. */
  chunk(index: number): Promise<T[]>;
  /** Every started engine request has settled: reap before history or disposal. */
  settled(): Promise<void>;
  /** Starts nothing more, waits for in-flight requests, disposes results never handed out. */
  close(): Promise<void>;
}

interface Task<T> { promise: Promise<T>; resolve(value: T): void; reject(error: unknown): void; started: boolean; result?: { value: T } }

/** One read's engine requests: started strictly in segment order, at most `concurrency` at once.
 * Queued requests never start after abort, failure or close; their chunks reject instead. */
export function createSegmentScheduler<T>(
  plan: Pick<ProsodyPlan, "segments" | "chunks">,
  synthesize: (segment: ProsodySegment, index: number, signal: AbortSignal) => Promise<T>,
  { signal, concurrency = PROSODY_SYNTH_CONCURRENCY, lookahead = 2, dispose }: SegmentSchedulerOptions<T>,
): SegmentScheduler<T> {
  const tasks: Task<T>[] = [];
  const inFlight = new Set<Promise<unknown>>();
  const handedOut = new Set<number>();
  let next = 0, running = 0, stopped: unknown;
  const stop = (reason: unknown) => {
    if (stopped !== undefined) return;
    stopped = reason;
    for (const task of tasks.slice(next)) task.reject(reason);
  };
  const abort = () => stop(signal.reason ?? new Error("Synthesis cancelled"));
  if (signal.aborted) abort(); else signal.addEventListener("abort", abort, { once: true });

  const enqueue = (through: number) => {
    while (tasks.length < Math.min(through, plan.segments.length)) {
      let resolve!: (value: T) => void, reject!: (error: unknown) => void;
      const promise = new Promise<T>((a, b) => { resolve = a; reject = b; });
      promise.catch(() => {});
      tasks.push({ promise, resolve, reject, started: false });
      if (stopped !== undefined) reject(stopped);
    }
  };
  const pump = () => {
    while (stopped === undefined && running < concurrency && next < tasks.length) {
      const index = next++, task = tasks[index];
      task.started = true; running++;
      const run = synthesize(plan.segments[index], index, signal).then(
        (value) => { task.result = { value }; task.resolve(value); },
        (error) => { task.reject(error); stop(new Error("Synthesis stopped after an earlier failure")); },
      ).finally(() => { running--; inFlight.delete(run); pump(); });
      inFlight.add(run);
    }
  };

  return {
    chunk(index) {
      const chunk = plan.chunks[index];
      if (!chunk) return Promise.reject(new Error(`No prosody chunk ${index}`));
      enqueue(plan.chunks[Math.min(index + lookahead, plan.chunks.length - 1)].end);
      pump();
      for (let i = chunk.first; i < chunk.end; i++) handedOut.add(i);
      return Promise.all(tasks.slice(chunk.first, chunk.end).map((task) => task.promise));
    },
    async settled() {
      while (inFlight.size) await Promise.allSettled([...inFlight]);
    },
    async close() {
      stop(new Error("Synthesis closed"));
      await this.settled();
      tasks.forEach((task, index) => {
        if (task.result && !handedOut.has(index)) { const { value } = task.result; task.result = undefined; dispose?.(value); }
      });
    },
  };
}
