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

  test("effort changes admit an idle daemon booking but reject active voice work", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const save = spyOn(performance, "setWhisperPerformanceEffort").mockImplementation(() => {});
    const restart = spyOn(performance, "restartWhisperServerForPerformanceChange").mockImplementation(() => {});
    spies.push(save, restart);
    expect(handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "idle-effort" }))
      .toMatchObject({ outcome: "accept" });
    const operation = reserveStandardVoiceOperation();
    try {
      expect(operation).not.toBeNull();
      expect(handleSocketCommand({ cmd: "set_whisper_effort", effort: "accurate", id: "active-effort" }))
        .toMatchObject({ outcome: "reject", reason: "busy" });
      expect(save).toHaveBeenCalledTimes(1);
      expect(restart).toHaveBeenCalledTimes(1);
    } finally { operation?.release(); }
  });

  test("an accepted effort change supplies different decode args at the next server launch", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const restart = spyOn(performance, "restartWhisperServerForPerformanceChange")
      .mockImplementation(() => {});
    spies.push(restart);
    const previous = performance.getWhisperPerformanceEffort();
    try {
      expect(handleSocketCommand({ cmd: "set_whisper_effort", effort: "fast", id: "next-decode-fast" }))
        .toMatchObject({ outcome: "accept" });
      const fast = server.buildWhisperServerLaunchPlan({
        binary: "/fixture/whisper-server", model: "/fixture/model.bin", port: 8178,
        inheritedEnv: process.env,
      });
      expect(fast.args.slice(fast.args.indexOf("-bo"), fast.args.indexOf("-bo") + 4))
        .toEqual(["-bo", "1", "-bs", "1"]);

      expect(handleSocketCommand({ cmd: "set_whisper_effort", effort: "accurate", id: "next-decode-accurate" }))
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
