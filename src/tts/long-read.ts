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
}
export interface LongReadDependencies {
  synthesize(text: string, index: number, signal: AbortSignal): Promise<LongReadChunk>;
  play(chunk: LongReadChunk, text: string, info: NonNullable<StateEvent["long_read"]>): {
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
  let offsetMs = 0;

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
    for (let index = 0; index < texts.length; index++) {
      const result = await ready.get(index)!;
      ready.delete(index);
      if (signal.aborted) break;
      if ("error" in result) throw result.error;
      // Fence enqueue here; the player/decoder must also enforce its own stop ownership.
      const playback = deps.play(result.chunk, texts[index], {
        id, chunk_index: index, chunk_count: texts.length, chunk_start_ms: offsetMs,
      });
      const started = await playback.started;
      const outcome = await playback.exited;
      if (started) {
        const playedMs = outcome.status === "completed"
          ? result.chunk.durationMs
          : Math.max(0, Math.min(result.chunk.durationMs, outcome.stopped_at_ms));
        if (playedMs > 0) played.push({ chunk: result.chunk, text: texts[index], playedMs });
      }
      if (signal.aborted || outcome.status !== "completed") break;
      offsetMs += result.chunk.durationMs;
      currentIndex = index + 1;
      pump();
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
