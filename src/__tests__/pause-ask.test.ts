import { afterEach, beforeEach, expect, it, jest, spyOn } from "bun:test";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as input from "../input";
import * as recording from "../recording-state";
import * as booking from "../session-booking";
import * as socket from "../socket-client";
import { handleVoiceAsk } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
import { hasActiveVoiceOperation } from "../voice-operation-reservation";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint as flush } from "./long-read-fixture-barriers";

type Player = { exit: ReturnType<typeof deferred<number>>; signals: string[] };
let players: ReturnType<typeof fixtureBarrier<Player>>;
let trims: ReturnType<typeof fixtureBarrier<ReturnType<typeof deferred<number>>>>;
let handles: tts.QueuedPlaybackHandle[];
let spies: Array<{ mockRestore(): void }>;
let capture: ReturnType<typeof spyOn<typeof input, "waitForInput">>;
let pending: ReturnType<typeof handleVoiceAsk> | undefined;

beforeEach(() => {
  jest.useFakeTimers();
  players = fixtureBarrier(); trims = fixtureBarrier(); handles = []; spies = [];
  spies.push(spyOn(Bun, "spawn").mockImplementation((argv, _options) => {
    if (!Array.isArray(argv)) throw new Error("fixture requires argv");
    const exit = deferred<number>();
    if (argv[0] === "which") return { pid: 1, exited: Promise.resolve(0), stdout: new Blob(["/fake/ffmpeg"]).stream(), kill() {} } as ReturnType<typeof Bun.spawn>;
    if (argv.includes("-version")) exit.resolve(0);
    else if (argv.includes("-ss")) trims.push(exit);
    else {
      const player = { exit, signals: [] as string[] }; players.push(player);
      return { pid: 9000 + players.values.length, exited: exit.promise, kill(signal = "SIGTERM") { player.signals.push(String(signal)); } } as ReturnType<typeof Bun.spawn>;
    }
    return { pid: 2, exited: exit.promise, kill() { exit.resolve(143); } } as ReturnType<typeof Bun.spawn>;
  }));
  spies.push(spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({
    result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel() {},
  }));
  spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
    spyOn(booking, "clearStopSignal").mockImplementation(() => {}),
    spyOn(input, "clearInput").mockImplementation(() => {}),
    spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(socket, "isConnected").mockReturnValue(true),
    spyOn(socket, "broadcast").mockImplementation(() => {}));
  capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
  spies.push(spyOn(tts, "speak").mockImplementation(async (text, options) => {
    const handle = tts.playAudioNonBlocking(`${TEST_TMP}/ask.mp3`, {
      text, voice: "fixture", durationMs: 600_000, priority: "critical", onQueued: options?.onPlaybackQueued,
    });
    handles.push(handle);
    return { playbackId: handle.id, playbackOutcome: await handle.exited, displayText: text,
      engine: "edge-tts", voice: "fixture", audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } };
  }));
});

afterEach(async () => {
  tts.stopPlayback();
  for (const player of players.values) player.exit.resolve(143);
  for (const trim of trims.values) trim.resolve(143);
  await pending;
  await tts.awaitCurrentPlayback();
  pending = undefined;
  for (const spy of spies.reverse()) spy.mockRestore();
  jest.useRealTimers();
  expect(tts.isCaptureAdmissionReserved()).toBe(false);
  expect(hasActiveVoiceOperation()).toBe(false);
});

async function startAsk() {
  pending = handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
  const player = await players.at(0);
  return { player, handle: handles[0] };
}
async function pauseAsk(activeMs = 0) {
  const started = await startAsk();
  jest.advanceTimersByTime(activeMs);
  expect(tts.pausePlayback({ id: started.handle.id, generation: started.handle.generation }, 4200)).toMatchObject({ outcome: "accept", offset_ms: 4200 });
  return started;
}

it("holds Ask and its reservation at the offset until resumed natural completion and all physical exits", async () => {
  const { player, handle } = await pauseAsk();
  (await trims.at(0)).resolve(0); await flush();
  expect(tts.isCaptureAdmissionReserved()).toBe(true);
  expect(capture).not.toHaveBeenCalled();
  const foreign = tts.playAudioNonBlocking(`${TEST_TMP}/foreign.mp3`, { text: "Foreign", voice: "fixture", durationMs: 1000 });
  expect(tts.isPlaybackPaused()).toBe(true);
  expect(tts.resumePlayback({ id: "foreign" })).toMatchObject({ outcome: "reject", reason: "stale" });
  expect(tts.resumePlayback({ id: handle.id, generation: 1 })).toMatchObject({ outcome: "reject", reason: "stale" });
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation })).toMatchObject({ outcome: "accept", offset_ms: 4200 });
  await flush(); expect(players.values).toHaveLength(1);
  player.exit.resolve(143);
  const resumed = await players.at(1);
  expect(capture).not.toHaveBeenCalled();
  resumed.exit.resolve(0);
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
  tts.cancelPlayback({ id: foreign.id });
});

for (const paused of [false, true]) it(`Stop during ${paused ? "paused" : "playing"} Ask never captures or resurrects`, async () => {
  const { player, handle } = paused ? await pauseAsk() : await startAsk();
  if (paused) (await trims.at(0)).resolve(0);
  tts.stopPlayback(); player.exit.resolve(143);
  const result = await pending;
  expect(result?.content[0].text).toContain("stopped");
  expect(capture).not.toHaveBeenCalled();
  expect(tts.isCaptureAdmissionReserved()).toBe(false);
  expect(tts.resumePlayback({ id: handle.id })).toMatchObject({ outcome: "noop" });
});

it("suspends only parked prompt time and rearms the remaining active budget on Resume", async () => {
  const { player, handle } = await pauseAsk(60_000);
  player.exit.resolve(143); (await trims.at(0)).resolve(0); await flush();
  jest.advanceTimersByTime(300_000); await flush();
  expect(tts.isPlaybackPaused()).toBe(true);
  expect(capture).not.toHaveBeenCalled();
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation })).toMatchObject({ outcome: "accept" });
  const resumed = await players.at(1);
  jest.advanceTimersByTime(119_999); await flush();
  expect(resumed.signals).toEqual([]);
  jest.advanceTimersByTime(1); await flush();
  expect(resumed.signals).toContain("SIGTERM");
  resumed.exit.resolve(143);
  expect((await pending)?.isError).toBe(true);
  expect(capture).not.toHaveBeenCalled();
});

it("rejects Pause for an unadmitted critical job", async () => {
  tts.playAudioNonBlocking(`${TEST_TMP}/critical.mp3`, { text: "Critical", voice: "fixture", durationMs: 1000, priority: "critical" });
  await players.at(0);
  expect(tts.pausePlayback()).toMatchObject({ outcome: "reject", reason: "unsupported" });
});

for (const failed of [false, true]) it(`Resume ${failed ? "slice failure" : "at EOF"} retains the capture fence`, async () => {
  const { player, handle } = await startAsk();
  expect(tts.pausePlayback({ id: handle.id }, failed ? 4200 : 600_000).outcome).toBe("accept");
  const trim = await trims.at(0);
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation }).outcome).toBe("accept");
  trim.resolve(failed ? 1 : 0); await flush();
  expect(capture).not.toHaveBeenCalled();
  if (failed) {
    expect(tts.isPlaybackPaused()).toBe(true);
    expect(tts.isCaptureAdmissionReserved()).toBe(true);
    tts.stopPlayback(); player.exit.resolve(143);
    expect((await pending)?.content[0].text).toContain("stopped");
    expect(capture).not.toHaveBeenCalled();
  } else {
    player.exit.resolve(143);
    expect((await pending)?.content[0].text).toContain("fixture answer");
    expect(capture).toHaveBeenCalledTimes(1);
    expect(players.values).toHaveLength(1);
  }
});

it("Stop wins a pending Resume slice and late conversion cannot resurrect Ask", async () => {
  const { player, handle } = await pauseAsk();
  const trim = await trims.at(0);
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation }).outcome).toBe("accept");
  tts.stopPlayback(); trim.resolve(0); player.exit.resolve(143);
  expect((await pending)?.content[0].text).toContain("stopped");
  await flush();
  expect(players.values).toHaveLength(1);
  expect(capture).not.toHaveBeenCalled();
});

it("rejects stale Pause and refuses Resume while actual recording owns the mic", async () => {
  const { player, handle } = await startAsk();
  expect(tts.pausePlayback({ id: "foreign" })).toMatchObject({ outcome: "reject", reason: "stale" });
  expect(tts.pausePlayback({ id: handle.id, generation: 999 })).toMatchObject({ outcome: "reject", reason: "stale" });
  expect(player.signals).toEqual([]);
  expect(tts.pausePlayback({ id: handle.id }, 0).outcome).toBe("accept");
  const busy = spyOn(recording, "getEffectiveRecordingState").mockReturnValue("recording");
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation })).toMatchObject({ outcome: "reject", reason: "busy" });
  busy.mockReturnValue("idle");
  tts.stopPlayback(); player.exit.resolve(143); await pending;
  expect(capture).not.toHaveBeenCalled();
});

it("failed natural player exit never opens the microphone", async () => {
  const { player } = await startAsk();
  player.exit.resolve(1);
  expect((await pending)?.isError).toBe(true);
  expect(capture).not.toHaveBeenCalled();
});

it("VoiceBar socket commands pause and resume the admitted Ask identity", async () => {
  const { player, handle } = await startAsk();
  expect(await handleSocketCommand({ cmd: "pause", id: "vb-p", playback_id: handle.id,
    generation: handle.generation, playback_elapsed_ms: 4200 })).toMatchObject({ command: "pause", outcome: "accept", offset_ms: 4200 });
  player.exit.resolve(143); (await trims.at(0)).resolve(0); await flush();
  expect(await handleSocketCommand({ cmd: "resume", id: "vb-r", playback_id: handle.id,
    generation: handle.generation })).toMatchObject({ command: "resume", outcome: "accept", offset_ms: 4200 });
  (await players.at(1)).exit.resolve(0);
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
});

it("Stop during admitted prompt preparation never captures", async () => {
  const envelope = deferred<amplitude.PlaybackAmplitudeEnvelope>();
  spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({ result: envelope.promise, cancel() {} });
  pending = handleVoiceAsk({ message: "Question?" });
  await flush();
  expect(handles).toHaveLength(1);
  expect(players.values).toHaveLength(0);
  tts.stopPlayback(); envelope.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] });
  expect((await pending)?.content[0].text).toContain("stopped");
  expect(capture).not.toHaveBeenCalled();
});
