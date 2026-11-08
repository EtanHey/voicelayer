/**
 * Lane B (2.4) daemon-side proof for the PlaybackSession engine wired into the real queue
 * manager: Etan's named bugs, fail-first. Players, trims and the clock are faked exactly as in
 * tts-pause.test.ts; no audio device, socket or live path is touched.
 */
import { afterEach, beforeEach, describe, expect, it, setSystemTime, spyOn } from "bun:test";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as input from "../input";
import * as recording from "../recording-state";
import * as booking from "../session-booking";
import { handleVoiceAsk } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
import { addToHistory } from "../tts";
import { playbackSessionViolations, resetPlaybackSessionLedger } from "../playback/ledger";
import { mkdirSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

const T0 = new Date("2026-11-08T12:00:00.000Z").getTime();
const at = (ms: number) => setSystemTime(new Date(T0 + ms));
const words = ["One", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
  .map((text, i) => ({ offset_ms: i * 1000, duration_ms: 800, text }));
const text = words.map(word => word.text).join(" ");

type Player = { argv: string[]; exit: ReturnType<typeof deferred<number>> };
let players: ReturnType<typeof fixtureBarrier<Player>>;
let trims: ReturnType<typeof fixtureBarrier<{ argv: string[]; exit: ReturnType<typeof deferred<number>> }>>;
let events: any[];
let restore: (() => void)[];

beforeEach(() => {
  at(0);
  resetPlaybackSessionLedger();
  players = fixtureBarrier(); trims = fixtureBarrier(); events = []; restore = [];
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    const exit = deferred<number>();
    if (argv[0] === "which") { exit.resolve(0); return { pid: 1, exited: exit.promise, kill() {}, stdout: new Blob(["/fake/ffmpeg"]).stream() }; }
    if (argv.includes("-version")) { exit.resolve(0); return { pid: 3, exited: exit.promise, kill() {} }; }
    if (argv.includes("-ss")) { trims.push({ argv, exit }); return { pid: 2, exited: exit.promise, kill: () => exit.resolve(143) }; }
    players.push({ argv, exit });
    return { pid: 9000 + players.values.length, exited: exit.promise, kill: () => exit.resolve(143) };
  }) as any);
  const extract = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue(
    { result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel: () => {} } as any);
  // Each event carries its virtual time (__t, ms since T0) so a Swift test can replay the stream on the same clock.
  const cast = spyOn(socket, "broadcast").mockImplementation((event: any) => { events.push({ ...event, __t: Date.now() - T0 }); });
  restore = [() => spawn.mockRestore(), () => extract.mockRestore(), () => cast.mockRestore()];
});

afterEach(async () => {
  tts.stopPlayback();
  for (const p of players.values) p.exit.resolve(0);
  for (const t of trims.values) t.exit.resolve(0);
  await tts.awaitCurrentPlayback();
  for (const undo of restore) undo();
  setSystemTime();
});

const lastState = () => events.filter(e => e.type === "playback_state").at(-1);

describe("Etan bug: pause jumps back (QA 2026-11-08, pause button → 0:00)", () => {
  it("a client clock reset to 0 (VoiceBar 'preparing') pauses at the daemon's word, not word 0", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/jump.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words });
    await players.at(0);
    at(4200);
    expect(tts.pausePlayback({}, 0)).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    expect(lastState()).toMatchObject({ state: "paused", word_index: 4, offset_ms: 4000 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    expect(tts.resumePlayback()).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    await players.at(1); await fixtureCheckpoint();
    expect(lastState()).toMatchObject({ state: "resumed", word_index: 4, offset_ms: 4000 });
  });

  it("a chunk-local client clock on a later chunk never rewinds to the chunk start", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/jump-chunk.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words,
      longRead: { id: "jump-read", chunk_index: 1, chunk_count: 2, chunk_start_ms: 10_000 } });
    await players.at(0);
    at(6500);
    // VoiceBar sent the chunk-local 6.5 s instead of the read-global 16.5 s.
    expect(tts.pausePlayback({}, 6500)).toMatchObject({ outcome: "accept", offset_ms: 16_000 });
    expect(lastState()).toMatchObject({ word_index: 6, chunk_offset_ms: 6000 });
  });

  it("a second pause after a resume lands on the word heard, never an earlier one", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/jump-twice.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words });
    await players.at(0);
    at(3100);
    expect(tts.pausePlayback({}, 3100)).toMatchObject({ offset_ms: 3000 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    at(20_000);
    expect(tts.resumePlayback()).toMatchObject({ offset_ms: 3000 });
    await players.at(1); await fixtureCheckpoint();
    // 2.4 s after the resume the audio is on word 5 (3000 + 2400). The client clock reads 0.
    at(22_400);
    expect(tts.pausePlayback({}, 0)).toMatchObject({ outcome: "accept", offset_ms: 5000 });
    expect(lastState()).toMatchObject({ word_index: 5 });
  });

  it("a client clock that agrees with the player is still used (it follows what was heard)", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/agree.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words });
    await players.at(0);
    at(4300);
    // The client heard word 3 a moment ago; within tolerance, its clock wins over the spawn clock.
    expect(tts.pausePlayback({}, 3900)).toMatchObject({ outcome: "accept", offset_ms: 3000 });
  });
});

const read = (id = "read-1", file = "read.mp3") => tts.playAudioNonBlocking(`${TEST_TMP}/${file}`, {
  text, voice: "test", durationMs: 10_000, wordBoundaries: words,
  longRead: { id, chunk_index: 0, chunk_count: 1, chunk_start_ms: 0 } });
const states = (state: string) => events.filter(e => e.type === "playback_state" && e.state === state);

describe("socket E2E: the playback engine through real commands (VoiceBar's wire)", () => {
  it("pause → resume by socket lands on the paused word, even with VoiceBar's reset clock", async () => {
    read();
    await players.at(0);
    at(4200);
    expect(await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 0 })).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept", offset_ms: 4000 });
    await players.at(1); await fixtureCheckpoint();
    expect(states("resumed").at(-1)).toMatchObject({ word_index: 4, offset_ms: 4000 });
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "playing", session_id: "read-1", word_index: 4 });
    // The speaking edge names the NarrationSource (VoiceBar exposes it as narration-origin).
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ narration_source: "voicelayer-engines" });
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("Esc (stop) during a resumed read ends it and nothing restarts", async () => {
    const handle = read();
    await players.at(0);
    at(2100);
    await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 2100 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    await handleSocketCommand({ cmd: "resume" });
    const resumed = await players.at(1); await fixtureCheckpoint();
    at(3000);
    const ack = handleSocketCommand({ cmd: "stop", playback_elapsed_ms: 2900 });
    resumed.exit.resolve(143);
    expect(await ack).toMatchObject({ outcome: "accept" });
    expect((await handle.exited).status).toBe("interrupted");
    await fixtureCheckpoint();
    expect(players.values).toHaveLength(2);
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "idle" });
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("seek lands on its word and the session follows", async () => {
    read();
    await players.at(0);
    at(1500);
    expect(await handleSocketCommand({ cmd: "seek", offset_ms: 6000 })).toMatchObject({ outcome: "accept", offset_ms: 6000 });
    (await trims.at(0)).exit.resolve(0);
    await players.at(1); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 6000 });
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "playing", word_index: 6 });
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("previous read replays the last narration from word 0; the read on screen returns paused at its word", async () => {
    const earlier = `${TEST_TMP}/earlier.mp3`;
    writeFileSync(earlier, "fake audio");
    addToHistory("An earlier read about Codex", earlier, "test");
    read();
    await players.at(0);
    at(5300);
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "accept" });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    const replay = await players.at(1); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "An earlier read about Codex" });
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "playing", word_index: 0 });
    replay.exit.resolve(0); await fixtureCheckpoint(); await fixtureCheckpoint();
    expect(states("paused").at(-1)).toMatchObject({ word_index: 5, offset_ms: 5000, pause_owner: "user" });
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "paused", session_id: "read-1", word_index: 5 });
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept", offset_ms: 5000 });
    await players.at(2);
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("previous read with nothing on screen replays the last narration", async () => {
    const earlier = `${TEST_TMP}/earlier-idle.mp3`;
    writeFileSync(earlier, "fake audio");
    addToHistory("The last thing read", earlier, "test");
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "accept" });
    await players.at(0);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "The last thing read" });
  });

  it("set_playback_speed: 1.5× restarts the playing read at its word with afplay -r, and the clock scales", async () => {
    read();
    await players.at(0);
    at(3400);
    expect(await handleSocketCommand({ cmd: "set_playback_speed", speed: 1.5 })).toMatchObject({ outcome: "accept" });
    (await trims.at(0)).exit.resolve(0);
    const fast = await players.at(1); await fixtureCheckpoint();
    expect(fast.argv).toContain("-r");
    expect(fast.argv[fast.argv.indexOf("-r") + 1]).toBe("1.5");
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 3000, playback_rate: 1.5 });
    // 2 s of wall time at 1.5× is 3 s of audio: 3000 + 3000 = word 6.
    at(5400);
    expect(tts.pausePlayback({})).toMatchObject({ outcome: "accept", offset_ms: 6000 });
    expect(await handleSocketCommand({ cmd: "set_playback_speed", speed: 3 })).toBeNull;
    await handleSocketCommand({ cmd: "set_playback_speed", speed: 1 });
  });
});

describe("socket E2E: voice_ask over a read (parks and restores, twice back to back)", () => {
  let asks: ReturnType<typeof spyOn>[] = [];
  let captures = 0;
  beforeEach(() => {
    captures = 0;
    asks = [
      spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true } as any),
      spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
      spyOn(input, "clearInput").mockImplementation(() => {}),
      spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(socket, "isConnected").mockReturnValue(true),
      spyOn(input, "waitForInput").mockImplementation((async (_ms: number, _mode: unknown, _push: unknown, options: any) => {
        captures++;
        options?.onCaptureStart?.();
        options?.onCaptureEnd?.(1000);
        return `answer ${captures}`;
      }) as any),
      spyOn(tts, "speak").mockImplementation(async (message: string, options: any) => {
        const handle = tts.playAudioNonBlocking(`${TEST_TMP}/prompt.mp3`, {
          text: message, voice: "test", durationMs: 1000, priority: "critical", onQueued: options?.onPlaybackQueued,
          wordBoundaries: [{ text: message, offset_ms: 0, duration_ms: 1000 }] });
        return { playbackId: handle.id, playbackOutcome: await handle.exited, displayText: message,
          engine: "edge-tts", voice: "test", audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } } as any;
      }),
    ];
  });
  afterEach(() => { for (const spy of asks) spy.mockRestore(); });

  async function askOver(expectedPlayer: number, message: string, trim?: number) {
    const answer = handleVoiceAsk({ message, timeout_seconds: 5 });
    await fixtureCheckpoint();
    // The parked read's resume slice is cut while the ask drains the queue; the prompt follows it.
    if (trim !== undefined) (await trims.at(trim)).exit.resolve(0);
    await fixtureCheckpoint();
    const prompt = await players.at(expectedPlayer);
    await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: message });
    prompt.exit.resolve(0);
    const result = await answer;
    expect(result.isError).not.toBe(true);
    expect(result.content[0].text).toContain(`answer ${captures}`);
    return result;
  }

  it("a playing read is parked at its word, restored playing from it, and the second ask does the same", async () => {
    const handle = read();
    await players.at(0);
    at(3200);
    await askOver(1, "First question?", 0);
    await players.at(2); await fixtureCheckpoint();
    expect(states("resumed").at(-1)).toMatchObject({ word_index: 3, offset_ms: 3000 });
    // 1.1 s into the restored read the audio is on word 4; the second ask parks it there.
    at(4300);
    await askOver(3, "Second question?", 1);
    const last = await players.at(4); await fixtureCheckpoint();
    expect(states("resumed").at(-1)).toMatchObject({ word_index: 4, offset_ms: 4000 });
    expect(captures).toBe(2);
    expect(playbackSessionViolations()).toEqual([]);
    last.exit.resolve(0);
    expect((await handle.exited).status).toBe("completed");
  });

  /** QA 11:47 Row 1: after ask 1 the clock came back at 0:10 (the read paused at 0:41); after ask 2 the read UI
   * vanished while its audio played. The read here is chunk 2 of 2 (it starts at 0:30), so a chunk-local clock
   * would show 0:11. The stream is also written for the Swift replay (PlaybackEngineContractReplayTests). */
  it("Row 1: a read on its second chunk comes back at 0:40 (never a chunk-local 0:10) after ask 1 and ask 2, attached each time", async () => {
    const handle = tts.playAudioNonBlocking(`${TEST_TMP}/row1.mp3`, { text, voice: "test", durationMs: 20_000, utteranceDurationMs: 50_000,
      wordBoundaries: words.map(word => ({ ...word, offset_ms: word.offset_ms * 2 })),
      longRead: { id: "row1-read", chunk_index: 1, chunk_count: 2, chunk_start_ms: 30_000 } });
    await players.at(0);
    at(11_200);
    await askOver(1, "Quick check for your recording?", 0);
    await players.at(2); await fixtureCheckpoint();
    const first = events.filter(e => e.state === "speaking" && e.text === text).at(-1);
    // The restored edge keeps the read's total: a chunk-length duration would clamp the clock (QA: 0:41 came back 0:10).
    expect(first).toMatchObject({ playback_offset_ms: 40_000, duration_ms: 50_000, chunk_duration_ms: 20_000,
      long_read: { chunk_start_ms: 30_000 } });
    expect(states("resumed").at(-1)).toMatchObject({ offset_ms: 40_000, chunk_offset_ms: 10_000, word_index: 5 });
    // The pill's last word after the restore is the read, never idle.
    expect(events.filter(e => e.type === "state").at(-1)).toMatchObject({ state: "speaking", text });
    at(14_300);
    await askOver(3, "Second check: did the read pause?", 1);
    await players.at(4); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking" && e.text === text).at(-1)).toMatchObject({ playback_offset_ms: 42_000 });
    expect(events.filter(e => e.type === "state").at(-1)).toMatchObject({ state: "speaking", text });
    // #818: a Pause after the second restore, answered by the daemon, so the Swift replay checks the response too.
    at(15_300);
    const restored = events.filter(e => e.state === "speaking" && e.text === text).at(-1);
    expect(await handleSocketCommand({ cmd: "pause", playback_id: restored.playback_id, generation: restored.generation,
      playback_elapsed_ms: 43_000 })).toMatchObject({ outcome: "accept", offset_ms: 42_000 });
    expect(states("paused").at(-1)).toMatchObject({ offset_ms: 42_000, word_index: 6 });
    expect(playbackSessionViolations()).toEqual([]);
    // Normalized stream for the Swift contract replay: process-specific ids become stable tokens.
    const ids = new Map<string, string>();
    const stable = (value: string) => value.replace(/playback-\d+-\d+-\d+/g, id => {
      if (!ids.has(id)) ids.set(id, `playback-${ids.size + 1}`);
      return ids.get(id)!;
    });
    const consumed = new Set(["state", "playback_state", "speech_words", "subtitle", "playback_duration", "playback_session", "ack"]);
    const stream = events.filter(e => consumed.has(e.type)).map(e => JSON.parse(stable(JSON.stringify(e))));
    const fixture = join(import.meta.dir, "../../flow-bar/Tests/Fixtures/laneb-row1-ask-over-read-events.json");
    if (process.env.LANEB_RECORD_STREAM === "1") {
      mkdirSync(dirname(fixture), { recursive: true });
      writeFileSync(fixture, JSON.stringify({ source: "src/__tests__/playback-engine.test.ts Row 1", text, events: stream }, null, 1) + "\n");
    }
    void handle.exited;
  });

  it("a user-paused read stays paused across the ask and keeps its word", async () => {
    read();
    await players.at(0);
    at(6400);
    await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 6400 });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    await askOver(1, "Question while paused?");
    await fixtureCheckpoint();
    expect(states("resumed")).toHaveLength(0);
    expect(states("paused").at(-1)).toMatchObject({ word_index: 6, offset_ms: 6000, pause_owner: "user" });
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept", offset_ms: 6000 });
    await players.at(2);
    expect(playbackSessionViolations()).toEqual([]);
  });
});

describe("Lane B P0 (QA 11:47 clock rows): the daemon reports its player's position and re-anchors honestly", () => {
  const positions = () => events.filter(e => e.type === "playback_position");
  const tick = () => new Promise(resolve => setTimeout(resolve, 160));

  it("k04-49/k07-64: playback_position carries the read-global position, the player's bounds and the word", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/position.mp3`, { text, voice: "test", durationMs: 10_000, utteranceDurationMs: 40_000,
      wordBoundaries: words, longRead: { id: "position-read", chunk_index: 1, chunk_count: 3, chunk_start_ms: 10_000 } });
    await players.at(0);
    at(3200);
    await tick();
    expect(positions().at(-1)).toMatchObject({ offset_ms: 13_200, chunk_start_ms: 10_000, chunk_duration_ms: 10_000,
      duration_ms: 40_000, word_index: 3 });
    at(6500);
    await tick();
    expect(positions().at(-1)).toMatchObject({ offset_ms: 16_500, word_index: 6 });
    // The ledger's cursor follows the player too (TeleTracksAudio is now checked on real word progress).
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "playing", word_index: 6 });
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("S-01: resync_playback re-sends the playing read at its live position with its word table", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/resync.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words,
      longRead: { id: "resync-read", chunk_index: 0, chunk_count: 1, chunk_start_ms: 0 } });
    await players.at(0);
    at(4100);
    const before = events.length;
    expect(await handleSocketCommand({ cmd: "resync_playback" })).toMatchObject({ outcome: "accept" });
    const sent = events.slice(before);
    expect(sent.find(e => e.state === "speaking")).toMatchObject({ text, playback_offset_ms: 4100, reanchor: "resync" });
    expect(sent.some(e => e.type === "speech_words")).toBe(true);
    expect(sent.find(e => e.type === "playback_state")).toMatchObject({ state: "resumed" });
    expect(await handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "accept" });
    expect(await handleSocketCommand({ cmd: "resync_playback" })).toMatchObject({ outcome: "noop" });
  });

  it("k03-21/k07-29: only a seek, resume or replay edge may move the client clock back (edges say why)", async () => {
    tts.playAudioNonBlocking(`${TEST_TMP}/reanchor.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words });
    await players.at(0);
    expect(events.filter(e => e.state === "speaking").at(-1).reanchor).toBeUndefined();
    at(5000);
    await handleSocketCommand({ cmd: "seek", offset_ms: 2000 });
    (await trims.at(0)).exit.resolve(0);
    await players.at(1); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 2000, reanchor: "seek" });
    at(6000);
    tts.pausePlayback({}, undefined);
    (await trims.at(1)).exit.resolve(0); await fixtureCheckpoint();
    tts.resumePlayback();
    await players.at(2); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ reanchor: "resume" });
  });
});
