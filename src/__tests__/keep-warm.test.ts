import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync, rmSync, writeFileSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { ModelResidency, modelIdlePolicy, modelIdleSeconds, setModelIdleSeconds, setModelUnloadWhenIdle } from "../model-residency";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand } from "../socket-handlers";
import { warmSelectedRecognizer, type RecognizerTransitionDeps } from "../recognizer-controller";
import { beginRecognizerRequestAfterMaintenance, finishRecognizerRequest, readRecognizerStatus, configureRecognizerBusyProbe, noteRecognizerEngine } from "../recognizer-state";
import { canStartBarCapture } from "../recording-jobs";

const settings = testTmp("keep-warm.json");
const env = { ...process.env, VOICELAYER_MODEL_SETTINGS_PATH: settings,
  VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: undefined, VOICELAYER_MODEL_UNLOAD_WHEN_IDLE: undefined };
const saved = { path: process.env.VOICELAYER_MODEL_SETTINGS_PATH, idle: process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS,
  enabled: process.env.VOICELAYER_MODEL_UNLOAD_WHEN_IDLE, backend: process.env.QA_VOICE_STT_BACKEND };
afterEach(() => {
  rmSync(settings, { force: true });
  for (const [key, value] of Object.entries({ VOICELAYER_MODEL_SETTINGS_PATH: saved.path, VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: saved.idle,
    VOICELAYER_MODEL_UNLOAD_WHEN_IDLE: saved.enabled, QA_VOICE_STT_BACKEND: saved.backend })) {
    if (value === undefined) delete process.env[key]; else process.env[key] = value;
  }
  configureRecognizerBusyProbe(() => null);
});
function isolatedPolicy() {
  process.env.VOICELAYER_MODEL_SETTINGS_PATH = settings;
  delete process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
  delete process.env.VOICELAYER_MODEL_UNLOAD_WHEN_IDLE;
}

test("new and legacy settings default resident; setters preserve each other", () => {
  expect(modelIdlePolicy(env)).toMatchObject({ unload_when_idle: false, unload_when_idle_locked: false });
  writeFileSync(settings, JSON.stringify({ version: 1, idle_unload_seconds: 600 }));
  expect(modelIdlePolicy(env).unload_when_idle).toBe(false);
  setModelUnloadWhenIdle(true, env); expect(modelIdleSeconds(env)).toBe(600);
  setModelIdleSeconds(31, env); expect(modelIdlePolicy(env).unload_when_idle).toBe(true);
  expect(JSON.parse(readFileSync(settings, "utf8"))).toEqual({ version: 1, idle_unload_seconds: 31, unload_when_idle: true });
  setModelUnloadWhenIdle(false, env); expect(modelIdleSeconds(env)).toBe(31);
});

test("env wins and locks including legacy timeout; explicit false defeats legacy timeout", () => {
  setModelUnloadWhenIdle(true, env);
  const overridden = { ...env, VOICELAYER_MODEL_UNLOAD_WHEN_IDLE: "false", VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "12" };
  expect(modelIdlePolicy(overridden)).toEqual({ unload_when_idle: false, unload_when_idle_locked: true, unload_when_idle_env_var: "VOICELAYER_MODEL_UNLOAD_WHEN_IDLE" });
  expect(() => setModelUnloadWhenIdle(true, overridden)).toThrow("set by VOICELAYER_MODEL_UNLOAD_WHEN_IDLE");
  expect(modelIdlePolicy({ ...env, VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "12" }).unload_when_idle).toBe(true);
  expect(modelIdlePolicy({ ...env, VOICELAYER_MODEL_UNLOAD_WHEN_IDLE: "" }).unload_when_idle).toBe(false);
});

test("OFF schedules no eviction; ON requests exactly 600 seconds and unloads", async () => {
  let unloads = 0;
  const residency = new ModelResidency(async () => { unloads++; }, () => modelIdleSeconds(env), () => false, () => modelIdlePolicy(env).unload_when_idle);
  const timer = spyOn(globalThis, "setTimeout");
  try {
    await residency.use(async () => {}); expect(timer).not.toHaveBeenCalled();
    setModelUnloadWhenIdle(true, env); residency.refresh();
    expect(timer).toHaveBeenCalledTimes(1);
    const [callback, milliseconds] = timer.mock.calls[0]!;
    expect(milliseconds).toBe(600_000);
    if (typeof callback !== "function") throw new Error("Expected timer callback");
    callback(); await Promise.resolve(); await Promise.resolve();
    expect(unloads).toBe(1);
  } finally { timer.mockRestore(); residency.reset(); }
});

test("wire parser rejects invalid switch/pressure fields; ack and status expose lock", async () => {
  isolatedPolicy();
  expect(parseCommand('{"cmd":"set_model_unload_when_idle","value":true,"id":"k2"}')).toEqual({ cmd: "set_model_unload_when_idle", value: true, id: "k2" });
  expect(parseCommand('{"cmd":"set_model_unload_when_idle","value":1}')).toBeNull();
  expect(parseCommand('{"cmd":"memory_pressure","level":"warning"}')).toEqual({ cmd: "memory_pressure", level: "warning" });
  expect(parseCommand('{"cmd":"memory_pressure","level":"normal"}')).toBeNull();
  expect(await handleSocketCommand({ cmd: "set_model_unload_when_idle", value: true, id: "k2" })).toMatchObject({ type: "ack", id: "k2", outcome: "accept", recognizer_status: { unload_when_idle: true, unload_when_idle_locked: false } });
  process.env.VOICELAYER_MODEL_UNLOAD_WHEN_IDLE = "off";
  expect(await handleSocketCommand({ cmd: "set_model_unload_when_idle", value: true })).toMatchObject({ outcome: "reject", recognizer_status: { unload_when_idle: false, unload_when_idle_locked: true } });
});

test("pressure command refuses capture before touching the provider", async () => {
  configureRecognizerBusyProbe(() => "capture-active");
  expect(await handleSocketCommand({ cmd: "memory_pressure", level: "critical", id: "pressure" })).toMatchObject({ command: "memory_pressure", outcome: "reject", reason: "capture-active" });
});

for (const engine of ["parakeet", "whisper"] as const) test(`boot warms selected ${engine}; capture remains admitted and inference waits for that load`, async () => {
  process.env.QA_VOICE_STT_BACKEND = engine;
  configureRecognizerBusyProbe(() => null);
  const ready = Promise.withResolvers<void>();
  const calls: string[] = [];
  const deps: RecognizerTransitionDeps = { assetsPresent: () => true, reset: () => {}, stopP: async () => {}, stopW: async () => {},
    startP: async () => { calls.push("parakeet"); await ready.promise; }, startW: async () => { calls.push("whisper"); await ready.promise; } };
  const warm = warmSelectedRecognizer(deps);
  expect(calls).toEqual([engine]);
  expect(canStartBarCapture()).toBe(true);
  let admitted = false;
  const request = beginRecognizerRequestAfterMaintenance().then(() => { admitted = true; });
  try {
    await Promise.resolve(); expect(admitted).toBe(false);
    ready.resolve(); await warm; await request;
    expect(admitted).toBe(true); expect(calls).toEqual([engine]);
    expect(readRecognizerStatus()).toMatchObject({ effective: engine, phase: "ready" });
  } finally { ready.resolve(); await warm; await request; finishRecognizerRequest(); noteRecognizerEngine(engine, { phase: "sleeping" }); }
});
