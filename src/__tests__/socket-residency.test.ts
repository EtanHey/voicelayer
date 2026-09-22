import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { handleSocketCommand } from "../socket-handlers";
import * as input from "../input";
import * as booking from "../session-booking";
import * as tts from "../tts";
import * as server from "../whisper-server";
import * as model from "../model-status";
import { whisperLifecycleGate } from "../whisper-lifecycle-gate";

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
    expect(response).toMatchObject({ type: "ack", outcome: "reject", reason: "busy" });
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
    const bookingResult = booking.bookVoiceSession("capture-wins-load-race");
    try {
      expect(bookingResult.success).toBe(true);
      releaseEnsure(8178);
      expect(await response).toMatchObject({ outcome: "reject", reason: "busy" });
    } finally {
      booking.releaseVoiceSession();
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
    const bookingResult = booking.bookVoiceSession("capture-during-load-status");
    try {
      expect(bookingResult.success).toBe(true);
      releaseStatus();
      expect(await response).toMatchObject({ outcome: "reject", reason: "busy" });
    } finally {
      booking.releaseVoiceSession();
    }
  });

  test("rejects a booked voice operation before unload", async () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const stop = spyOn(server, "unloadOwnedServer").mockResolvedValue({
      outcome: "accept", residency: "not_loaded",
    });
    spies.push(stop);
    spies.push(spyOn(model, "readWhisperModelStatus").mockResolvedValue(status));
    expect(await handleSocketCommand({ cmd: "set_whisper_residency", action: "unload", id: "r4" }))
      .toMatchObject({ outcome: "reject", reason: "busy", residency: "not_loaded" });
    expect(stop).not.toHaveBeenCalled();
  });
});
