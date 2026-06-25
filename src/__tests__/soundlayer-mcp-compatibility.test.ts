import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { handleVoiceAsk, handleVoiceSpeak } from "../handlers";
import * as input from "../input";
import * as recordingState from "../recording-state";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as launcher from "../voice-bar-launcher";

describe("SoundLayer MCP compatibility regression", () => {
  let ensureBarSpy: ReturnType<typeof spyOn>;
  let speakSpy: ReturnType<typeof spyOn>;
  let awaitPlaybackSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let isConnectedSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let bookingSpy: ReturnType<typeof spyOn>;
  let bookSpy: ReturnType<typeof spyOn>;
  let clearInputSpy: ReturnType<typeof spyOn>;
  let clearStopSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    ensureBarSpy = spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(
      () => {},
    );
    speakSpy = spyOn(tts, "speak").mockResolvedValue({});
    awaitPlaybackSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(
      undefined,
    );
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("answer");
    isConnectedSpy = spyOn(socketClient, "isConnected").mockReturnValue(true);
    recordingStateSpy = spyOn(
      recordingState,
      "getEffectiveRecordingState",
    ).mockReturnValue("idle");
    bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: true,
      ownedByUs: true,
      owner: {
        pid: process.pid,
        sessionId: "test-session",
        startedAt: new Date().toISOString(),
      },
    });
    bookSpy = spyOn(sessionBooking, "bookVoiceSession").mockReturnValue({
      success: true,
      sessionId: "test-session",
      lockPath: "/tmp/test-lock",
    });
    clearInputSpy = spyOn(input, "clearInput").mockImplementation(() => {});
    clearStopSpy = spyOn(sessionBooking, "clearStopSignal").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    ensureBarSpy.mockRestore();
    speakSpy.mockRestore();
    awaitPlaybackSpy.mockRestore();
    waitForInputSpy.mockRestore();
    isConnectedSpy.mockRestore();
    recordingStateSpy.mockRestore();
    bookingSpy.mockRestore();
    bookSpy.mockRestore();
    clearInputSpy.mockRestore();
    clearStopSpy.mockRestore();
  });

  it("keeps voice_speak non-blocking by not requesting playback wait", async () => {
    const result = await handleVoiceSpeak({
      message: "ship it",
      mode: "announce",
    });

    expect(result.isError).toBeUndefined();
    expect(ensureBarSpy).toHaveBeenCalled();
    expect(speakSpy).toHaveBeenCalledWith("ship it", {
      mode: "announce",
      rate: undefined,
      voice: undefined,
    });
    expect(awaitPlaybackSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("keeps voice_ask blocking through playback completion before recording", async () => {
    const calls: string[] = [];
    awaitPlaybackSpy.mockImplementation(async () => {
      calls.push("awaitCurrentPlayback");
    });
    speakSpy.mockImplementation(async () => {
      calls.push("speak");
      return {};
    });
    waitForInputSpy.mockImplementation(async () => {
      calls.push("waitForInput");
      return "answer";
    });

    const result = await handleVoiceAsk({
      message: "What changed?",
      timeout_seconds: 45,
      silence_mode: "quick",
      press_to_talk: true,
      voice: "theo",
    });

    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("answer");
    expect(calls).toEqual(["awaitCurrentPlayback", "speak", "waitForInput"]);
    expect(speakSpy).toHaveBeenCalledWith("What changed?", {
      mode: "converse",
      waitForPlayback: true,
      voice: undefined,
    });
    expect(waitForInputSpy).toHaveBeenCalledWith(45_000, "quick", true);
  });
});
