import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { unlinkSync, writeFileSync } from "fs";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleSocketCommand } from "../socket-handlers";
import * as tts from "../tts";

const REPLAY_FILE = `/tmp/voicelayer-socket-replay-${process.pid}.mp3`;
const SPEAKER_REFUSED = "user is recording — speaker output refused";

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
    try {
      unlinkSync(REPLAY_FILE);
    } catch {}
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

  it("marks accepted replay to remount when playback starts", () => {
    const response = handleSocketCommand({ cmd: "replay", id: "replay-idle" });

    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "accept",
      id: "replay-idle",
    });
    expect(playAudioSpy).toHaveBeenCalledTimes(1);
    expect((playAudioSpy.mock.calls[0][1] as any).preStartIdle).toBe(true);
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
