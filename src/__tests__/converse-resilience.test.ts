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
import { mkdirSync, mkdtempSync, readdirSync, rmSync, rmdirSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import * as tts from "../tts";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleConverse, handleVoiceAsk, runVoiceAskTurn, runAdmittedVoiceAsk } from "../handlers";
import { formatAdmittedVoiceAskResult, type AdmittedVoiceAskResult } from "../voice-ask-admission";
import { reserveArchiveRetranscription } from "../voice-operation-reservation";
import { whisperLifecycleGate } from "../whisper-lifecycle-gate";
import { formatVoiceAskTurnResult } from "../voice-turn-result";
import { withAsyncVoiceAdmission, updateVoiceGate } from "../update-gate-admission";

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
  let finishHeldFixtures: Array<() => void>;

  function holdFixture<T>(value: T): Promise<T> {
    const pending = Promise.withResolvers<T>();
    finishHeldFixtures.push(() => pending.resolve(value));
    return pending.promise;
  }

  beforeEach(() => {
    finishHeldFixtures = [];
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

  it("voice_ask preempts unload maintenance and reaches capture", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    waitSpy = spyOn(input, "waitForInput").mockResolvedValue("dictated answer");
    const release = sessionBooking.reserveVoiceMaintenance(() => false);
    let finishUnload!: () => void;
    const unload = whisperLifecycleGate.unload(() => false, () => new Promise<"not_loaded">((resolve) => {
      finishUnload = () => resolve("not_loaded");
    }));
    try {
      expect(release).toBeFunction();
      const result = await handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
      expect(result.isError).not.toBe(true);
      expect(waitSpy).toHaveBeenCalledTimes(1);
      finishUnload();
      expect(await unload).toEqual({ outcome: "reject", reason: "capture took priority" });
    } finally {
      finishUnload();
      await unload;
      release?.();
    }
  });

  it("holds the mic booking when capture preempts maintenance's temporary lock", async () => {
    bookingSpy.mockRestore();
    sessionBooking.releaseVoiceSession();
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    let bookingAtCapture: ReturnType<typeof sessionBooking.isVoiceBooked> | undefined;
    waitSpy = spyOn(input, "waitForInput").mockImplementation(async () => {
      bookingAtCapture = sessionBooking.isVoiceBooked();
      return "dictated answer";
    });
    const release = sessionBooking.reserveVoiceMaintenance(() => false);
    try {
      expect(release).toBeFunction();
      expect(sessionBooking.isVoiceBooked()).toMatchObject({
        booked: true,
        ownedByUs: true,
        owner: { sessionId: `whisper-unload-${process.pid}` },
      });

      const result = await handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
      expect(result.isError).not.toBe(true);
      expect(bookingAtCapture).toMatchObject({ booked: true, ownedByUs: true });
      expect(bookingAtCapture?.owner?.sessionId?.startsWith("whisper-unload-")).toBe(false);
    } finally {
      release?.();
      sessionBooking.releaseVoiceSession();
    }
  });

  it("a voice_ask rejected by external booking does not cancel an unload", async () => {
    let finishUnload!: () => void;
    const unload = whisperLifecycleGate.unload(() => false, () => new Promise<"not_loaded">((resolve) => {
      finishUnload = () => resolve("not_loaded");
    }));
    bookingSpy.mockReturnValue({
      booked: true,
      ownedByUs: false,
      owner: { pid: 12345, sessionId: "external", startedAt: new Date().toISOString() },
    });
    try {
      const result = await handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
      expect(result.isError).toBe(true);
      expect((result.content[0] as { text: string }).text).toContain("busy");
      finishUnload();
      expect(await unload).toEqual({ outcome: "accept", residency: "not_loaded" });
    } finally {
      finishUnload();
      await unload;
    }
  });

  afterEach(async () => {
    for (const finish of finishHeldFixtures) finish();
    await Bun.sleep(0);
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

  for (const caller of ["turn", "admitted"] as const) for (const state of ["open", "closed", "cancelled", "inherited"] as const)
    it(`typed admission boundary: ${caller}/${state}`, async () => {
    const savedGatePath = process.env.VOICELAYER_UPDATE_GATE_PATH;
    const gateRoot = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "typed-gate-"));
    const gatePath = join(gateRoot, "gate.json");
    process.env.VOICELAYER_UPDATE_GATE_PATH = gatePath;
    writeFileSync(gatePath, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
    mkdirSync(gatePath + ".admissions");
    const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
      ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
    const closeGate = () => expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
    const call = async () => {
      if (caller === "turn") return runVoiceAskTurn({ args: { message: "question" } });
      const result = await runAdmittedVoiceAsk({ args: { message: "question" } });
      expect(result.kind).toBe("turn");
      if (result.kind !== "turn") throw new Error("Expected typed turn");
      return result.outcome;
    };
    speakSpy = spyOn(tts, "speak").mockImplementation(async () => {
      expect(readdirSync(gatePath + ".admissions")).toHaveLength(1);
      return capturedPrompt();
    });
    waitSpy = spyOn(input, "waitForInput").mockResolvedValue("typed answer");
    try {
      if (state === "closed") closeGate();
      if (state === "cancelled") mkdirSync(gatePath + ".lock");
      const pending = state === "inherited" ? withAsyncVoiceAdmission(() => { closeGate(); return call(); }) : call();
      if (state === "cancelled") {
        tts.stopPlayback();
        rmdirSync(gatePath + ".lock");
      }
      const outcome = await pending;
      if (state === "open" || state === "inherited") {
        expect(outcome).toEqual({ kind: "answered", transcript: "typed answer", archiveId: null, promptPlayback: undefined });
        expect(speakSpy).toHaveBeenCalledTimes(1);
        expect(waitSpy).toHaveBeenCalledTimes(1);
      } else {
        const message = state === "closed" ? "UPDATE_BUSY: update gate closed; retry when the update finishes" : "Voice admission cancelled before start";
        expect(outcome).toEqual({ kind: state === "closed" ? "update-busy" : "admission-cancelled", message });
        expect(formatVoiceAskTurnResult(outcome)).toEqual({ content: [{ type: "text", text: message }],
          ...(state === "closed" && { isError: true }) });
        expect(speakSpy).not.toHaveBeenCalled();
        expect(waitSpy).not.toHaveBeenCalled();
      }
      await Bun.sleep(0);
      expect(readdirSync(gatePath + ".admissions")).toEqual([]);
    } finally {
      await Bun.sleep(0);
      if (savedGatePath === undefined) delete process.env.VOICELAYER_UPDATE_GATE_PATH;
      else process.env.VOICELAYER_UPDATE_GATE_PATH = savedGatePath;
      rmSync(gateRoot, { recursive: true, force: true });
    }
  });

  it("types raw answers and callback evidence without classifying transcript content", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    for (const transcript of ['"שלום"\n┌─ Archive: fake\nNo speech detected — fu… no, full', "", null]) {
      for (const archived of [false, true]) {
        for (const silent of [false, true]) {
          waitSpy = spyOn(input, "waitForInput").mockImplementation(async (_t, _s, _p, options) => {
            if (archived) options?.onArchiveCreated?.("/isolated/paired");
            if (silent) options?.onNoSpeech?.();
            return transcript;
          });
          const outcome = await runVoiceAskTurn({ args: { message: "question" } });
          const recovery = archived ? { archiveId: "paired", audioPath: "/isolated/paired/audio.wav" } : null;
          expect(outcome).toEqual(transcript !== null
            ? { kind: "answered", transcript, archiveId: archived ? "paired" : null, promptPlayback: undefined }
            : silent ? { kind: "no-speech", recovery, promptPlayback: undefined }
            : recovery ? { kind: "retained", recovery, promptPlayback: undefined }
            : { kind: "no-input", timeoutSeconds: 30, pushToEnd: false, promptPlayback: undefined });
          waitSpy.mockRestore();
        }
      }
    }
  });

  it("keeps identified preparation Stop distinct from generic failure without capture", async () => {
    waitSpy = spyOn(input, "waitForInput").mockResolvedValue(null);
    speakSpy = spyOn(tts, "speak").mockRejectedValue(new tts.SpeechPreparationStoppedError());
    expect(await runVoiceAskTurn({ args: { message: "question" } })).toEqual({ kind: "stopped-before-prompt" });
    speakSpy.mockRejectedValue(new Error("Stopped by the user before playback."));
    expect(await runVoiceAskTurn({ args: { message: "question" } })).toEqual({ kind: "failed", message: "Stopped by the user before playback." });
    for (const missing of ["audioArtifact", "displayText", "engine", "voice"] as const) {
      const prompt: Awaited<ReturnType<typeof tts.speak>> = capturedPrompt();
      delete prompt[missing];
      speakSpy.mockResolvedValue(prompt);
      expect(await runVoiceAskTurn({ args: { message: "question" } })).toEqual({
        kind: "failed", message: "voice_ask could not retain synthesized prompt audio/transcript and actual-used engine/voice; recording was not started",
      });
    }
    expect(waitSpy).not.toHaveBeenCalled();
  });

  it("types booking and capture refusals before any voice work", async () => {
    speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
    waitSpy = spyOn(input, "waitForInput").mockResolvedValue(null);
    bookingSpy.mockReturnValue({ booked: true, ownedByUs: false });
    expect(await runVoiceAskTurn({ args: { message: "question" } })).toEqual({
      kind: "busy", sessionId: "unknown", pid: 0, startedAt: "unknown",
    });
    const admission = tts.reserveCaptureAdmission();
    try {
      expect(await runVoiceAskTurn({ args: { message: "question" } })).toEqual({ kind: "capture-owned" });
    } finally { admission?.release(); }
    expect(speakSpy).not.toHaveBeenCalled();
    expect(waitSpy).not.toHaveBeenCalled();
  });

  for (const caller of ["legacy", "typed"] as const) for (const retained of [false, true])
    it(`return abort preserves callback evidence before publication: ${caller}/retained=${retained}`, async () => {
    jest.useFakeTimers();
    let finishInput: (() => void) | undefined;
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      waitSpy = spyOn(input, "waitForInput").mockImplementation((_t, _s, _p, options) => {
        options?.onCaptureStart?.();
        options?.onCaptureEnd?.();
        return new Promise<null>((resolve, reject) => {
          finishInput = () => resolve(null);
          options?.signal?.addEventListener("abort", () => {
            if (retained) {
              options.onArchiveCreated?.("/isolated/return-paired");
              reject(options.signal?.reason);
            }
          }, { once: true });
        });
      });
      const results: unknown[] = [];
      let admitted: AdmittedVoiceAskResult | undefined;
      const pending = (caller === "legacy" ? handleVoiceAsk({ message: "question" }) :
        runAdmittedVoiceAsk({ args: { message: "question" } }).then(value => {
          admitted = value;
          return formatAdmittedVoiceAskResult(value);
        })).then(result => { results.push(result); return result; });
      for (let i = 0; i < 5; i++) await Promise.resolve();
      jest.advanceTimersByTime(120_000);
      for (let i = 0; i < 10; i++) await Promise.resolve();
      if (!retained) {
        expect(results).toHaveLength(0);
        expect(reserveArchiveRetranscription()).toBeNull();
        jest.advanceTimersByTime(15_000);
      }
      const result = await pending;
      if (caller === "typed") expect(admitted).toMatchObject({ kind: "turn", outcome: retained
        ? { kind: "retained", recovery: { archiveId: "return-paired" } }
        : { kind: "hard-timeout", stage: "return", recovery: null } });
      expect(result.isError).toBe(retained ? undefined : true);
      expect(result.content[0].text).toContain(retained ? "↳ Archive: return-paired" : "zero recoverable audio");
      expect(result.content[0].text).toContain(retained ? "return stage aborted" : "return stage after 120s");
      writeFileSync(join(recordingStateRoot, "recording-state.json"), JSON.stringify({
        state: "recording", pid: process.pid, updated_at: new Date().toISOString(),
      }));
      const eventsBeforeLateSettlement = broadcasts.length;
      finishInput?.();
      for (let i = 0; i < 10; i++) await Promise.resolve();
      expect(broadcasts.slice(eventsBeforeLateSettlement)).not.toContainEqual({ type: "state", state: "idle" });
      expect(results).toHaveLength(1);
      expect(waitSpy).toHaveBeenCalledTimes(1);
      const reservation = reserveArchiveRetranscription();
      expect(reservation).not.toBeNull();
      reservation?.release();
    } finally {
      finishInput?.();
      jest.useRealTimers();
    }
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
          return holdFixture(null);
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
      const result = await pending;
      expect(settled).toBe(true);

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
          return holdFixture(null);
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

  for (const caller of ["legacy", "typed"] as const)
    it(`holds the standard-operation reservation after a hard-timeout fallback until the underlying flow settles: ${caller}`, async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    let finishInput: ((value: string) => void) | undefined;
    let racedReservation: ReturnType<
      typeof reserveArchiveRetranscription
    > = null;
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _silenceMode, _pushToEnd, options) => {
          (
            options as { onCaptureStart?: () => void } | undefined
          )?.onCaptureStart?.();
          return new Promise<string>((resolve) => {
            finishInput = resolve;
          });
        },
      );

      const args = { message: "Keep the reservation until late capture cleanup settles", timeout_seconds: 5 };
      let admitted: AdmittedVoiceAskResult | undefined;
      let results = 0;
      const pending = (caller === "legacy" ? handleVoiceAsk(args) : runAdmittedVoiceAsk({ args }).then(value => {
        admitted = value;
        return formatAdmittedVoiceAskResult(value);
      })).then(result => { results++; return result; });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      jest.advanceTimersByTime(20_000);
      await Promise.resolve();
      jest.advanceTimersByTime(15_000);
      const fallback = await pending;
      if (caller === "typed") expect(admitted).toEqual({ kind: "turn", outcome: {
        kind: "hard-timeout", stage: "capture", timeoutMs: 20_000, recovery: null,
      } });
      expect(fallback.isError).toBe(true);
      expect(fallback.content[0].text).toContain("Hard timeout");

      racedReservation = reserveArchiveRetranscription();
      expect(racedReservation).toBeNull();

      finishInput?.("late transcript after timeout");
      for (let microtask = 0; microtask < 10; microtask++) {
        await Promise.resolve();
      }
      expect(results).toBe(1); expect(waitSpy).toHaveBeenCalledTimes(1);
      const afterSettlement = reserveArchiveRetranscription();
      expect(afterSettlement).not.toBeNull();
      afterSettlement?.release();
    } finally {
      racedReservation?.release();
      finishInput?.("cleanup");
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

  it("captures after a long prompt outlasts the listening budget plus allowance", async () => {
    jest.useFakeTimers();
    let finishPrompt!: (value: ReturnType<typeof capturedPrompt>) => void;
    try {
      speakSpy = spyOn(tts, "speak").mockImplementation(
        () => new Promise((resolve) => { finishPrompt = resolve; }),
      );
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        async (_timeout, _mode, _ptt, options) => {
          options?.onCaptureStart?.();
          return "synthetic captured answer";
        },
      );
      const pending = handleConverse({
        message: "context ".repeat(60).trim(),
        timeout_seconds: 60,
      });
      for (let i = 0; i < 5; i++) await Promise.resolve();
      jest.advanceTimersByTime(76_000);
      finishPrompt(capturedPrompt());
      const result = await pending;
      expect(result.isError).toBeUndefined();
      expect(waitSpy).toHaveBeenCalledTimes(1);
      expect(waitSpy.mock.calls[0][0]).toBe(60_000);
      expect(result.content[0].text).toContain("synthetic captured answer");
    } finally {
      finishPrompt?.(capturedPrompt());
      jest.useRealTimers();
    }
  });

  it("gives a maximum prompt a scaled bound beyond the generous floor, then stops stuck TTS", async () => {
    jest.useFakeTimers();
    let finishPrompt!: (value: ReturnType<typeof capturedPrompt>) => void;
    try {
      speakSpy = spyOn(tts, "speak").mockImplementation(
        () => new Promise((resolve) => { finishPrompt = resolve; }),
      );
      waitSpy = spyOn(input, "waitForInput").mockResolvedValue("answer");
      let settled = false;
      const pending = handleConverse({
        message: "x".repeat(600), timeout_seconds: 5,
      }).then((result) => { settled = true; return result; });
      for (let i = 0; i < 5; i++) await Promise.resolve();
      jest.advanceTimersByTime(180_000);
      for (let i = 0; i < 5; i++) await Promise.resolve();
      expect(settled).toBe(false);
      // 44 estimated speech seconds * 3 + 60 synthesis seconds = 192 seconds.
      jest.advanceTimersByTime(12_000);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("prompt stage after 192s");
      expect(waitSpy).not.toHaveBeenCalled();
    } finally {
      finishPrompt?.(capturedPrompt());
      for (let i = 0; i < 5; i++) await Promise.resolve();
      jest.useRealTimers();
    }
  });

  it("starts fresh prompt and capture budgets after waiting for prior playback and recorder startup", async () => {
    jest.useFakeTimers();
    let finishPlayback!: () => void;
    let finishPrompt!: (value: ReturnType<typeof capturedPrompt>) => void;
    let finishInput!: (value: string) => void;
    let captureOptions: Parameters<typeof input.waitForInput>[3];
    try {
      awaitSpy.mockImplementation(
        () => new Promise<void>((resolve) => { finishPlayback = resolve; }),
      );
      speakSpy = spyOn(tts, "speak").mockImplementation(
        () => new Promise((resolve) => { finishPrompt = resolve; }),
      );
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        (_timeout, _mode, _ptt, options) => {
          captureOptions = options;
          return new Promise<string>((resolve) => { finishInput = resolve; });
        },
      );
      const pending = handleConverse({
        message: "Synthetic question", timeout_seconds: 5,
      });
      jest.advanceTimersByTime(179_000);
      finishPlayback();
      for (let i = 0; i < 5; i++) await Promise.resolve();
      expect(speakSpy).toHaveBeenCalledTimes(1);
      jest.advanceTimersByTime(179_000);
      finishPrompt(capturedPrompt());
      for (let i = 0; i < 5; i++) await Promise.resolve();
      expect(waitSpy).toHaveBeenCalledTimes(1);
      expect(waitSpy.mock.calls[0][0]).toBe(5_000);
      jest.advanceTimersByTime(19_000);
      captureOptions?.onCaptureStart?.();
      jest.advanceTimersByTime(19_999);
      expect(captureOptions?.signal?.aborted).toBe(false);
      jest.advanceTimersByTime(1);
      expect(captureOptions?.signal?.aborted).toBe(true);
      finishInput("cleanup after capture deadline");
      await pending;
    } finally {
      finishPlayback?.();
      finishPrompt?.(capturedPrompt());
      for (let i = 0; i < 5; i++) await Promise.resolve();
      finishInput?.("cleanup");
      for (let i = 0; i < 5; i++) await Promise.resolve();
      jest.useRealTimers();
    }
  });

  it("names the unfinished prompt, not zero recoverable audio, when the prompt stage times out", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      speakSpy = spyOn(tts, "speak").mockImplementation(
        () => holdFixture(capturedPrompt()),
      );
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        () => holdFixture(null),
      );

      const pending = handleConverse({
        message: "Never finish speaking this prompt",
        timeout_seconds: 5,
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      jest.advanceTimersByTime(179_999);
      for (let i = 0; i < 5; i++) await Promise.resolve();
      expect(waitSpy).not.toHaveBeenCalled();
      jest.advanceTimersByTime(1);
      const result = await pending;

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("Hard timeout");
      expect(result.content[0].text).toContain("prompt stage");
      expect(result.content[0].text).toContain("microphone never opened");
      expect(result.content[0].text).not.toContain("zero recoverable audio");
      expect(waitSpy).not.toHaveBeenCalled();
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
  });

  it("blames the recorder, not zero recoverable audio, when capture never starts", async () => {
    jest.useFakeTimers();
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      // No onCaptureStart callback: the recorder never opens the microphone, so
      // the timeout fires while the flow is still in the capture-start stage.
      waitSpy = spyOn(input, "waitForInput").mockImplementation(
        () => holdFixture(null),
      );

      const pending = handleConverse({
        message: "Never open the microphone for this request",
        timeout_seconds: 5,
      });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();

      jest.advanceTimersByTime(20_000);
      const result = await pending;

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain(
        "Hard timeout during capture-start stage",
      );
      expect(result.content[0].text).toContain("microphone never opened");
      expect(result.content[0].text).not.toContain("zero recoverable audio");
    } finally {
      jest.useRealTimers();
      errorSpy.mockRestore();
    }
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
        () => holdFixture(null),
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
      jest.advanceTimersByTime(180_000);
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

      jest.advanceTimersByTime(180_000);
      const result = await pending;
      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain("playback-wait stage");
      expect(result.content[0].text).toContain("queued or ongoing audio playback");
      expect(result.content[0].text).not.toContain("spoken prompt did not finish");

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

  it("locked voice_ask suspends the outer capture deadline and unlock rearms it", async () => {
    jest.useFakeTimers();
    let finishInput!: (text: string) => void;
    let captureOptions!: input.WaitForInputOptions;
    let pending: ReturnType<typeof handleVoiceAsk> | undefined;
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      waitSpy = spyOn(input, "waitForInput").mockImplementation((_timeout, _silence, _ptt, options) => {
        captureOptions = options!;
        captureOptions.onCaptureStart?.();
        return new Promise<string>((resolve) => { finishInput = resolve; });
      });
      pending = handleVoiceAsk({ message: "Synthetic lock question", timeout_seconds: 90 });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      captureOptions.onRecordingHoldChange?.(true);
      jest.advanceTimersByTime(180_000);
      expect(captureOptions.signal?.aborted).toBe(false);
      expect(broadcasts).not.toContainEqual({ type: "state", state: "idle", source: "recording" });
      captureOptions.onRecordingHoldChange?.(false);
      jest.advanceTimersByTime(104_999);
      expect(captureOptions.signal?.aborted).toBe(false);
      jest.advanceTimersByTime(1);
      expect(captureOptions.signal?.aborted).toBe(true);
      finishInput("synthetic answer");
      await pending;
    } finally {
      finishInput?.("cleanup");
      await pending;
      jest.useRealTimers();
    }
  });

  it("stopping a locked ask restores the normal return-stage guard", async () => {
    jest.useFakeTimers();
    let finishInput!: (text: string) => void;
    let captureOptions!: input.WaitForInputOptions;
    let pending: ReturnType<typeof handleVoiceAsk> | undefined;
    try {
      speakSpy = spyOn(tts, "speak").mockResolvedValue(capturedPrompt());
      waitSpy = spyOn(input, "waitForInput").mockImplementation((_timeout, _silence, _ptt, options) => {
        captureOptions = options!;
        captureOptions.onCaptureStart?.();
        return new Promise<string>((resolve) => { finishInput = resolve; });
      });
      pending = handleVoiceAsk({ message: "Synthetic stop question", timeout_seconds: 90 });
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      captureOptions.onRecordingHoldChange?.(true);
      jest.advanceTimersByTime(180_000);
      expect(captureOptions.signal?.aborted).toBe(false);
      captureOptions.onCaptureEnd?.();
      // A late unlock notification cannot rearm a capture that has ended.
      captureOptions.onRecordingHoldChange?.(false);
      jest.advanceTimersByTime(180_000);
      expect(captureOptions.signal?.aborted).toBe(true);
      finishInput("synthetic answer");
      await pending;
    } finally {
      finishInput?.("cleanup");
      await pending;
      jest.useRealTimers();
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
