import { runBarCaptureWithPausedRead } from "../f5-capture";
import { registerBarRecorderExit } from "../recording-jobs";
import { setRecordingState, getRecordingState, getEffectiveRecordingState } from "../recording-state";
import { STOP_FILE, recordingStateFilePath, safeWriteFileSync } from "../paths";
import { clearStopSignal } from "../session-booking";
import { finishBarCapture, recordingJobsSnapshot, deliverInputTranscription, acknowledgeDictationDelivery } from "../recording-jobs";
import { finishSyntheticCapture, settleRecordingJobs } from "./setup/recording-jobs-fixture";
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
let holdPlayerExit = false;

beforeEach(() => {
  at(0);
  holdPlayerExit = false;
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
      kill: (signal = "SIGTERM") => { player.signals.push(String(signal)); if (signal !== "SIGSTOP" && !holdPlayerExit) exit.resolve(143); } };
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

  it("pause-resume-rewinds-to-containing-word: frozen clock, offset and envelope; one resume within 150 ms", async () => {
    const { handle, player, paused, trim } = await pauseAt4200();
    expect(paused).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    expect(player.signals).not.toContain("SIGSTOP");
    expect(player.signals).toEqual(["SIGTERM"]);
    expect(trim.argv[trim.argv.indexOf("-ss") + 1]).toBe("4");
    const pausedEvent = events.filter(e => e.type === "playback_state").at(-1);
    expect(pausedEvent).toMatchObject({ state: "paused", playback_id: handle.id, offset_ms: 4000, chunk_offset_ms: 4000, word_index: 4, word_count: 10, duration_ms: 10_000 });
    expect(tts.isPlaybackPaused()).toBe(true);

    const frozen = events.length;
    expect(tts.pausePlayback()).toMatchObject({ outcome: "noop" });
    at(94_200); await fixtureCheckpoint();
    // Advancing 90 s: no new player, no speaking/idle edge, no outcome, frozen queue progress.
    expect(players.values).toHaveLength(1);
    const later = events.slice(frozen);
    expect(later.filter(e => e.type === "state" || e.type === "playback_outcome")).toEqual([]);
    for (const q of later.filter(e => e.type === "queue")) expect(q.items[0]).toMatchObject({ is_current: true, progress: 0.4 });

    expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    expect(tts.resumePlayback()).toMatchObject({ outcome: "noop" });
    const resumed = await players.at(1); await fixtureCheckpoint();
    expect(players.values).toHaveLength(2);
    expect(resumed.argv.at(-1)).toBe(trim.argv.at(-1));
    const speaking = events.filter(e => e.state === "speaking").at(-1);
    expect(Math.abs(speaking.playback_offset_ms - 4000)).toBeLessThanOrEqual(150);
    const resumedEvent = events.filter(e => e.type === "playback_state").at(-1);
    expect(resumedEvent).toMatchObject({ state: "resumed", playback_id: handle.id, offset_ms: 4000, word_index: 4 });
    expect(resumedEvent.generation).toBeGreaterThan(pausedEvent.generation);
    // Watchdog rebased on the remaining 6 s, never the pre-pause budget or paused wall time.
    expect(timers).toContain(10_000 - 4000 + 5000);
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
    expect(await handle.exited).toMatchObject({ status: "interrupted", reason: "stopped", stopped_at_ms: 4000, word_index: 4 });
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
    expect(await handle.exited).toMatchObject({ status: "interrupted", reason: "replaced", stopped_at_ms: 4000 });
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
  it("R1C waveform resume redecodes cancelled prepared amplitude for a non-opening chunk", async () => {
    const result = deferred<amplitude.PlaybackAmplitudeEnvelope>();
    let cancelled = 0;
    const preparedAmplitude = { result: result.promise, cancel: () => {
      cancelled++;
      result.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] });
    } };
    const envelope: amplitude.PlaybackAmplitudeEnvelope = {
      source: "decoded-rms", sample_interval_ms: 50, samples: [0.2, 0.7, 0.4],
    };
    extractSpy.mockReturnValue({ result: Promise.resolve(envelope), cancel: () => {} });
    const file = `${TEST_TMP}/non-opening-chunk.mp3`;
    const handle = tts.playAudioNonBlocking(file, {
      text: "Second chunk", voice: "fixture", durationMs: 10_000, preparedAmplitude,
      longRead: { id: "waveform-fixture", chunk_index: 1, chunk_count: 2, chunk_start_ms: 1000 },
    });
    await fixtureCheckpoint();
    expect(players.values).toHaveLength(0);
    expect(tts.pausePlayback()).toMatchObject({ outcome: "accept", offset_ms: 1000 });
    await fixtureCheckpoint();
    expect(cancelled).toBe(1);
    expect(players.values).toHaveLength(0);
    expect(trims.values).toHaveLength(0);
    expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 1000 });
    const player = await players.at(0);
    await fixtureCheckpoint();
    expect(events.filter(event => event.state === "speaking").at(-1).playback_amplitude).toEqual(envelope);
    expect(extractSpy).toHaveBeenCalledWith(file);
    expect(player.argv.at(-1)).toBe(file);
    expect(players.values).toHaveLength(1);
    expect(trims.values).toHaveLength(0);
    player.exit.resolve(0);
    expect(await handle.exited).toMatchObject({ status: "completed", duration_ms: 10_000 });
  });

  it("resumes with the original decoded envelope, rebased to the resume offset", async () => {
    const samples = Array.from({ length: 200 }, (_, i) => (i % 10) / 10 + 0.05);
    extractSpy.mockReturnValue({ result: Promise.resolve({ source: "decoded-rms", sample_interval_ms: 50, samples }), cancel: () => {} });
    await pauseAt4200();
    expect(events.filter(e => e.state === "speaking")[0].playback_amplitude.samples).toEqual(samples);
    tts.resumePlayback();
    await players.at(1); await fixtureCheckpoint();
    // VoiceBar indexes the envelope from 0 at the speaking edge: the resumed frame starts at sample 4000/50.
    expect(events.filter(e => e.state === "speaking").at(-1).playback_amplitude)
      .toEqual({ source: "decoded-rms", sample_interval_ms: 50, samples: samples.slice(80) });
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
    expect(handleSocketCommand({ cmd: "pause", id: "p1" } as any)).toMatchObject({ type: "ack", command: "pause", id: "p1", outcome: "accept", offset_ms: 4000 });
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
    expect(handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 3950 } as any)).toMatchObject({ outcome: "accept", offset_ms: 3000 });
    expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ state: "paused", offset_ms: 3000, word_index: 3 });
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
    expect(handleSocketCommand(pause as any)).toMatchObject({ command: "pause", id: "vb-p", outcome: "accept", offset_ms: 4000 });
    const paused = events.filter(e => e.type === "playback_state").at(-1);
    expect(paused).toMatchObject({ state: "paused", playback_id: handle.id, offset_ms: 4000, word_index: 4, word_count: 10 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    at(60_000);
    const resume = parseCommand(JSON.stringify({ cmd: "resume", id: "vb-r", playback_id: paused.playback_id, generation: paused.generation }));
    expect(handleSocketCommand(resume as any)).toMatchObject({ command: "resume", id: "vb-r", outcome: "accept", offset_ms: 4000 });
    const resumedPlayer = await players.at(1); await fixtureCheckpoint();
    const speaking = events.filter(e => e.state === "speaking").at(-1);
    // Same utterance: same text, same readback identity, clock anchored at the paused offset.
    expect(speaking).toMatchObject({ text: firstSpeaking.text, readback_id: firstSpeaking.readback_id, playback_offset_ms: 4000 });
    const resumedEvent = events.filter(e => e.type === "playback_state").at(-1);
    expect(resumedEvent).toMatchObject({ state: "resumed", playback_id: handle.id, offset_ms: 4000, word_index: 4 });
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
      expect(handleSocketCommand({ cmd: "pause" } as any)).toMatchObject({ outcome: "accept", offset_ms: 4000 });
      (await trims.at(trim)).exit.resolve(0); await fixtureCheckpoint();
      const recording = spyOn(input, "getRecordingState").mockReturnValue("recording" as any);
      try {
        expect(await handleSocketCommand({ cmd, id: `${cmd}-1`, ...(cmd === "stop" ? { scope: "capture" } : {}) } as any)).toMatchObject({ command: cmd, outcome: "accept" });
      } finally { recording.mockRestore(); }
      expect(tts.isPlaybackPaused()).toBe(true);
      expect(events.filter(e => e.type === "playback_outcome" && e.playback_id === handle.id)).toEqual([]);
      // Capture over: Play continues the same read from the same word.
      const next = players.values.length;
      expect(handleSocketCommand({ cmd: "resume", playback_id: handle.id } as any)).toMatchObject({ outcome: "accept", offset_ms: 4000 });
      const resumed = await players.at(next); await fixtureCheckpoint();
      expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ state: "resumed", playback_id: handle.id });
      tts.stopPlayback(); resumed.exit.resolve(0); await handle.exited;
    }
  });
});

it("admitted paused playback restarts during drain without new admission", async () => {
  const { updateVoiceGate } = await import("../update-gate-admission");
  const { readUpdateGateFile } = await import("../update-gate-storage");
  await startTenSecondRead();
  at(4200); tts.pausePlayback();
  (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
  const state = readUpdateGateFile();
  if (state.kind !== "OPEN") throw Error("fixture gate must be open");
  const lease = { generation: state.generation + 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  try {
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "accept" });
    await players.at(1);
  } finally { updateVoiceGate({ kind: "CANCEL", lease }); }
});


describe("R2-01 F5 capture ownership", () => {
  it("snaps an arbitrary pause to the containing word, including nonzero words", async () => {
    await startTenSecondRead();
    expect(tts.pausePlayback({}, 4200)).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ word_index: 4, offset_ms: 4000 });
  });

  for (const outcome of ["pasted", "empty", "failed", "cancelled", "timeout"] as const) {
    for (const manual of [false, true]) {
      it(`${outcome}: F5 pauses before capture; manual=${manual} settles exactly once`, async () => {
        await startTenSecondRead();
        at(4200);
        let rejectCapture!: (error: Error) => void;
        const capture = deferred<string | null>();
        const captureResult = Promise.race([capture.promise, new Promise<never>((_resolve, reject) => { rejectCapture = reject; })]);
        let opened = false;
        const wait = spyOn(input, "waitForInput").mockImplementation(() => {
          opened = true;
          expect(tts.isPlaybackPaused()).toBe(true);
          expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ pause_owner: "f5", offset_ms: 4000 });
          return finishSyntheticCapture(() => captureResult);
        });
        try {
          const result = handleSocketCommand({ cmd: "record", id: "capture" });
          await fixtureCheckpoint();
          expect(tts.isPlaybackPaused()).toBe(true);
          for (const trim of trims.values) trim.exit.resolve(0);
          expect(await result).toMatchObject({ outcome: "accept" });
          expect(opened).toBe(true);
          if (manual) expect(await handleSocketCommand({ cmd: "pause" })).toMatchObject({ outcome: "accept", reason: "manual pause" });
          if (outcome === "failed") rejectCapture(new Error("fixture failure"));
          else capture.resolve(outcome === "pasted" ? "fixture transcript" : null);
          await settleRecordingJobs();
          await fixtureCheckpoint();
          expect(tts.isPlaybackPaused()).toBe(manual);
          expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(manual ? 0 : 1);
          if (!manual) expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 4000 });
        } finally { capture.resolve(null); wait.mockRestore(); }
      });
    }
  }
});


it("R2-01 N6 all takes and actual paste delivery settle before exactly one resume", async () => {
  await startTenSecondRead();
  at(4300);
  const a = deferred<void>(), b = deferred<void>(), bMic = deferred<void>();
  let captures = 0;
  const wait = spyOn(input, "waitForInput").mockImplementation(() => {
    const index = captures++;
    return (async () => {
      if (index === 1) await bMic.promise;
      return finishBarCapture(Promise.resolve(), "fixture.wav", async () => {
        await (index === 0 ? a.promise : b.promise);
        await deliverInputTranscription({ type: "transcription", text: index === 0 ? "first" : "second" });
        return "transcript";
      });
    })();
  });
  try {
    await handleSocketCommand({ cmd: "record", take_id: "A", playback_elapsed_ms: 2500 });
    (await trims.at(0)).exit.resolve(0);
    await fixtureCheckpoint();
    expect(recordingJobsSnapshot().mic_take_id).toBeNull();
    expect(recordingJobsSnapshot().processing_count).toBe(1);
    await handleSocketCommand({ cmd: "record", take_id: "B" });
    await fixtureCheckpoint();
    expect(captures).toBe(2);
    expect(recordingJobsSnapshot().mic_take_id).toBe("B");
    a.resolve();
    await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(acknowledgeDictationDelivery("A", "A")).toBe(true);
    await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(true);
    bMic.resolve(); b.resolve();
    await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(acknowledgeDictationDelivery("B", "B")).toBe(true);
    await settleRecordingJobs(); await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(1);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 2000 });
    // Stale delivery plus stale recording idle cannot change a later manual pause.
    expect(await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 3500 })).toMatchObject({ outcome: "accept", offset_ms: 3000 });
    expect(acknowledgeDictationDelivery("A", "A")).toBe(false);
    expect(acknowledgeDictationDelivery("B", "B")).toBe(false);
    await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(1);
  } finally {
    a.resolve(); b.resolve(); bMic.resolve();
    acknowledgeDictationDelivery("A", "A"); acknowledgeDictationDelivery("B", "B");
    await settleRecordingJobs(); wait.mockRestore();
  }
});

it("R2-01 N6 actual early B failure keeps the read parked for processing A", async () => {
  await startTenSecondRead();
  at(4300);
  const finishA = deferred<void>(), processingA = deferred<void>();
  const first = runBarCaptureWithPausedRead("early-failure-A", async (opened) => {
    opened();
    return finishBarCapture(Promise.resolve(), "fixture.wav", async () => {
      processingA.resolve();
      await finishA.promise;
      return null;
    });
  }, () => {}, () => {}, 2500);
  (await trims.at(0)).exit.resolve(0);
  try {
    await processingA.promise;
    const second = runBarCaptureWithPausedRead("early-failure-B", async () => {
      throw new Error("B recorder failed before archive");
    }, () => {}, () => {});
    await expect(second).rejects.toThrow("B recorder failed before archive");
    // B really left the take set; this is not just a result waiting behind A in FIFO.
    expect(recordingJobsSnapshot().recording_jobs.map(job => job.take_id)).toEqual(["early-failure-A"]);
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(events.filter(event => event.type === "playback_state" && event.state === "resumed")).toHaveLength(0);
    finishA.resolve();
    await first;
    await fixtureCheckpoint();
    expect(recordingJobsSnapshot().recording_jobs).toHaveLength(0);
    expect(tts.isPlaybackPaused()).toBe(false);
    const resumed = events.filter(event => event.type === "playback_state" && event.state === "resumed");
    expect(resumed).toHaveLength(1);
    expect(resumed[0]).toMatchObject({ offset_ms: 2000 });
  } finally {
    finishA.resolve();
    await first;
  }
});

it("R2-01 speech-scoped Stop wins without stopping an active take", async () => {
  await startTenSecondRead();
  const done = deferred<string | null>();
  const wait = spyOn(input, "waitForInput").mockImplementation(() => finishSyntheticCapture(() => done.promise));
  try {
    await handleSocketCommand({ cmd: "record", take_id: "stop-capture" });
    await fixtureCheckpoint();
    expect(await handleSocketCommand({ cmd: "stop", scope: "speech" })).toMatchObject({ outcome: "accept" });
    expect(recordingJobsSnapshot().recording_jobs).toHaveLength(1);
    done.resolve(null); await settleRecordingJobs(); await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(players.values).toHaveLength(1);
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(0);
  } finally { done.resolve(null); await settleRecordingJobs(); wait.mockRestore(); }
});


it("R2-01 waits for actual player exit and preserves the early physical release", async () => {
  holdPlayerExit = true;
  clearStopSignal();
  const { player } = await startTenSecondRead();
  at(2500);
  const done = deferred<string | null>();
  let opened = false;
  const wait = spyOn(input, "waitForInput").mockImplementation((_timeout, _silence, _ptt, options) => {
    opened = true;
    options?.onCaptureStart?.();
    return finishSyntheticCapture(() => done.promise);
  });
  try {
    expect(await handleSocketCommand({ cmd: "record", take_id: "early-release" })).toMatchObject({ outcome: "accept" });
    await fixtureCheckpoint();
    expect(opened).toBe(false);
    expect(await handleSocketCommand({ cmd: "stop", scope: "capture", take_id: "early-release", physical_press: true })).toMatchObject({ outcome: "accept" });
    player.exit.resolve(143);
    (await trims.at(0)).exit.resolve(0);
    await fixtureCheckpoint();
    expect(opened).toBe(true);
    expect(JSON.parse(readFileSync(STOP_FILE, "utf8"))).toMatchObject({ physical_press: true });
    done.resolve(null); await settleRecordingJobs(); await fixtureCheckpoint();
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(1);
  } finally { done.resolve(null); player.exit.resolve(143); await settleRecordingJobs(); wait.mockRestore(); }
});

for (const state of ["idle", "recording", "transcribing"] as const) {
  it(`R2-01 legacy unscoped Stop ends paused speech without an F5 capture (${state})`, async () => {
    const { handle } = await pauseAt4200();
    setRecordingState(state);
    try {
      expect(tts.hasF5Capture()).toBe(false);
      expect(await handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "accept" });
      expect(tts.isPlaybackPaused()).toBe(false);
      expect(await handle.exited).toMatchObject({ reason: "stopped" });
    } finally { setRecordingState("idle"); }
  });
}

for (const phase of ["opening", "capturing"] as const) {
  it(`R2-01 unscoped Stop targets only its F5 take (${phase})`, async () => {
    await startTenSecondRead();
    const opened = deferred<void>(), result = deferred<string | null>();
    const wait = spyOn(input, "waitForInput").mockImplementation((_timeout, _silence, _ptt, options) => {
      options?.onCaptureStart?.(); opened.resolve();
      return finishSyntheticCapture(() => result.promise);
    });
    try {
      expect(handleSocketCommand({ cmd: "record", take_id: `unscoped-${phase}`, playback_elapsed_ms: 4200 })).toMatchObject({ outcome: "accept" });
      if (phase === "capturing") await opened.promise;
      expect(await handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "accept" });
      await opened.promise;
      expect(JSON.parse(readFileSync(STOP_FILE, "utf8"))).toMatchObject({ take_id: `unscoped-${phase}`, physical_press: false });
      expect(tts.isPlaybackPaused()).toBe(true);
      expect(events.filter(e => e.type === "playback_outcome")).toEqual([]);
      for (const trim of trims.values) trim.exit.resolve(0);
      result.resolve(null);
      await settleRecordingJobs(); await fixtureCheckpoint();
      await players.at(1);
      expect(tts.hasF5Capture()).toBe(false);
    } finally { result.resolve(null); await settleRecordingJobs(); wait.mockRestore(); clearStopSignal(); }
  });
}

it("R2-01 a fresh daemon has no loan or parked read after restart", async () => {
  await startTenSecondRead();
  const capture = tts.pauseForF5Capture();
  await capture.ready;
  try {
    const child = Bun.spawnSync([process.execPath, "--preload", "./src/__tests__/setup/preload.ts", "-e",
      'import { hasF5Capture, isPlaybackPaused } from "./src/tts.ts"; if (hasF5Capture() || isPlaybackPaused()) process.exit(1);'],
      { cwd: process.cwd(), env: process.env, stdout: "pipe", stderr: "pipe" });
    expect(child.exitCode).toBe(0);
  } finally { tts.stopPlayback(); capture.settle(); }
});

it("R2-01 refused automatic resume after slice preparation releases the read", async () => {
  const { handle } = await startTenSecondRead();
  const capture = tts.pauseForF5Capture(4200);
  await capture.ready;
  capture.settle(); // Resume waits for the owned trim; a new busy state wins before it completes.
  setRecordingState("transcribing");
  try {
    (await trims.at(0)).exit.resolve(0);
    await fixtureCheckpoint();
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(await handle.exited).toMatchObject({ reason: "resume-refused" });
    expect(events.filter(e => e.type === "error")).toEqual([]);
    expect(players.values).toHaveLength(1);
  } finally { setRecordingState("idle"); capture.settle(); }
});

it("R2-01 refused automatic resume releases the read instead of stranding its F5 park", async () => {
  const { handle } = await startTenSecondRead();
  const capture = tts.pauseForF5Capture(4200);
  await capture.ready;
  (await trims.at(0)).exit.resolve(0);
  await fixtureCheckpoint();
  expect(getRecordingState()).toBe("idle");
  safeWriteFileSync(recordingStateFilePath(), JSON.stringify({ state: "transcribing", pid: process.ppid, updated_at: new Date().toISOString() }));
  expect(getEffectiveRecordingState()).toBe("transcribing");
  try {
    capture.settle();
    expect(tts.hasF5Capture()).toBe(false);
    expect(tts.isPlaybackPaused()).toBe(false);
    expect(await handle.exited).toMatchObject({ status: "interrupted", reason: "resume-refused", stopped_at_ms: 4000 });
    expect(events.filter(e => e.type === "playback_outcome").at(-1)).toMatchObject({ playback_id: handle.id, reason: "resume-refused" });
    expect(players.values).toHaveLength(1);
  } finally { setRecordingState("idle"); capture.settle(); }
  await startTenSecondRead("A later read can start");
  expect(players.values).toHaveLength(2);
});

it("R2-01 stale capture settlement cannot unpause a later user pause", async () => {
  await startTenSecondRead();
  at(2500);
  const capture = tts.pauseForF5Capture();
  await capture.ready;
  (await trims.at(0)).exit.resolve(0);
  await fixtureCheckpoint();
  capture.settle();
  await players.at(1);
  expect(tts.pausePlayback({}, 3500)).toMatchObject({ outcome: "accept", offset_ms: 3000 });
  capture.settle(); capture.settle();
  await fixtureCheckpoint();
  expect(tts.isPlaybackPaused()).toBe(true);
  expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(1);
  expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ pause_owner: "user" });
});

it("R2-01 retains the containing word at a nonzero chunk offset", async () => {
  tts.playAudioNonBlocking(`${TEST_TMP}/later-chunk.mp3`, { text: words.map(word => word.text).join(" "),
    voice: "test", durationMs: 10000, wordBoundaries: words,
    longRead: { id: "long", chunk_index: 1, chunk_count: 2, chunk_start_ms: 10000 } });
  await players.at(0);
  expect(tts.pausePlayback({}, 13500)).toMatchObject({ outcome: "accept", offset_ms: 13000 });
  (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
  expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 13000 });
  await players.at(1);
  expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ word_index: 3, chunk_offset_ms: 3000, offset_ms: 13000 });
});


it("R2-01 uses clone alignment and retains its display word index", async () => {
  tts.playAudioNonBlocking(`${TEST_TMP}/clone.mp3`, { text: "One two three", voice: "test", durationMs: 10000,
    alignedWords: [
      { word_index: 0, text: "One", offset_ms: 0, duration_ms: 1000 },
      { word_index: 1, text: "two", offset_ms: 1000, duration_ms: 1000 },
      { word_index: 2, text: "three", offset_ms: 2000, duration_ms: 8000 },
    ] });
  await players.at(0);
  expect(tts.pausePlayback({}, 4200)).toMatchObject({ outcome: "accept", offset_ms: 2000 });
  (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
  expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ word_index: 2, offset_ms: 2000 });
  expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 2000 });
  await players.at(1);
  expect(events.filter(e => e.type === "playback_state").at(-1)).toMatchObject({ word_index: 2, offset_ms: 2000 });
});


it("R2-01 Lane I failed-take promise does not release the read before physical exit proof", async () => {
  await startTenSecondRead();
  const exit = deferred<void>();
  const capture = runBarCaptureWithPausedRead("failed-exit-proof", async () => {
    registerBarRecorderExit(exit.promise);
    throw new Error("fixture recorder failure");
  }, () => {}, () => {}, undefined, { failureSettlementMs: 1 });
  try {
    await expect(capture).rejects.toThrow("fixture recorder failure");
    expect(recordingJobsSnapshot().capture_error).toContain("Recorder exit unconfirmed");
    expect(tts.hasF5Capture()).toBe(true);
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(0);
    exit.resolve();
    await settleRecordingJobs(); await fixtureCheckpoint();
    expect(tts.hasF5Capture()).toBe(false);
    expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(1);
  } finally { exit.resolve(); await settleRecordingJobs(); }
});

it("R2-01 Lane I legacy delivery capability is passed through the single adapter", async () => {
  await startTenSecondRead();
  await runBarCaptureWithPausedRead("legacy-no-ack", () => finishSyntheticCapture(async () => {
    await deliverInputTranscription({ type: "transcription", text: "legacy fixture" });
    return "legacy fixture";
  }), () => {}, () => {}, undefined, { expectsAck: false });
  await fixtureCheckpoint();
  expect(recordingJobsSnapshot().recording_jobs).toHaveLength(0);
  expect(acknowledgeDictationDelivery("legacy-no-ack", "legacy-no-ack")).toBe(false);
  expect(events.filter(e => e.type === "playback_state" && e.state === "resumed")).toHaveLength(1);
});
