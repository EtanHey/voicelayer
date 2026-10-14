import type { PlaybackOutcomeEvent, StateEvent, WordBoundary } from "../socket-protocol";

export interface LongReadChunk {
  audioFile: string;
  durationMs: number;
  wordBoundaries: WordBoundary[];
}
export interface PlayedChunk {
  chunk: LongReadChunk;
  text: string;
  playedMs: number;
  startMs?: number;
}
export interface SeekResult {
  outcome: "accept" | "noop" | "reject";
  reason?: string;
  offset_ms?: number;
  clamped?: boolean;
}
export interface LongReadSeek { seek(offsetMs: number): SeekResult }

export interface LongReadDependencies {
  registerSeek?(control: LongReadSeek): void;
  synthesize(text: string, index: number, signal: AbortSignal): Promise<LongReadChunk>;
  play(chunk: LongReadChunk, text: string, info: NonNullable<StateEvent["long_read"]>, position: { offsetMs: number; durationMs: number; getDurationMs(): number }): {
    interrupt?(): void;
    started: Promise<boolean>;
    exited: Promise<Pick<PlaybackOutcomeEvent, "status" | "stopped_at_ms">>;
  };
  saveHistory(played: PlayedChunk[]): Promise<void>;
  dispose(chunk: LongReadChunk, index: number): void;
}

type Synthesis = { chunk: LongReadChunk } | { error: unknown };

/** One playing/preparing chunk plus bounded lookahead, with one synthesis in flight. */
export async function runLongRead(
  texts: string[], id: string, signal: AbortSignal, deps: LongReadDependencies, lookahead: 1 | 2 = 1,
): Promise<void> {
  const owned = new Map<number, LongReadChunk>();
  const ready = new Map<number, Promise<Synthesis>>();
  const played: PlayedChunk[] = [];
  let inFlight: Promise<Synthesis> | undefined;
  let currentIndex = 0;
  let nextIndex = 0;
  let closing = false;
  let synthesisFailed = false;
  let localOffsetMs = 0;
  let target: { index: number; local: number } | undefined;
  let playback: ReturnType<LongReadDependencies["play"]> | undefined;
  let wake!: () => void;
  let changed = new Promise<void>((resolve) => { wake = resolve; });
  const duration = () => [...owned.values()].reduce((total, chunk) => total + chunk.durationMs, 0);
  const chunkStart = (index: number) => [...owned.entries()].reduce((total, [i, chunk]) => total + (i < index ? chunk.durationMs : 0), 0);
  deps.registerSeek?.({ seek: (offsetMs) => {
    if (!Number.isFinite(offsetMs) || offsetMs < 0) return { outcome: "reject", reason: "invalid offset" };
    if (closing || signal.aborted || owned.size === 0) return { outcome: "noop", reason: "nothing playing" };
    const total = duration(), offset = Math.min(offsetMs, total);
    let index = 0, local = offset;
    while (index < owned.size - 1 && local >= owned.get(index)!.durationMs) {
      local -= owned.get(index)!.durationMs; index++;
    }
    target = { index, local };
    playback?.interrupt?.(); wake();
    return { outcome: "accept", offset_ms: offset, clamped: offsetMs > total };
  } });

  const pump = () => {
    if (closing || signal.aborted || synthesisFailed || inFlight ||
        nextIndex >= texts.length || nextIndex > currentIndex + lookahead) return;
    const index = nextIndex++;
    // Handle rejection immediately, even while the consumer is preparing/playing.
    const synthesis: Promise<Synthesis> = deps.synthesize(texts[index], index, signal).then(
      (chunk) => { owned.set(index, chunk); return { chunk }; },
      (error) => ({ error }),
    );
    ready.set(index, synthesis);
    inFlight = synthesis;
    void synthesis.then((result) => {
      inFlight = undefined;
      if ("error" in result) synthesisFailed = true;
      // Refill at synthesis completion, never wait for the player's started signal.
      pump();
    });
  };

  try {
    if (signal.aborted || texts.length === 0) return;
    pump();
    while (currentIndex < texts.length && !signal.aborted) {
      if (target) {
        currentIndex = target.index; localOffsetMs = target.local; target = undefined;
        changed = new Promise<void>((resolve) => { wake = resolve; });
      }
      pump();
      const index = currentIndex;
      const result = await Promise.race([ready.get(index)!, changed.then(() => undefined)]);
      if (signal.aborted) break;
      if (target || !result) continue;
      if ("error" in result) throw result.error;
      if (localOffsetMs >= result.chunk.durationMs) {
        currentIndex = index + 1; localOffsetMs = 0; continue;
      }
      const offsetMs = chunkStart(index);
      playback = deps.play(result.chunk, texts[index], {
        id, chunk_index: index, chunk_count: texts.length, chunk_start_ms: offsetMs,
      }, { offsetMs: localOffsetMs, durationMs: duration(), getDurationMs: duration });
      const started = await playback.started;
      const outcome = await playback.exited;
      playback = undefined;
      if (started) {
        const endMs = outcome.status === "completed" ? result.chunk.durationMs
          : Math.max(0, Math.min(result.chunk.durationMs, outcome.stopped_at_ms));
        const playedMs = Math.max(0, endMs - localOffsetMs);
        if (playedMs > 0) played.push({ chunk: result.chunk, text: texts[index], playedMs,
          ...(localOffsetMs ? { startMs: localOffsetMs } : {}) });
      }
      if (signal.aborted) break;
      if (target) continue;
      if (outcome.status !== "completed") break;
      currentIndex = index + 1; localOffsetMs = 0;
    }
  } finally {
    closing = true;
    // Reap the owned synthesis before history/disposal; a late result is never played.
    if (inFlight) await inFlight;
    try {
      if (played.length > 0) await deps.saveHistory(played);
    } finally {
      for (const [index, chunk] of owned) deps.dispose(chunk, index);
    }
  }
}
