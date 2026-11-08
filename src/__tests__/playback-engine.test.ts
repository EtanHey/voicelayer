/**
 * Lane B (2.4) daemon-side proof for the PlaybackSession engine wired into the real queue
 * manager: Etan's named bugs, fail-first. Players, trims and the clock are faked exactly as in
 * tts-pause.test.ts; no audio device, socket or live path is touched.
 */
import { afterEach, beforeEach, describe, expect, it, setSystemTime, spyOn } from "bun:test";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
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
  const cast = spyOn(socket, "broadcast").mockImplementation((event: any) => { events.push(event); });
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
