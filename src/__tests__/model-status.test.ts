import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import {
  buildWhisperModelStatus,
  readWhisperModelStatus,
  selectConfiguredModelPath,
} from "../model-status";
import {
  __clearWhisperServerLaunchRecordForTests,
  __setWhisperServerLaunchRecordForTests,
  __setWhisperServerTestHooksForTests,
  type WhisperServerLaunchRecord,
} from "../whisper-server";

describe("whisper model status", () => {
  it("uses the CLI model search result when that backend is configured", () => {
    expect(selectConfiguredModelPath("whisper", null, "/models/ggml-small.en.bin"))
      .toBe("/models/ggml-small.en.bin");
  });
  it("reports configured and proven active identities separately", () => {
    expect(buildWhisperModelStatus({
      configuredPath: "/private/user/ggml-large-v3-turbo.bin",
      configuredSizeBytes: 1_617_000_000,
      residentHealthy: true,
      launchRecord: {
        modelPath: "/another/private/path/ggml-base.en.bin",
        performanceEffort: "balanced",
      },
      configuredEffort: "accurate",
    })).toEqual({
      configured_model: { name: "large-v3-turbo", size_bytes: 1_617_000_000, installed: true },
      residency: "loaded",
      active_model: "base.en",
      configured_effort: "accurate",
      active_effort: "balanced",
    });
  });
  it("does not guess active identity for a healthy server without provenance", () => {
    const status = buildWhisperModelStatus({
      configuredPath: "/models/ggml-large-v3-turbo.bin",
      configuredSizeBytes: 10,
      residentHealthy: true,
      launchRecord: null,
      configuredEffort: "fast",
    });
    expect(status.residency).toBe("loaded");
    expect(status.active_model).toBeNull();
    expect(status.active_effort).toBeNull();
  });
  it("keeps proven adopted model identity when its effort is unknown", () => {
    const status = buildWhisperModelStatus({
      configuredPath: "/models/ggml-large-v3-turbo.bin",
      configuredSizeBytes: 10,
      residentHealthy: true,
      launchRecord: { modelPath: "/models/ggml-base.en.bin", performanceEffort: null },
      configuredEffort: "accurate",
    });
    expect(status.active_model).toBe("base.en");
    expect(status.active_effort).toBeNull();
  });
  it("keeps unavailable residency unknown", () => {
    const status = buildWhisperModelStatus({
      configuredPath: null,
      configuredSizeBytes: null,
      residentHealthy: null,
      launchRecord: null,
      configuredEffort: "accurate",
    });
    expect(status.configured_model).toEqual({ name: null, size_bytes: null, installed: false });
    expect(status.residency).toBe("unknown");
  });
});

describe("resident whisper model identity", () => {
  const statusPort = 28_178;
  const statusModelDir = join(
    process.env.VOICELAYER_STATE_DIR ?? ".test-tmp",
    "model-status",
  );
  const configuredModel = join(statusModelDir, "ggml-configured.bin");
  const previousEnv = {
    backend: process.env.QA_VOICE_STT_BACKEND,
    port: process.env.QA_VOICE_WHISPER_SERVER_PORT,
    effort: process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT,
  };

  function restoreEnv(name: string, value: string | undefined): void {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }

  function launchRecord(
    pid: number,
    performanceEffort: WhisperServerLaunchRecord["performanceEffort"] = "balanced",
  ): WhisperServerLaunchRecord {
    return {
      binary: "/opt/homebrew/bin/whisper-server",
      modelPath: "/models/ggml-active.bin",
      args: [],
      performanceEffort,
      accelerationMode: "metal",
      pid,
      startedAt: "2026-09-22T18:00:00.000Z",
    };
  }

  function expectIndependentStatus(
    status: Awaited<ReturnType<typeof readWhisperModelStatus>>,
  ): void {
    expect(status.configured_model).toEqual({
      name: "configured",
      size_bytes: 4,
      installed: true,
    });
    expect(status.configured_effort).toBe("fast");
    expect(status.residency).toBe("loaded");
  }

  beforeEach(() => {
    mkdirSync(statusModelDir, { recursive: true });
    writeFileSync(configuredModel, "test");
    process.env.QA_VOICE_STT_BACKEND = "whisper-server";
    process.env.QA_VOICE_WHISPER_SERVER_PORT = String(statusPort);
    process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = "fast";
    __clearWhisperServerLaunchRecordForTests();
  });

  afterEach(() => {
    __setWhisperServerTestHooksForTests({});
    __clearWhisperServerLaunchRecordForTests();
    rmSync(statusModelDir, { recursive: true, force: true });
    restoreEnv("QA_VOICE_STT_BACKEND", previousEnv.backend);
    restoreEnv("QA_VOICE_WHISPER_SERVER_PORT", previousEnv.port);
    restoreEnv("QA_VOICE_WHISPER_PERFORMANCE_EFFORT", previousEnv.effort);
  });

  it("attributes a healthy resident only when its live listener matches the record", async () => {
    __setWhisperServerLaunchRecordForTests(launchRecord(51_001, null));
    __setWhisperServerTestHooksForTests({
      findModel: () => configuredModel,
      isServerHealthy: async () => true,
      findPortListenerPids: () => [51_001],
      isPidAlive: () => true,
    });

    const status = await readWhisperModelStatus();

    expectIndependentStatus(status);
    expect(status.active_model).toBe("active");
    expect(status.active_effort).toBeNull();
  });

  it("withholds active identity when the recorded PID is dead", async () => {
    __setWhisperServerLaunchRecordForTests(launchRecord(51_002));
    __setWhisperServerTestHooksForTests({
      findModel: () => configuredModel,
      isServerHealthy: async () => true,
      findPortListenerPids: () => [51_002],
      isPidAlive: () => false,
    });

    const status = await readWhisperModelStatus();

    expectIndependentStatus(status);
    expect(status.active_model).toBeNull();
    expect(status.active_effort).toBeNull();
  });

  it("withholds active identity when another PID owns the healthy listener", async () => {
    __setWhisperServerLaunchRecordForTests(launchRecord(51_003));
    __setWhisperServerTestHooksForTests({
      findModel: () => configuredModel,
      isServerHealthy: async () => true,
      findPortListenerPids: () => [61_003],
      isPidAlive: () => true,
    });

    const status = await readWhisperModelStatus();

    expectIndependentStatus(status);
    expect(status.active_model).toBeNull();
    expect(status.active_effort).toBeNull();
  });

  it("keeps a healthy resident unattributed when listener evidence is absent", async () => {
    __setWhisperServerLaunchRecordForTests(launchRecord(51_004));
    __setWhisperServerTestHooksForTests({
      findModel: () => configuredModel,
      isServerHealthy: async () => true,
      findPortListenerPids: () => [],
      isPidAlive: () => true,
    });

    const status = await readWhisperModelStatus();

    expectIndependentStatus(status);
    expect(status.active_model).toBeNull();
    expect(status.active_effort).toBeNull();
  });

  it("revalidates identity after asynchronous health sampling", async () => {
    let listenerPid = 51_005;
    __setWhisperServerLaunchRecordForTests(launchRecord(51_005));
    __setWhisperServerTestHooksForTests({
      findModel: () => configuredModel,
      isServerHealthy: async () => {
        await Promise.resolve();
        listenerPid = 61_005;
        return true;
      },
      findPortListenerPids: () => [listenerPid],
      isPidAlive: () => true,
    });

    const status = await readWhisperModelStatus();

    expectIndependentStatus(status);
    expect(status.active_model).toBeNull();
    expect(status.active_effort).toBeNull();
  });
});
