import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import * as tts from "../tts";
import * as runner from "../tts/long-read";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as input from "../input";
import * as recording from "../recording-state";
import { handleSocketCommand } from "../socket-handlers";
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

  beforeEach(() => {
    gate = deferred(); entered = deferred(); enqueued = deferred();
    players = fixtureBarrier(); events = []; handles = []; restores = [];
    const add = (restore: () => void) => restores.push(restore);
    const cast = spyOn(socket, "broadcast").mockImplementation(event => { events.push(structuredClone(event)); });
    add(() => cast.mockRestore());
    const idle = spyOn(input, "getRecordingState").mockReturnValue("idle"); add(() => idle.mockRestore());
    const effective = spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"); add(() => effective.mockRestore());
    const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockImplementation(() => ({
      result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
    })); add(() => decode.mockRestore());
    const run = spyOn(runner, "runLongRead").mockImplementation((texts, id, signal, deps, lookahead) =>
      actualRun(texts, id, signal, { ...deps,
        synthesize: async () => {
          entered.resolve(); await gate.promise;
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
});
