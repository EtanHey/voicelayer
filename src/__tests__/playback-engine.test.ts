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
import { ledgerSnapshot, playbackSessionEngine, playbackSessionViolations, resetPlaybackSessionLedger } from "../playback/ledger";
import { mkdirSync, rmSync, writeFileSync } from "fs";
import { TTS_HISTORY_FILE } from "../paths";
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
  tts.resetHeardQueueForTests();
  // History is process-wide in a combined run: another file's later-stamped narration must not become "previous".
  rmSync(TTS_HISTORY_FILE, { force: true });
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
/** T1: Back reaches only what this queue played. Hear `earlier` to its end, then put read-1 on screen (player 1). */
async function hearThenRead(file: string, earlierText: string): Promise<void> {
  tts.playAudioNonBlocking(file, { text: earlierText, voice: "test", durationMs: 2000 });
  read();
  (await players.at(0)).exit.resolve(0);
  await players.at(1);
}

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
    // T1: the earlier narration was heard in this queue, right before the read on screen.
    await hearThenRead(earlier, "An earlier read about Codex");
    at(5300);
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "accept" });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    const replay = await players.at(2); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "An earlier read about Codex" });
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "playing", word_index: 0 });
    replay.exit.resolve(0); await fixtureCheckpoint(); await fixtureCheckpoint();
    expect(states("paused").at(-1)).toMatchObject({ word_index: 5, offset_ms: 5000, pause_owner: "user" });
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ phase: "paused", session_id: "read-1", word_index: 5 });
    expect(await handleSocketCommand({ cmd: "resume" })).toMatchObject({ outcome: "accept", offset_ms: 5000 });
    await players.at(3);
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("previous read with nothing on screen replays the last narration heard", async () => {
    const earlier = `${TEST_TMP}/earlier-idle.mp3`;
    writeFileSync(earlier, "fake audio");
    addToHistory("The last thing read", earlier, "test");
    tts.playAudioNonBlocking(earlier, { text: "The last thing read", voice: "test", durationMs: 2000 });
    (await players.at(0)).exit.resolve(0); await tts.awaitCurrentPlayback(); await fixtureCheckpoint();
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "accept" });
    await players.at(1);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "The last thing read" });
  });

  it("T1: Back is scoped to the current queue: archive-only and unheard narrations are never offered", async () => {
    const archived = `${TEST_TMP}/archive-only.mp3`;
    writeFileSync(archived, "fake audio");
    // In History (synthesised earlier, or queued ahead and never played), but not heard in this queue.
    addToHistory("Never heard in this queue", archived, "test");
    expect(tts.hasPreviousRead()).toBe(false);
    read();
    await players.at(0);
    expect(tts.hasPreviousRead()).toBe(false);
    expect(events.filter(e => e.type === "playback_session").at(-1)).toMatchObject({ previous_available: false });
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "noop", reason: "no previous read" });
    expect(players.values).toHaveLength(1);
  });

  /** Codex round 1 (P2): Back keeps narration identity and occurrence order, never unique text. */
  async function hearInOrder(items: { file: string; text: string; voice?: string; ref?: ReturnType<typeof addToHistory> }[]) {
    for (const item of items) {
      tts.playAudioNonBlocking(item.file, { text: item.text, voice: item.voice ?? "heard", durationMs: 2000,
        ...(item.ref ? { historyRef: item.ref } : {}) });
    }
    for (let i = 0; i < items.length - 1; i++) { (await players.at(i)).exit.resolve(0); await players.at(i + 1); }
  }
  async function back(): Promise<any> {
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "accept" });
    for (const trim of trims.values) trim.exit.resolve(0);
    await fixtureCheckpoint();
    return events.filter(e => e.state === "speaking").at(-1);
  }
  const audio = (name: string) => { const path = `${TEST_TMP}/${name}.mp3`; writeFileSync(path, name); return path; };

  it("T1 r2: a heard A, B, A, C goes back from C to the SECOND A (its own retained audio)", async () => {
    const a1 = audio("order-a1"), b = audio("order-b"), a2 = audio("order-a2"), c = audio("order-c");
    const refA1 = addToHistory("Narration A", a1, "first-a");
    const refB = addToHistory("Narration B", b, "heard");
    const refA2 = addToHistory("Narration A", a2, "second-a");
    const refC = addToHistory("Narration C", c, "heard");
    await hearInOrder([{ file: a1, text: "Narration A", voice: "first-a", ref: refA1 }, { file: b, text: "Narration B", ref: refB },
      { file: a2, text: "Narration A", voice: "second-a", ref: refA2 }, { file: c, text: "Narration C", ref: refC }]);
    const replay = await back();
    expect(replay).toMatchObject({ text: "Narration A", voice: "second-a" });
  });

  it("T1 r2: while the second A plays, Back is available and goes to B", async () => {
    const a1 = audio("again-a1"), b = audio("again-b"), a2 = audio("again-a2");
    const refA1 = addToHistory("Narration A", a1, "first-a");
    const refB = addToHistory("Narration B", b, "heard");
    const refA2 = addToHistory("Narration A", a2, "second-a");
    await hearInOrder([{ file: a1, text: "Narration A", voice: "first-a", ref: refA1 }, { file: b, text: "Narration B", ref: refB },
      { file: a2, text: "Narration A", voice: "second-a", ref: refA2 }]);
    expect(tts.hasPreviousRead()).toBe(true);
    expect(await back()).toMatchObject({ text: "Narration B" });
  });

  it("T1 r2: Back replays the audio that was heard, never a newer unheard archive entry with the same text", async () => {
    const heard = audio("identity-heard"), b = audio("identity-b"), unheard = audio("identity-unheard");
    const refHeard = addToHistory("Narration A", heard, "heard-voice");
    const refB = addToHistory("Narration B", b, "heard");
    await hearInOrder([{ file: heard, text: "Narration A", voice: "heard-voice", ref: refHeard },
      { file: b, text: "Narration B", ref: refB }]);
    at(50);
    addToHistory("Narration A", unheard, "UNHEARD-voice");
    expect(await back()).toMatchObject({ text: "Narration A", voice: "heard-voice" });
  });

  it("T1 r2: a referenced entry is the identity even when its saved text differs from the spoken text", async () => {
    const heard = audio("clone-heard"), b = audio("clone-b");
    const refHeard = addToHistory("Display text of A", heard, "clone-voice");
    const refB = addToHistory("Narration B", b, "heard");
    await hearInOrder([{ file: heard, text: "Spoken text of A", voice: "clone-voice", ref: refHeard },
      { file: b, text: "Narration B", ref: refB }]);
    expect(await back()).toMatchObject({ text: "Display text of A", voice: "clone-voice" });
  });

  it("T1 r2: without an explicit reference, the entry bound when it started (a later same-text entry never wins)", async () => {
    const heard = audio("bare-heard"), b = audio("bare-b"), unheard = audio("bare-unheard");
    addToHistory("Narration A", heard, "heard-voice");
    addToHistory("Narration B", b, "heard");
    await hearInOrder([{ file: heard, text: "Narration A", voice: "heard-voice" }, { file: b, text: "Narration B" }]);
    // Same millisecond on purpose: identity is bound at start, not compared by timestamp.
    addToHistory("Narration A", unheard, "UNHEARD-voice");
    expect(await back()).toMatchObject({ text: "Narration A", voice: "heard-voice" });
  });

  it("T1 r3: an explicit History replay binds the SELECTED entry, never newer same-text audio (Codex r2 P2)", async () => {
    const selected = audio("replay-selected"), newer = audio("replay-newer"), b = audio("replay-b");
    addToHistory("Narration A", selected, "SELECTED-heard-voice");
    at(10);
    addToHistory("Narration A", newer, "UNHEARD-newer-voice");
    const older = tts.loadHistory().find(e => e.voice === "SELECTED-heard-voice");
    expect(older).toBeDefined();
    // The MCP `voice_speak` replay and the socket `replay` both play an entry with historyReplayMetadata.
    tts.playAudioNonBlocking(older!.file, tts.historyReplayMetadata(older!));
    const refB = addToHistory("Narration B", b, "heard");
    tts.playAudioNonBlocking(b, { text: "Narration B", voice: "heard", durationMs: 2000, historyRef: refB });
    (await players.at(0)).exit.resolve(0); await players.at(1);
    expect(await back()).toMatchObject({ text: "Narration A", voice: "SELECTED-heard-voice" });
  });

  it("T1: a queue that ended starts over; the next queue's Back cannot reach the old one", async () => {
    const old = `${TEST_TMP}/old-queue.mp3`;
    writeFileSync(old, "fake audio");
    addToHistory("A narration from an earlier queue", old, "test");
    tts.playAudioNonBlocking(old, { text: "A narration from an earlier queue", voice: "test", durationMs: 2000 });
    (await players.at(0)).exit.resolve(0); await tts.awaitCurrentPlayback(); await fixtureCheckpoint();
    expect(events.filter(e => e.type === "state" && e.state === "idle").length).toBeGreaterThan(0);
    read();
    await players.at(1);
    expect(tts.hasPreviousRead()).toBe(false);
  });

  it("set_playback_speed: 1.5× restarts the playing read at its word with afplay -r, and the clock scales", async () => {
    read();
    await players.at(0);
    at(3400);
    expect(await handleSocketCommand({ cmd: "set_playback_speed", speed: 1.5 })).toMatchObject({ outcome: "accept" });
    (await trims.at(0)).exit.resolve(0);
    const fast = await players.at(1); await fixtureCheckpoint();
    // macOS uses afplay -r; the Linux CI runner plays through ffplay (or mpv) with a pitch-preserving tempo.
    if (fast.argv[0] === "afplay") expect(fast.argv[fast.argv.indexOf("-r") + 1]).toBe("1.5");
    else if (fast.argv[0] === "ffplay") expect(fast.argv[fast.argv.indexOf("-af") + 1]).toBe("atempo=1.5");
    else if (fast.argv[0] === "mpv") expect(fast.argv).toContain("--speed=1.5");
    else throw new Error(`unexpected player ${fast.argv[0]}`);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 3000, playback_rate: 1.5 });
    // 2 s of wall time at 1.5× is 3 s of audio: 3000 + 3000 = word 6.
    at(5400);
    expect(tts.pausePlayback({})).toMatchObject({ outcome: "accept", offset_ms: 6000 });
    expect(await handleSocketCommand({ cmd: "set_playback_speed", speed: 3 })).toBeNull;
    await handleSocketCommand({ cmd: "set_playback_speed", speed: 1 });
  });
});

/** BRIEF-B-MODEL-GAPS (statechart "Where code and model disagree"), fail-first per item. */
describe("statechart gap 3: a live seek or speed change drives the engine's Seek / SeekDone", () => {
  const transitions = (id = "read-1") => playbackSessionEngine().log.filter(entry => entry.id === id).map(entry => entry.event);

  it("a socket seek goes playing -> seeking -> preparing -> playing at its word, with the invariants checked", async () => {
    read();
    await players.at(0);
    at(1500);
    expect(await handleSocketCommand({ cmd: "seek", offset_ms: 6000 })).toMatchObject({ outcome: "accept", offset_ms: 6000 });
    (await trims.at(0)).exit.resolve(0);
    await players.at(1); await fixtureCheckpoint();
    expect(transitions()).toEqual(["start", "ready", "seek", "seek-done", "ready"]);
    expect(playbackSessionEngine().log.find(entry => entry.event === "seek")).toMatchObject({ from: "playing", to: "seeking" });
    expect(ledgerSnapshot()).toMatchObject({ phase: "playing", session_id: "read-1", word_index: 6 });
    expect(playbackSessionViolations()).toEqual([]);
  });

  it("set_playback_speed restarts the player through the same Seek / SeekDone at the word it is on", async () => {
    read();
    await players.at(0);
    at(3400);
    expect(await handleSocketCommand({ cmd: "set_playback_speed", speed: 1.5 })).toMatchObject({ outcome: "accept" });
    (await trims.at(0)).exit.resolve(0);
    await players.at(1); await fixtureCheckpoint();
    expect(transitions()).toEqual(["start", "ready", "seek", "seek-done", "ready"]);
    expect(ledgerSnapshot()).toMatchObject({ phase: "playing", word_index: 3, speed: 1.5 });
    expect(playbackSessionViolations()).toEqual([]);
    await handleSocketCommand({ cmd: "set_playback_speed", speed: 1 });
  });

  it("a pause between the seek's commit and its new player lands on the seek's word (SeekDone, then Pause)", async () => {
    read();
    await players.at(0);
    at(1500);
    await handleSocketCommand({ cmd: "seek", offset_ms: 6000 });
    (await trims.at(0)).exit.resolve(0);
    await fixtureCheckpoint();
    expect(await handleSocketCommand({ cmd: "pause", playback_elapsed_ms: 0 })).toMatchObject({ outcome: "accept", offset_ms: 6000 });
    expect(ledgerSnapshot()).toMatchObject({ phase: "paused", word_index: 6 });
    expect(playbackSessionViolations()).toEqual([]);
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
      // As the long-read runner sends it: a chunk's first edge carries its read-global start.
      playbackOffsetMs: 30_000,
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

  /** Lane B night item 2 (Etan: "resume the read when the voice_ask answer capture ENDS"): the read comes back at
   * the recorder's exit, from its word, while the answer is still transcribing; never only after the whole ask. */
  it("capture-end r2: the read resumes from its word at recorder exit, before the answer finishes transcribing", async () => {
    const recordingState = asks[3] as ReturnType<typeof spyOn>;
    let finishTranscription!: (answer: string) => void;
    (asks[5] as ReturnType<typeof spyOn>).mockImplementation((async (_ms: number, _mode: unknown, _push: unknown, options: any) => {
      captures++;
      options?.onCaptureStart?.();
      options?.onCaptureEnd?.(1000);
      // The recorder has exited; the answer transcribes now.
      recordingState.mockReturnValue("transcribing");
      options?.onPhaseChange?.("transcribing");
      try { return await new Promise<string>(resolve => { finishTranscription = resolve; }); }
      finally { recordingState.mockReturnValue("idle"); }
    }) as any);
    const handle = read();
    await players.at(0);
    at(3200);
    let settled = false;
    const answer = handleVoiceAsk({ message: "Question?", timeout_seconds: 5 }).finally(() => { settled = true; });
    await fixtureCheckpoint();
    (await trims.at(0)).exit.resolve(0);
    await fixtureCheckpoint();
    (await players.at(1)).exit.resolve(0);
    for (let i = 0; i < 20; i++) await fixtureCheckpoint();
    expect(settled).toBe(false);
    expect(players.values.length, "the read's player starts while the answer transcribes").toBe(3);
    expect(states("resumed").at(-1)).toMatchObject({ word_index: 3, offset_ms: 3000 });
    expect(events.filter(e => e.type === "read_processing").map(e => e.active)).toEqual([true]);
    finishTranscription("answer 1");
    expect((await answer).content[0].text).toContain("answer 1");
    expect(events.filter(e => e.type === "read_processing").map(e => e.active)).toEqual([true, false]);
    // The read kept playing through the ask's end: no second resume, no pause.
    expect(states("resumed")).toHaveLength(1);
    expect(playbackSessionViolations()).toEqual([]);
    players.values[2].exit.resolve(0);
    expect((await handle.exited).status).toBe("completed");
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

  /** Statechart gap 1: the queue refused to park in these cases and preemptLongRead("ask") cancelled the read (or the
   * engine recorded a park the player never made). An ask never cancels a read: each case parks it. */
  it("gap 1: a read queued behind short agent speech is parked where it waits, and plays from its word after the ask", async () => {
    const agent = tts.playAudioNonBlocking(`${TEST_TMP}/agent.mp3`, { text: "Agent note.", voice: "test", durationMs: 1000,
      wordBoundaries: [{ text: "Agent", offset_ms: 0, duration_ms: 500 }, { text: "note.", offset_ms: 500, duration_ms: 500 }] });
    const queued = read();
    const short = await players.at(0);
    const answer = handleVoiceAsk({ message: "Question behind agent speech?", timeout_seconds: 5 });
    await fixtureCheckpoint();
    // Parked by the ask while it still waited behind the agent's speech: never cancelled.
    expect(states("paused").at(-1)).toMatchObject({ word_index: 0, long_read: { id: "read-1" } });
    expect(playbackSessionEngine().ask).toBe("waiting");
    expect(events.some(e => e.type === "playback_outcome" && e.long_read?.id === "read-1")).toBe(false);
    // Short agent speech keeps the wait contract: the ask's prompt follows it.
    short.exit.resolve(0); expect((await agent.exited).status).toBe("completed");
    const prompt = await players.at(1); await fixtureCheckpoint();
    prompt.exit.resolve(0);
    expect((await answer).content[0].text).toContain("answer 1");
    const resumed = await players.at(2); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text, playback_offset_ms: 0 });
    expect(playbackSessionViolations()).toEqual([]);
    resumed.exit.resolve(0);
    expect((await queued.exited).status).toBe("completed");
  });

  it("gap 1: a critical-priority read is parked at its word and restored from it (the critical guard refused it)", async () => {
    const handle = tts.playAudioNonBlocking(`${TEST_TMP}/critical.mp3`, { text, voice: "test", durationMs: 10_000, wordBoundaries: words,
      priority: "critical", longRead: { id: "read-critical", chunk_index: 0, chunk_count: 1, chunk_start_ms: 0 } });
    await players.at(0);
    at(3200);
    const answer = handleVoiceAsk({ message: "Critical question?", timeout_seconds: 5 });
    await fixtureCheckpoint();
    expect(states("paused").at(-1)).toMatchObject({ word_index: 3, long_read: { id: "read-critical" } });
    expect(ledgerSnapshot()).toMatchObject({ parked_by_ask: "read-critical" });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    (await players.at(1)).exit.resolve(0);
    expect((await answer).isError).not.toBe(true);
    await players.at(2); await fixtureCheckpoint();
    expect(states("resumed").at(-1)).toMatchObject({ word_index: 3, offset_ms: 3000 });
    expect(playbackSessionViolations()).toEqual([]);
    void handle.exited;
  });

  it("gap 1: another ask still owning capture refuses this ask before the read is touched", async () => {
    const admission = tts.reserveCaptureAdmission()!;
    expect(admission).toBeDefined();
    const queued = read();
    const hold = tts.holdReadForAsk();
    expect(hold).toMatchObject({ held: false, refused: "capture-owned" });
    // Neither the player nor the engine moved: no park, no ask, no cancel.
    expect(ledgerSnapshot()).toMatchObject({ ask: "none", parked_by_ask: null });
    expect(states("paused")).toHaveLength(0);
    hold.restore();
    admission.release();
    await players.at(0); await fixtureCheckpoint();
    expect(ledgerSnapshot()).toMatchObject({ phase: "playing", session_id: "read-1" });
    players.values[0].exit.resolve(0);
    expect((await queued.exited).status).toBe("completed");
  });

  it("gap 1: a read the driver still cannot park is ended in the engine too, with the violation kept (never a silent park)", async () => {
    const handle = read();
    await players.at(0);
    at(2200);
    // The pause refuses while a capture is recording (voice_ask itself checks this first, synchronously).
    (asks[3] as ReturnType<typeof spyOn>).mockReturnValue("recording");
    const hold = tts.holdReadForAsk();
    (asks[3] as ReturnType<typeof spyOn>).mockReturnValue("idle");
    expect(hold.held).toBe(false);
    expect((await handle.exited).status).toBe("interrupted");
    expect(playbackSessionEngine().get("read-1")?.state).toBe("ended");
    expect(ledgerSnapshot()).toMatchObject({ parked_by_ask: null });
    expect(playbackSessionViolations()).toEqual(["AskKeepsRead(driver): read-1 could not be parked and was ended"]);
    hold.restore();
  });

  it("gap 4: Stop during an ask over a replay ends the ask and the replay; the held read still returns paused at its word", async () => {
    const earlier = `${TEST_TMP}/earlier-stop.mp3`;
    writeFileSync(earlier, "fake audio");
    addToHistory("An earlier read about stopping", earlier, "test", [], { wordBoundaries: "An earlier read about stopping".split(" ")
      .map((word, i) => ({ text: word, offset_ms: i * 1000, duration_ms: 800 })) });
    await hearThenRead(earlier, "An earlier read about stopping");
    at(5300);
    await handleSocketCommand({ cmd: "previous_read" });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    await players.at(2); await fixtureCheckpoint();
    const answer = handleVoiceAsk({ message: "Question then Stop?", timeout_seconds: 5 });
    await fixtureCheckpoint();
    expect(playbackSessionEngine().previousHeld).toBe("read-1");
    expect(await handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "accept" });
    for (const player of players.values) player.exit.resolve(143);
    await answer;
    for (let i = 0; i < 10; i++) await fixtureCheckpoint();
    // Stop means stop for the ask and the replay it parked; the read held aside was never on screen, so it returns.
    expect(states("paused").at(-1)).toMatchObject({ word_index: 5, offset_ms: 5000, pause_owner: "user" });
    expect(ledgerSnapshot()).toMatchObject({ phase: "paused", session_id: "read-1", word_index: 5, ask: "none" });
    expect(playbackSessionViolations()).toEqual([]);
  });

  /** Statechart gap 4 (recommended reading): an ask during a previous_read replay parks the REPLAY (the read on screen,
   * at its word) and keeps the read held aside held; after the ask the replay plays on, then the held read returns. */
  it("gap 4: an ask during previous_read parks the replay; the held read stays held and returns paused after it", async () => {
    const earlier = `${TEST_TMP}/earlier-ask.mp3`;
    writeFileSync(earlier, "fake audio");
    const replayWords = "An earlier read about Codex and Claude together".split(" ")
      .map((word, i) => ({ text: word, offset_ms: i * 1000, duration_ms: 800 }));
    addToHistory("An earlier read about Codex and Claude together", earlier, "test", [], { wordBoundaries: replayWords });
    await hearThenRead(earlier, "An earlier read about Codex and Claude together");
    at(5300);
    expect(await handleSocketCommand({ cmd: "previous_read" })).toMatchObject({ outcome: "accept" });
    (await trims.at(0)).exit.resolve(0); await fixtureCheckpoint();
    const replay = await players.at(2); await fixtureCheckpoint();
    const replayId = events.filter(e => e.state === "speaking").at(-1).playback_id;
    const answer = handleVoiceAsk({ message: "Question over the replay?", timeout_seconds: 5 });
    await fixtureCheckpoint();
    // The replay was parked by the ask, not cancelled; the read held aside is still held (engine prevHeld).
    expect(events.some(e => e.type === "playback_outcome" && e.playback_id === replayId)).toBe(false);
    expect(states("paused").at(-1)).toMatchObject({ playback_id: replayId });
    expect(playbackSessionEngine().previousHeld).toBe("read-1");
    expect(playbackSessionEngine().get("read-1")?.state).toBe("queued");
    expect(ledgerSnapshot()).toMatchObject({ parked_by_ask: playbackSessionEngine().parked?.id });
    expect(playbackSessionEngine().parked?.id).not.toBe("read-1");
    void replay;
    for (const trim of trims.values.slice(1)) trim.exit.resolve(0);
    await fixtureCheckpoint();
    (await players.at(3)).exit.resolve(0);
    expect((await answer).isError).not.toBe(true);
    // After the ask the replay plays on from its word; the held read waits for it.
    const replayed = await players.at(4); await fixtureCheckpoint();
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ text: "An earlier read about Codex and Claude together" });
    expect(playbackSessionEngine().previousHeld).toBe("read-1");
    replayed.exit.resolve(0); await fixtureCheckpoint(); await fixtureCheckpoint();
    expect(states("paused").at(-1)).toMatchObject({ word_index: 5, offset_ms: 5000, pause_owner: "user" });
    expect(ledgerSnapshot()).toMatchObject({ phase: "paused", session_id: "read-1", word_index: 5 });
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
