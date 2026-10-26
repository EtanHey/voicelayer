import { afterEach, beforeEach, describe, expect, it, setSystemTime, spyOn } from "bun:test";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as input from "../input";
import { handleSocketCommand } from "../socket-handlers";
import { parseCommand } from "../socket-protocol";
import { TEST_TMP } from "./setup/test-tmp";
import { beginSpeechArchive } from "../speech-archive-live";
import { readFileSync } from "fs";
import { join } from "path";
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
let extractSpy: any;

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
  const extract = extractSpy = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue(
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
  it("R1C pause at duration resumes to a durable completed receipt without another player", async () => {
    const archive = beginSpeechArchive("endpoint pause fixture");
    await archive.settled();
    const handle = tts.playAudioNonBlocking(`${TEST_TMP}/endpoint.mp3`, {
      text: "Endpoint", voice: "fixture", durationMs: 1000, speechArchive: archive,
      onCompleted: outcome => archive.finish(outcome.status === "completed" ? "completed" : "stopped", "PLAYBACK_COMPLETED"),
    });
    await players.at(0);
    at(1000);
    expect(tts.pausePlayback()).toMatchObject({ outcome: "accept", offset_ms: 1000 });
    const trim = await trims.at(0);
    trim.exit.resolve(0);
    await fixtureCheckpoint();
    at(31_000);
    expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 1000 });
    expect(await handle.exited).toMatchObject({ status: "completed" });
    await archive.settled();
    expect(players.values).toHaveLength(1);
    expect(archive.failures).toEqual([]);
    expect(JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).speech).toMatchObject({ state: "completed", played_ms: 1000 });
  });

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

  it("SEEK2 integration: a readback seek cannot replace a parked read, and resume keeps its readback identity", async () => {
    await pauseAt4200();
    const readbackID = events.filter(e => e.state === "speaking")[0].readback_id;
    expect(readbackID).toBeString();
    expect(tts.seekPlayback(1000, "readback", readbackID)).toMatchObject({ outcome: "reject", reason: "paused" });
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(players.values).toHaveLength(1);
    tts.resumePlayback();
    await players.at(1); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1).readback_id).toBe(readbackID);
  });
});

describe("P10 envelope and preparation", () => {
  it("resumes with the original decoded envelope, rebased to the resume offset", async () => {
    const samples = Array.from({ length: 200 }, (_, i) => (i % 10) / 10 + 0.05);
    extractSpy.mockReturnValue({ result: Promise.resolve({ source: "decoded-rms", sample_interval_ms: 50, samples }), cancel: () => {} });
    await pauseAt4200();
    expect(events.filter(e => e.state === "speaking")[0].playback_amplitude.samples).toEqual(samples);
    tts.resumePlayback();
    await players.at(1); await fixtureCheckpoint();
    // VoiceBar indexes the envelope from 0 at the speaking edge: the resumed frame starts at sample 4200/50.
    expect(events.filter(e => e.state === "speaking").at(-1).playback_amplitude)
      .toEqual({ source: "decoded-rms", sample_interval_ms: 50, samples: samples.slice(84) });
    expect(extractSpy).toHaveBeenCalledTimes(1);
  });

  for (const ending of ["stop", "resume"] as const) {
    it(`pause during envelope preparation parks at zero; a late decoder never starts a player (${ending})`, async () => {
      const decoders = [deferred<any>(), deferred<any>()];
      let calls = 0, cancelled = 0;
      extractSpy.mockImplementation(() => ({ result: decoders[calls++].promise, cancel: () => { cancelled++; } }));
      const handle = tts.playAudioNonBlocking(`${TEST_TMP}/prep.mp3`, { text: "Prep", voice: "test", durationMs: 10_000, wordBoundaries: words });
      await fixtureCheckpoint();
      at(3000);
      expect(tts.pausePlayback()).toMatchObject({ outcome: "accept", offset_ms: 0 });
      expect(cancelled).toBe(1);
      expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ state: "paused", offset_ms: 0 });
      decoders[0].resolve({ source: "decoded-rms", sample_interval_ms: 50, samples: [0.9] });
      await fixtureCheckpoint();
      expect(players.values).toHaveLength(0);
      expect(trims.values).toHaveLength(0);
      if (ending === "stop") {
        tts.stopPlayback();
        expect(await handle.exited).toMatchObject({ reason: "stopped", stopped_at_ms: 0 });
        expect(tts.resumePlayback()).toMatchObject({ outcome: "noop" });
        await fixtureCheckpoint();
        expect(players.values).toHaveLength(0);
        return;
      }
      expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 0 });
      await fixtureCheckpoint();
      expect(players.values).toHaveLength(0); // a fresh decode, not the cancelled one, gates the start
      const envelope = { source: "decoded-rms", sample_interval_ms: 50, samples: [0.3, 0.6] };
      decoders[1].resolve(envelope);
      const player = await players.at(0); await fixtureCheckpoint();
      expect(player.argv.at(-1)).toBe(`${TEST_TMP}/prep.mp3`);
      expect(players.values).toHaveLength(1);
      expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_amplitude: envelope });
      expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ state: "resumed", offset_ms: 0 });
      player.exit.resolve(0);
      expect(await handle.exited).toMatchObject({ status: "completed" });
    });
  }
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
  it("P16 e2e: VoiceBar's pause → resume wire continues the same utterance from the paused word", async () => {
    const { handle } = await startTenSecondRead();
    const firstSpeaking = events.filter(e => e.state === "speaking").at(-1);
    at(4200);
    // The speaking frame names the player VoiceBar's controls bind to.
    expect(firstSpeaking.playback_id).toBe(handle.id);
    expect(Number.isSafeInteger(firstSpeaking.generation)).toBe(true);
    // The exact lines VoiceBar writes: both commands are scoped to that player.
    const pause = parseCommand(JSON.stringify({ cmd: "pause", id: "vb-p", playback_elapsed_ms: 4100,
      playback_id: firstSpeaking.playback_id, generation: firstSpeaking.generation }));
    expect(handleSocketCommand(pause as any)).toMatchObject({ command: "pause", id: "vb-p", outcome: "accept", offset_ms: 4100 });
    const paused = events.filter(e => e.type === "playback_state").at(-1);
    expect(paused).toMatchObject({ state: "paused", playback_id: handle.id, offset_ms: 4100, word_index: 4, word_count: 10 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    at(60_000);
    const resume = parseCommand(JSON.stringify({ cmd: "resume", id: "vb-r", playback_id: paused.playback_id, generation: paused.generation }));
    expect(handleSocketCommand(resume as any)).toMatchObject({ command: "resume", id: "vb-r", outcome: "accept", offset_ms: 4100 });
    const resumedPlayer = await players.at(1); await fixtureCheckpoint();
    const speaking = events.filter(e => e.state === "speaking").at(-1);
    // Same utterance: same text, same readback identity, clock anchored at the paused offset.
    expect(speaking).toMatchObject({ text: firstSpeaking.text, readback_id: firstSpeaking.readback_id, playback_offset_ms: 4100 });
    const resumedEvent = events.filter(e => e.type === "playback_state").at(-1);
    expect(resumedEvent).toMatchObject({ state: "resumed", playback_id: handle.id, offset_ms: 4100, word_index: 4 });
    // The resumed frame and its event agree on the new generation; the pre-pause scope is now stale.
    expect(speaking).toMatchObject({ playback_id: handle.id, generation: resumedEvent.generation });
    expect(handleSocketCommand(parseCommand(JSON.stringify({ cmd: "pause", playback_id: handle.id,
      generation: firstSpeaking.generation })) as any)).toMatchObject({ outcome: "reject", reason: "stale" });
    expect(handleSocketCommand(parseCommand(JSON.stringify({ cmd: "pause", playback_id: "playback-retired" })) as any))
      .toMatchObject({ outcome: "reject", reason: "stale" });
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(events.filter(e => e.type === "playback_outcome")).toEqual([]);
    resumedPlayer.exit.resolve(0);
    expect(await handle.exited).toMatchObject({ status: "completed", playback_id: handle.id });
    expect(players.values).toHaveLength(2);
  });
  it("P16: F5's stop/cancel during a capture end the capture, never the parked read", async () => {
    for (const [cmd, base] of [["stop", 0], ["cancel", 100_000]] as const) {
      at(base);
      const { handle } = await startTenSecondRead();
      at(base + 4200);
      const trim = trims.values.length;
      expect(handleSocketCommand({ cmd: "pause" } as any)).toMatchObject({ outcome: "accept", offset_ms: 4200 });
      (await trims.at(trim)).exit.resolve(0); await fixtureCheckpoint();
      const recording = spyOn(input, "getRecordingState").mockReturnValue("recording" as any);
      try {
        expect(await handleSocketCommand({ cmd, id: `${cmd}-1` } as any)).toMatchObject({ command: cmd, outcome: "accept" });
      } finally { recording.mockRestore(); }
      expect(tts.isPlaybackPaused()).toBe(true);
      expect(events.filter(e => e.type === "playback_outcome" && e.playback_id === handle.id)).toEqual([]);
      // Capture over: Play continues the same read from the same word.
      const next = players.values.length;
      expect(handleSocketCommand({ cmd: "resume", playback_id: handle.id } as any)).toMatchObject({ outcome: "accept", offset_ms: 4200 });
      const resumed = await players.at(next); await fixtureCheckpoint();
      expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ state: "resumed", playback_id: handle.id });
      tts.stopPlayback(); resumed.exit.resolve(0); await handle.exited;
    }
  });
});
