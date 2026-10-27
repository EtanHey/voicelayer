import { afterEach, expect, spyOn, test } from "bun:test";
import { rmSync } from "fs";
import { join } from "path";
import { ModelResidency, modelIdleSeconds, setModelIdleSeconds } from "../model-residency";
import { resetSTTPolishServerManagerForTests, withSTTPolishServer } from "../stt-polish-server";

import { __resetWhisperServerStateForTests, __setWhisperServerTestHooksForTests, ensureServer, transcribeViaServer } from "../whisper-server";

const settings = join(process.env.VOICELAYER_STATE_DIR!, "idle-test.json");
afterEach(() => { rmSync(settings, { force: true }); resetSTTPolishServerManagerForTests(); });

test("one persisted timeout: env > file > 600 seconds, invalid values use default", () => {
  const env = { ...process.env, VOICELAYER_MODEL_SETTINGS_PATH: settings };
  expect(modelIdleSeconds(env)).toBe(600);
  setModelIdleSeconds(31, env);
  expect(modelIdleSeconds(env)).toBe(31);
  expect(modelIdleSeconds({ ...env, VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "12" })).toBe(12);
  expect(modelIdleSeconds({ ...env, VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "" })).toBe(600);
  expect(() => setModelIdleSeconds(-1, env)).toThrow();
});

test("idle eviction waits for work; new requests wait for unloading to finish", async () => {
  let unloads = 0, finishUnload!: () => void, finishWork!: () => void;
  const unloading = Promise.withResolvers<void>();
  const residency = new ModelResidency(async () => { unloads++; unloading.resolve(); await new Promise<void>(r => { finishUnload = r; }); }, () => 0.01);
  try {
    const work = residency.use(() => new Promise<void>(r => { finishWork = r; }));
    await Bun.sleep(30);
    expect(unloads).toBe(0);
    finishWork(); await work; await unloading.promise;
    let served = false;
    const next = residency.use(async () => { served = true; });
    await Bun.sleep(0); expect(served).toBe(false);
    finishUnload(); await next; expect(served).toBe(true);
  } finally { residency.reset(); }
});


test("first concurrent polish requests share a load; idle stop waits for child exit before reload", async () => {
  let spawns = 0, probes = 0, ready = false, alive = false, exit!: (code: number) => void;
  let stopped!: () => void;
  const stopping = new Promise<void>(r => { stopped = r; });
  const spawned = Promise.withResolvers<void>(), loaded = Promise.withResolvers<void>();
  const options = {
    env: { ...process.env, QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_ENDPOINT: "http://127.0.0.1:8080/v1/chat/completions", VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "0.01" },
    findBinary: () => "/fixture/mlx_lm.server", findPortOwnerPids: () => alive ? [456] : [],
    isProcessAlive: () => alive, isEndpointReady: async () => { probes++; if (alive) await loaded.promise; return ready; },
    spawn: () => { spawns++; alive = ready = true; spawned.resolve(); return { pid: 456, exited: new Promise<number>(r => { exit = r; }), kill: () => { stopped(); } }; },
    appendEvent: () => {}, log: () => {}, sleep: async () => {},
  };
  expect(spawns).toBe(0);
  let finish!: () => void;
  const held = withSTTPolishServer(() => new Promise<void>(r => { finish = r; }), options);
  await spawned.promise;
  let secondServed = false;
  const second = withSTTPolishServer(async () => { secondServed = true; }, options);
  await Bun.sleep(0); expect(secondServed).toBe(false);
  loaded.resolve(); await second;
  const warmProbes = probes;
  await withSTTPolishServer(async () => {}, options);
  expect(probes).toBe(warmProbes);
  await Bun.sleep(30); expect(spawns).toBe(1); expect(ready).toBe(true);
  finish(); await held; await stopping;
  let served = false;
  const reload = withSTTPolishServer(async () => { served = true; }, options);
  await Bun.sleep(0); expect(served).toBe(false);
  alive = ready = false; exit(0);
  await reload; expect(spawns).toBe(2); expect(served).toBe(true);
  alive = ready = false; exit(0);
});

test("stub cold/warm lease latency separates loading from inference", async () => {
  let loaded = false, loads = 0;
  const residency = new ModelResidency(async () => { loaded = false; });
  const request = () => residency.use(async () => {
    if (!loaded) { loads++; await Bun.sleep(25); loaded = true; }
    await Bun.sleep(2);
  });
  const start = performance.now(); await request(); const cold = performance.now() - start;
  const warmStart = performance.now(); await request(); const warm = performance.now() - warmStart;
  residency.reset();
  expect(loads).toBe(1);
  console.log(JSON.stringify({ model: "stub", cold_ms: cold, warm_ms: warm, real_model: "NOT MEASURED" }));
});


test("Whisper idle stop respects inference and queues a fresh load behind child exit", async () => {
  const previous = process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
  process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = "0.015";
  let healthy = false, spawns = 0, stoppedCount = 0, exits!: (code: number) => void;
  const stopped = Promise.withResolvers<void>();
  const inference = Promise.withResolvers<Response>();
  const fetchMock = spyOn(globalThis, "fetch").mockImplementation(() => inference.promise);
  __setWhisperServerTestHooksForTests({
    findServerBinary: () => "/fixture/whisper-server", findModel: () => "/fixture/model.bin",
    isServerHealthy: async () => healthy, isPidAlive: () => healthy,
    processStartTimeMs: () => Date.now() - 1000,
    findPortListenerPids: () => healthy ? [55111] : [], postUnloadListeners: () => healthy ? [55111] : [],
    reserveVoiceMaintenance: () => () => {},
    spawn: () => { spawns++; healthy = true; return { pid: 55111, kill: () => { stoppedCount++; stopped.resolve(); }, exited: new Promise<number>(r => { exits = r; }) }; },
  });
  try {
    await Promise.all([ensureServer(18889), ensureServer(18889)]);
    expect(spawns).toBe(1);
    const pending = transcribeViaServer(new Uint8Array(44), 18889);
    await Bun.sleep(40); expect(stoppedCount).toBe(0);
    inference.resolve(Response.json({ text: "hello" }));
    expect(await pending).toBe("hello");
    await stopped.promise;
    const next = ensureServer(18889);
    await Bun.sleep(0); expect(spawns).toBe(1);
    healthy = false; exits(0);
    await next; expect(spawns).toBe(2);
  } finally {
    fetchMock.mockRestore(); __resetWhisperServerStateForTests(null); __setWhisperServerTestHooksForTests({});
    if (previous === undefined) delete process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
    else process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = previous;
  }
});

for (const state of ["recording", "transcribing", "voice_ask"] as const) {
  test(`daemon-owned ${state} defers Whisper and polish eviction until idle`, async () => {
    const input = await import("../input");
    const tts = await import("../tts");
    const operations = await import("../voice-operation-reservation");
    const booking = await import("../session-booking");
    const previous = process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
    process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = "0.04";
    const recording = spyOn(input, "getRecordingState").mockReturnValue(state === "voice_ask" ? "idle" : state);
    const playback = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0);
    const operation = spyOn(operations, "hasActiveVoiceOperation").mockReturnValue(state === "voice_ask");
    let whisperAlive = false, polishAlive = false, whisperStops = 0, polishStops = 0;
    const whisperExit = Promise.withResolvers<number>(), polishExit = Promise.withResolvers<number>();
    __setWhisperServerTestHooksForTests({
      findServerBinary: () => "/fixture/whisper-server", findModel: () => "/fixture/model.bin",
      isServerHealthy: async () => whisperAlive, isPidAlive: () => whisperAlive,
      processStartTimeMs: () => Date.now() - 1000,
      findPortListenerPids: () => whisperAlive ? [55112] : [], postUnloadListeners: () => [],
      spawn: () => { whisperAlive = true; return { pid: 55112, exited: whisperExit.promise,
        kill: () => { whisperStops++; whisperAlive = false; whisperExit.resolve(0); } }; },
    });
    try {
      expect(booking.bookVoiceSession().success).toBe(true);
      expect(booking.isVoiceBooked().ownedByUs).toBe(true);
      await ensureServer(18890);
      await withSTTPolishServer(async () => {}, {
        env: { QA_VOICE_STT_POLISH: "on", VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "0.04" },
        findBinary: () => "/fixture/mlx_lm.server", isEndpointReady: async () => polishAlive,
        isProcessAlive: () => polishAlive,
        spawn: () => { polishAlive = true; return { pid: 456, exited: polishExit.promise,
          kill: () => { polishStops++; polishAlive = false; polishExit.resolve(0); } }; },
        appendEvent: () => {}, log: () => {}, sleep: async () => {},
      });
      await Bun.sleep(110);
      expect([whisperStops, polishStops]).toEqual([0, 0]);
      recording.mockReturnValue("idle"); operation.mockReturnValue(false);
      await Bun.sleep(25);
      expect([whisperStops, polishStops]).toEqual([0, 0]);
      const deadline = Date.now() + 2000;
      while ((!whisperStops || !polishStops) && Date.now() < deadline) await Bun.sleep(10);
      expect([whisperStops, polishStops]).toEqual([1, 1]);
    } finally {
      recording.mockRestore(); playback.mockRestore(); operation.mockRestore();
      booking.releaseVoiceSession();
      __resetWhisperServerStateForTests(null); __setWhisperServerTestHooksForTests({});
      resetSTTPolishServerManagerForTests();
      if (previous === undefined) delete process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
      else process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = previous;
    }
  });
}

test("cold polish never-ready startup returns unpolished within the transcript budget", async () => {
  const manager = await import("../stt-polish-server");
  const { polishTranscriptionText } = await import("../stt-polish");
  const original = manager.withSTTPolishServer;
  let spawns = 0;
  const exit = Promise.withResolvers<number>();
  const launcher = spyOn(manager, "withSTTPolishServer").mockImplementation((work, options) => original(work, {
    ...options, findBinary: () => "/fixture/mlx_lm.server", findPortOwnerPids: () => [],
    isEndpointReady: async () => false, isProcessAlive: () => true,
    spawn: () => { spawns++; return { pid: 457, exited: exit.promise, kill: () => exit.resolve(1) }; },
    startupTimeoutMs: 350, sleep: () => Bun.sleep(20), appendEvent: () => {}, log: () => {},
  }));
  const network = spyOn(globalThis, "fetch").mockResolvedValue(Response.json({}, { status: 503 }));
  try {
    const start = performance.now();
    const result = await polishTranscriptionText({ rawText: "Hello.", cleanedText: "Hello.",
      env: { QA_VOICE_STT_POLISH: "on", QA_VOICE_STT_POLISH_TIMEOUT_MS: "50" } });
    expect(result.text).toBe("Hello.");
    expect(result.polished).toBe(false);
    expect(performance.now() - start).toBeLessThan(250);
    expect(spawns).toBe(1);
    expect(network).not.toHaveBeenCalled();
  } finally {
    resetSTTPolishServerManagerForTests(); exit.resolve(1);
    launcher.mockRestore(); network.mockRestore();
  }
});

test("recording-start polish warmup launches a cold server", async () => {
  const manager = await import("../stt-polish-server");
  const { warmPolishEndpoint } = await import("../stt-polish");
  const original = manager.withSTTPolishServer;
  let spawns = 0;
  const launcher = spyOn(manager, "withSTTPolishServer").mockImplementation((work, options) => original(work, {
    ...options, findBinary: () => "/fixture/mlx_lm.server", isEndpointReady: async () => spawns > 0,
    spawn: () => { spawns++; return { pid: 458 }; }, appendEvent: () => {}, log: () => {},
  }));
  const network = spyOn(globalThis, "fetch").mockImplementation(async () => Response.json({ choices: [{ message: { content: "Ready." } }] }));
  try {
    await warmPolishEndpoint({ QA_VOICE_STT_POLISH: "on", VOICELAYER_STT_POLISH_WARMUP: "1" });
    expect(spawns).toBe(1);
  } finally { resetSTTPolishServerManagerForTests(); launcher.mockRestore(); network.mockRestore(); }
});

test("daemon polish startup subscribes without launching; first use launches once", async () => {
  const { startSTTPolishStatusReporting } = await import("../stt-polish-daemon-status");
  const spawn = spyOn(Bun, "spawn").mockImplementation(() => { throw new Error("startup spawned a model"); });
  let launches = 0;
  const events: unknown[] = [];
  const reporting = startSTTPolishStatusReporting(event => events.push(event));
  try {
    reporting.reporter.replay();
    expect(spawn).not.toHaveBeenCalled();
    expect(events).toEqual([]);
    await withSTTPolishServer(async () => {}, {
      env: { QA_VOICE_STT_POLISH: "on" }, findBinary: () => "/fixture/mlx_lm.server",
      isEndpointReady: async () => launches > 0,
      spawn: () => { launches++; return { pid: 459 }; }, appendEvent: () => {}, log: () => {},
    });
    expect(launches).toBe(1);
    expect(events).toEqual([{ type: "polish_ready" }]);
  } finally { reporting.unsubscribe(); resetSTTPolishServerManagerForTests(); spawn.mockRestore(); }
});

test.each([["1_000", 600], ["0x10", 600], ["1e3", 600], ["+12", 600], [" 12.5 ", 12.5], ["0", 600], ["Infinity", 600]])("strict idle env %s resolves to %s", (raw, expected) => {
  expect(modelIdleSeconds({ VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: String(raw) })).toBe(Number(expected));
});

test("polish child startup failure is reported immediately after exit", async () => {
  const { ensureSTTPolishServer } = await import("../stt-polish-server");
  const start = performance.now();
  const result = await ensureSTTPolishServer({ env: { QA_VOICE_STT_POLISH: "on" },
    findBinary: () => "/fixture/mlx_lm.server", isEndpointReady: async () => false,
    spawn: () => ({ pid: 460, exited: Promise.resolve(1) }),
    startupTimeoutMs: 400, appendEvent: () => {}, log: () => {},
  });
  expect(result.status).toBe("launch-failed");
  expect(performance.now() - start).toBeLessThan(250);
});
