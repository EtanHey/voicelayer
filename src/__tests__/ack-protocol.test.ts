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
    expect(response).toEqual({
      type: "ack",
      command: "record",
      outcome: "accept",
      id: "record-1",
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
