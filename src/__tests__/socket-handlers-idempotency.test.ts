import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleSocketCommand } from "../socket-handlers";
import * as tts from "../tts";

describe("socket handler idempotency matrix", () => {
  let stopPlaybackSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let setCancelSignalSpy: ReturnType<typeof spyOn>;
  let playAudioSpy: ReturnType<typeof spyOn>;
  let queueDepthSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let historySpy: ReturnType<typeof spyOn>;
  let hasRetainedRecordingSpy: ReturnType<typeof spyOn>;
  let retranscribeLastCaptureSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockImplementation(() => true);
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
    historySpy = spyOn(tts, "getHistoryEntry").mockReturnValue({
      file: "/tmp/replay.mp3",
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
  });

  afterEach(() => {
    stopPlaybackSpy.mockRestore();
    waitForInputSpy.mockRestore();
    broadcastSpy.mockRestore();
    setCancelSignalSpy.mockRestore();
    playAudioSpy.mockRestore();
    queueDepthSpy.mockRestore();
    recordingStateSpy.mockRestore();
    historySpy.mockRestore();
    hasRetainedRecordingSpy.mockRestore();
    retranscribeLastCaptureSpy.mockRestore();
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
