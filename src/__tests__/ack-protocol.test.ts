import { fixtureCheckpoint } from "./long-read-fixture-barriers";
import { finishSyntheticCapture } from "./setup/recording-jobs-fixture";
import { finishBarCapture, recordingJobsSnapshot } from "../recording-jobs";
import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { TEST_TMP } from "./setup/test-tmp";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { existsSync, unlinkSync, writeFileSync } from "fs";
import * as actualPaths from "../paths";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import {
  parseCommand,
  serializeEvent,
  type SocketCommand,
  type SocketEvent,
} from "../socket-protocol";
import * as tts from "../tts";

const TEST_TTS_DISABLED_FILE = `${TEST_TMP}/voicelayer-ack-${process.pid}-tts-disabled`;
const TEST_MIC_DISABLED_FILE = `${TEST_TMP}/voicelayer-ack-${process.pid}-mic-disabled`;
const TEST_VOICE_DISABLED_FILE = `${TEST_TMP}/voicelayer-ack-${process.pid}-voice-disabled`;
const TEST_REPLAY_FILE = `${TEST_TMP}/voicelayer-ack-${process.pid}-replay.mp3`;

mock.module("../paths", () => ({
  ...actualPaths,
  TTS_DISABLED_FILE: TEST_TTS_DISABLED_FILE,
  MIC_DISABLED_FILE: TEST_MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE: TEST_VOICE_DISABLED_FILE,
}));

import { handleSocketCommand } from "../socket-handlers";

async function settleHistoryJobs(): Promise<void> {
  for (let i = 0; i < 100; i++) {
    if (recordingJobsSnapshot().recording_jobs.length === 0) return;
    await Bun.sleep(1);
  }
  throw new Error("History fixture did not settle before restoring its input spies");
}

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

  beforeEach(() => {
    cleanup();
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockImplementation(() => true);
    playAudioSpy = spyOn(tts, "playAudioNonBlocking").mockImplementation(
      () => {},
    );
    waitForInputSpy = spyOn(input, "waitForInput").mockImplementation(() =>
      finishBarCapture(Promise.resolve(), "synthetic-ack-archive", async () => ""));
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
    writeFileSync(TEST_REPLAY_FILE, "mp3");
  });

  afterEach(async () => {
    await fixtureCheckpoint();
    await settleHistoryJobs();
    await fixtureCheckpoint();
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

  it("parses speech/capture Stop scopes and the F5 press position without accepting invalid fields", () => {
    for (const scope of ["speech", "capture"]) {
      expect(parseCommand(JSON.stringify({ cmd: "stop", scope }))).toEqual({ cmd: "stop", scope });
    }
    expect(parseCommand('{"cmd":"stop","scope":"both"}')).toBeNull();
    expect(parseCommand('{"cmd":"record","playback_elapsed_ms":3500}')).toEqual({ cmd: "record", playback_elapsed_ms: 3500 });
    for (const position of [-1, "3500", null]) {
      expect(parseCommand(JSON.stringify({ cmd: "record", playback_elapsed_ms: position }))).toBeNull();
    }
  });

  it("honors trusted VoiceBar press_to_talk without the MCP gate or a deprecation warning", async () => {
    const savedAllowPushToEnd = process.env.VOICELAYER_ALLOW_PUSH_TO_END;
    delete process.env.VOICELAYER_ALLOW_PUSH_TO_END;
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      const command = parseCommand(
        '{"cmd":"record","id":"voicebar-record","timeout_seconds":30,"press_to_talk":true}',
      );
      expect(command).toEqual({
        cmd: "record",
        id: "voicebar-record",
        timeout_seconds: 30,
        press_to_talk: true,
      });

      queueDepthSpy.mockReturnValue(0);
      recordingStateSpy.mockReturnValue("idle");
      await handleSocketCommand(command!);
      await fixtureCheckpoint();

      expect(waitForInputSpy).toHaveBeenCalledWith(
        30_000,
        "standard",
        true,
        { archiveSource: "voicebar", onCaptureStart: expect.any(Function) },
      );
      expect(errorSpy).not.toHaveBeenCalled();
    } finally {
      errorSpy.mockRestore();
      if (savedAllowPushToEnd === undefined) {
        delete process.env.VOICELAYER_ALLOW_PUSH_TO_END;
      } else {
        process.env.VOICELAYER_ALLOW_PUSH_TO_END = savedAllowPushToEnd;
      }
    }
  });

  it("returns accept ack for record under happy path", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");

    const response = handleSocketCommand({
      cmd: "record",
      id: "record-1",
      timeout_seconds: 30,
      silence_mode: "standard",
    } as unknown as SocketCommand);

    await fixtureCheckpoint();
    expect(waitForInputSpy).toHaveBeenCalled();
    expect(waitForInputSpy).toHaveBeenCalledWith(30000, "standard", false, {
      archiveSource: "voicebar", onCaptureStart: expect.any(Function),
    });
    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-1",
    });
  });

  it("returns accept ack for stop when recording is active", async () => {
    const response = await handleSocketCommand({
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

  it("returns accept ack for cancel under happy path", async () => {
    const response = await handleSocketCommand({
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

  it("returns accept ack for retranscribe-last under happy path", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");

    const response = handleSocketCommand({
      cmd: "retranscribe_last",
      id: "retranscribe-1",
    } as unknown as SocketCommand);

    await settleHistoryJobs();
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

  it("returns accept ack for history-entry retranscribe and passes the archived audio path", async () => {
    queueDepthSpy.mockReturnValue(0);
    recordingStateSpy.mockReturnValue("idle");
    const audioPath =
      "/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav";

    const response = handleSocketCommand({
      cmd: "retranscribe_recording",
      id: "history-retry-1",
      audio_path: audioPath,
    } as unknown as SocketCommand);

    await settleHistoryJobs();
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
      "/Users/fixture-user/.local/share/voicelayer/recordings/2026-06-25/2026-06-25T10-11-12-000Z-abcd1234/audio.wav";

    const response = handleSocketCommand({
      cmd: "retranscribe_recording",
      id: "history-retry-fail",
      audio_path: audioPath,
    } as unknown as SocketCommand);
    await settleHistoryJobs();

    expect(response).toEqual({
      type: "ack",
      command: "retranscribe_recording",
      outcome: "accept",
      id: "history-retry-fail",
    });
    expect(broadcastSpy).toHaveBeenCalledWith({
      type: "state", state: "idle", source: "recording",
      recording_jobs: [], processing_count: 0, mic_take_id: null,
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
