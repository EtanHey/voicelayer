import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { handleSocketCommand } from "../socket-handlers";
import * as input from "../input";
import * as booking from "../session-booking";
import * as tts from "../tts";
import * as server from "../whisper-server";
import * as model from "../model-status";
import { whisperLifecycleGate } from "../whisper-lifecycle-gate";
import { reserveStandardVoiceOperation } from "../voice-operation-reservation";
import * as performance from "../whisper-performance";

describe("socket residency command", () => {
  const spies: Array<ReturnType<typeof spyOn>> = [];
  const status = {
    configured_model: { name: "large-v3-turbo", size_bytes: 10, installed: true },
    residency: "not_loaded" as const,
    active_model: null,
    configured_effort: "accurate" as const,
    active_effort: null,
  };

  afterEach(() => {
    for (const spy of spies.splice(0)) spy.mockRestore();
  });

  test("rejects unload during capture before touching the server", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("recording"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    const stop = spyOn(server, "unloadOwnedServer").mockResolvedValue({
      outcome: "accept", residency: "not_loaded",
    });
    spies.push(stop);
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    const response = await handleSocketCommand({ cmd: "set_whisper_residency", action: "unload", id: "r1" });
    expect(response).toMatchObject({ type: "ack", outcome: "reject", reason: "Recording in progress" });
    expect(stop).not.toHaveBeenCalled();
  });

  test("acknowledges the freshly observed residency after owned unload", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
    spies.push(spyOn(server, "unloadOwnedServer").mockResolvedValue({
      outcome: "accept", residency: "not_loaded",
    }));
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "unload", id: "r2" }))
      .toMatchObject({
        type: "ack", command: "set_whisper_residency", id: "r2",
        outcome: "accept", model_status: { residency: "not_loaded" },
      });
  });

  test("does not claim unloaded when another launch starts before status returns", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
    spies.push(spyOn(server, "unloadOwnedServer").mockResolvedValue({
      outcome: "accept", residency: "not_loaded",
    }));
    let statusEntered!: () => void;
    const entered = new Promise<void>((resolve) => { statusEntered = resolve; });
    let releaseStatus!: () => void;
    const pendingStatus = new Promise<void>((resolve) => { releaseStatus = resolve; });
    spies.push(spyOn(model, "readWhisperModelStatus").mockImplementation(async () => {
      statusEntered();
      await pendingStatus;
      return { ...status, residency: "unknown" };
    }));
    const response = handleSocketCommand({ cmd: "set_whisper_residency", action: "unload", id: "r2b" });
    await entered;
    let releaseLaunch!: () => void;
    const pendingLaunch = new Promise<void>((resolve) => { releaseLaunch = resolve; });
    const launch = whisperLifecycleGate.use(() => pendingLaunch);
    releaseStatus();
    const ack = await response;
    releaseLaunch();
    await launch;
    expect(ack).toMatchObject({ outcome: "reject", residency: "unknown",
      model_status: { residency: "unknown" } });
  });

  test("loads only when the fresh owned listener is reported loaded", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
    const ensure = spyOn(server, "ensureServer").mockResolvedValue(8178);
    spies.push(ensure);
    spies.push(spyOn(server, "verifiedWhisperServerLaunchRecord").mockReturnValue({
      pid: 123, startedAt: "2026-09-23T00:00:00Z", binary: "/tmp/whisper-server",
      modelPath: "/tmp/model.bin", args: [], performanceEffort: "accurate",
      accelerationMode: "metal",
    }));
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue({
      ...status, residency: "loaded", active_model: "large-v3-turbo",
    }));
    expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "r3" }))
      .toMatchObject({ outcome: "accept", residency: "loaded" });
    expect(ensure).toHaveBeenCalledTimes(1);
  });

  test("accepts load with the daemon's idle permanent session booking", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    expect(booking.bookVoiceSession().success).toBe(true);
    const ensure = spyOn(server, "ensureServer").mockResolvedValue(8178);
    spies.push(ensure);
    spies.push(spyOn(server, "verifiedWhisperServerLaunchRecord").mockReturnValue({
      pid: 123, startedAt: "2026-09-23T00:00:00Z", binary: "/tmp/whisper-server",
      modelPath: "/tmp/model.bin", args: [], performanceEffort: "accurate",
      accelerationMode: "metal",
    }));
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue({
      ...status, residency: "loaded", active_model: "large-v3-turbo",
    }));
    try {
      expect(booking.isVoiceBooked()).toMatchObject({ booked: true, ownedByUs: true,
        owner: { sessionId: `mcp-${process.pid}` } });
      expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "idle-owner" }))
        .toMatchObject({ outcome: "accept", residency: "loaded" });
      expect(ensure).toHaveBeenCalledTimes(1);
    } finally { booking.releaseVoiceSession(); }
  });

  test("lets an idle daemon booking reach unload", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const stop = spyOn(server, "unloadOwnedServer").mockResolvedValue({ outcome: "accept", residency: "not_loaded" });
    spies.push(stop);
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "unload", id: "idle-unload" }))
      .toMatchObject({ outcome: "accept", residency: "not_loaded" });
    expect(stop).toHaveBeenCalledTimes(1);
  });

  test("capture booking wins while a Settings load is pending", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    let releaseEnsure!: (port: number) => void;
    const pendingEnsure = new Promise<number>((resolve) => { releaseEnsure = resolve; });
    spies.push(spyOn(server, "ensureServer").mockReturnValue(pendingEnsure));
    spies.push(spyOn(server, "verifiedWhisperServerLaunchRecord").mockReturnValue({
      pid: 123, startedAt: "2026-09-23T00:00:00Z", binary: "/tmp/whisper-server",
      modelPath: "/tmp/model.bin", args: [], performanceEffort: "accurate",
      accelerationMode: "metal",
    }));
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue({
      ...status, residency: "loaded", active_model: "large-v3-turbo",
    }));
    const response = handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "r3b" });
    const operation = reserveStandardVoiceOperation();
    try {
      expect(operation).not.toBeNull();
      releaseEnsure(8178);
      expect(await response).toMatchObject({ outcome: "reject", reason: "Voice session in progress" });
    } finally {
      operation?.release();
    }
  });

  test("load rechecks capture after asynchronous status sampling", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(server, "ensureServer").mockResolvedValue(8178));
    spies.push(spyOn(server, "verifiedWhisperServerLaunchRecord").mockReturnValue({
      pid: 123, startedAt: "2026-09-23T00:00:00Z", binary: "/tmp/whisper-server",
      modelPath: "/tmp/model.bin", args: [], performanceEffort: "accurate",
      accelerationMode: "metal",
    }));
    let statusEntered!: () => void;
    const entered = new Promise<void>((resolve) => { statusEntered = resolve; });
    let releaseStatus!: () => void;
    const pendingStatus = new Promise<void>((resolve) => { releaseStatus = resolve; });
    spies.push(spyOn(model, "readWhisperModelStatus").mockImplementation(async () => {
      statusEntered();
      await pendingStatus;
      return { ...status, residency: "loaded", active_model: "large-v3-turbo" };
    }));
    const response = handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "r3c" });
    await entered;
    const operation = reserveStandardVoiceOperation();
    try {
      expect(operation).not.toBeNull();
      releaseStatus();
      expect(await response).toMatchObject({ outcome: "reject", reason: "Voice session in progress" });
    } finally {
      operation?.release();
    }
  });

  test("rejects an active voice operation before unload", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const stop = spyOn(server, "unloadOwnedServer").mockResolvedValue({
      outcome: "accept", residency: "not_loaded",
    });
    spies.push(stop);
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    const operation = reserveStandardVoiceOperation();
    try {
      expect(operation).not.toBeNull();
      expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "unload", id: "r4" }))
        .toMatchObject({ outcome: "reject", reason: "Voice session in progress", residency: "not_loaded" });
      expect(stop).not.toHaveBeenCalled();
    } finally { operation?.release(); }
  });

  test("external booking blocks load, unload, and effort before recording state appears", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: false }));
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    const ensure = spyOn(server, "ensureServer").mockResolvedValue(8178);
    const stop = spyOn(server, "unloadOwnedServer").mockResolvedValue({ outcome: "accept", residency: "not_loaded" });
    const save = spyOn(performance, "setWhisperPerformanceEffort").mockImplementation(() => {});
    spies.push(ensure, stop, save);
    for (const action of ["load", "unload"] as const) {
      expect(await handleSocketCommand({ cmd: "set_whisper_residency", action, id: `other-${action}` }))
        .toMatchObject({ outcome: "reject", reason: "Another app is using the voice session" });
    }
    expect(handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "other-effort" }))
      .toMatchObject({ outcome: "reject", reason: "Another app is using the voice session" });
    expect(ensure).not.toHaveBeenCalled();
    expect(stop).not.toHaveBeenCalled();
    expect(save).not.toHaveBeenCalled();
  });

  test("effort changes admit an idle daemon booking but reject active voice work", async () => {
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const save = spyOn(performance, "setWhisperPerformanceEffort").mockImplementation(() => {});
    const restart = spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(() => {});
    spies.push(save, restart);
    expect(await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "idle-effort" }))
      .toMatchObject({ outcome: "accept" });
    const operation = reserveStandardVoiceOperation();
    try {
      expect(operation).not.toBeNull();
      expect(await handleSocketCommand({ cmd: "set_whisper_effort", effort: "accurate", id: "active-effort" }))
        .toMatchObject({ outcome: "reject", reason: "busy" });
      expect(save).toHaveBeenCalledTimes(1);
      expect(restart).toHaveBeenCalledTimes(1);
    } finally { operation?.release(); }
  });

  test("an accepted effort change supplies different decode args at the next server launch", async () => {
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const restart = spyOn(performance, "restartWhisperServerForPerformanceChange")
      .mockImplementation(() => {});
    spies.push(restart);
    const previous = performance.getWhisperPerformanceEffort();
    try {
      expect(await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "next-decode-fast" }))
        .toMatchObject({ outcome: "accept" });
      const fast = server.buildWhisperServerLaunchPlan({
        binary: "/fixture/whisper-server", model: "/fixture/model.bin", port: 8178,
        inheritedEnv: process.env,
      });
      expect(fast.args.slice(fast.args.indexOf("-bo"), fast.args.indexOf("-bo") + 4))
        .toEqual(["-bo", "1", "-bs", "1"]);

      expect(await handleSocketCommand({ cmd: "set_whisper_effort", effort: "accurate", id: "next-decode-accurate" }))
        .toMatchObject({ outcome: "accept" });
      const accurate = server.buildWhisperServerLaunchPlan({
        binary: "/fixture/whisper-server", model: "/fixture/model.bin", port: 8178,
        inheritedEnv: process.env,
      });
      expect(accurate.args.slice(accurate.args.indexOf("-bo"), accurate.args.indexOf("-bo") + 4))
        .toEqual(["-bo", "5", "-bs", "5"]);
      expect(restart).toHaveBeenCalledTimes(2);
    } finally {
      performance.setWhisperPerformanceEffort(previous);
    }
  });

  test("effort changes wait for model inference even without a voice booking", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    const save = spyOn(performance, "setWhisperPerformanceEffort").mockImplementation(() => {});
    spies.push(save);
    let finish!: () => void;
    const pending = new Promise<void>((resolve) => { finish = resolve; });
    const inference = whisperLifecycleGate.use(() => pending);
    try {
      expect(handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "inference-effort" }))
        .toMatchObject({ outcome: "reject", reason: "busy" });
      expect(save).not.toHaveBeenCalled();
    } finally { finish(); await inference; }
  });

  describe("effort change reloads a loaded model (E2)", () => {
    function idle(): void {
      spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
      spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
      spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
      spies.push(spyOn(performance, "setWhisperPerformanceEffort").mockImplementation(() => {}));
    }
    const loaded = (effort: "fast" | "accurate") => ({
      ...status, residency: "loaded" as const, active_model: "large-v3-turbo", active_effort: effort,
    });

    test("relaunches the model after stopping it, so In memory returns to Loaded", async () => {
      idle();
      const calls: string[] = [];
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange")
        .mockImplementation(() => { calls.push("stop"); }));
      spies.push(spyOn(server, "ensureServer").mockImplementation(async () => {
        calls.push("launch");
        return 8178;
      }));
      const statuses = [loaded("accurate"), { ...loaded("fast"), configured_effort: "fast" as const }];
      spies.push(spyOn(model, "readWhisperModelStatus").mockImplementation(async () => statuses.shift()!));

      const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-reload" });

      expect(calls).toEqual(["stop", "launch"]);
      expect(ack).toMatchObject({
        type: "ack", command: "set_whisper_effort", id: "e2-reload", outcome: "accept",
        model_status: { residency: "loaded", active_effort: "fast" },
      });
      expect((ack as { reason?: string }).reason).toBeUndefined();
    });

    test("relaunches only after the stopped server has exited", async () => {
      idle();
      const calls: string[] = [];
      let exited!: () => void;
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(
        () => new Promise<void>((resolve) => { exited = () => { calls.push("exited"); resolve(); }; }),
      ));
      spies.push(spyOn(server, "ensureServer").mockImplementation(async () => {
        calls.push("launch");
        return 8178;
      }));
      spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(loaded("fast")));

      const ack = handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-order" });
      for (let i = 0; i < 20 && !exited; i++) await Bun.sleep(5);
      await Bun.sleep(20);
      expect(calls).toEqual([]);
      exited();
      await ack;
      expect(calls).toEqual(["exited", "launch"]);
    });

    test("does not load a model the user had unloaded", async () => {
      idle();
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(() => {}));
      const ensure = spyOn(server, "ensureServer").mockResolvedValue(8178);
      spies.push(ensure);
      spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));

      const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-unloaded" });

      expect(ensure).not.toHaveBeenCalled();
      expect(ack).toMatchObject({ outcome: "accept", model_status: { residency: "not_loaded" } });
    });

    test("says so when a server it did not launch keeps the old effort", async () => {
      idle();
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(() => {}));
      spies.push(spyOn(server, "ensureServer").mockResolvedValue(8178));
      spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(loaded("accurate")));

      const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-adopted" });

      expect(ack).toMatchObject({ outcome: "accept", model_status: { active_effort: "accurate" } });
      expect((ack as { reason?: string }).reason).toContain("restarts");
    });

    test("says so when the reload fails, keeping the saved effort", async () => {
      idle();
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(() => {}));
      spies.push(spyOn(server, "ensureServer").mockRejectedValue(new Error("whisper-server failed to start")));
      const statuses = [loaded("accurate"), status];
      spies.push(spyOn(model, "readWhisperModelStatus").mockImplementation(async () => statuses.shift()!));

      const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-failed" });

      expect(ack).toMatchObject({ outcome: "accept", model_status: { residency: "not_loaded" } });
      expect((ack as { reason?: string }).reason).toContain("whisper-server failed to start");
    });

    test("rejects visibly and keeps the old effort when the old server will not stop", async () => {
      idle();
      const saved: string[] = [];
      spies.push(spyOn(performance, "getWhisperPerformanceEffort").mockReturnValue("accurate"));
      spies.push(spyOn(performance, "setWhisperPerformanceEffort")
        .mockImplementation((effort) => { saved.push(effort); }));
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange")
        .mockRejectedValue(new Error("the old model server did not stop")));
      const ensure = spyOn(server, "ensureServer").mockResolvedValue(8178);
      spies.push(ensure);
      spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(loaded("accurate")));

      const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-stuck" });

      expect(ack).toMatchObject({ outcome: "reject" });
      expect((ack as { reason?: string }).reason).toContain("did not stop");
      expect(saved).toEqual(["fast", "accurate"]);
      expect(ensure).not.toHaveBeenCalled();
    });

    test("a failed reload restores the SAVED effort, never an env override (#142 r3 C)", async () => {
      const path = `${process.env.VOICELAYER_STATE_DIR ?? "/tmp"}/e2-r3-effort.json`;
      const savedPath = process.env.QA_VOICE_WHISPER_PERFORMANCE_PATH;
      const savedOverride = process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
      spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
      spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
      spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
      process.env.QA_VOICE_WHISPER_PERFORMANCE_PATH = path;
      try {
        delete process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
        performance.setWhisperPerformanceEffort("accurate");
        process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = "balanced";
        spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange")
          .mockRejectedValue(new Error("the old model server did not stop")));
        spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(loaded("accurate")));

        const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-r3c" });

        expect(ack).toMatchObject({ outcome: "reject" });
        delete process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
        expect(performance.getWhisperPerformanceEffort()).toBe("accurate");
      } finally {
        if (savedPath === undefined) delete process.env.QA_VOICE_WHISPER_PERFORMANCE_PATH;
        else process.env.QA_VOICE_WHISPER_PERFORMANCE_PATH = savedPath;
        if (savedOverride === undefined) delete process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT;
        else process.env.QA_VOICE_WHISPER_PERFORMANCE_EFFORT = savedOverride;
      }
    });

    test("a rollback that fails still sends a reject naming both failures (#142 r3 D)", async () => {
      spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
      spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
      spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: false, ownedByUs: false }));
      spies.push(spyOn(performance, "setWhisperPerformanceEffort").mockImplementation(() => {}));
      spies.push(spyOn(performance, "restorePersistedWhisperPerformanceEffort").mockImplementation(() => {
        throw new Error("config write failed");
      }));
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange")
        .mockRejectedValue(new Error("the old model server did not stop")));
      spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(loaded("accurate")));

      const ack = await handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-r3d" });

      expect(ack).toMatchObject({ outcome: "reject" });
      const reason = (ack as { reason?: string }).reason ?? "";
      expect(reason).toContain("did not stop");
      expect(reason).toContain("config write failed");
    });

    test("a Load or another effort change waits while the reload runs", async () => {
      idle();
      spies.push(spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(() => {}));
      let finish!: (port: number) => void;
      spies.push(spyOn(server, "ensureServer").mockImplementation(
        () => new Promise<number>((resolve) => { finish = resolve; }),
      ));
      spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(loaded("accurate")));

      const first = handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "e2-first" });
      for (let i = 0; i < 20 && !finish; i++) await Bun.sleep(5);
      expect(await handleSocketCommand({ cmd: "set_whisper_effort", effort: "balanced", id: "e2-second" }))
        .toMatchObject({ outcome: "reject", reason: "Model load in progress" });
      expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "load", id: "e2-load" }))
        .toMatchObject({ outcome: "reject", reason: "Model load in progress" });
      finish(8178);
      expect(await first).toMatchObject({ outcome: "accept" });
    });
  });

  test("F5 capture preempts unload maintenance and keeps the daemon booking", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    const capture = spyOn(input, "waitForInput").mockResolvedValue(null);
    spies.push(capture);
    expect(booking.bookVoiceSession().success).toBe(true);
    const release = booking.reserveVoiceMaintenance(() => false);
    try {
      expect(release).toBeFunction();
      expect(handleSocketCommand({ cmd: "record", id: "during-unload" }))
        .toMatchObject({ outcome: "accept" });
      expect(capture).toHaveBeenCalledTimes(1);
      expect(booking.isVoiceBooked()).toMatchObject({ booked: true, ownedByUs: true });
    } finally {
      release?.();
      booking.releaseVoiceSession();
    }
  });
});
