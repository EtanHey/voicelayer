import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync, rmSync } from "fs";
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

test("daemon startup does not ensure or warm model servers", () => {
  const source = readFileSync(join(import.meta.dir, "../mcp-server-daemon.ts"), "utf8");
  expect(source).not.toContain("ensureSTTPolishServer");
  expect(source).not.toContain("warmPolishEndpoint");
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
  expect(cold).toBeGreaterThan(warm + 15);
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
