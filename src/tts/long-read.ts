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
export interface LongReadSeek { seek(offsetMs: number): SeekResult; restart(): SeekResult }

export interface LongReadDependencies {
  initialOffsetMs?: number;
  registerSeek?(control: LongReadSeek): void;
  canReplay?(chunk: LongReadChunk): boolean;
  prepareSeek?(chunk: LongReadChunk, offsetMs: number, signal: AbortSignal): Promise<string | undefined>;
  disposeSeek?(file?: string): void;
  seekFailed?(error: unknown): void;
  synthesize(text: string, index: number, signal: AbortSignal): Promise<LongReadChunk>;
  play(chunk: LongReadChunk, text: string, info: NonNullable<StateEvent["long_read"]>, position: { offsetMs: number; durationMs: number; getDurationMs(): number; isSeek?: boolean; sliceFile?: string }): {
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
  let localOffsetMs = deps.initialOffsetMs ?? 0;
  let initialSeek = localOffsetMs > 0;
  let target: { index: number; local: number; sliceFile?: string } | undefined;
  let playback: ReturnType<LongReadDependencies["play"]> | undefined;
  let seeking: AbortController | undefined;
  const conversions = new Set<Promise<void>>();
  let seekFile: string | undefined;
  let isSeek = false;
  let wake!: () => void;
  let changed = new Promise<void>((resolve) => { wake = resolve; });
  const duration = () => [...owned.values()].reduce((total, chunk) => total + chunk.durationMs, 0);
  const chunkStart = (index: number) => [...owned.entries()].reduce((total, [i, chunk]) => total + (i < index ? chunk.durationMs : 0), 0);
  const seek = (offsetMs: number, replay = false): SeekResult => {
    if (!Number.isFinite(offsetMs) || offsetMs < 0) return { outcome: "reject", reason: "invalid offset" };
    if (closing || signal.aborted) return { outcome: "noop", reason: "nothing playing" };
    if (replay) {
      for (let i = 0; i <= currentIndex; i++) {
        const chunk = owned.get(i);
        if (!chunk || deps.canReplay?.(chunk) === false) return { outcome: "reject", reason: "Replay prefix audio unavailable" };
      }
    }
    if (owned.size === 0) return { outcome: "noop", reason: "not ready" };
    const total = duration(), offset = Math.min(offsetMs, total);
    let index = 0, local = offset;
    while (index < owned.size - 1 && local >= owned.get(index)!.durationMs) {
      local -= owned.get(index)!.durationMs; index++;
    }
    seeking?.abort(); seeking = undefined;
    const apply = (sliceFile?: string) => {
      // A committed cursor must survive while a newer conversion is pending.
      // Replacing it early could turn its interrupted player into a read stop.
      deps.disposeSeek?.(target?.sliceFile);
      target = { index, local, sliceFile };
      playback?.interrupt?.(); wake();
    };
    // Global zero reuses the retained original; no asynchronous slice can overtake Stop.
    if (replay || !deps.prepareSeek) apply();
    else {
      const preparation = new AbortController(); seeking = preparation;
      const conversion = (async () => {
        try {
          const slice = await deps.prepareSeek!(owned.get(index)!, local, AbortSignal.any([signal, preparation.signal]));
          if (seeking !== preparation || closing || signal.aborted) { deps.disposeSeek?.(slice); return; }
          seeking = undefined; apply(slice);
        } catch (error) {
          if (seeking === preparation) {
            seeking = undefined;
            if (!signal.aborted && !closing) deps.seekFailed?.(error);
          }
        }
      })();
      conversions.add(conversion);
      void conversion.then(() => conversions.delete(conversion));
    }
    return { outcome: "accept", offset_ms: offset, clamped: offsetMs > total };
  };
  deps.registerSeek?.({ seek, restart: () => seek(0, true) });

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
        deps.disposeSeek?.(seekFile);
        currentIndex = target.index; localOffsetMs = target.local; seekFile = target.sliceFile; isSeek = true; target = undefined;
        initialSeek = false;
        changed = new Promise<void>((resolve) => { wake = resolve; });
      }
      pump();
      const index = currentIndex;
      const result = await Promise.race([ready.get(index)!, changed.then(() => undefined)]);
      if (signal.aborted) break;
      if (target || !result) continue;
      if ("error" in result) throw result.error;
      if (localOffsetMs >= result.chunk.durationMs) {
        deps.disposeSeek?.(seekFile); seekFile = undefined; isSeek = false;
        currentIndex = index + 1; localOffsetMs -= result.chunk.durationMs; continue;
      }
      if (initialSeek) {
        seekFile = await deps.prepareSeek?.(result.chunk, localOffsetMs, signal);
        if (signal.aborted) break;
        isSeek = true; initialSeek = false;
        if (target) { deps.disposeSeek?.(seekFile); seekFile = undefined; continue; }
      }
      const offsetMs = chunkStart(index);
      playback = deps.play(result.chunk, texts[index], {
        id, chunk_index: index, chunk_count: texts.length, chunk_start_ms: offsetMs,
      }, { offsetMs: localOffsetMs, durationMs: duration(), getDurationMs: duration, isSeek, sliceFile: seekFile });
      seekFile = undefined; // Successful enqueue transfers slice ownership to the player.
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
      currentIndex = index + 1; localOffsetMs = 0; isSeek = false;
    }
  } finally {
    closing = true;
    seeking?.abort();
    await Promise.all([...conversions]);
    deps.disposeSeek?.(seekFile);
    deps.disposeSeek?.(target?.sliceFile);
    // Reap the owned synthesis before history/disposal; a late result is never played.
    if (inFlight) await inFlight;
    try {
      if (played.length > 0) await deps.saveHistory(played);
    } finally {
      for (const [index, chunk] of owned) deps.dispose(chunk, index);
    }
  }
}
