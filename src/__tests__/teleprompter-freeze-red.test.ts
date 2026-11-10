import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import * as seekAudio from "../tts/seek-audio";
import { resetPlaybackSessionLedger } from "../playback/ledger";
import { TEST_TMP } from "./setup/test-tmp";
import { TTS_HISTORY_FILE } from "../paths";
import { deferredFixture, fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

// Regression coverage for Previous Read return and an ended read's fresh presentation.
let players: ReturnType<typeof fixtureBarrier<ReturnType<typeof deferredFixture<number>>>>;
let events: any[];
let restore: (() => void)[] = [];

beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  console.error("freeze-red: VOICELAYER_TEST_ISOLATED=1 (preload confirmed)");
  players = fixtureBarrier(); events = [];
  resetPlaybackSessionLedger();
  tts.resetHeardQueueForTests();
  rmSync(TTS_HISTORY_FILE, { force: true });
  const spawn = spyOn(Bun, "spawn").mockImplementation((() => {
    const exit = deferredFixture<number>();
    players.push(exit);
    return { pid: 90001, exited: exit.promise, kill: () => exit.resolve(143) };
  }) as any);
  const extract = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
    result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
  } as any);
  const cast = spyOn(socket, "broadcast").mockImplementation(event => events.push(structuredClone(event)));
  const idle = spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle");
  const slice = spyOn(seekAudio, "prepareSeekSlice").mockResolvedValue(undefined);
  restore = [() => spawn.mockRestore(), () => extract.mockRestore(), () => cast.mockRestore(), () => idle.mockRestore(), () => slice.mockRestore()];
});

afterEach(async () => {
  tts.stopPlayback();
  for (const exit of players.values) exit.resolve(143);
  await tts.awaitCurrentPlayback();
  for (const undo of restore) undo();
});

it("V3-7: an ended readback seek must not reuse the retired submission identity", async () => {
  const file = join(TEST_TMP, "freeze-red-synthetic.mp3");
  writeFileSync(file, "synthetic media; decoder and player are owned fakes");
  const original = tts.playAudioNonBlocking(file, {
    text: "One two", voice: "fixture", durationMs: 2000,
    speechIdentity: { request_id: "completed-submission", text_hash: "original-hash" },
    wordBoundaries: [{ text: "One", offset_ms: 0, duration_ms: 900 },
      { text: "two", offset_ms: 1000, duration_ms: 900 }],
  });
  const player = await players.at(0);
  const first = events.find(event => event.state === "speaking");
  expect(first.request_id).toBe("completed-submission");
  expect(typeof first.readback_id).toBe("string");
  player.resolve(0);
  await original.exited;
  await tts.awaitCurrentPlayback();
  expect(events.some(event => event.state === "idle" && event.source === "playback")).toBe(true);
  expect(tts.seekPlayback(0, "readback", first.readback_id)).toMatchObject({ outcome: "accept" });
  await players.at(1);
  await fixtureCheckpoint();
  const replay = events.filter(event => event.state === "speaking").at(-1);
  expect(replay.playback_id).not.toBe(first.playback_id);
  expect(replay.utteranceId).not.toBe(first.utteranceId);
  expect(replay.request_id, "the client retired this submission at playback idle").not.toBe(first.request_id);
  expect(replay.request_id).toBeString();
  expect(replay.text_hash).toBe(first.text_hash);
  expect(replay.readback_id).toBe(first.readback_id);
  expect(replay.text).toBe(first.text);
});

it("V3-5/7: previous-read return must restore the held read's presentation", async () => {
  const start = Date.now(), clock = spyOn(Date, "now").mockReturnValue(start);
  restore.push(() => clock.mockRestore());
  const firstFile = join(TEST_TMP, "freeze-red-first.mp3");
  const secondFile = join(TEST_TMP, "freeze-red-second.mp3");
  writeFileSync(firstFile, "synthetic first"); writeFileSync(secondFile, "synthetic second");
  const firstRef = tts.addToHistory("First read", firstFile, "fixture");
  const secondRef = tts.addToHistory("Second read", secondFile, "fixture");
  tts.playAudioNonBlocking(firstFile, { text: "First read", voice: "fixture", durationMs: 2000, historyRef: firstRef });
  await players.at(0);
  const held = tts.playAudioNonBlocking(secondFile, {
    text: "Second read", voice: "fixture", durationMs: 2000, historyRef: secondRef,
    speechIdentity: { request_id: "held-submission" },
    wordBoundaries: [{ text: "Second", offset_ms: 0, duration_ms: 900 },
      { text: "read", offset_ms: 1000, duration_ms: 900 }],
  });
  players.values[0].resolve(0); await players.at(1);
  const heldEdge = events.find(event => event.playback_id === held.id && event.state === "speaking");
  clock.mockReturnValue(start + 1000);
  expect(tts.playPreviousRead()).toMatchObject({ outcome: "accept" });
  await players.at(2); await fixtureCheckpoint();
  const beginning = events.length;
  players.values[2].resolve(0);
  await fixtureCheckpoint();
  const returned = events.slice(beginning);
  expect(returned.some(event => event.type === "playback_state" && event.playback_id === held.id && event.state === "paused")).toBe(true);
  expect(returned.some(event => event.playback_id === held.id && event.text === "Second read"),
    "the current screen still contains First read; a bare pause for another player is rejected as wrong-owner").toBe(true);
  const presentation = returned.find(event => event.previous_read_return);
  const replay = events.filter(event => event.state === "speaking" && event.playback_id !== held.id).at(-1);
  expect(replay.previous_read_hold).toEqual({ playback_id: held.id, generation: 2 });
  expect(presentation).toMatchObject({ utteranceId: heldEdge.utteranceId, request_id: "held-submission",
    generation: 2, duration_ms: 2000, chunk_duration_ms: 2000, playback_offset_ms: 1000,
    previous_read_return: { from_playback_id: replay.playback_id, offset_ms: 1000, pause_owner: "user" } });
  const pauseIndex = returned.findIndex(event => event.type === "playback_state");
  expect(returned.findIndex(event => event === presentation)).toBeLessThan(pauseIndex);
  expect(returned.slice(0, pauseIndex).some(event => event.type === "speech_words" && event.utteranceId === heldEdge.utteranceId)).toBe(true);
  expect(players.values).toHaveLength(3); // Restoring the presentation never spawns audio.
});
