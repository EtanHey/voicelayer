import { writeWhisperServerOwnership, clearWhisperServerOwnership } from "../whisper-server-ownership";
import { mkdirSync, writeFileSync } from "fs";
import { testTmp } from "./setup/test-tmp";
import { afterEach, expect, test } from "bun:test";
import {
  __clearWhisperServerLaunchRecordForTests,
  __resetWhisperServerStateForTests,
  __setWhisperServerTestHooksForTests,
  ensureServer,
  onWhisperModelStateChange,
  stopServer,
} from "../whisper-server";

afterEach(() => {
  __resetWhisperServerStateForTests(null);
  __clearWhisperServerLaunchRecordForTests();
  __setWhisperServerTestHooksForTests({});
});

test("adoption and stop emit model state changes without a health poll", async () => {
  __resetWhisperServerStateForTests(null);
  __clearWhisperServerLaunchRecordForTests();
  const port = 28_179;
  const savedModel = process.env.QA_VOICE_WHISPER_MODEL;
  const root = testTmp("model-events");
  mkdirSync(root, { recursive: true });
  process.env.QA_VOICE_WHISPER_MODEL = root + "/fixture-model.bin";
  writeFileSync(process.env.QA_VOICE_WHISPER_MODEL, "isolated synthetic weights");
  let changes = 0;
  const unsubscribe = onWhisperModelStateChange(() => { changes++; });
  __setWhisperServerTestHooksForTests({
    isServerHealthy: async () => true,
    findPortListenerPids: () => [process.pid],
  });
  writeWhisperServerOwnership(port, { pid: process.pid, owner_pid: process.pid,
    started_at: new Date().toISOString(), binary: "/synthetic/whisper-server", args: [],
    model_path: process.env.QA_VOICE_WHISPER_MODEL, performance_effort: "accurate", acceleration_mode: "cpu" });
  try {
    await ensureServer(port);
    expect(changes).toBe(1);
    stopServer();
    expect(changes).toBe(2);
  } finally {
    unsubscribe(); clearWhisperServerOwnership(port);
    if (savedModel === undefined) delete process.env.QA_VOICE_WHISPER_MODEL;
    else process.env.QA_VOICE_WHISPER_MODEL = savedModel;
  }
});
