import { describe, expect, it } from "bun:test";
import { runLongRead, type LongReadChunk, type LongReadDependencies } from "../tts/long-read";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}
const tick = () => Bun.sleep(0);
const chunk = (i: number): LongReadChunk => ({ audioFile: `${i}.mp3`, durationMs: 1000, wordBoundaries: [] });

function fixture() {
  const controller = new AbortController();
  const synths: number[] = [], plays: number[] = [], disposed: number[] = [];
  const synthesis = Array.from({ length: 3 }, () => deferred<LongReadChunk>());
  const playback = Array.from({ length: 3 }, () => deferred<any>());
  const started = Array.from({ length: 3 }, () => deferred<boolean>());
  let saved: any[] = [];
  const deps: LongReadDependencies = {
    synthesize: (_text, i, signal) => { expect(signal).toBe(controller.signal); synths.push(i); return synthesis[i].promise; },
    play: (_chunk, _text, info) => { plays.push(info.chunk_index); return { started: started[info.chunk_index].promise, exited: playback[info.chunk_index].promise }; },
    saveHistory: async (played) => { saved = [...played]; },
    dispose: (_chunk, i) => { disposed.push(i); },
  };
  const done = () => runLongRead(["One.", "Two.", "Three."], "read-id", controller.signal, deps);
  return { controller, synths, plays, disposed, synthesis, playback, started, done, saved: () => saved };
}

describe("long-read pipeline", () => {
  it("starts chunk zero before synthesizing later chunks, with only one chunk of lookahead", async () => {
    const f = fixture(); const done = f.done();
    expect(f.synths).toEqual([0]);
    f.synthesis[0].resolve(chunk(0)); await tick();
    expect(f.plays).toEqual([0]); expect(f.synths).toEqual([0]);
    f.started[0].resolve(true); await tick();
    expect(f.synths).toEqual([0, 1]);
    f.synthesis[1].resolve(chunk(1)); await tick();
    expect(f.plays).toEqual([0]); expect(f.synths).toEqual([0, 1]);
    f.playback[0].resolve({ status: "completed", stopped_at_ms: 1000 }); await tick();
    expect(f.plays).toEqual([0, 1]);
    f.started[1].resolve(true); await tick(); f.synthesis[2].resolve(chunk(2));
    f.playback[1].resolve({ status: "completed", stopped_at_ms: 1000 }); await tick();
    f.started[2].resolve(true); f.playback[2].resolve({ status: "completed", stopped_at_ms: 1000 });
    await done;
    expect(f.plays).toEqual([0, 1, 2]); expect(f.saved()).toHaveLength(3);
    expect(f.disposed.sort()).toEqual([0, 1, 2]);
  });

  it("stop during chunk-one synthesis prevents every later playback even when synthesis ignores abort", async () => {
    const f = fixture(); const done = f.done();
    f.synthesis[0].resolve(chunk(0)); await tick(); f.started[0].resolve(true); await tick();
    expect(f.synths).toEqual([0, 1]);
    f.controller.abort(); f.playback[0].resolve({ status: "interrupted", stopped_at_ms: 230 });
    f.synthesis[1].resolve(chunk(1)); await done;
    expect(f.plays).toEqual([0]); expect(f.synths).toEqual([0, 1]);
    expect(f.saved().map((p) => p.playedMs)).toEqual([230]);
    expect(f.disposed.sort()).toEqual([0, 1]);
  });

  it("stop before first synthesis completes produces no playback or history", async () => {
    const f = fixture(); const done = f.done(); f.controller.abort(); f.synthesis[0].resolve(chunk(0));
    await done; expect(f.plays).toEqual([]); expect(f.saved()).toEqual([]); expect(f.disposed).toEqual([0]);
  });

  it("a player refusal ends the pipeline without synthesizing ahead", async () => {
    const f = fixture(); const done = f.done(); f.synthesis[0].resolve(chunk(0)); await tick();
    f.started[0].resolve(false); f.playback[0].resolve({ status: "failed", stopped_at_ms: 0 });
    await done; expect(f.synths).toEqual([0]); expect(f.saved()).toEqual([]);
  });
});
