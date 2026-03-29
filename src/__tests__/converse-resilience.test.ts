/**
 * P0-2 voice_ask resilience tests.
 *
 * TDD RED phase: handleConverse must:
 * 1. Catch speak() failures and return clean error (not throw)
 * 2. Catch waitForInput() failures and return clean error
 * 3. Broadcast idle on all error paths so VoiceBar doesn't get stuck
 * 4. Log warning when VoiceBar is disconnected (non-blocking)
 */

import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import * as tts from "../tts";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleConverse } from "../handlers";

describe("handleConverse resilience — P0-2", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: unknown[];
  let speakSpy: ReturnType<typeof spyOn>;
  let awaitSpy: ReturnType<typeof spyOn>;
  let waitSpy: ReturnType<typeof spyOn>;
  let bookingSpy: ReturnType<typeof spyOn>;
  let clearInputSpy: ReturnType<typeof spyOn>;
  let clearStopSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    broadcasts = [];
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(JSON.parse(JSON.stringify(event)));
      },
    );
    bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: true,
      ownedByUs: true,
      owner: {
        pid: process.pid,
        sessionId: "test",
        startedAt: new Date().toISOString(),
      },
    });
    awaitSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined);
    clearInputSpy = spyOn(input, "clearInput").mockImplementation(() => {});
    clearStopSpy = spyOn(sessionBooking, "clearStopSignal").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    broadcastSpy.mockRestore();
    speakSpy?.mockRestore();
    awaitSpy.mockRestore();
    waitSpy?.mockRestore();
    bookingSpy.mockRestore();
    clearInputSpy.mockRestore();
    clearStopSpy.mockRestore();
  });

  it("returns error result when speak() throws, not unhandled rejection", async () => {
    speakSpy = spyOn(tts, "speak").mockRejectedValue(
      new Error("edge-tts crashed"),
    );

    // Should return clean McpResult, not throw
    const result = await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("edge-tts crashed");
  });

  it("broadcasts idle when speak() fails", async () => {
    speakSpy = spyOn(tts, "speak").mockRejectedValue(new Error("TTS failed"));

    await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBeGreaterThanOrEqual(1);
  });

  it("returns error result when waitForInput() throws", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue({});
    waitSpy = spyOn(input, "waitForInput").mockRejectedValue(
      new Error("sox not found"),
    );

    const result = await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("sox not found");
  });

  it("broadcasts idle when waitForInput() fails", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue({});
    waitSpy = spyOn(input, "waitForInput").mockRejectedValue(
      new Error("recording failed"),
    );

    await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBeGreaterThanOrEqual(1);
  });

  it("logs warning when VoiceBar is disconnected", async () => {
    const isConnectedSpy = spyOn(socketClient, "isConnected").mockReturnValue(
      false,
    );
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    speakSpy = spyOn(tts, "speak").mockResolvedValue({});
    waitSpy = spyOn(input, "waitForInput").mockResolvedValue("hello");

    // Should complete normally, just with a warning
    const result = await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toBe("hello");

    // Verify warning was logged
    const warningCalls = errorSpy.mock.calls.filter(
      (args: unknown[]) =>
        typeof args[0] === "string" &&
        args[0].includes("VoiceBar not connected"),
    );
    expect(warningCalls.length).toBe(1);

    isConnectedSpy.mockRestore();
    errorSpy.mockRestore();
  });
});
