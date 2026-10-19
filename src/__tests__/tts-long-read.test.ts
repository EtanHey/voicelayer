import { describe, expect, it, jest } from "bun:test";
import { fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";
import { runLongRead, type LongReadChunk, type LongReadDependencies, type PlayedChunk } from "../tts/long-read";

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((r) => { resolve = r; });
  return { promise, resolve };
}
const tick = fixtureCheckpoint;
const chunk = (i: number): LongReadChunk => ({ audioFile: `${i}.mp3`, durationMs: 1000, wordBoundaries: [] });

function fixture() {
  const controller = new AbortController();
  const synths: number[] = [], plays: number[] = [], disposed: number[] = [];
  const synthesis = Array.from({ length: 3 }, () => deferred<LongReadChunk>());
  const playback = Array.from({ length: 3 }, () => deferred<any>());
  const started = Array.from({ length: 3 }, () => deferred<boolean>());
  let saved: any[] = [];
  const synthesized = fixtureBarrier<number>(), played = fixtureBarrier<number>();
  const deps: LongReadDependencies = {
    synthesize: (_text, i, signal) => { expect(signal).toBe(controller.signal); synths.push(i); synthesized.push(i); return synthesis[i].promise; },
    play: (_chunk, _text, info) => { plays.push(info.chunk_index); played.push(info.chunk_index); return { started: started[info.chunk_index].promise, exited: playback[info.chunk_index].promise }; },
    saveHistory: async (played) => { saved = [...played]; },
    dispose: (_chunk, i) => { disposed.push(i); },
  };
  const done = (lookahead = 1) => runLongRead(["One.", "Two.", "Three."], "read-id", controller.signal, deps, lookahead);
  return { controller, synths, plays, disposed, synthesis, playback, started, done, synthesized, played, saved: () => saved };
}

describe("long-read pipeline", () => {
  it("R1-5 synthesizes ahead as soon as a chunk is ready, before the player starts", async () => {
    const f = fixture(); const done = f.done();
    expect(f.synths).toEqual([0]);
    f.synthesis[0].resolve(chunk(0)); await tick();
    expect(f.plays).toEqual([0]); expect(f.synths).toEqual([0, 1]);
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

  it("R1-5 1500ms synthesis is ready when 1000ms playback ends after 800ms preparation", async () => {
    jest.useFakeTimers();
    let done: Promise<void> | undefined;
    try {
      const plays: number[] = [];
      let nextReady = false;
      done = runLongRead(["One.", "Two."], "slow-read", new AbortController().signal, {
        synthesize: (_text, index) => index === 0 ? Promise.resolve(chunk(0)) :
          new Promise((resolve) => setTimeout(() => { nextReady = true; resolve(chunk(index)); }, 1500)),
        play: (_chunk, _text, info) => {
          plays.push(info.chunk_index);
          const started = info.chunk_index === 0 ?
            new Promise<boolean>((resolve) => setTimeout(() => resolve(true), 800)) : Promise.resolve(true);
          const exited = new Promise<{ status: "completed"; stopped_at_ms: number }>((resolve) =>
            setTimeout(() => resolve({ status: "completed", stopped_at_ms: 1000 }), info.chunk_index === 0 ? 1800 : 1000));
          return { started, exited };
        },
        saveHistory: async () => {}, dispose: () => {},
      });
      await fixtureCheckpoint();
      jest.advanceTimersByTime(800); await fixtureCheckpoint();
      expect(plays).toEqual([0]);
      jest.advanceTimersByTime(700); await fixtureCheckpoint();
      expect(nextReady).toBe(true);
      jest.advanceTimersByTime(300); await fixtureCheckpoint();
      expect(plays).toEqual([0, 1]);
      jest.advanceTimersByTime(1000); await done;
    } finally {
      // Reap fake work even on RED: promise continuations can schedule the next timer.
      for (let i = 0; i < 3; i++) { jest.advanceTimersByTime(10000); await fixtureCheckpoint(); }
      await done;
      jest.useRealTimers();
    }
  });

  it("R1-5 clone can fill two chunks ahead while the first player is preparing", async () => {
    const f = fixture(); const done = f.done(2);
    f.synthesis[0].resolve(chunk(0)); await tick(); f.synthesis[1].resolve(chunk(1)); await tick();
    expect(f.synths).toEqual([0, 1, 2]); expect(f.plays).toEqual([0]);
    f.synthesis[2].resolve(chunk(2)); f.started[0].resolve(true); f.playback[0].resolve({ status: "completed", stopped_at_ms: 1000 });
    await f.played.at(1); f.started[1].resolve(true); f.playback[1].resolve({ status: "completed", stopped_at_ms: 1000 });
    await f.played.at(2); f.started[2].resolve(true); f.playback[2].resolve({ status: "completed", stopped_at_ms: 1000 }); await done;
  });

  it("stop during chunk-one synthesis prevents every later playback even when synthesis ignores abort", async () => {
    const f = fixture(); const done = f.done();
    f.synthesis[0].resolve(chunk(0)); await tick(); f.started[0].resolve(true); await tick();
    expect(f.synths).toEqual([0, 1]);
    f.controller.abort(); f.playback[0].resolve({ status: "interrupted", stopped_at_ms: 230 });
    f.synthesis[1].resolve(chunk(1)); await done;
    expect(f.plays).toEqual([0]); expect(f.synths).toEqual([0, 1]);
    // History is the utterance: both synthesized chunks whole, though only 230 ms was heard.
    expect(f.saved().map((p) => p.playedMs)).toEqual([1000, 1000]);
    expect(f.disposed.sort()).toEqual([0, 1]);
  });

  it("stop before first synthesis completes produces no playback or history", async () => {
    const f = fixture(); const done = f.done(); f.controller.abort(); f.synthesis[0].resolve(chunk(0));
    await done; expect(f.plays).toEqual([]); expect(f.saved()).toEqual([]); expect(f.disposed).toEqual([0]);
  });

  it("a player refusal disposes bounded lookahead without playing it", async () => {
    const f = fixture(); const done = f.done(); f.synthesis[0].resolve(chunk(0)); await tick();
    f.synthesis[1].resolve(chunk(1)); f.started[0].resolve(false); f.playback[0].resolve({ status: "failed", stopped_at_ms: 0 });
    await done; expect(f.synths).toEqual([0, 1]); expect(f.plays).toEqual([0]); expect(f.saved()).toEqual([]);
  });
});

describe("REP1 owned long-read restart", () => {
  for (const stop of [false, true]) it(`replaces a pending seek with global zero; Stop=${stop}`, async () => {
    const controller = new AbortController(), plays = fixtureBarrier<any>(), preparations = fixtureBarrier<any>();
    let control: import("../tts/long-read").LongReadSeek;
    const disposed: string[] = [];
    const done = runLongRead(["A", "B"], "replay-owner", controller.signal, {
      registerSeek: value => { control = value; },
      synthesize: async (_text, i) => chunk(i),
      prepareSeek: async () => { const result = deferred<string>(); preparations.push(result); return result.promise; },
      disposeSeek: file => { if (file) disposed.push(file); },
      play: (_chunk, _text, info, position) => {
        const exit = deferred<any>(); plays.push({ info, position, exit });
        return { started: Promise.resolve(true), exited: exit.promise,
          interrupt: () => exit.resolve({ status: "interrupted", stopped_at_ms: 200 }) };
      }, saveHistory: async () => {}, dispose: () => {},
    });
    try {
      await plays.at(0); expect(control!.seek(300).outcome).toBe("accept"); await preparations.at(0);
      expect(control!.restart()).toMatchObject({ outcome: "accept", offset_ms: 0 });
      if (stop) controller.abort();
      preparations.values[0].resolve("stale.wav"); await tick();
      expect(disposed).toContain("stale.wav");
      expect(plays.values).toHaveLength(stop ? 1 : 2);
      if (!stop) expect(plays.values[1]).toMatchObject({ info: { id: "replay-owner", chunk_index: 0 }, position: { offsetMs: 0 } });
    } finally {
      controller.abort(); for (const prep of preparations.values) prep.resolve("stale.wav");
      for (const play of plays.values) play.exit.resolve({ status: "interrupted", stopped_at_ms: 200 }); await done;
    }
  });
});

describe("HISTDUP1 history is the whole utterance once, whatever was replayed, skipped or stopped", () => {
  type Exit = { status: string; stopped_at_ms?: number };
  type Saved = { audio: PlayedChunk[]; text: string; missingChunks: number[] };
  function scrubbed(texts: string[], opts: { lookahead?: 1 | 2; unsynthesized?: number[] } = {}) {
    const controller = new AbortController(), plays = fixtureBarrier<{ index: number; offsetMs: number; exit: ReturnType<typeof deferred<Exit>> }>();
    let control!: import("../tts/long-read").LongReadSeek; let saved: Saved | undefined;
    const chunks = texts.map((_t, i) => chunk(i));
    const done = runLongRead(texts, "scrub", controller.signal, {
      registerSeek: value => { control = value; },
      // An "unsynthesized" chunk's synthesis only ends when the read is stopped.
      synthesize: (_text, i, signal) => opts.unsynthesized?.includes(i)
        ? new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true }))
        : Promise.resolve(chunks[i]),
      play: (_chunk, _text, info, position) => {
        const exit = deferred<Exit>(); plays.push({ index: info.chunk_index, offsetMs: position.offsetMs, exit });
        return { started: Promise.resolve(true), exited: exit.promise };
      },
      saveHistory: async (audio, info) => { saved = { audio: audio.map(p => ({ ...p })), ...info }; },
      dispose: () => {},
    }, opts.lookahead ?? 1);
    // The real player reports the position it reached when a seek interrupts it.
    const scrub = async (n: number, stoppedAt: number, act: () => unknown) => {
      await plays.at(n); await tick(); act(); plays.values[n].exit.resolve({ status: "interrupted", stopped_at_ms: stoppedAt });
    };
    const finish = async (n: number) => { await plays.at(n); plays.values[n].exit.resolve({ status: "completed" }); };
    const stop = async (n: number, stoppedAt: number) => {
      await plays.at(n); controller.abort(); plays.values[n].exit.resolve({ status: "interrupted", stopped_at_ms: stoppedAt });
    };
    const whole = (indexes: number[]) => indexes.map(i => ({ chunk: chunks[i], text: texts[i], playedMs: 1000 }));
    return { plays, done, scrub, finish, stop, whole, control: () => control, saved: () => saved! };
  }

  it("RED repro: 1 play + 1 replay + 5 seeks saves the sentence once, not ×7", async () => {
    const f = scrubbed(["The whole sentence."]);
    await f.scrub(0, 400, () => f.control().restart());
    await f.scrub(1, 600, () => f.control().seek(200));
    await f.scrub(2, 500, () => f.control().seek(100));
    await f.scrub(3, 300, () => f.control().seek(250));
    await f.scrub(4, 700, () => f.control().seek(50));
    await f.scrub(5, 900, () => f.control().seek(300));
    await f.finish(6); await f.done;
    expect(f.plays.values).toHaveLength(7);
    expect(f.saved().text).toBe("The whole sentence.");
    // Audio: the chunk once, whole, so the assembled replay plays it once.
    expect(f.saved().audio).toEqual(f.whole([0]));
  });

  it("a backward seek across chunks keeps every chunk once, in order", async () => {
    const f = scrubbed(["One.", "Two.", "Three."]);
    await f.finish(0);
    await f.scrub(1, 500, () => f.control().seek(200)); // back into chunk 0
    await f.finish(2); await f.finish(3); await f.finish(4); await f.done;
    expect(f.saved()).toEqual({ text: "One. Two. Three.", audio: f.whole([0, 1, 2]), missingChunks: [] });
  });

  it("RED: a forward skip inside a chunk keeps the skipped words", async () => {
    const f = scrubbed(["One.", "Two."]);
    await f.scrub(0, 300, () => f.control().seek(700));
    await f.finish(1); await f.finish(2); await f.done;
    expect(f.saved()).toEqual({ text: "One. Two.", audio: f.whole([0, 1]), missingChunks: [] });
  });

  it("RED: a seek past a whole chunk keeps that chunk", async () => {
    const f = scrubbed(["One.", "Two.", "Three."], { lookahead: 2 });
    await f.scrub(0, 300, () => f.control().seek(2000));
    await f.finish(1); await f.done;
    expect(f.plays.values.map(p => p.index)).toEqual([0, 2]);
    expect(f.saved()).toEqual({ text: "One. Two. Three.", audio: f.whole([0, 1, 2]), missingChunks: [] });
  });

  it("RED: an interrupted final chunk keeps its whole audio and text", async () => {
    const f = scrubbed(["One.", "Two."]);
    await f.finish(0); await f.stop(1, 300); await f.done;
    expect(f.saved()).toEqual({ text: "One. Two.", audio: f.whole([0, 1]), missingChunks: [] });
  });

  it("RED: a stop before later chunks were synthesized keeps their text and names the audio gap", async () => {
    const f = scrubbed(["One.", "Two.", "Three."], { unsynthesized: [2] });
    await f.stop(0, 300); await f.done;
    expect(f.saved()).toEqual({ text: "One. Two. Three.", audio: f.whole([0, 1]), missingChunks: [2] });
  });

  it("sentences really repeated in the text stay repeated", async () => {
    const f = scrubbed(["Again.", "Again."]);
    await f.finish(0); await f.finish(1); await f.done;
    expect(f.saved()).toEqual({ text: "Again. Again.", audio: f.whole([0, 1]), missingChunks: [] });
  });
});
