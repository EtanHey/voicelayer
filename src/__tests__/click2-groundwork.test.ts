import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import * as tts from "../tts";
import * as runner from "../tts/long-read";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as input from "../input";
import * as recording from "../recording-state";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import type { SocketEvent } from "../socket-protocol";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

// Keep the real runner, adapter play callback and P16 queue. Replace only external I/O.
const actualRun = runner.runLongRead;
const selection = "CLICK2_SYNTHETIC_PRIVATE_SELECTION must never appear in click telemetry";
type Player = { argv: string[]; exit: ReturnType<typeof deferred<number>> };

describe("CLICK2 groundwork RED contracts", () => {
  let gate: ReturnType<typeof deferred<void>>;
  let entered: ReturnType<typeof deferred<void>>;
  let enqueued: ReturnType<typeof deferred<void>>;
  let players: ReturnType<typeof fixtureBarrier<Player>>;
  let events: SocketEvent[];
  let handles: ReturnType<typeof tts.speakLongRead>[];
  let restores: (() => void)[];
  let effectiveState: ReturnType<typeof spyOn>;
  let synthFailure: Error | undefined;

  beforeEach(() => {
    gate = deferred(); entered = deferred(); enqueued = deferred();
    players = fixtureBarrier(); events = []; handles = []; restores = []; synthFailure = undefined;
    const add = (restore: () => void) => restores.push(restore);
    const cast = spyOn(socket, "broadcast").mockImplementation(event => { events.push(structuredClone(event)); });
    add(() => cast.mockRestore());
    const idle = spyOn(input, "getRecordingState").mockReturnValue("idle"); add(() => idle.mockRestore());
    const effective = effectiveState = spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"); add(() => effective.mockRestore());
    const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockImplementation(() => ({
      result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
    })); add(() => decode.mockRestore());
    const run = spyOn(runner, "runLongRead").mockImplementation((texts, id, signal, deps, lookahead) =>
      actualRun(texts, id, signal, { ...deps,
        synthesize: async () => {
          entered.resolve(); await gate.promise;
          if (synthFailure) throw synthFailure;
          return { audioFile: `${TEST_TMP}/click2.mp3`, durationMs: 10000, wordBoundaries: [] };
        },
        canReplay: () => true,
        play: (...args) => { const playback = deps.play(...args); enqueued.resolve(); return playback; },
        saveHistory: async () => {}, dispose() {},
      }, lookahead)); add(() => run.mockRestore());
    // No real child of any kind is allowed: a trim/probe/player is an owned fake.
    const spawn = spyOn(Bun, "spawn").mockImplementation((...args: Parameters<typeof Bun.spawn>) => {
      const argv = args[0];
      if (!Array.isArray(argv)) throw new Error("CLICK2 fixture requires argv spawn");
      const exit = deferred<number>();
      if (argv[0] === "which") {
        exit.resolve(0);
        return { pid: 98001, exited: exit.promise, stdout: new Blob(["/fixture/ffmpeg"]).stream(), kill() {} } as ReturnType<typeof Bun.spawn>;
      }
      if (argv.includes("-ss") || argv.includes("-version")) exit.resolve(0);
      else players.push({ argv: argv.map(String), exit });
      return { pid: 98002, exited: exit.promise, kill: () => exit.resolve(143) } as ReturnType<typeof Bun.spawn>;
    }); add(() => spawn.mockRestore());
  });

  afterEach(async () => {
    resetSelectionReadQueueForTests();
    tts.stopPlayback(); gate.resolve();
    for (const player of players.values) player.exit.resolve(143);
    await Promise.all(handles.map(handle => handle.done));
    await tts.awaitCurrentPlayback();
    for (const restore of restores.reverse()) restore();
  });

  async function preparing() {
    const handle = tts.speakLongRead(selection, { engine: "edge", voice: "fixture", rate: "+0%" });
    handles.push(handle); await entered.promise;
    expect(players.values).toHaveLength(0);
    expect(events).toContainEqual(expect.objectContaining({ type: "state", state: "speaking",
      long_read: expect.objectContaining({ preparing: true, id: handle.id }) }));
    return handle;
  }
  const pausedEvents = () => events.filter(event => event.type === "playback_state" && event.state === "paused");

  it("a: Pause before first synthesis accepts and parks; release stays silent until Play", async () => {
    await preparing();
    expect(await handleSocketCommand({ cmd: "pause", id: "click2-pause" })).toMatchObject({ outcome: "accept" });
    gate.resolve(); await enqueued.promise; await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(players.values).toHaveLength(0);
    // The actual daemon event that makes VoiceState show Play (Swift companion checks presentation).
    expect(events).toContainEqual(expect.objectContaining({ type: "playback_state", state: "paused", offset_ms: 0 }));
    expect(await handleSocketCommand({ cmd: "resume", id: "click2-play" })).toMatchObject({ outcome: "accept", offset_ms: 0 });
    await players.at(0);
    expect(tts.isPlaybackPaused()).toBe(false);
  });

  it("b: Stop cancels a parked preparation and late synthesis cannot start a player", async () => {
    const handle = await preparing();
    const pause = await handleSocketCommand({ cmd: "pause", id: "click2-park-stop" });
    const stop = Promise.resolve(handleSocketCommand({ cmd: "stop", id: "click2-stop" }));
    gate.resolve();
    expect(await stop).toMatchObject({ outcome: "accept" });
    await handle.done; await fixtureCheckpoint();
    expect(players.values).toHaveLength(0);
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "noop" });
    // Stop already cancels unparked synthesis on main. The missing precondition is accepted parking.
    expect(pause).toMatchObject({ outcome: "accept" });
  });

  it("c: Replay while paused accepts, resets to zero and plays the retained current read", async () => {
    await preparing(); gate.resolve(); await players.at(0);
    expect(await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 4200 })).toMatchObject({ outcome: "accept", offset_ms: 4200 });
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(await handleSocketCommand({ cmd: "replay", id: "click2-replay" })).toMatchObject({ outcome: "accept" });
    await players.at(1); await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(events.filter(event => event.type === "state" && event.state === "speaking").at(-1))
      .toMatchObject({ playback_offset_ms: 0 });
  });

  // CLICK2 risk list: each case is RED on main (Pause during preparation was a no-op there and paused
  // Replay was rejected) and pins a boundary the implementation must keep.
  it("repeated Pause while preparing is idempotent: one park, one paused confirmation, no player", async () => {
    await preparing();
    expect(await handleSocketCommand({ cmd: "pause", id: "p1" })).toMatchObject({ outcome: "accept", reason: "parked", offset_ms: 0 });
    expect(await handleSocketCommand({ cmd: "pause", id: "p2" })).toMatchObject({ outcome: "noop", reason: "already paused", offset_ms: 0 });
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(tts.getPlaybackQueueDepth()).toBe(0);
    gate.resolve(); await enqueued.promise; await fixtureCheckpoint();
    expect(await handleSocketCommand({ cmd: "pause", id: "p3" })).toMatchObject({ outcome: "noop", reason: "already paused", offset_ms: 0 });
    expect(pausedEvents()).toHaveLength(1);
    expect(players.values).toHaveLength(0);
  });

  it("Play before readiness un-parks: the first chunk starts normally with no paused edge", async () => {
    await preparing();
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept" });
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept", offset_ms: 0 });
    expect(tts.isPlaybackPaused()).toBe(false);
    gate.resolve(); await players.at(0);
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(pausedEvents()).toHaveLength(0);
  });

  it("Play before readiness is refused while a capture owns the voice, and the read stays parked", async () => {
    await preparing();
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept" });
    effectiveState.mockReturnValue("recording");
    expect(tts.resumePlayback()).toMatchObject({ outcome: "reject", reason: "busy" });
    expect(tts.isPlaybackPaused()).toBe(true);
    effectiveState.mockReturnValue("idle");
  });

  it("Stop after readiness cancels the parked first chunk; nothing plays and Play is a no-op", async () => {
    const handle = await preparing();
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept" });
    gate.resolve(); await enqueued.promise; await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(await handleSocketCommand({ cmd: "stop", id: "stop-after" })).toMatchObject({ outcome: "accept" });
    await handle.done; await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(players.values).toHaveLength(0);
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "noop", reason: "not paused" });
  });

  it("a stale scope cannot park a preparing read, and a successor read is never parked by its predecessor's Pause", async () => {
    const first = await preparing();
    expect(await handleSocketCommand({ cmd: "pause", playback_id: "playback-old", generation: 4 }))
      .toMatchObject({ outcome: "reject", reason: "stale" });
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept" });
    const second = tts.speakLongRead("A replacement read", { engine: "edge", voice: "fixture", rate: "+0%" });
    handles.push(second);
    expect(tts.isPlaybackPaused()).toBe(false);
    gate.resolve(); await first.done;
    await players.at(0); await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(pausedEvents()).toHaveLength(0);
    expect(events.filter(event => event.type === "state" && event.state === "speaking").at(-1))
      .toMatchObject({ long_read: expect.objectContaining({ id: second.id }) });
  });

  it("synthesis failure while parked ends the read truthfully: no player, no park left behind", async () => {
    const handle = await preparing();
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept" });
    synthFailure = new Error("synthetic synthesis failure");
    gate.resolve(); await handle.done; await fixtureCheckpoint();
    expect(players.values).toHaveLength(0);
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(tts.playbackTelemetrySnapshot()).toEqual({ phase: "none", generation: null });
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "noop", reason: "not paused" });
    expect(events).toContainEqual(expect.objectContaining({ type: "error", message: "synthetic synthesis failure" }));
  });

  it("Replay of a read paused before its first chunk plays it from zero once it is ready", async () => {
    await preparing();
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept" });
    expect(await handleSocketCommand({ cmd: "replay", id: "replay-preparing" })).toMatchObject({ outcome: "accept" });
    gate.resolve(); await players.at(0); await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(pausedEvents()).toHaveLength(0);
  });

  it("Replay while paused is refused during a capture and leaves the park untouched", async () => {
    await preparing(); gate.resolve(); await players.at(0);
    expect(await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 4200 })).toMatchObject({ outcome: "accept", offset_ms: 4200 });
    effectiveState.mockReturnValue("recording");
    expect(await handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "reject", reason: "busy" });
    effectiveState.mockReturnValue("idle");
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(players.values).toHaveLength(1);
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept", offset_ms: 4200 });
  });

  it("Replay of ordinary parked audio restarts the same job from zero on the original file and keeps its handle", async () => {
    const file = `${TEST_TMP}/click2-short.mp3`;
    const playback = tts.playAudioNonBlocking(file, { text: "Short speech", voice: "fixture", durationMs: 10000 });
    let exited = false; void playback.exited.then(() => { exited = true; });
    await players.at(0);
    expect(await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 4200 })).toMatchObject({ outcome: "accept", offset_ms: 4200 });
    await fixtureCheckpoint();
    expect(await handleSocketCommand({ cmd: "replay", id: "replay-ordinary" })).toMatchObject({ outcome: "accept" });
    const replayed = await players.at(1); await fixtureCheckpoint();
    expect(replayed.argv).toContain(file);
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(exited).toBe(false);
    expect(events.filter(event => event.type === "state" && event.state === "speaking").at(-1))
      .toMatchObject({ playback_id: playback.id, playback_offset_ms: 0 });
  });

  it("telemetry snapshot reports the actual phase and owning generation, never another owner's counter", async () => {
    expect(tts.playbackTelemetrySnapshot()).toEqual({ phase: "none", generation: null });
    await preparing();
    expect(tts.playbackTelemetrySnapshot()).toEqual({ phase: "preparing", generation: null });
    await handleSocketCommand({ cmd: "pause" });
    expect(tts.playbackTelemetrySnapshot()).toEqual({ phase: "paused", generation: null });
    gate.resolve(); await enqueued.promise; await fixtureCheckpoint();
    const paused = pausedEvents().at(-1) as { generation: number };
    expect(tts.playbackTelemetrySnapshot()).toEqual({ phase: "paused", generation: paused.generation });
    await handleSocketCommand({ cmd: "resume" }); await players.at(0);
    expect(tts.playbackTelemetrySnapshot()).toMatchObject({ phase: "playing", generation: expect.any(Number) });
  });

  it("a parked queue head keeps queue order, natural advance and QPRE1's one prepared lease", async () => {
    const leases: { disposed: number; dispose(): void; take(): undefined }[] = [];
    const prepare = spyOn(tts, "prepareSelectionReadStart").mockImplementation(async () => {
      const lease = { disposed: 0, dispose() { lease.disposed++; }, take: () => undefined };
      leases.push(lease);
      return lease as never;
    });
    restores.push(() => prepare.mockRestore());
    const actualSpeakText = tts.speakText;
    const starts: { id?: string; prepared: unknown }[] = [];
    const start = spyOn(tts, "speakText").mockImplementation((text, kind, identity, prepared) => {
      starts.push({ id: identity?.request_id, prepared });
      const read = actualSpeakText(text, kind, identity, prepared); handles.push(read as never); return read;
    });
    restores.push(() => start.mockRestore());
    const hash = "c".repeat(64);
    expect(handleSocketCommand({ cmd: "speak_text", id: "A", text: "selection A", text_hash: hash, source: "selection" } as never))
      .toMatchObject({ outcome: "accept" });
    await entered.promise;
    expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept", reason: "parked" });
    expect(handleSocketCommand({ cmd: "speak_text", id: "B", text: "selection B", text_hash: hash, source: "selection", queue: true } as never))
      .toMatchObject({ outcome: "accept", reason: "queued" });
    gate.resolve(); await enqueued.promise; await fixtureCheckpoint();
    expect(players.values).toHaveLength(0);
    expect(leases).toHaveLength(1);
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept" });
    (await players.at(0)).exit.resolve(0);
    await players.at(1); await fixtureCheckpoint();
    const reads = events.filter(event => event.type === "state" && event.state === "speaking" && event.request_id)
      .map(event => (event as { request_id?: string }).request_id);
    expect([...new Set(reads)]).toEqual(["A", "B"]);
    // B started with A's one prepared lease (the runner seam ignores its audio); nothing was disposed early.
    expect(starts.map(read => read.id)).toEqual(["A", "B"]);
    expect(starts[1].prepared).toBe(leases[0]);
    expect(leases[0].disposed).toBe(0);
  });
});
