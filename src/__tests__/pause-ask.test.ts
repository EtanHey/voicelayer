import { narrationSource } from "../narration/source";
import { finishSyntheticCapture } from "./setup/recording-jobs-fixture";
import { hasScopedCapture } from "../f5-capture";
import { afterEach, beforeEach, expect, it, jest, setSystemTime, spyOn } from "bun:test";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as input from "../input";
import * as recording from "../recording-state";
import * as booking from "../session-booking";
import * as socket from "../socket-client";
import { handleVoiceAsk } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
import { hasActiveVoiceOperation } from "../voice-operation-reservation";
import { createMcpDaemon } from "../mcp-daemon";
import { serializeMcpFrame } from "../mcp-framing";
import { TEST_TMP, testSocket } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint as flush } from "./long-read-fixture-barriers";

const question = "First question?";
const realSpeak = tts.speak;

type Player = { exit: ReturnType<typeof deferred<number>>; signals: string[] };
let players: ReturnType<typeof fixtureBarrier<Player>>;
let trims: ReturnType<typeof fixtureBarrier<ReturnType<typeof deferred<number>>>>;
let handles: tts.QueuedPlaybackHandle[];
let spies: Array<{ mockRestore(): void }>;
let capture: ReturnType<typeof spyOn<typeof input, "waitForInput">>;
let pending: ReturnType<typeof handleVoiceAsk> | undefined;

beforeEach(() => {
  jest.useFakeTimers();
  booking.clearCancelSignal();
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
    expect(text).toBe(question);
    const handle = tts.playAudioNonBlocking(`${TEST_TMP}/ask.mp3`, {
      text, voice: "fixture", durationMs: 600_000, priority: "critical", onQueued: options?.onPlaybackQueued,
      wordBoundaries: [{ text: "First", offset_ms: 0, duration_ms: 4200 },
        { text: "question?", offset_ms: 4200, duration_ms: 595800 }],
    });
    handles.push(handle);
    return { playbackId: handle.id, playbackOutcome: await handle.exited, displayText: text,
      engine: "edge-tts", voice: "fixture", audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } };
  }));
});

afterEach(async () => {
  setSystemTime();
  tts.stopPlayback();
  for (const player of players.values) player.exit.resolve(143);
  for (const trim of trims.values) trim.resolve(143);
  await pending;
  await tts.awaitCurrentPlayback();
  pending = undefined;
  booking.clearCancelSignal();
  for (const spy of spies.reverse()) spy.mockRestore();
  jest.useRealTimers();
  expect(tts.isCaptureAdmissionReserved()).toBe(false);
  expect(hasActiveVoiceOperation()).toBe(false);
});

/** #818: the prompt player's clock reaches the claimed position before a pause (a client clock ahead never moves one). */
let askStartedAt = 0;
const playTo = (ms: number) => setSystemTime(new Date(askStartedAt + ms));
async function startAsk() {
  pending = handleVoiceAsk({ message: question, timeout_seconds: 5 });
  const player = await players.at(0);
  askStartedAt = Date.now();
  return { player, handle: handles[0] };
}
async function pauseAsk(activeMs = 0) {
  const started = await startAsk();
  jest.advanceTimersByTime(activeMs);
  playTo(4200);
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

for (const paused of [false, true]) it(`Stop during ${paused ? "paused" : "playing"} Ask captures only after physical exit`, async () => {
  const { player, handle } = paused ? await pauseAsk() : await startAsk();
  if (paused) (await trims.at(0)).resolve(0);
  const command = handleSocketCommand({ cmd: "stop", id: "ask-stop", playback_elapsed_ms: 4200 });
  await flush();
  expect(capture).not.toHaveBeenCalled();
  expect(tts.isCaptureAdmissionReserved()).toBe(true);
  player.exit.resolve(143);
  expect(await command).toMatchObject({ outcome: "accept" });
  const result = await pending;
  expect(result?.content[0].text).toContain("fixture answer");
  expect(result?.content[0].text).toContain("Prompt interrupted");
  expect(result?.content[0].text).toContain("1%");
  expect(capture).toHaveBeenCalledTimes(1);
  expect(tts.isCaptureAdmissionReserved()).toBe(false);
  expect(tts.resumePlayback({ id: handle.id })).toMatchObject({ outcome: "noop" });
});

for (const paused of [false, true]) it(`Cancel during ${paused ? "paused" : "playing"} Ask preserves main capture after physical exit`, async () => {
  const { player, handle } = paused ? await pauseAsk() : await startAsk();
  if (paused) (await trims.at(0)).resolve(0);
  const command = handleSocketCommand({ cmd: "cancel", id: "ask-cancel" });
  await flush();
  expect(capture).not.toHaveBeenCalled();
  player.exit.resolve(143);
  expect(await command).toMatchObject({ outcome: "accept" });
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
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

it("prompt watchdog uses monotonic active time across a wall-clock jump", async () => {
  const { player, handle } = await startAsk();
  jest.advanceTimersByTime(60_000);
  spies.push(spyOn(Date, "now").mockReturnValue(Date.now() + 300_000));
  expect(tts.pausePlayback({ id: handle.id }, 4200).outcome).toBe("accept");
  player.exit.resolve(143); (await trims.at(0)).resolve(0); await flush();
  expect(tts.resumePlayback({ id: handle.id }).outcome).toBe("accept");
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

it("Resume slice failure retains the capture fence", async () => {
  const { player, handle } = await startAsk();
  playTo(4200);
  expect(tts.pausePlayback({ id: handle.id }, 4200).outcome).toBe("accept");
  const trim = await trims.at(0);
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation }).outcome).toBe("accept");
  trim.resolve(1); await flush();
  expect(capture).not.toHaveBeenCalled();
  expect(tts.isPlaybackPaused()).toBe(true);
  expect(tts.isCaptureAdmissionReserved()).toBe(true);
  tts.stopPlayback(); player.exit.resolve(143);
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
});

for (const offset of [600_000, 650_000]) for (const exitCode of [0, 143])
it(`Ask Resume at client EOF ${offset} never captures after terminated player exit ${exitCode}`, async () => {
  const { player, handle } = await startAsk();
  playTo(offset);
  expect(await handleSocketCommand({ cmd: "pause", id: "eof-p", playback_id: handle.id,
    generation: handle.generation, playback_elapsed_ms: offset })).toMatchObject({ outcome: "accept", offset_ms: 600_000 });
  expect(player.signals).toContain("SIGTERM");
  (await trims.at(0)).resolve(0); await flush();
  expect(await handleSocketCommand({ cmd: "resume", id: "eof-r", playback_id: handle.id,
    generation: handle.generation })).toMatchObject({ outcome: "accept", offset_ms: 600_000 });
  await flush();
  expect(capture).not.toHaveBeenCalled();
  expect(tts.isCaptureAdmissionReserved()).toBe(true);
  player.exit.resolve(exitCode);
  const result = await pending;
  expect(capture).not.toHaveBeenCalled();
  expect(result?.isError).toBe(true);
  expect(result?.content[0].text).toContain("nothing was recorded");
  expect(await handle.exited).toMatchObject({ status: "failed" });
  expect(tts.isCaptureAdmissionReserved()).toBe(false);
  expect(players.values).toHaveLength(1);
});

it("Stop wins a pending Resume slice and late conversion cannot resurrect Ask", async () => {
  const { player, handle } = await pauseAsk();
  const trim = await trims.at(0);
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation }).outcome).toBe("accept");
  tts.stopPlayback(); trim.resolve(0); player.exit.resolve(143);
  expect((await pending)?.content[0].text).toContain("fixture answer");
  await flush();
  expect(players.values).toHaveLength(1);
  expect(capture).toHaveBeenCalledTimes(1);
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
  expect(capture).toHaveBeenCalledTimes(1);
});

for (const exitCode of [1, 143]) it(`failed natural player exit ${exitCode} never opens the microphone`, async () => {
  const { player } = await startAsk();
  player.exit.resolve(exitCode);
  expect((await pending)?.isError).toBe(true);
  expect(capture).not.toHaveBeenCalled();
});

it("VoiceBar socket commands pause and resume the admitted Ask identity", async () => {
  const { player, handle } = await startAsk();
  playTo(4200);
  expect(await handleSocketCommand({ cmd: "pause", id: "vb-p", playback_id: handle.id,
    generation: handle.generation, playback_elapsed_ms: 4200 })).toMatchObject({ command: "pause", outcome: "accept", offset_ms: 4200 });
  player.exit.resolve(143); (await trims.at(0)).resolve(0); await flush();
  expect(await handleSocketCommand({ cmd: "resume", id: "vb-r", playback_id: handle.id,
    generation: handle.generation })).toMatchObject({ command: "resume", outcome: "accept", offset_ms: 4200 });
  (await players.at(1)).exit.resolve(0);
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
});

it("Stop during admitted prompt preparation captures without spawning a player", async () => {
  const envelope = deferred<amplitude.PlaybackAmplitudeEnvelope>();
  spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({ result: envelope.promise, cancel() {} });
  pending = handleVoiceAsk({ message: question });
  await flush();
  expect(handles).toHaveLength(1);
  expect(players.values).toHaveLength(0);
  tts.stopPlayback(); envelope.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] });
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
  expect(players.values).toHaveLength(0);
});

for (const preparing of [false, true]) it(`Stop after Resume while ${preparing ? "preparing" : "waiting for the old exit"} captures after all exits`, async () => {
  const envelope = deferred<amplitude.PlaybackAmplitudeEnvelope>();
  let player: Player | undefined;
  let handle: tts.QueuedPlaybackHandle;
  if (preparing) {
    spies.push(spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({ result: envelope.promise, cancel() {} }));
    pending = handleVoiceAsk({ message: question });
    await flush();
    handle = handles[0];
    expect(tts.pausePlayback({ id: handle.id }, 0).outcome).toBe("accept");
  } else {
    ({ player, handle } = await pauseAsk());
    (await trims.at(0)).resolve(0);
  }
  await flush();
  expect(tts.resumePlayback({ id: handle.id, generation: handle.generation }).outcome).toBe("accept");
  await flush();
  expect(players.values).toHaveLength(preparing ? 0 : 1);
  const command = handleSocketCommand({ cmd: "stop", id: "resume-stop" });
  await flush();
  expect(capture).not.toHaveBeenCalled();
  player?.exit.resolve(143);
  envelope.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] });
  expect(await command).toMatchObject({ outcome: "accept" });
  const result = await pending;
  expect(result?.content[0].text).toContain("fixture answer");
  expect(result?.content[0].text).toContain("Prompt interrupted");
  expect(capture).toHaveBeenCalledTimes(1);
  expect(await handle.exited).toMatchObject({ status: "skipped", reason: "stopped" });
  expect(players.values).toHaveLength(preparing ? 0 : 1);
});

it("Stop then Esc before player exit preserves main capture behaviour", async () => {
  const { player } = await startAsk();
  const stop = handleSocketCommand({ cmd: "stop", id: "stop-esc" });
  await flush();
  const cancel = handleSocketCommand({ cmd: "cancel", id: "esc-after-stop" });
  expect(booking.hasCancelSignal()).toBe(true);
  expect(capture).not.toHaveBeenCalled();
  player.exit.resolve(143);
  expect(await cancel).toMatchObject({ outcome: "accept" });
  await stop;
  expect((await pending)?.content[0].text).toContain("fixture answer");
  expect(capture).toHaveBeenCalledTimes(1);
});

for (const paused of [false, true]) it(`Disconnect during ${paused ? "paused" : "playing"} Ask never captures`, async () => {
  const disconnect = new AbortController();
  pending = handleVoiceAsk({ message: question }, { emit() {}, disconnectSignal: disconnect.signal });
  const player = await players.at(0);
  if (paused) expect(tts.pausePlayback({ id: handles[0].id }, 0).outcome).toBe("accept");
  disconnect.abort();
  tts.stopPlayback();
  await flush();
  expect(capture).not.toHaveBeenCalled();
  player.exit.resolve(143);
  expect((await pending)?.content[0].text).toContain("ended before recording");
  expect(capture).not.toHaveBeenCalled();
});

for (const shutdown of [false, true]) for (const framing of ["mcp", "ndjson"]) it(`${framing} ${shutdown ? "daemon shutdown" : "client disconnect"} cancels its owned Ask without capture`, async () => {
  let disconnectSignal: AbortSignal | undefined;
  const daemon = await createMcpDaemon({
    socketPath: testSocket("ask.sock"),
    toolExecutor: { executeTool(_name, args, context) {
      disconnectSignal = context.disconnectSignal;
      pending = handleVoiceAsk(args, context);
      return pending;
    } },
  });
  const client = await Bun.connect({
    unix: testSocket("ask.sock"),
    socket: { data() {}, close() {}, error() {} },
  });
  try {
    const request = { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "voice_ask", arguments: { message: question } } };
    client.write(framing === "mcp" ? serializeMcpFrame(request) : JSON.stringify(request) + "\n");
    const player = await players.at(0);
    expect(disconnectSignal).toBeDefined();
    if (!disconnectSignal) return;
    const disconnected = new Promise<void>(resolve => disconnectSignal?.addEventListener("abort", () => resolve(), { once: true }));
    if (shutdown) {
      daemon.stop();
      expect(disconnectSignal.aborted).toBe(true);
    } else client.end();
    await disconnected;
    await flush();
    expect(capture).not.toHaveBeenCalled();
    player.exit.resolve(143);
    expect((await pending)?.content[0].text).toContain("ended before recording");
    expect(capture).not.toHaveBeenCalled();
  } finally {
    client.end();
    daemon.stop();
  }
});

// BUSY-ASK: F5 cancels only a question; physical exit and reservation release precede its mic.
it("F5 during an Ask prompt admits the named take instead of returning Busy", async () => {
  const { player } = await startAsk();
  capture.mockImplementation(async () => {
    expect(tts.isCaptureAdmissionReserved()).toBe(false);
    expect(hasActiveVoiceOperation()).toBe(false);
    return finishSyntheticCapture(async () => "dictation words");
  });
  const record = Promise.resolve(handleSocketCommand({ cmd: "record", id: "during-ask", take_id: "during-ask-take" }));
  try {
    await flush();
    expect(player.signals).toContain("SIGTERM");
    expect(capture).not.toHaveBeenCalled();
    expect(tts.isCaptureAdmissionReserved()).toBe(true);
    expect(hasActiveVoiceOperation()).toBe(true);
    expect(hasScopedCapture(null)).toBe(true);
  } finally { player.exit.resolve(143); }
  expect(await record).toMatchObject({ command: "record", outcome: "accept" });
  const result = await pending;
  expect(result?.isError).not.toBe(true);
  expect(result?.content[0].text).toContain("the user started a dictation; ask cancelled");
  expect(result?.content[0].text).toMatch(/ask\/archive id: (?!unavailable)[^ )]+/);
  await flush();
  expect(tts.hasF5Capture()).toBe(false);
  expect(capture).toHaveBeenCalledTimes(1);
  expect(tts.isCaptureAdmissionReserved()).toBe(false);
  expect(hasActiveVoiceOperation()).toBe(false);
  // A second dictation and a second Ask must work without restarting either owner.
  expect(await handleSocketCommand({ cmd: "record", id: "next-f5", take_id: "next-take" })).toMatchObject({ outcome: "accept" });
  await flush();
  expect(capture).toHaveBeenCalledTimes(2);
  capture.mockResolvedValue("next Ask answer");
  pending = handleVoiceAsk({ message: question, timeout_seconds: 5 });
  (await players.at(1)).exit.resolve(0);
  expect((await pending)?.content[0].text).toContain("next Ask answer");
});

for (const control of ["stop", "cancel"] as const) it(`F5 ${control} during Ask physical exit is buffered for only its named take`, async () => {
  const { player } = await startAsk();
  const stopFile = await import("../paths");
  const fs = await import("node:fs");
  capture.mockImplementation(async (_timeout, _mode, _ptt, options) => {
    options?.onCaptureStart?.();
    const signal = JSON.parse(fs.readFileSync(stopFile.STOP_FILE, "utf8"));
    expect(signal.take_id).toBe(`buffered-${control}-take`);
    expect(signal.cancelled === true).toBe(control === "cancel");
    return finishSyntheticCapture(async () => "retained words");
  });
  const record = Promise.resolve(handleSocketCommand({ cmd: "record", id: "buffered-record", take_id: `buffered-${control}-take` }));
  try {
    await flush();
    expect(await handleSocketCommand({ cmd: control, id: "buffered-control", take_id: `buffered-${control}-take`, ...(control === "stop" ? { physical_press: true } : {}) }))
      .toMatchObject({ outcome: "accept" });
    expect(capture).not.toHaveBeenCalled();
  } finally { player.exit.resolve(143); }
  expect(await record).toMatchObject({ outcome: "accept" });
  await pending;
  await flush();
  expect(capture).toHaveBeenCalledTimes(1);
  expect(hasScopedCapture(null)).toBe(false);
  booking.clearStopSignal();
});

it("F5 during Ask listening retains the existing busy refusal and does not cancel the answer", async () => {
  const answer = deferred<string>();
  const listening = deferred<void>();
  capture.mockImplementation(async () => { listening.resolve(); return answer.promise; });
  const { player } = await startAsk();
  player.exit.resolve(0);
  await listening.promise;
  try {
    expect(await handleSocketCommand({ cmd: "record", id: "listening-f5", take_id: "listening-take" }))
      .toMatchObject({ outcome: "reject", reason: "busy" });
  } finally { answer.resolve("retained answer"); }
  expect((await pending)?.content[0].text).toContain("retained answer");
});


it("F5 aborts only Ask synthesis and admits dictation before the 2 second record-ack deadline", async () => {
  const entered = deferred<AbortSignal>();
  const synthesis = deferred<null>();
  const otherSynthesis = deferred<null>();
  const otherEntered = deferred<AbortSignal>();
  let releasedSynthesis = false;
  spies.push(spyOn(narrationSource(), "synthesize").mockImplementation(request => {
    expect(request.signal).toBeDefined();
    const other = request.text === "Unrelated narration";
    (other ? otherEntered : entered).resolve(request.signal!);
    return new Promise((resolve, reject) => {
      request.signal!.addEventListener("abort", () => reject(request.signal!.reason), { once: true });
      void (other ? otherSynthesis : synthesis).promise.then(resolve, reject);
    });
  }));
  spyOn(tts, "speak").mockImplementation((text, options) => realSpeak(text, { ...options, voice: "en-US-AriaNeural" }));
  capture.mockImplementation(async () => {
    expect(tts.isCaptureAdmissionReserved()).toBe(false);
    expect(hasActiveVoiceOperation()).toBe(false);
    return finishSyntheticCapture(async () => "every dictated word");
  });
  pending = handleVoiceAsk({ message: question, timeout_seconds: 5 });
  const promptSignal = await entered.promise;
  const other = realSpeak("Unrelated narration", { voice: "en-US-AriaNeural" }).catch(error => error);
  const otherSignal = await otherEntered.promise;
  let ack: unknown;
  const record = Promise.resolve(handleSocketCommand({ cmd: "record", id: "synthesis-f5", take_id: "synthesis-take" }))
    .then(value => { ack = value; return value; });
  try {
    await flush();
    jest.advanceTimersByTime(1999);
    await flush();
    expect(releasedSynthesis).toBe(false);
    expect(ack).toMatchObject({ command: "record", outcome: "accept" });
    expect(promptSignal.aborted).toBe(true);
    expect(otherSignal.aborted).toBe(false);
    expect(capture).toHaveBeenCalledTimes(1);
    expect(players.values).toHaveLength(0);
    const result = await pending;
    expect(result?.isError).not.toBe(true);
    expect(result?.content[0].text).toContain("the user started a dictation; ask cancelled");
  } finally {
    releasedSynthesis = true;
    synthesis.resolve(null);
    otherSynthesis.resolve(null);
    await other;
    await record;
    await pending;
    await flush();
  }
});


for (const refusal of ["mic-disabled", "foreign-booking"] as const) it(`F5 ${refusal} does not cancel the Ask prompt`, async () => {
  const { player } = await startAsk();
  const check = refusal === "mic-disabled"
    ? spyOn(input, "micAllowed").mockReturnValue(false)
    : spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: false,
        owner: { sessionId: "other-session", pid: 9999, startedAt: "2026-01-01T00:00:00Z" } });
  let ack: unknown;
  const record = Promise.resolve(handleSocketCommand({ cmd: "record", id: refusal, take_id: `${refusal}-take` }))
    .then(value => { ack = value; return value; });
  try {
    await flush();
    expect(ack).toMatchObject({ outcome: "reject", reason: refusal === "mic-disabled" ? "mic disabled" : "busy" });
    expect(player.signals).toEqual([]);
    expect(tts.isCaptureAdmissionReserved()).toBe(true);
    expect(hasActiveVoiceOperation()).toBe(true);
    expect(capture).not.toHaveBeenCalled();
  } finally {
    check.mockRestore();
    player.exit.resolve(0);
    await pending;
    await record;
    await flush();
  }
  expect((await pending)?.content[0].text).toContain("fixture answer");
});
