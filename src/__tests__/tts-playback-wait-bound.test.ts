import { afterEach, beforeEach, describe, expect, it, jest, spyOn } from "bun:test";
import * as runner from "../tts/long-read";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import * as input from "../input";
import * as booking from "../session-booking";
import * as tts from "../tts";
import { handleSocketCommand } from "../socket-handlers";
import { handleVoiceAsk } from "../handlers";
import { deferredFixture, fixtureCheckpoint } from "./long-read-fixture-barriers";

// Real subprocesses: standalone p95 <= 44 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

describe("cancelled read settling and bounded playback wait", () => {
  let completion: ReturnType<typeof deferredFixture<void>>;
  let handle: ReturnType<typeof tts.speakLongRead> | undefined;
  let spies: ReturnType<typeof spyOn>[];

  beforeEach(() => {
    completion = deferredFixture<void>(); handle = undefined; spies = [];
    spies.push(spyOn(runner, "runLongRead").mockImplementation(() => completion.promise));
    spies.push(spyOn(socket, "broadcast").mockImplementation(() => {}));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
  });
  afterEach(async () => {
    tts.stopPlayback(); completion.resolve(); await handle?.done; await tts.awaitCurrentPlayback();
    jest.useRealTimers(); for (const spy of spies) spy.mockRestore();
  });
  const startHeldRead = () => { handle = tts.speakLongRead("Held read.", { engine: "edge", voice: "fixture", rate: "+0%" }); return handle; };

  it("N3 repeated stop/cancel wait until cancelled teardown completes", async () => {
    startHeldRead();
    const first = Promise.resolve(handleSocketCommand({ cmd: "stop" }));
    await fixtureCheckpoint();
    expect(tts.getPlaybackQueueDepth()).toBeGreaterThan(0);
    let settled = 0;
    const second = Promise.resolve(handleSocketCommand({ cmd: "stop" })).then((ack) => { settled++; return ack; });
    const third = Promise.resolve(handleSocketCommand({ cmd: "cancel" })).then((ack) => { settled++; return ack; });
    await fixtureCheckpoint(); expect(settled).toBe(0);
    completion.resolve();
    for (const ack of await Promise.all([first, second, third])) expect(ack).toMatchObject({ outcome: "accept" });
    expect(tts.getPlaybackQueueDepth()).toBe(0);
  });

  it("N4 rejects a hung playback wait at 35000ms and logs a warning", async () => {
    jest.useFakeTimers();
    const warning = spyOn(console, "warn").mockImplementation(() => {}); spies.push(warning);
    startHeldRead(); tts.stopPlayback();
    let failure: Error | undefined;
    const wait = tts.awaitCurrentPlayback().catch((error) => { failure = error; });
    jest.advanceTimersByTime(34999); await fixtureCheckpoint();
    expect(failure).toBeUndefined(); expect(warning).not.toHaveBeenCalled();
    jest.advanceTimersByTime(1); await fixtureCheckpoint();
    expect(failure?.message).toBe("Playback wait timed out after 35000ms");
    expect(warning).toHaveBeenCalledTimes(1); expect(warning.mock.calls[0][0]).toContain("35000ms");
    expect(tts.getPlaybackQueueDepth()).toBeGreaterThan(0);
    await wait;
  });

  it("N4 stop/cancel return rejection acknowledgements when teardown exceeds 35000ms", async () => {
    jest.useFakeTimers();
    const warning = spyOn(console, "warn").mockImplementation(() => {}); spies.push(warning);
    startHeldRead();
    const responses: any[] = [];
    const stop = Promise.resolve(handleSocketCommand({ cmd: "stop", id: "bounded-stop" })).then((ack) => responses.push(ack));
    const cancel = Promise.resolve(handleSocketCommand({ cmd: "cancel", id: "bounded-cancel" })).then((ack) => responses.push(ack));
    jest.advanceTimersByTime(34999); await fixtureCheckpoint(); expect(responses).toEqual([]);
    jest.advanceTimersByTime(1); await fixtureCheckpoint();
    expect(responses).toHaveLength(2);
    expect(responses).toEqual([
      { type: "ack", command: "stop", id: "bounded-stop", outcome: "reject", reason: "Playback wait timed out after 35000ms" },
      { type: "ack", command: "cancel", id: "bounded-cancel", outcome: "reject", reason: "Playback wait timed out after 35000ms" },
    ]);
    expect(warning).toHaveBeenCalledTimes(2); await Promise.all([stop, cancel]);
  });

  it("N4 voice_ask returns a playback timeout without speaking or recording", async () => {
    jest.useFakeTimers();
    spies.push(spyOn(console, "warn").mockImplementation(() => {}));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true, owner: { pid: process.pid, sessionId: "fixture", startedAt: new Date().toISOString() } }));
    const speak = spyOn(tts, "speak").mockResolvedValue({}); spies.push(speak);
    const capture = spyOn(input, "waitForInput").mockResolvedValue("unexpected capture"); spies.push(capture);
    startHeldRead();
    const answer = handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
    await fixtureCheckpoint(); jest.advanceTimersByTime(35000); await fixtureCheckpoint();
    let result: any; answer.then((value) => { result = value; }); await fixtureCheckpoint();
    expect(result?.isError).toBe(true);
    expect(result.content[0].text).toContain("Playback wait timed out after 35000ms");
    expect(speak).not.toHaveBeenCalled(); expect(capture).not.toHaveBeenCalled();
    await answer;
  });

  it("N4 a successful playback wait clears its outer deadline", async () => {
    jest.useFakeTimers();
    const warning = spyOn(console, "warn").mockImplementation(() => {}); spies.push(warning);
    startHeldRead(); tts.stopPlayback(); const wait = tts.awaitCurrentPlayback();
    completion.resolve(); await wait;
    expect(jest.getTimerCount()).toBe(0);
    jest.advanceTimersByTime(35000); expect(warning).not.toHaveBeenCalled();
  });

  it("N4 the outer deadline also bounds a stalled player with no pending generation", async () => {
    jest.useFakeTimers();
    const warning = spyOn(console, "warn").mockImplementation(() => {}); spies.push(warning);
    const playerExit = deferredFixture<number>();
    spies.push(spyOn(Bun, "spawn").mockImplementation(() => ({
      pid: 99001, exited: playerExit.promise, kill: () => playerExit.resolve(143),
    }) as any));
    const playback = tts.playAudioNonBlocking("owned-fixture.mp3");
    let failure: Error | undefined;
    const wait = tts.awaitCurrentPlayback().catch((error) => { failure = error; });
    await fixtureCheckpoint(); jest.advanceTimersByTime(35000); await fixtureCheckpoint();
    expect(failure?.message).toBe("Playback wait timed out after 35000ms");
    expect(warning).toHaveBeenCalledTimes(1); expect(tts.getPlaybackQueueDepth()).toBeGreaterThan(0);
    await wait; tts.stopPlayback(); await playback.exited;
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});
