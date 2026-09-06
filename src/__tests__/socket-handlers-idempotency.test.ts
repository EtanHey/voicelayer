import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { TEST_TMP } from "./setup/test-tmp";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { unlinkSync, writeFileSync } from "fs";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleSocketCommand } from "../socket-handlers";
import * as recordingHold from "../recording-hold";
import * as tts from "../tts";
import * as whisperPerformance from "../whisper-performance";

const REPLAY_FILE = `${TEST_TMP}/voicelayer-socket-replay-${process.pid}.mp3`;
const SPEAKER_REFUSED = "user is recording — speaker output refused";

describe("socket handler idempotency matrix", () => {
  let stopPlaybackSpy: ReturnType<typeof spyOn>;
  let restartPlaybackSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let setCancelSignalSpy: ReturnType<typeof spyOn>;
  let playAudioSpy: ReturnType<typeof spyOn>;
  let queueDepthSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let historySpy: ReturnType<typeof spyOn>;
  let hasRetainedRecordingSpy: ReturnType<typeof spyOn>;
  let retranscribeLastCaptureSpy: ReturnType<typeof spyOn>;
  let setWhisperEffortSpy: ReturnType<typeof spyOn>;
  let restartWhisperServerSpy: ReturnType<typeof spyOn>;
  let setRecordingHoldSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockImplementation(() => true);
    restartPlaybackSpy = spyOn(tts, "restartPlayback").mockImplementation(
      () => true,
    );
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("");
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
    );
    setCancelSignalSpy = spyOn(
      sessionBooking,
      "setCancelSignal",
    ).mockImplementation(() => {});
    playAudioSpy = spyOn(tts, "playAudioNonBlocking").mockImplementation(
      () => ({ exited: Promise.resolve() }),
    );
    queueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0);
    recordingStateSpy = spyOn(input, "getRecordingState").mockReturnValue(
      "idle",
    );
    writeFileSync(REPLAY_FILE, "fake replay");
    historySpy = spyOn(tts, "getHistoryEntry").mockReturnValue({
      file: REPLAY_FILE,
      text: "latest replay",
      voice: "jenny",
      timestamp: Date.now(),
    });
    hasRetainedRecordingSpy = spyOn(
      input,
      "hasRetainedRecording",
    ).mockReturnValue(true);
    retranscribeLastCaptureSpy = spyOn(
      input,
      "retranscribeLastCapture",
    ).mockResolvedValue("retranscribed note");
    setWhisperEffortSpy = spyOn(
      whisperPerformance,
      "setWhisperPerformanceEffort",
    ).mockImplementation(() => {});
    restartWhisperServerSpy = spyOn(
      whisperPerformance,
      "restartWhisperServerForPerformanceChange",
    ).mockImplementation(() => {});
    setRecordingHoldSpy = spyOn(
      recordingHold,
      "setRecordingHold",
    ).mockImplementation(() => {});
  });

  afterEach(() => {
    stopPlaybackSpy.mockRestore();
    restartPlaybackSpy.mockRestore();
    waitForInputSpy.mockRestore();
    broadcastSpy.mockRestore();
    setCancelSignalSpy.mockRestore();
    playAudioSpy.mockRestore();
    queueDepthSpy.mockRestore();
    recordingStateSpy.mockRestore();
    historySpy.mockRestore();
    try {
      unlinkSync(REPLAY_FILE);
    } catch {}
    hasRetainedRecordingSpy.mockRestore();
    retranscribeLastCaptureSpy.mockRestore();
    setWhisperEffortSpy.mockRestore();
    restartWhisperServerSpy.mockRestore();
    setRecordingHoldSpy.mockRestore();
  });

  it("returns noop for stop while idle without broadcasting or stopping playback", () => {
    const response = handleSocketCommand({ cmd: "stop", id: "stop-idle" });

    expect(response).toEqual({
      type: "ack",
      command: "stop",
      outcome: "noop",
      id: "stop-idle",
      reason: "already idle",
    });
    expect(stopPlaybackSpy).not.toHaveBeenCalled();
    expect(broadcastSpy).not.toHaveBeenCalled();
  });

  it("returns noop for cancel while idle without mutating state", () => {
    const response = handleSocketCommand({ cmd: "cancel", id: "cancel-idle" });

    expect(response).toEqual({
      type: "ack",
      command: "cancel",
      outcome: "noop",
      id: "cancel-idle",
      reason: "already idle",
    });
    expect(setCancelSignalSpy).not.toHaveBeenCalled();
    expect(stopPlaybackSpy).not.toHaveBeenCalled();
    expect(broadcastSpy).not.toHaveBeenCalled();
  });

  it("returns noop when record is requested while already recording", () => {
    recordingStateSpy.mockReturnValue("recording");

    const response = handleSocketCommand({ cmd: "record", id: "record-busy" });

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "noop",
      id: "record-busy",
      reason: "already recording",
    });
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("accepts recording hold engage and release only while recording", () => {
    recordingStateSpy.mockReturnValue("recording");

    expect(
      handleSocketCommand({
        cmd: "set_recording_hold",
        engaged: true,
        id: "hold-engage",
      }),
    ).toEqual({
      type: "ack",
      command: "set_recording_hold",
      outcome: "accept",
      id: "hold-engage",
    });
    expect(
      handleSocketCommand({
        cmd: "set_recording_hold",
        engaged: false,
        id: "hold-release",
      }),
    ).toEqual({
      type: "ack",
      command: "set_recording_hold",
      outcome: "accept",
      id: "hold-release",
    });
    expect(setRecordingHoldSpy.mock.calls).toEqual([[true], [false]]);
  });

  it("returns noop for recording hold outside recording without writing", () => {
    for (const state of ["idle", "transcribing"] as const) {
      recordingStateSpy.mockReturnValue(state);
      expect(
        handleSocketCommand({
          cmd: "set_recording_hold",
          engaged: true,
          id: `hold-${state}`,
        }),
      ).toEqual({
        type: "ack",
        command: "set_recording_hold",
        outcome: "noop",
        id: `hold-${state}`,
        reason: "not recording",
      });
    }
    expect(setRecordingHoldSpy).not.toHaveBeenCalled();
  });

  it("stops playback before recording when record arrives while speaking", () => {
    const calls: string[] = [];
    stopPlaybackSpy.mockImplementation(() => {
      calls.push("stopPlayback");
      return true;
    });
    waitForInputSpy.mockImplementation(async () => {
      calls.push("waitForInput");
      return "";
    });
    queueDepthSpy.mockReturnValue(1);

    const response = handleSocketCommand({
      cmd: "record",
      id: "record-speaking",
    });

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-speaking",
    });
    expect(calls).toEqual(["stopPlayback", "waitForInput"]);
  });

  it("persists whisper effort changes and restarts the whisper sidecar", () => {
    const response = handleSocketCommand({
      cmd: "set_whisper_effort",
      id: "effort-fast",
      effort: "fast",
    });

    expect(response).toEqual({
      type: "ack",
      command: "set_whisper_effort",
      outcome: "accept",
      id: "effort-fast",
    });
    expect(setWhisperEffortSpy).toHaveBeenCalledWith("fast");
    expect(restartWhisperServerSpy).toHaveBeenCalled();
  });

  it("rejects whisper effort changes while recording without restarting the sidecar", () => {
    recordingStateSpy.mockReturnValue("recording");

    const response = handleSocketCommand({
      cmd: "set_whisper_effort",
      id: "effort-busy",
      effort: "accurate",
    });

    expect(response).toEqual({
      type: "ack",
      command: "set_whisper_effort",
      outcome: "reject",
      id: "effort-busy",
      reason: "busy",
    });
    expect(setWhisperEffortSpy).not.toHaveBeenCalled();
    expect(restartWhisperServerSpy).not.toHaveBeenCalled();
  });

  it("returns a reject ack when whisper effort persistence fails", () => {
    setWhisperEffortSpy.mockImplementation(() => {
      throw new Error("config write failed");
    });

    const response = handleSocketCommand({
      cmd: "set_whisper_effort",
      id: "effort-error",
      effort: "balanced",
    });

    expect(response).toEqual({
      type: "ack",
      command: "set_whisper_effort",
      outcome: "reject",
      id: "effort-error",
      reason: "config write failed",
    });
    expect(restartWhisperServerSpy).not.toHaveBeenCalled();
  });

  it("does not broadcast idle when an accepted record hits a recording conflict", async () => {
    waitForInputSpy.mockRejectedValue(
      new Error("Recording already in progress (state: recording)"),
    );

    const response = handleSocketCommand({
      cmd: "record",
      id: "record-late-busy",
    });
    await Bun.sleep(0);

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-late-busy",
    });
    expect(
      broadcastSpy.mock.calls.filter(
        ([event]: any[]) => event.type === "state" && event.state === "idle",
      ),
    ).toHaveLength(0);
  });

  it("rejects replay while recording without restarting playback", () => {
    recordingStateSpy.mockReturnValue("recording");

    const response = handleSocketCommand({ cmd: "replay", id: "replay-busy" });

    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "reject",
      id: "replay-busy",
      reason: "busy",
    });
    expect(playAudioSpy).not.toHaveBeenCalled();
    expect(broadcastSpy).not.toHaveBeenCalled();
  });

  it("restarts active replay atomically without stopping the blocking playback", () => {
    queueDepthSpy.mockReturnValue(1);
    const response = handleSocketCommand({ cmd: "replay", id: "replay-idle" });

    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "accept",
      id: "replay-idle",
    });
    expect(stopPlaybackSpy).not.toHaveBeenCalled();
    expect(restartPlaybackSpy).toHaveBeenCalledTimes(1);
    expect(playAudioSpy).not.toHaveBeenCalled();
    expect(broadcastSpy).not.toHaveBeenCalled();
  });

  it("rejects active replay when an unrelated preparation cannot be restarted", () => {
    queueDepthSpy.mockReturnValue(1);
    restartPlaybackSpy.mockReturnValue(false);

    const response = handleSocketCommand({
      cmd: "replay",
      id: "replay-unowned-preparation",
    });

    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "reject",
      id: "replay-unowned-preparation",
      reason: "busy",
    });
    expect(restartPlaybackSpy).toHaveBeenCalledTimes(1);
    expect(playAudioSpy).not.toHaveBeenCalled();
  });

  it("starts finished replay without a pre-start idle flicker", () => {
    const response = handleSocketCommand({ cmd: "replay", id: "replay-finished" });

    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "accept",
      id: "replay-finished",
    });
    expect(playAudioSpy).toHaveBeenCalledTimes(1);
    expect((playAudioSpy.mock.calls[0][1] as any).preStartIdle).toBeUndefined();
    expect(broadcastSpy).not.toHaveBeenCalled();
  });

  it("does not broadcast idle when replay is refused by the late speaker gate", () => {
    playAudioSpy.mockImplementation(() => {
      throw new Error(SPEAKER_REFUSED);
    });

    const response = handleSocketCommand({
      cmd: "replay",
      id: "replay-late-busy",
    });

    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "reject",
      id: "replay-late-busy",
      reason: SPEAKER_REFUSED,
    });
    expect(
      broadcastSpy.mock.calls.filter(
        ([event]: any[]) => event.type === "state" && event.state === "idle",
      ),
    ).toHaveLength(0);
  });

  it("rejects retranscribe-last while recording without starting a new transcription", () => {
    recordingStateSpy.mockReturnValue("recording");

    const response = handleSocketCommand({
      cmd: "retranscribe_last",
      id: "retranscribe-busy",
    });

    expect(response).toEqual({
      type: "ack",
      command: "retranscribe_last",
      outcome: "reject",
      id: "retranscribe-busy",
      reason: "busy",
    });
    expect(retranscribeLastCaptureSpy).not.toHaveBeenCalled();
  });
});

// V1 — single-recorder invariant: a bar-initiated `record` must claim the
// cross-process voice-session lock (bookVoiceSession), exactly like
// handleConverse does for voice_ask. Without it, an F5 dictation that starts
// before any MCP voice_ask leaves NO lock on disk, so a voice_ask in a second
// daemon process books + records concurrently → two `sox` on one mic →
// rms=0 silence → whisper hallucination → lost transcript (M1 escalation #7d).
//
// NOTE: these live in this file (not a standalone one) on purpose — adding a
// new test file that spies on the shared tts/socket-client/session-booking
// modules destabilizes the full suite (bun schedules files concurrently, so a
// new file's spies leak into the playback/converse suites). Folding into an
// existing heavily-spied file keeps the suite's file-set — and its
// concurrency profile — unchanged.
describe("socket-handlers record — cross-process booking (V1)", () => {
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let stopPlaybackSpy: ReturnType<typeof spyOn>;
  let queueDepthSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let isVoiceBookedSpy: ReturnType<typeof spyOn>;
  let bookVoiceSessionSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("");
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
    );
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockImplementation(() => true);
    queueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0);
    recordingStateSpy = spyOn(input, "getRecordingState").mockReturnValue(
      "idle",
    );
    isVoiceBookedSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: false,
      ownedByUs: false,
    });
    bookVoiceSessionSpy = spyOn(
      sessionBooking,
      "bookVoiceSession",
    ).mockReturnValue({ success: true });
  });

  afterEach(() => {
    waitForInputSpy.mockRestore();
    broadcastSpy.mockRestore();
    stopPlaybackSpy.mockRestore();
    queueDepthSpy.mockRestore();
    recordingStateSpy.mockRestore();
    isVoiceBookedSpy.mockRestore();
    bookVoiceSessionSpy.mockRestore();
  });

  it("claims the voice-session lock before recording when nothing is booked", () => {
    const response = handleSocketCommand({ cmd: "record", id: "rec-book" });

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "rec-book",
    });
    expect(bookVoiceSessionSpy).toHaveBeenCalledTimes(1);
    expect(waitForInputSpy).toHaveBeenCalledTimes(1);
  });

  it("rejects without recording when the lock cannot be claimed (lost race)", () => {
    // isVoiceBooked still reports free at check time, but the atomic book loses
    // the race to a competing process between check and write.
    bookVoiceSessionSpy.mockReturnValue({
      success: false,
      error: "Line is busy — voice booked by session other (race condition)",
    });

    const response = handleSocketCommand({ cmd: "record", id: "rec-race" });

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "reject",
      id: "rec-race",
      reason: "busy",
    });
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("does not re-book when this process already owns the session", () => {
    isVoiceBookedSpy.mockReturnValue({ booked: true, ownedByUs: true });

    const response = handleSocketCommand({ cmd: "record", id: "rec-owned" });

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "rec-owned",
    });
    expect(bookVoiceSessionSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).toHaveBeenCalledTimes(1);
  });

  it("rejects when another process owns the session (unchanged behavior)", () => {
    isVoiceBookedSpy.mockReturnValue({
      booked: true,
      ownedByUs: false,
      owner: { pid: 999, sessionId: "other", startedAt: "now" },
    });

    const response = handleSocketCommand({ cmd: "record", id: "rec-busy" });

    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "reject",
      id: "rec-busy",
      reason: "busy",
    });
    expect(bookVoiceSessionSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });
});
