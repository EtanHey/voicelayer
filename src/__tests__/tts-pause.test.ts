import { afterEach, beforeEach, describe, expect, it, setSystemTime, spyOn } from "bun:test";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as input from "../input";
import { handleSocketCommand } from "../socket-handlers";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

const T0 = new Date("2026-10-18T12:00:00.000Z").getTime();
const at = (ms: number) => setSystemTime(new Date(T0 + ms));
const words = ["One", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
  .map((text, i) => ({ offset_ms: i * 1000, duration_ms: 800, text }));

type Player = { argv: string[]; signals: string[]; exit: ReturnType<typeof deferred<number>> };
let players: ReturnType<typeof fixtureBarrier<Player>>;
let trims: ReturnType<typeof fixtureBarrier<{ argv: string[]; exit: ReturnType<typeof deferred<number>> }>>;
let events: any[];
let timers: number[];
let restore: (() => void)[];

beforeEach(() => {
  at(0);
  players = fixtureBarrier(); trims = fixtureBarrier(); events = []; timers = []; restore = [];
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    const exit = deferred<number>();
    if (argv[1] === "-version") exit.resolve(0);
    if (argv[0] === "which") { exit.resolve(0); return { pid: 1, exited: exit.promise, kill() {}, stdout: new Blob(["/fake/ffmpeg"]).stream() }; }
    if (argv.includes("-ss")) { trims.push({ argv, exit }); return { pid: 2, exited: exit.promise, kill: () => exit.resolve(143) }; }
    if (argv[1] === "-version") return { pid: 3, exited: exit.promise, kill() {} };
    const player: Player = { argv, signals: [], exit };
    players.push(player);
    return { pid: 9000 + players.values.length, exited: exit.promise,
      kill: (signal = "SIGTERM") => { player.signals.push(String(signal)); if (signal !== "SIGSTOP") exit.resolve(143); } };
  }) as any);
  const extract = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue(
    { result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel: () => {} } as any);
  const cast = spyOn(socket, "broadcast").mockImplementation((event: any) => { events.push(event); });
  const realSetTimeout = globalThis.setTimeout;
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((fn: any, ms?: number, ...rest: any[]) => {
    timers.push(ms ?? 0); return realSetTimeout(fn, ms, ...rest);
  }) as any);
  restore = [() => spawn.mockRestore(), () => extract.mockRestore(), () => cast.mockRestore(), () => timeout.mockRestore()];
});

afterEach(async () => {
  tts.stopPlayback();
  for (const p of players.values) p.exit.resolve(0);
  for (const t of trims.values) t.exit.resolve(0);
  await tts.awaitCurrentPlayback();
  for (const undo of restore) undo();
  setSystemTime();
});

async function startTenSecondRead(text = "One two three four five six seven eight nine ten") {
  const handle = tts.playAudioNonBlocking(`${TEST_TMP}/pause-source.mp3`,
    { text, voice: "test", durationMs: 10_000, wordBoundaries: words });
  const player = await players.at(players.values.length);
  return { handle, player };
}

async function pauseAt4200() {
  const started = await startTenSecondRead();
  at(4200);
  const paused = tts.pausePlayback();
  const trim = await trims.at(trims.values.length);
  trim.exit.resolve(0); await fixtureCheckpoint();
  return { ...started, paused, trim };
}

describe("P10 queue pause/resume", () => {
  it("pause-resume-keeps-4200ms-cursor: frozen clock, offset and envelope; one resume within 150 ms", async () => {
    const { handle, player, paused, trim } = await pauseAt4200();
    expect(paused).toMatchObject({ outcome: "accept", offset_ms: 4200 });
    expect(player.signals).not.toContain("SIGSTOP");
    expect(player.signals).toEqual(["SIGTERM"]);
    expect(trim.argv[trim.argv.indexOf("-ss") + 1]).toBe("4.2");
    const pausedEvent = events.filter(e => e.type === "playback_state").at(-1);
    expect(pausedEvent).toMatchObject({ state: "paused", playback_id: handle.id, offset_ms: 4200, chunk_offset_ms: 4200, word_index: 4, word_count: 10, duration_ms: 10_000 });
    expect(tts.isPlaybackPaused()).toBe(true);

    const frozen = events.length;
    expect(tts.pausePlayback()).toMatchObject({ outcome: "noop" });
    at(94_200); await fixtureCheckpoint();
    // Advancing 90 s: no new player, no speaking/idle edge, no outcome, frozen queue progress.
    expect(players.values).toHaveLength(1);
    const later = events.slice(frozen);
    expect(later.filter(e => e.type === "state" || e.type === "playback_outcome")).toEqual([]);
    for (const q of later.filter(e => e.type === "queue")) expect(q.items[0]).toMatchObject({ is_current: true, progress: 0.42 });

    expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 4200 });
    expect(tts.resumePlayback()).toMatchObject({ outcome: "noop" });
    const resumed = await players.at(1); await fixtureCheckpoint();
    expect(players.values).toHaveLength(2);
    expect(resumed.argv.at(-1)).toBe(trim.argv.at(-1));
    const speaking = events.filter(e => e.state === "speaking").at(-1);
    expect(Math.abs(speaking.playback_offset_ms - 4200)).toBeLessThanOrEqual(150);
    const resumedEvent = events.filter(e => e.type === "playback_state").at(-1);
    expect(resumedEvent).toMatchObject({ state: "resumed", playback_id: handle.id, offset_ms: 4200, word_index: 4 });
    expect(resumedEvent.generation).toBeGreaterThan(pausedEvent.generation);
    // Watchdog rebased on the remaining 5.8 s, never the pre-pause budget or paused wall time.
    expect(timers).toContain(10_000 - 4200 + 5000);
    expect(tts.isPlaybackPaused()).toBe(false);

    at(100_000); resumed.exit.resolve(0);
    expect(await handle.exited).toMatchObject({ status: "completed" });
    expect(players.values).toHaveLength(2);
  });

  it("Stop is terminal while paused and a stale player exit never restarts playback", async () => {
    const { handle, player } = await pauseAt4200();
    player.exit.resolve(0); await fixtureCheckpoint();
    expect(players.values).toHaveLength(1);
    expect(tts.stopPlayback()).toBe(true);
    expect(await handle.exited).toMatchObject({ status: "interrupted", reason: "stopped", stopped_at_ms: 4200, word_index: 4 });
    expect(events.filter(e => e.type === "state").at(-1)).toMatchObject({ state: "idle" });
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(tts.resumePlayback()).toMatchObject({ outcome: "noop" });
    expect(tts.pausePlayback()).toMatchObject({ outcome: "noop" });
    await fixtureCheckpoint();
    expect(players.values).toHaveLength(1);
  });

  it("Stop before the resume slice resolves disposes the late result with zero starts", async () => {
    await startTenSecondRead();
    at(4200); tts.pausePlayback();
    const trim = await trims.at(0);
    expect(tts.resumePlayback()).toMatchObject({ outcome: "accept" });
    tts.stopPlayback();
    trim.exit.resolve(0); await fixtureCheckpoint();
    expect(players.values).toHaveLength(1);
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toEqual([]);
  });

  it("scoped controls reject stale identities without touching the paused item", async () => {
    const { handle } = await pauseAt4200();
    expect(tts.resumePlayback({ id: "playback-foreign" })).toMatchObject({ outcome: "reject", reason: "stale" });
    expect(tts.resumePlayback({ id: handle.id, generation: 1 })).toMatchObject({ outcome: "reject", reason: "stale" });
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(tts.resumePlayback({ id: handle.id, generation: handle.generation })).toMatchObject({ outcome: "accept" });
    await players.at(1);
  });

  it("holds pending speech while paused, keeps no paused TTL, and replaces the parked item on new speech", async () => {
    const { handle } = await startTenSecondRead();
    const held = tts.playAudioNonBlocking(`${TEST_TMP}/held.mp3`, { text: "Held", voice: "test", durationMs: 1000 });
    at(4200); tts.pausePlayback();
    (await trims.at(0)).exit.resolve(0);
    at(200_000); await fixtureCheckpoint();
    expect(players.values).toHaveLength(1);
    const fresh = tts.playAudioNonBlocking(`${TEST_TMP}/fresh.mp3`, { text: "Fresh", voice: "test", durationMs: 1000 });
    expect(await handle.exited).toMatchObject({ status: "interrupted", reason: "replaced", stopped_at_ms: 4200 });
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(await held.exited).toMatchObject({ status: "skipped", reason: "expired" });
    const next = await players.at(1);
    expect(next.argv.at(-1)).toBe(`${TEST_TMP}/fresh.mp3`);
    next.exit.resolve(0);
    expect(await fresh.exited).toMatchObject({ status: "completed" });
  });

  it("refuses to pause an Ask prompt and seeks while paused", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/ask.mp3`, { text: "Question?", voice: "test", durationMs: 5000, priority: "critical" });
    await players.at(0);
    expect(tts.pausePlayback()).toMatchObject({ outcome: "reject", reason: "unsupported" });
    tts.stopPlayback(); await tts.awaitCurrentPlayback();
    await startTenSecondRead();
    at(4200); tts.pausePlayback();
    expect(tts.seekPlayback(1000)).toMatchObject({ outcome: "reject", reason: "paused" });
  });
});

describe("P10 socket pause/resume", () => {
  it("acks pause/resume idempotently, refuses recorder-active Resume, and Stop ends the parked read", async () => {
    await startTenSecondRead();
    at(4200);
    expect(handleSocketCommand({ cmd: "pause", id: "p1" } as any)).toMatchObject({ type: "ack", command: "pause", id: "p1", outcome: "accept", offset_ms: 4200 });
    expect(handleSocketCommand({ cmd: "pause", id: "p2" } as any)).toMatchObject({ command: "pause", outcome: "noop" });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    const recording = spyOn(input, "getRecordingState").mockReturnValue("recording" as any);
    try {
      expect(handleSocketCommand({ cmd: "resume", id: "r1" } as any)).toMatchObject({ command: "resume", outcome: "reject", reason: "busy" });
    } finally { recording.mockRestore(); }
    expect(players.values).toHaveLength(1);
    expect(tts.isPlaybackPaused()).toBe(true);
    const stopped = await handleSocketCommand({ cmd: "stop", id: "x1" } as any);
    expect(stopped).toMatchObject({ command: "stop", outcome: "accept" });
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(handleSocketCommand({ cmd: "resume", id: "r2" } as any)).toMatchObject({ command: "resume", outcome: "noop" });
    expect(players.values).toHaveLength(1);
  });

  it("pause with the teleprompter clock freezes at the client's word", async () => {
    await startTenSecondRead();
    at(4200);
    expect(handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 3950 } as any)).toMatchObject({ outcome: "accept", offset_ms: 3950 });
    expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ state: "paused", offset_ms: 3950, word_index: 3 });
  });
});
