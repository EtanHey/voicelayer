import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  mock,
  spyOn,
} from "bun:test";
import { handleConverse } from "../handlers";
import * as input from "../input";
import * as recordingState from "../recording-state";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import * as tts from "../tts";

const originalFetch = globalThis.fetch;

describe("voice_ask input backend integration", () => {
  let awaitPlaybackSpy: ReturnType<typeof spyOn>;
  let speakSpy: ReturnType<typeof spyOn>;
  let clearInputSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let bookingSpy: ReturnType<typeof spyOn>;
  let bookSpy: ReturnType<typeof spyOn>;
  let clearStopSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let isConnectedSpy: ReturnType<typeof spyOn>;
  let broadcastSpy: ReturnType<typeof spyOn>;
  let fetchMock: ReturnType<typeof mock>;

  beforeEach(() => {
    process.env.VOICELAYER_INPUT_BACKEND = "spokenly";
    awaitPlaybackSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(
      undefined,
    );
    speakSpy = spyOn(tts, "speak").mockResolvedValue({ warning: undefined });
    clearInputSpy = spyOn(input, "clearInput").mockImplementation(() => {});
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue(
      "local transcript",
    );
    bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: false,
      ownedByUs: false,
    });
    bookSpy = spyOn(sessionBooking, "bookVoiceSession").mockReturnValue({
      success: true,
      sessionId: "test-session",
      lockPath: "/tmp/test-lock",
    });
    clearStopSpy = spyOn(sessionBooking, "clearStopSignal").mockImplementation(
      () => {},
    );
    recordingStateSpy = spyOn(
      recordingState,
      "getEffectiveRecordingState",
    ).mockReturnValue("idle");
    isConnectedSpy = spyOn(socketClient, "isConnected").mockReturnValue(true);
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
    );
    fetchMock = mock(async () => {
      return new Response(
        JSON.stringify({
          jsonrpc: "2.0",
          id: 1,
          result: {
            content: [{ type: "text", text: "spokenly transcript" }],
          },
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    });
    globalThis.fetch = fetchMock as typeof fetch;
  });

  afterEach(() => {
    delete process.env.VOICELAYER_INPUT_BACKEND;
    globalThis.fetch = originalFetch;
    awaitPlaybackSpy.mockRestore();
    speakSpy.mockRestore();
    clearInputSpy.mockRestore();
    waitForInputSpy.mockRestore();
    bookingSpy.mockRestore();
    bookSpy.mockRestore();
    clearStopSpy.mockRestore();
    recordingStateSpy.mockRestore();
    isConnectedSpy.mockRestore();
    broadcastSpy.mockRestore();
  });

  it("routes post-question capture through the configured voice input backend", async () => {
    const result = await handleConverse({
      message: "What should we do?",
      timeout_seconds: 30,
      silence_mode: "thoughtful",
      press_to_talk: false,
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const requestBody = JSON.parse(
      String(fetchMock.mock.calls[0][1]?.body ?? ""),
    );
    expect(requestBody.params).toEqual({
      name: "ask_user_dictation",
      arguments: { questions: ["What should we do?"] },
    });
    expect(waitForInputSpy).not.toHaveBeenCalled();
    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("spokenly transcript");
    expect(broadcastSpy).toHaveBeenCalledWith({
      type: "state",
      state: "recording",
      mode: "vad",
      silence_mode: "thoughtful",
    });
    expect(broadcastSpy).toHaveBeenCalledWith({
      type: "transcription",
      text: "spokenly transcript",
      partial: false,
    });
    expect(broadcastSpy).toHaveBeenCalledWith({
      type: "state",
      state: "idle",
      source: "recording",
    });
  });
});
