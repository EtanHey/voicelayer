import { afterEach, expect, it, spyOn } from "bun:test";
import { writeFileSync } from "node:fs";
import * as tts from "../tts";
import * as socket from "../socket-client";
import * as amplitude from "../playback-amplitude";
import { runLongRead, type LongReadChunk } from "../tts/long-read";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint as tick } from "./long-read-fixture-barriers";

// SCRUB1: the teleprompter scrubber can only show what the speaking edge tells it.
const restores: (() => void)[] = [];
afterEach(async () => {
  tts.stopPlayback(); await tts.awaitCurrentPlayback();
  for (const restore of restores.splice(0)) restore();
});

it("idle Replay of a history file without metadata duration still reports its real duration", async () => {
  const file = `${TEST_TMP}/scrub-history.mp3`; writeFileSync(file, "fixture");
  const events: any[] = [], players = fixtureBarrier<{ exit: ReturnType<typeof deferred<number>> }>();
  const broadcast = spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); });
  const originalSpawnSync = Bun.spawnSync;
  // @ts-ignore fixture probe: the 18.3 s read Etan replayed.
  Bun.spawnSync = (cmd: string[], options?: any) => {
    if (cmd.includes("-show_entries")) return { exitCode: 0, stdout: Buffer.from("18.300\n"), stderr: Buffer.alloc(0) };
    if (cmd[0] === "which" || cmd[1] === "-version") return { exitCode: 0, stdout: Buffer.from(`${cmd.at(-1)}\n`), stderr: Buffer.alloc(0) };
    return originalSpawnSync(cmd, { ...options, env: process.env });
  };
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    const exit = deferred<number>();
    if (argv[0] === "which" || argv[1] === "-version" || argv[1] === "--version") exit.resolve(0);
    else players.push({ exit });
    return { pid: 95100, exited: exit.promise, kill: () => exit.resolve(143), stdout: new Blob([""]).stream() };
  }) as any);
  const decode = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
    result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
  });
  restores.push(() => { Bun.spawnSync = originalSpawnSync; spawn.mockRestore(); broadcast.mockRestore(); decode.mockRestore(); });

  tts.playAudioNonBlocking(file, { text: "Retained speech.", voice: "fixture" });
  const player = await players.at(0);
  expect(events.find(e => e.type === "state" && e.state === "speaking")).toMatchObject({ duration_ms: 18300 });
  player.exit.resolve(0);
});

const chunk = (i: number): LongReadChunk => ({ audioFile: `${i}.mp3`, durationMs: 1000 * (i + 1), wordBoundaries: [] });

it("a long read reports its growing total as each chunk lands and marks the final total", async () => {
  const synthesis = Array.from({ length: 3 }, () => deferred<LongReadChunk>());
  const playback = Array.from({ length: 3 }, () => deferred<any>());
  const infos: any[] = [], durations: [number, boolean][] = [], played = fixtureBarrier<number>();
  const done = runLongRead(["One.", "Two.", "Three."], "read", new AbortController().signal, {
    synthesize: (_text, i) => synthesis[i].promise,
    play: (_chunk, _text, info) => {
      infos.push(info); played.push(info.chunk_index);
      return { started: Promise.resolve(true), exited: playback[info.chunk_index].promise };
    },
    onDuration: (total, final) => { durations.push([total, final]); },
    saveHistory: async () => {},
    dispose: () => {},
  });
  synthesis[0].resolve(chunk(0)); await played.at(0);
  expect(infos[0].estimated_total_ms).toBeUndefined();
  synthesis[1].resolve(chunk(1)); await tick();
  expect(durations).toEqual([[1000, false], [3000, false]]);
  playback[0].resolve({ status: "completed", stopped_at_ms: 1000 }); await played.at(1);
  synthesis[2].resolve(chunk(2)); await tick();
  expect(durations.at(-1)).toEqual([6000, true]);
  playback[1].resolve({ status: "completed", stopped_at_ms: 2000 }); await played.at(2);
  expect(infos[2]).toMatchObject({ chunk_start_ms: 3000, estimated_total_ms: 6000 });
  playback[2].resolve({ status: "completed", stopped_at_ms: 3000 });
  await done;
});
