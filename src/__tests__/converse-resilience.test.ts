/**
 * P0-2 voice_ask resilience tests.
 *
 * TDD RED phase: handleConverse must:
 * 1. Catch speak() failures and return clean error (not throw)
 * 2. Catch waitForInput() failures and return clean error
 * 3. Broadcast idle on all error paths so VoiceBar doesn't get stuck
 * 4. Log warning when VoiceBar is disconnected (non-blocking)
 */

import {
  describe,
  it,
  expect,
  beforeEach,
  afterEach,
  spyOn,
  jest,
} from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import * as tts from "../tts";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleConverse } from "../handlers";

const capturedPrompt = () => ({
  displayText: "test question",
  engine: "edge-tts",
  voice: "en-US-JennyNeural",
  audioArtifact: {
    bytes: new Uint8Array([0x49, 0x44, 0x33]),
    format: "mp3" as const,
  },
});

describe("handleConverse resilience — P0-2", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: unknown[];
  let speakSpy: ReturnType<typeof spyOn>;
  let awaitSpy: ReturnType<typeof spyOn>;
  let waitSpy: ReturnType<typeof spyOn>;
  let bookingSpy: ReturnType<typeof spyOn>;
  let clearInputSpy: ReturnType<typeof spyOn>;
  let clearStopSpy: ReturnType<typeof spyOn>;
  let recordingStateRoot: string;
  let savedRecordingStatePath: string | undefined;

  beforeEach(() => {
    recordingStateRoot = mkdtempSync(
      join(tmpdir(), "voicelayer-converse-resilience-"),
    );
    savedRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
    process.env.QA_VOICE_RECORDING_STATE_PATH = join(
      recordingStateRoot,
      "recording-state.json",
    );
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
    if (savedRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = savedRecordingStatePath;
    }
    rmSync(recordingStateRoot, { recursive: true, force: true });
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
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
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
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
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

  it("does not broadcast idle when waitForInput() refuses an existing recording", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    waitSpy = spyOn(input, "waitForInput").mockRejectedValue(
      new Error("Recording already in progress (state: recording)"),
    );

    const result = await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("Recording already in progress");
    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles).toHaveLength(0);
  });

  it("logs warning when VoiceBar is disconnected", async () => {
    const isConnectedSpy = spyOn(socketClient, "isConnected").mockReturnValue(
      false,
    );
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    waitSpy = spyOn(input, "waitForInput").mockResolvedValue("hello");

    // Should complete normally, just with a warning
    const result = await handleConverse({
      message: "test question",
      timeout_seconds: 30,
    });

    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("hello");

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

  it("aborts the in-flight input pipeline when the outer timeout wins", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      let capturedSignal: AbortSignal | undefined;
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _silenceMode, _pushToEnd, options) => {
          capturedSignal = (options as { signal?: AbortSignal } | undefined)
            ?.signal;
          return new Promise(() => {});
        },
      );

      let settled = false;
      const pending = handleConverse({
        message: "test question",
        timeout_seconds: 5,
      }).finally(() => {
        settled = true;
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(waitSpy).toHaveBeenCalledTimes(1);
      expect(capturedSignal).toBeInstanceOf(AbortSignal);
      expect(capturedSignal?.aborted).toBe(false);

      jest.advanceTimersByTime(20_000);
      await Promise.resolve();
      expect(settled).toBe(true);
      const result = await pending;

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Hard timeout");
      expect(capturedSignal?.aborted).toBe(true);
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("returns a non-fatal archive pointer when hard timeout aborts captured audio", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      const archivePath =
        "/isolated/recordings/2026-08-01/2026-08-01T13-14-02-000Z-abcd1234";
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _silenceMode, _pushToEnd, options) => {
          const captureOptions = options as
            | {
                signal?: AbortSignal;
                onCaptureStart?: () => void;
                onArchiveCreated?: (path: string) => void;
              }
            | undefined;
          captureOptions?.onCaptureStart?.();
          return new Promise((_resolve, reject) => {
            captureOptions?.signal?.addEventListener(
              "abort",
              () => {
                captureOptions.onArchiveCreated?.(archivePath);
                reject(captureOptions.signal?.reason);
              },
              { once: true },
            );
          });
        },
      );

      const pending = handleConverse({
        message: "Keep my answer if the capture guard fires",
        timeout_seconds: 5,
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      jest.advanceTimersByTime(20_000);
      const result = await pending;

      expect(result.isError).toBeUndefined();
      expect(result.content[0].text).toContain(
        "2026-08-01T13-14-02-000Z-abcd1234",
      );
      expect(result.content[0].text).toContain(`${archivePath}/audio.wav`);
      expect(result.content[0].text).toContain("Re-transcribe");
      expect(result.content[0].text).not.toContain("Try again");
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("keeps a bounded fatal fallback when capture stalls with zero audio", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _silenceMode, _pushToEnd, options) => {
          (
            options as { onCaptureStart?: () => void } | undefined
          )?.onCaptureStart?.();
          return new Promise(() => {});
        },
      );

      let settled = false;
      const pending = handleConverse({
        message: "Bound a stuck empty capture",
        timeout_seconds: 5,
      }).finally(() => {
        settled = true;
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      jest.advanceTimersByTime(20_000);
      await Promise.resolve();
      expect(settled).toBe(false);

      jest.advanceTimersByTime(14_999);
      await Promise.resolve();
      expect(settled).toBe(false);

      jest.advanceTimersByTime(1);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("zero recoverable audio");
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("returns the archive pointer when a captured ask is cancelled", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    const archivePath =
      "/isolated/recordings/2026-08-01/2026-08-01T13-17-24-177Z-4633481a";
    waitSpy = spyOn(input, "waitForInput").mockImplementation(
      async (_timeout, _silenceMode, _pushToEnd, options) => {
        const captureOptions = options as
          | {
              onCaptureStart?: () => void;
              onArchiveCreated?: (path: string) => void;
              onCaptureEnd?: () => void;
            }
          | undefined;
        captureOptions?.onCaptureStart?.();
        captureOptions?.onArchiveCreated?.(archivePath);
        captureOptions?.onCaptureEnd?.();
        return null;
      },
    );

    const result = await handleConverse({
      message: "Keep a cancelled answer",
      timeout_seconds: 30,
    });

    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain(
      "2026-08-01T13-17-24-177Z-4633481a",
    );
    expect(result.content[0].text).toContain(`${archivePath}/audio.wav`);
    expect(result.content[0].text).toContain("Re-transcribe");
  });

  it("does not start a heartbeat or recording after prompt speech outlives the outer timeout", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      let finishPrompt!: (value: ReturnType<typeof capturedPrompt>) => void;
      speakSpy = spyOn(tts, "speak").mockImplementation(
        () =>
          new Promise((resolve) => {
            finishPrompt = resolve;
          }),
      );
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        () => new Promise(() => {}),
      );
      const events: unknown[] = [];

      const pending = handleConverse(
        {
          message: "Do not record after this request times out",
          timeout_seconds: 5,
        },
        {
          heartbeatIntervalMs: 10,
          emit: (event: unknown) => events.push(event),
        },
      );
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(speakSpy).toHaveBeenCalledTimes(1);
      jest.advanceTimersByTime(20_000);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Hard timeout");

      finishPrompt(capturedPrompt());
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      jest.advanceTimersByTime(100);

      expect(waitSpy).not.toHaveBeenCalled();
      expect(events).toEqual([]);
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("does not speak a stale prompt when queued playback outlives the outer timeout", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      let finishPlayback!: () => void;
      awaitSpy.mockImplementation(
        () =>
          new Promise<void>((resolve) => {
            finishPlayback = resolve;
          }),
      );
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());

      const pending = handleConverse({
        message: "Do not speak this prompt after the request times out",
        timeout_seconds: 5,
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(awaitSpy).toHaveBeenCalledTimes(1);
      expect(speakSpy).not.toHaveBeenCalled();

      jest.advanceTimersByTime(20_000);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Hard timeout");

      finishPlayback();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(speakSpy).not.toHaveBeenCalled();
      expect(jest.getTimerCount()).toBe(0);
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("gives capture a fresh hard-timeout window after long prompt playback", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      let finishPrompt!: (value: ReturnType<typeof capturedPrompt>) => void;
      speakSpy = spyOn(tts, "speak").mockImplementation(
        () =>
          new Promise((resolve) => {
            finishPrompt = resolve;
          }),
      );
      let capturedSignal: AbortSignal | undefined;
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _silenceMode, _pushToEnd, options) => {
          const captureOptions = options as
            | {
                signal?: AbortSignal;
                onCaptureStart?: () => void;
              }
            | undefined;
          capturedSignal = captureOptions?.signal;
          captureOptions?.onCaptureStart?.();
          return new Promise((_resolve, reject) => {
            capturedSignal?.addEventListener(
              "abort",
              () => reject(capturedSignal?.reason),
              { once: true },
            );
          });
        },
      );

      const pending = handleConverse({
        message: "Let the full recording window start after this prompt",
        timeout_seconds: 5,
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      jest.advanceTimersByTime(19_000);
      finishPrompt(capturedPrompt());
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(waitSpy).toHaveBeenCalledTimes(1);
      expect(capturedSignal?.aborted).toBe(false);

      jest.advanceTimersByTime(19_999);
      expect(capturedSignal?.aborted).toBe(false);
      jest.advanceTimersByTime(1);
      expect(capturedSignal?.aborted).toBe(true);
      await pending;
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("gives STT and the return pipe a fresh deadline after a long capture ends", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      let captureEnded: (() => void) | undefined;
      let finishTranscription!: (value: string) => void;
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _silenceMode, _pushToEnd, options) => {
          captureEnded = (
            options as { onCaptureEnd?: () => void } | undefined
          )?.onCaptureEnd;
          return new Promise<string>((resolve) => {
            finishTranscription = resolve;
          });
        },
      );

      const pending = handleConverse({
        message: "Return the complete 53-second answer",
        timeout_seconds: 5,
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      expect(waitSpy).toHaveBeenCalledTimes(1);
      jest.advanceTimersByTime(19_000);
      captureEnded?.();
      jest.advanceTimersByTime(6_000);
      finishTranscription("complete 53-second transcript");
      const result = await pending;

      expect(captureEnded).toBeInstanceOf(Function);
      expect(result.isError).toBeUndefined();
      expect(result.content[0].text).toContain("complete 53-second transcript");
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });
});
