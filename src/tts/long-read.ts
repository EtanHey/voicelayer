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

/** One playing chunk + at most one synthesizing/ready chunk. No synthesis backlog. */
export async function runLongRead(texts: string[], id: string, signal: AbortSignal, deps: LongReadDependencies): Promise<void> {
  const owned = new Map<number, LongReadChunk>();
  const played: PlayedChunk[] = [];
  let pending: Promise<Synthesis> | undefined;
  let offsetMs = 0;
  // Attach a rejection handler immediately: lookahead can fail before playback exits.
  const synthesize = (index: number): Promise<Synthesis> =>
    deps.synthesize(texts[index], index, signal).then(
      (chunk) => { owned.set(index, chunk); return { chunk }; },
      (error) => ({ error }),
    );
  try {
    if (signal.aborted || texts.length === 0) return;
    pending = synthesize(0);
    for (let index = 0; index < texts.length; index++) {
      const result = await pending!;
      pending = undefined;
      if (signal.aborted) break;
      if ("error" in result) throw result.error;
      // This check and play are synchronous, so stop cannot slip between them.
      const playback = deps.play(result.chunk, texts[index], {
        id, chunk_index: index, chunk_count: texts.length, chunk_start_ms: offsetMs,
      });
      const started = await playback.started;
      if (started && !signal.aborted && index + 1 < texts.length) {
        pending = synthesize(index + 1);
      }
      const outcome = await playback.exited;
      if (started) {
        const playedMs = outcome.status === "completed"
          ? result.chunk.durationMs
          : Math.max(0, Math.min(result.chunk.durationMs, outcome.stopped_at_ms));
        if (playedMs > 0) played.push({ chunk: result.chunk, text: texts[index], playedMs });
      }
      if (signal.aborted || outcome.status !== "completed") break;
      offsetMs += result.chunk.durationMs;
    }
  } finally {
    // A late result belongs to this generation and must be disposed, never played.
    if (pending) await pending;
    try {
      if (played.length > 0) await deps.saveHistory(played);
    } finally {
      for (const [index, chunk] of owned) deps.dispose(chunk, index);
    }
  }
}
