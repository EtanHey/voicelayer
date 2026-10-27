import { afterEach, expect, spyOn, test } from "bun:test";
import {
  __resetWhisperServerStateForTests,
  __setWhisperServerTestHooksForTests,
  ensureServer,
  whisperServerLaunchRecord,
} from "../whisper-server";
import { readWhisperServerOwnership } from "../whisper-server-ownership";
import {
  ensureSTTPolishServer,
  onSTTPolishServerStatus,
  resetSTTPolishServerManagerForTests,
  stopSTTPolishServerAndWait,
  withSTTPolishServer,
} from "../stt-polish-server";

const previousIdle = process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
afterEach(() => {
  __resetWhisperServerStateForTests(null);
  __setWhisperServerTestHooksForTests({});
  resetSTTPolishServerManagerForTests();
  if (previousIdle === undefined) delete process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS;
  else process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = previousIdle;
});

async function until(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 7_000;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error("custody condition not observed");
    await Bun.sleep(10);
  }
}

test("Whisper retains idle child custody past SIGKILL timeout and retries before reload", async () => {
  process.env.VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS = "0.02";
  const exited = Promise.withResolvers<number>();
  const signals: string[] = [];
  const errors: string[] = [];
  const logger = spyOn(console, "error").mockImplementation((...args) => errors.push(args.join(" ")));
  let healthy = false, spawns = 0;
  __setWhisperServerTestHooksForTests({
    findServerBinary: () => "/fixture/whisper-server", findModel: () => "/fixture/model.bin",
    isServerHealthy: async () => healthy, isPidAlive: () => true,
    processStartTimeMs: () => Date.now() - 10_000,
    findPortListenerPids: () => healthy ? [55113] : [], postUnloadListeners: () => [],
    findExternalWhisperServerPids: () => [], reserveVoiceMaintenance: () => () => {},
    spawn: () => {
      spawns++; healthy = true;
      return { pid: 55113, exited: spawns === 1 ? exited.promise : Promise.resolve(0),
        kill: (signal) => { signals.push(signal ?? "SIGTERM"); healthy = false; } };
    },
  });
  try {
    await ensureServer(18891);
    const record = whisperServerLaunchRecord();
    const owner = readWhisperServerOwnership(18891);
    await until(() => signals.includes("SIGKILL"));
    await Bun.sleep(1_100);
    expect(whisperServerLaunchRecord()).toEqual(record);
    expect(readWhisperServerOwnership(18891)).toEqual(owner);
    expect(errors.some(message => message.includes("unload unconfirmed"))).toBe(true);
    await expect(ensureServer(18891)).rejects.toThrow(/unload unconfirmed/);
    expect(spawns).toBe(1);
    const attempts = signals.length;
    await until(() => signals.length > attempts);
    exited.resolve(137);
    await until(() => whisperServerLaunchRecord() === null);
    expect(readWhisperServerOwnership(18891)).toBeNull();
    await ensureServer(18891);
    expect(spawns).toBe(2);
  } finally { exited.resolve(137); logger.mockRestore(); }
}, 15_000);

test("polish retains idle child after both waits, retries and publishes stopped only after exit", async () => {
  const exited = Promise.withResolvers<number>();
  const signals: string[] = [], statuses: string[] = [], errors: string[] = [];
  const logger = spyOn(console, "error").mockImplementation((...args) => errors.push(args.join(" ")));
  const unsubscribe = onSTTPolishServerStatus(status => statuses.push(status.status));
  let healthy = false, spawns = 0;
  const options = {
    env: { QA_VOICE_STT_POLISH: "on", VOICELAYER_MODEL_IDLE_UNLOAD_SECONDS: "0.02" },
    findBinary: () => "/fixture/mlx_lm.server", findPortOwnerPids: () => healthy ? [55114] : [],
    isEndpointReady: async () => healthy, isProcessAlive: () => true,
    spawn: () => {
      spawns++; healthy = true;
      return { pid: 55114, exited: spawns === 1 ? exited.promise : Promise.resolve(0),
        kill: (signal?: NodeJS.Signals) => { signals.push(signal ?? "SIGTERM"); healthy = false; } };
    },
    appendEvent: () => {}, log: () => {}, sleep: async () => {},
  };
  try {
    await withSTTPolishServer(async () => {}, options);
    expect(spawns).toBe(1);
    await until(() => signals.includes("SIGKILL"));
    await Bun.sleep(1_600);
    expect(statuses).not.toContain("stopped");
    expect(errors.some(message => message.includes("unload unconfirmed"))).toBe(true);
    expect(await ensureSTTPolishServer({ ...options, forceRestart: true }))
      .toMatchObject({ status: "launch-failed", error: expect.stringContaining("unload unconfirmed") });
    expect(spawns).toBe(1);
    const attempts = signals.length;
    await until(() => signals.length > attempts);
    exited.resolve(137);
    await until(() => statuses.includes("stopped"));
    expect(await ensureSTTPolishServer(options)).toMatchObject({ status: "ready" });
    expect(spawns).toBe(2);
  } finally { exited.resolve(137); unsubscribe(); logger.mockRestore(); }
}, 15_000);

test.each(["SIGTERM", "SIGKILL"] as const)("polish propagates %s failures and keeps its child tracked", async (failedSignal) => {
  const exited = Promise.withResolvers<number>();
  let healthy = false, spawns = 0, fail = true;
  const options = {
    env: { QA_VOICE_STT_POLISH: "on" }, findBinary: () => "/fixture/mlx_lm.server",
    findPortOwnerPids: () => healthy ? [55115] : [], isEndpointReady: async () => healthy,
    isProcessAlive: () => true,
    spawn: () => {
      spawns++; healthy = true;
      return { pid: 55115, exited: exited.promise, kill: (signal?: NodeJS.Signals) => {
        healthy = false;
        if (fail && signal === failedSignal) throw new Error(`fixture ${signal} refused`);
        if (!fail) exited.resolve(0);
      } };
    },
    appendEvent: () => {}, log: () => {}, sleep: async () => {},
  };
  try {
    await ensureSTTPolishServer(options);
    await expect(stopSTTPolishServerAndWait()).rejects.toThrow(`fixture ${failedSignal} refused`);
    expect(await ensureSTTPolishServer({ ...options, forceRestart: true })).toMatchObject({ status: "launch-failed" });
    expect(spawns).toBe(1);
    fail = false;
    await stopSTTPolishServerAndWait();
  } finally { exited.resolve(0); }
}, 10_000);
