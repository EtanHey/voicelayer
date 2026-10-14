import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { writeFileSync, existsSync } from "fs";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand } from "../socket-handlers";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";
import { runLongRead } from "../tts/long-read";

const seek = tts.seekPlayback;
afterEach(async () => { tts.stopPlayback(); await tts.awaitCurrentPlayback(); });

describe("seek protocol", () => {
  it("validates finite nonnegative offsets and current scope", () => {
    expect(parseCommand('{"cmd":"seek","offset_ms":123.5,"scope":"current","id":"s"}')).toEqual({ cmd: "seek", offset_ms: 123.5, scope: "current", id: "s" });
    for (const offset_ms of [-1, null, "1"]) expect(parseCommand(JSON.stringify({ cmd: "seek", offset_ms }))).toBeNull();
    expect(parseCommand('{"cmd":"seek","offset_ms":1e999}')).toBeNull();
    expect(parseCommand('{"cmd":"seek","offset_ms":1,"scope":"all"}')).toBeNull();
  });
  it("acknowledges an after-stop seek without resurrecting playback", () => {
    tts.stopPlayback();
    expect(handleSocketCommand({ cmd: "seek", offset_ms: 50 } as any)).toMatchObject({ command: "seek", outcome: "noop", reason: "nothing playing" });
  });
  it("rejects an old decoder result after a seek replacement commits", async () => {
    const decoded = deferred<any>(), trim = deferred<number>(), conversions = fixtureBarrier<string[]>();
    const extract = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({ result: decoded.promise, cancel: () => {} });
    const players: string[][] = [];
    const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      if (argv[0] === "which") return { pid: 91000, exited: Promise.resolve(0), stdout: new Blob(["/fake/ffmpeg"]).stream(), kill: () => {} };
      if (argv.includes("-ss")) { conversions.push(argv); return { pid: 91001, exited: trim.promise, kill: () => trim.resolve(143) }; }
      players.push(argv); return { pid: 91002, exited: Promise.resolve(0), kill: () => {} };
    }) as any);
    try {
      tts.playAudioNonBlocking(`${TEST_TMP}/preparing.mp3`, { text: "Preparing", voice: "test", durationMs: 1000 });
      seek(300); await conversions.at(0);
      trim.resolve(0); await fixtureCheckpoint();
      expect(players).toHaveLength(1); expect(players[0].at(-1)).toEndWith(".seek.wav");
      decoded.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] });
      await fixtureCheckpoint(); expect(players).toHaveLength(1);
      tts.stopPlayback(); await tts.awaitCurrentPlayback();
    } finally { tts.stopPlayback(); trim.resolve(143); await tts.awaitCurrentPlayback(); extract.mockRestore(); spawn.mockRestore(); }
  });
  it("trims from the original file, rebroadcasts timing, and fences rapid seeks/stop", async () => {
    const players = fixtureBarrier<any>(), trims = fixtureBarrier<any>(), events: any[] = [];
    const source = `${TEST_TMP}/seek-source.mp3`; writeFileSync(source, "audio");
    const words = [{ offset_ms: 300, duration_ms: 100, text: "Hello" }];
    const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      const exit = deferred<number>();
      const proc = { pid: 90000 + players.values.length + trims.values.length, exited: exit.promise, kill: () => exit.resolve(0), stdout: new Blob([new Uint8Array([0, 0])]).stream() };
      if (argv.includes("-ss")) trims.push({ argv, exit, proc });
      else if (argv.includes("-f") && argv.includes("s16le")) exit.resolve(0);
      else if (argv[0] === "which") { proc.stdout = new Blob(["/fake/ffmpeg"]).stream(); exit.resolve(0); }
      else {
        if (players.values.length === 0) proc.kill = () => {};
        players.push({ argv, exit, proc });
      }
      return proc;
    }) as any);
    const broadcast = spyOn(socket, "broadcast").mockImplementation((event) => { events.push(event); });
    try {
      const handle = tts.playAudioNonBlocking(source, { text: "Hello", voice: "test", durationMs: 1000, wordBoundaries: words });
      await players.at(0);
      expect(seek(300)).toMatchObject({ outcome: "accept", offset_ms: 300 });
      const first = await trims.at(0);
      expect(players.values).toHaveLength(1);
      expect(first.argv.indexOf("-ss")).toBeLessThan(first.argv.indexOf("-i"));
      expect(first.argv[first.argv.indexOf("-ss") + 1]).toBe("0.3");
      expect(first.argv[first.argv.indexOf("-i") + 1]).toBe(source);
      writeFileSync(first.argv.at(-1), "slice"); first.exit.resolve(0);
      await fixtureCheckpoint(); expect(players.values).toHaveLength(1);
      players.values[0].exit.resolve(0);
      const secondPlayer = await players.at(1);
      expect(secondPlayer.argv).toContain(first.argv.at(-1));
      expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 300, duration_ms: 1000 });
      expect(events.filter(e => e.type === "subtitle").at(-1).words).toEqual(words);
      seek(600); const stale = await trims.at(1);
      seek(700); stale.exit.resolve(0); await fixtureCheckpoint();
      const latest = await trims.at(2); expect(latest.argv[latest.argv.indexOf("-i") + 1]).toBe(source);
      tts.stopPlayback(); writeFileSync(latest.argv.at(-1), "late"); latest.exit.resolve(0);
      await handle.exited; await fixtureCheckpoint();
      expect(players.values).toHaveLength(2);
      expect(existsSync(latest.argv.at(-1))).toBe(false);
      expect(seek(10).outcome).toBe("noop");
      const preempted = tts.playAudioNonBlocking(source, { text: "Old", voice: "test", durationMs: 1000 });
      await players.at(2); seek(350); const cancelled = await trims.at(3);
      const replacement = tts.playAudioNonBlocking(source, { text: "Critical", voice: "test", durationMs: 1000, priority: "critical" });
      await players.at(3); cancelled.exit.resolve(0); await fixtureCheckpoint();
      expect(await preempted.exited).toMatchObject({ status: "interrupted", reason: "barge-in" });
      expect(players.values).toHaveLength(4);
      expect(events.filter(e => e.state === "speaking").at(-1).text).toBe("Critical");
      expect(seek(2000)).toMatchObject({ outcome: "accept", offset_ms: 1000, clamped: true });
      await replacement.exited; await tts.awaitCurrentPlayback(); expect(players.values).toHaveLength(4);
    } finally { tts.stopPlayback(); for (const player of players.values) player.exit.resolve(0); for (const t of trims.values) t.exit.resolve(0); await tts.awaitCurrentPlayback(); spawn.mockRestore(); broadcast.mockRestore(); }
  });
});

describe("long-read seek cursor", () => {
  it("reuses earlier audio, clamps forward, preserves ordering and rejects stopped generations", async () => {
    const controller = new AbortController(), plays = fixtureBarrier<any>(), synths: number[] = [], disposed: number[] = [];
    const next = deferred<any>(); let control: any;
    const done = runLongRead(["One", "Two", "Three"], "seek-read", controller.signal, {
      synthesize: async (_t: string, i: number) => { synths.push(i); return i === 2 ? next.promise : { audioFile: `${i}.mp3`, durationMs: 1000, wordBoundaries: [] }; },
      play: (chunk: any, text: string, info: any, position: any) => {
        const exit = deferred<any>(); plays.push({ chunk, text, info, position, exit });
        return { started: Promise.resolve(true), exited: exit.promise, interrupt: () => exit.resolve({ status: "interrupted", stopped_at_ms: 400 }) };
      },
      registerSeek: (value: any) => { control = value; },
      saveHistory: async () => {}, dispose: (_c: any, i: number) => { disposed.push(i); },
    } as any);
    const first = await plays.at(0); await fixtureCheckpoint();
    first.exit.resolve({ status: "completed", stopped_at_ms: 1000 });
    await plays.at(1);
    expect(control.seek(50).outcome).toBe("accept");
    expect(control.seek(250)).toMatchObject({ outcome: "accept", offset_ms: 250 });
    const back = await plays.at(2); expect(back.info.chunk_index).toBe(0); expect(back.position).toMatchObject({ offsetMs: 250, durationMs: 2000 });
    expect(synths.filter(i => i === 0)).toHaveLength(1);
    back.exit.resolve({ status: "completed", stopped_at_ms: 1000 });
    const resumed = await plays.at(3); expect(resumed.info.chunk_index).toBe(1);
    expect(control.seek(9999)).toMatchObject({ outcome: "accept", offset_ms: 2000, clamped: true });
    await fixtureCheckpoint(); expect(plays.values).toHaveLength(4);
    expect(control.seek(1250).outcome).toBe("accept");
    const gapReplay = await plays.at(4); expect(gapReplay.info.chunk_start_ms).toBe(1000);
    expect(gapReplay.position.offsetMs).toBe(250);
    controller.abort(); gapReplay.exit.resolve({ status: "interrupted", stopped_at_ms: 600 });
    expect(control.seek(0).outcome).toBe("noop");
    next.resolve({ audioFile: "2.mp3", durationMs: 1000, wordBoundaries: [] }); await done;
    expect(plays.values.map(p => p.info.chunk_index)).toEqual([0, 1, 0, 1, 1]);
    expect(synths).toEqual([0, 1, 2]); expect(disposed.sort()).toEqual([0, 1, 2]);
  });
});
