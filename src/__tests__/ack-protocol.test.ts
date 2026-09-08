import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  mock,
  spyOn,
} from "bun:test";
import { existsSync, unlinkSync, writeFileSync } from "fs";
import * as actualPaths from "../paths";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import * as androidBridge from "../android-bridge";
import {
  parseCommand,
  serializeEvent,
  type SocketCommand,
  type SocketEvent,
} from "../socket-protocol";
import * as tts from "../tts";

const TEST_TTS_DISABLED_FILE = `/tmp/voicelayer-ack-${process.pid}-tts-disabled`;
const TEST_MIC_DISABLED_FILE = `/tmp/voicelayer-ack-${process.pid}-mic-disabled`;
const TEST_VOICE_DISABLED_FILE = `/tmp/voicelayer-ack-${process.pid}-voice-disabled`;
const TEST_REPLAY_FILE = `/tmp/voicelayer-ack-${process.pid}-replay.mp3`;

mock.module("../paths", () => ({
  ...actualPaths,
  TTS_DISABLED_FILE: TEST_TTS_DISABLED_FILE,
  MIC_DISABLED_FILE: TEST_MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE: TEST_VOICE_DISABLED_FILE,
}));

import { handleSocketCommand } from "../socket-handlers";

function cleanup() {
  for (const file of [
    TEST_TTS_DISABLED_FILE,
    TEST_MIC_DISABLED_FILE,
    TEST_VOICE_DISABLED_FILE,
    TEST_REPLAY_FILE,
  ]) {
    try {
      if (existsSync(file)) unlinkSync(file);
    } catch {}
  }
}

describe("ack protocol", () => {
  let stopPlaybackSpy: ReturnType<typeof spyOn>;
  let playAudioSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let bookingSpy: ReturnType<typeof spyOn>;
  let queueDepthSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let historySpy: ReturnType<typeof spyOn>;
  let setCancelSignalSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let hasRetainedRecordingSpy: ReturnType<typeof spyOn>;
  let retranscribeLastCaptureSpy: ReturnType<typeof spyOn>;
  let retranscribeRecordingCaptureSpy: ReturnType<typeof spyOn>;
  let androidStartSpy: ReturnType<typeof spyOn>;
  let androidStopSpy: ReturnType<typeof spyOn>;
  let androidCancelSpy: ReturnType<typeof spyOn>;
  let androidPullSpy: ReturnType<typeof spyOn>;
  let transcribeExternalSpy: ReturnType<typeof spyOn>;
  const originalAndroidApplianceFlag = process.env.QA_VOICE_ANDROID_APPLIANCE;
  const originalAndroidApplianceUrl =
    process.env.QA_VOICE_ANDROID_APPLIANCE_URL;
  const originalAndroidApplianceTimeout =
    process.env.QA_VOICE_ANDROID_APPLIANCE_TIMEOUT_MS;

  beforeEach(() => {
    cleanup();
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockImplementation(() => true);
    playAudioSpy = spyOn(tts, "playAudioNonBlocking").mockImplementation(
      () => {},
    );
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("");
    bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: false,
      ownedByUs: true,
      owner: undefined,
    });
    queueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1);
    recordingStateSpy = spyOn(input, "getRecordingState").mockReturnValue(
      "recording",
    );
    historySpy = spyOn(tts, "getHistoryEntry").mockReturnValue({
      file: TEST_REPLAY_FILE,
      text: "latest replay",
      voice: "jenny",
      timestamp: Date.now(),
    });
    setCancelSignalSpy = spyOn(
      sessionBooking,
      "setCancelSignal",
    ).mockImplementation(() => {});
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
    );
    hasRetainedRecordingSpy = spyOn(
      input,
      "hasRetainedRecording",
    ).mockReturnValue(true);
    retranscribeLastCaptureSpy = spyOn(
      input,
      "retranscribeLastCapture",
    ).mockResolvedValue("retranscribed note");
    retranscribeRecordingCaptureSpy = spyOn(
      input,
      "retranscribeRecordingCapture",
    ).mockResolvedValue("history retranscribed note");
    androidStartSpy = spyOn(
      androidBridge.AndroidApplianceBridge.prototype,
      "startRecording",
    ).mockResolvedValue({ ok: false, reason: "unhealthy" });
    androidStopSpy = spyOn(
      androidBridge.AndroidApplianceBridge.prototype,
      "stopRecording",
    ).mockResolvedValue({ ok: true, durationMs: 1200 });
    androidCancelSpy = spyOn(
      androidBridge.AndroidApplianceBridge.prototype,
      "cancelRecording",
    ).mockResolvedValue({ ok: true });
    androidPullSpy = spyOn(
      androidBridge.AndroidApplianceBridge.prototype,
      "pullAudio",
    ).mockResolvedValue(new Uint8Array([82, 73, 70, 70]));
    transcribeExternalSpy = spyOn(
      input,
      "transcribeExternalVoiceBarWav",
    ).mockResolvedValue("android transcript");
    delete process.env.QA_VOICE_ANDROID_APPLIANCE;
    delete process.env.QA_VOICE_ANDROID_APPLIANCE_URL;
    delete process.env.QA_VOICE_ANDROID_APPLIANCE_TIMEOUT_MS;
    writeFileSync(TEST_REPLAY_FILE, "mp3");
  });

  afterEach(() => {
    stopPlaybackSpy.mockRestore();
    playAudioSpy.mockRestore();
    waitForInputSpy.mockRestore();
    bookingSpy.mockRestore();
    queueDepthSpy.mockRestore();
    recordingStateSpy.mockRestore();
    historySpy.mockRestore();
    setCancelSignalSpy.mockRestore();
    broadcastSpy.mockRestore();
    hasRetainedRecordingSpy.mockRestore();
    retranscribeLastCaptureSpy.mockRestore();
    retranscribeRecordingCaptureSpy.mockRestore();
    androidStartSpy.mockRestore();
    androidStopSpy.mockRestore();
    androidCancelSpy.mockRestore();
    androidPullSpy.mockRestore();
    transcribeExternalSpy.mockRestore();
    if (originalAndroidApplianceFlag === undefined) {
      delete process.env.QA_VOICE_ANDROID_APPLIANCE;
    } else {
      process.env.QA_VOICE_ANDROID_APPLIANCE = originalAndroidApplianceFlag;
    }
    if (originalAndroidApplianceUrl === undefined) {
      delete process.env.QA_VOICE_ANDROID_APPLIANCE_URL;
    } else {
      process.env.QA_VOICE_ANDROID_APPLIANCE_URL = originalAndroidApplianceUrl;
    }
    if (originalAndroidApplianceTimeout === undefined) {
      delete process.env.QA_VOICE_ANDROID_APPLIANCE_TIMEOUT_MS;
    } else {
      process.env.QA_VOICE_ANDROID_APPLIANCE_TIMEOUT_MS =
        originalAndroidApplianceTimeout;
    }
    cleanup();
  });

  it("serializes ack events to NDJSON", () => {
    const event = {
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-1",
    } as unknown as SocketEvent;

    expect(serializeEvent(event)).toBe(
      '{"type":"ack","command":"record","outcome":"accept","id":"record-1"}\n',
    );
  });

  it("preserves command ids when parsing socket commands", () => {
    expect(parseCommand('{"cmd":"stop","id":"stop-1"}')).toEqual({
      cmd: "stop",
      id: "stop-1",
    });

    expect(
      parseCommand(
        '{"cmd":"record","id":"record-1","timeout_seconds":45,"press_to_talk":true}',
      ),
    ).toEqual({
      cmd: "record",
      id: "record-1",
      timeout_seconds: 45,
      press_to_talk: true,
    });
  });

  it("returns accept ack for record under happy path", () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");

    const response = handleSocketCommand({
      cmd: "record",
      id: "record-1",
      timeout_seconds: 30,
      silence_mode: "standard",
    } as unknown as SocketCommand);

    expect(waitForInputSpy).toHaveBeenCalled();
    expect(waitForInputSpy).toHaveBeenCalledWith(30000, "standard", false, {
      archiveSource: "voicebar",
    });
    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-1",
    });
  });

  it("falls back to local recording when the Android appliance is unavailable", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    process.env.QA_VOICE_ANDROID_APPLIANCE = "1";
    androidStartSpy.mockResolvedValueOnce({ ok: false, reason: "busy" });

    const response = handleSocketCommand({
      cmd: "record",
      id: "record-android-fallback",
      timeout_seconds: 30,
      silence_mode: "standard",
    } as unknown as SocketCommand);

    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(androidStartSpy).toHaveBeenCalledWith({
      timeoutMs: 30000,
      pressToTalk: false,
    });
    expect(waitForInputSpy).toHaveBeenCalledWith(30000, "standard", false, {
      archiveSource: "voicebar",
    });
    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-android-fallback",
    });
  });

  it("uses Android recording when the feature flag is enabled and start succeeds", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    process.env.QA_VOICE_ANDROID_APPLIANCE = "1";
    androidStartSpy.mockResolvedValueOnce({
      ok: true,
      sessionId: "android-session",
      source: "android",
    });

    const response = handleSocketCommand({
      cmd: "record",
      id: "record-android",
      timeout_seconds: 30,
      press_to_talk: true,
    } as unknown as SocketCommand);

    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(waitForInputSpy).not.toHaveBeenCalled();
    expect(broadcastSpy).toHaveBeenCalledWith({
      type: "state",
      state: "recording",
      mode: "ptt",
      source: "android",
    });
    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-android",
    });
  });

  it("stops an active Android recording and hands audio to Mac transcription", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    process.env.QA_VOICE_ANDROID_APPLIANCE = "1";
    androidStartSpy.mockResolvedValueOnce({
      ok: true,
      sessionId: "android-session",
      source: "android",
    });

    handleSocketCommand({
      cmd: "record",
      id: "record-android-stop",
      timeout_seconds: 30,
      silence_mode: "standard",
      press_to_talk: true,
    } as unknown as SocketCommand);
    await new Promise((resolve) => setTimeout(resolve, 0));

    recordingStateSpy.mockReturnValue("recording");
    const response = handleSocketCommand({
      cmd: "stop",
      id: "stop-android",
    } as unknown as SocketCommand);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(androidStopSpy).toHaveBeenCalledWith("android-session");
    expect(androidPullSpy).toHaveBeenCalledWith("android-session");
    expect(transcribeExternalSpy).toHaveBeenCalledWith(
      new Uint8Array([82, 73, 70, 70]),
      {
        silenceMode: "standard",
        pressToTalk: true,
      },
    );
    expect(response).toEqual({
      type: "ack",
      command: "stop",
      outcome: "accept",
      id: "stop-android",
    });
  });

  it("cancels an active Android recording without transcribing", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    process.env.QA_VOICE_ANDROID_APPLIANCE = "1";
    androidStartSpy.mockResolvedValueOnce({
      ok: true,
      sessionId: "android-session-cancel",
      source: "android",
    });

    handleSocketCommand({
      cmd: "record",
      id: "record-android-cancel",
      timeout_seconds: 30,
    } as unknown as SocketCommand);
    await new Promise((resolve) => setTimeout(resolve, 0));

    recordingStateSpy.mockReturnValue("recording");
    const response = handleSocketCommand({
      cmd: "cancel",
      id: "cancel-android",
    } as unknown as SocketCommand);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(androidCancelSpy).toHaveBeenCalledWith("android-session-cancel");
    expect(androidPullSpy).not.toHaveBeenCalled();
    expect(transcribeExternalSpy).not.toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "cancel",
      outcome: "accept",
      id: "cancel-android",
    });
  });

  it("returns accept ack for stop when recording is active", () => {
    const response = handleSocketCommand({
      cmd: "stop",
      id: "stop-1",
    } as unknown as SocketCommand);

    expect(stopPlaybackSpy).toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "stop",
      outcome: "accept",
      id: "stop-1",
    });
  });

  it("returns noop ack for stop while idle", () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");

    const response = handleSocketCommand({
      cmd: "stop",
      id: "stop-idle",
    } as unknown as SocketCommand);

    expect(stopPlaybackSpy).not.toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "stop",
      outcome: "noop",
      id: "stop-idle",
      reason: "already idle",
    });
  });

  it("returns accept ack for cancel under happy path", () => {
    const response = handleSocketCommand({
      cmd: "cancel",
      id: "cancel-1",
    } as unknown as SocketCommand);

    expect(setCancelSignalSpy).toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "cancel",
      outcome: "accept",
      id: "cancel-1",
    });
  });

  it("returns accept ack for replay under happy path", () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");

    const response = handleSocketCommand({
      cmd: "replay",
      id: "replay-1",
    } as unknown as SocketCommand);

    expect(playAudioSpy).toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "replay",
      outcome: "accept",
      id: "replay-1",
    });
  });

  it("returns accept ack for retranscribe-last under happy path", () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");

    const response = handleSocketCommand({
      cmd: "retranscribe_last",
      id: "retranscribe-1",
    } as unknown as SocketCommand);

    expect(retranscribeLastCaptureSpy).toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "retranscribe_last",
      outcome: "accept",
      id: "retranscribe-1",
    });
  });

  it("returns noop ack for retranscribe-last when no retained capture exists", () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    hasRetainedRecordingSpy.mockReturnValue(false);

    const response = handleSocketCommand({
      cmd: "retranscribe_last",
      id: "retranscribe-empty",
    } as unknown as SocketCommand);

    expect(retranscribeLastCaptureSpy).not.toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "retranscribe_last",
      outcome: "noop",
      id: "retranscribe-empty",
      reason: "nothing to retranscribe",
    });
  });

  it("returns accept ack for history-entry retranscribe and passes the archived audio path", () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    const audioPath =
      "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav";

    const response = handleSocketCommand({
      cmd: "retranscribe_recording",
      id: "history-retry-1",
      audio_path: audioPath,
    } as unknown as SocketCommand);

    expect(retranscribeRecordingCaptureSpy).toHaveBeenCalledWith(audioPath);
    expect(retranscribeLastCaptureSpy).not.toHaveBeenCalled();
    expect(response).toEqual({
      type: "ack",
      command: "retranscribe_recording",
      outcome: "accept",
      id: "history-retry-1",
    });
  });

  it("keeps archived retranscribe recovery idle scoped to recording source", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    retranscribeRecordingCaptureSpy.mockRejectedValueOnce(new Error("boom"));
    const audioPath =
      "/Users/etan/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav";

    const response = handleSocketCommand({
      cmd: "retranscribe_recording",
      id: "history-retry-fail",
      audio_path: audioPath,
    } as unknown as SocketCommand);
    await Promise.resolve();

    expect(response).toEqual({
      type: "ack",
      command: "retranscribe_recording",
      outcome: "accept",
      id: "history-retry-fail",
    });
    expect(broadcastSpy).toHaveBeenCalledWith({
      type: "state",
      state: "idle",
      source: "recording",
    });
    expect(broadcastSpy).not.toHaveBeenCalledWith({
      type: "state",
      state: "idle",
    });
  });

  it("returns accept ack for toggle under happy path", () => {
    const response = handleSocketCommand({
      cmd: "toggle",
      id: "toggle-1",
      scope: "all",
      enabled: false,
    } as unknown as SocketCommand);

    expect(existsSync(TEST_VOICE_DISABLED_FILE)).toBe(true);
    expect(response).toEqual({
      type: "ack",
      command: "toggle",
      outcome: "accept",
      id: "toggle-1",
    });
  });
});
