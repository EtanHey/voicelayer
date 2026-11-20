/**
 * voice_ask keeps its MCP progress heartbeat alive from the first moment, so a client with an idle
 * limit is not cut while the ask waits for earlier playback or speaks its question (T8).
 * No microphone: TTS, playback and the recorder are mocked with latches.
 */
import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import * as tts from "../tts";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleConverse } from "../handlers";
import type { VoiceToolEvent } from "../mcp-notifications";

const prompt = () => ({
  displayText: "test question",
  engine: "edge-tts",
  voice: "en-US-JennyNeural",
  audioArtifact: { bytes: new Uint8Array([0x49, 0x44, 0x33]), format: "mp3" as const },
});

const TICK = 10;
const progress = (events: VoiceToolEvent[]) =>
  events.filter((e) => e.kind === "voice_ask_progress") as Extract<VoiceToolEvent, { kind: "voice_ask_progress" }>[];
const stages = (events: VoiceToolEvent[]) => progress(events).map((e) => e.stage);

describe("voice_ask heartbeat starts with the flow", () => {
  let spies: Array<{ mockRestore(): void }>;
  let root: string;
  let savedState: string | undefined;
  let awaitSpy: ReturnType<typeof spyOn>;
  let events: VoiceToolEvent[];
  const ctx = (extra: Record<string, unknown> = {}) => ({
    heartbeatIntervalMs: TICK,
    emit: (event: VoiceToolEvent) => void events.push(event),
    ...extra,
  });
  const latch = <T = void>() => Promise.withResolvers<T>();

  beforeEach(() => {
    events = [];
    root = mkdtempSync(join(tmpdir(), "voicelayer-heartbeat-start-"));
    savedState = process.env.QA_VOICE_RECORDING_STATE_PATH;
    process.env.QA_VOICE_RECORDING_STATE_PATH = join(root, "recording-state.json");
    awaitSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined);
    spies = [
      spyOn(socketClient, "broadcast").mockImplementation(() => {}),
      spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
        booked: true,
        ownedByUs: true,
        owner: { pid: process.pid, sessionId: "test", startedAt: new Date().toISOString() },
      }),
      spyOn(input, "clearInput").mockImplementation(() => {}),
      spyOn(sessionBooking, "clearStopSignal").mockImplementation(() => {}),
      awaitSpy,
    ];
  });

  afterEach(async () => {
    await Bun.sleep(0);
    for (const spy of spies) spy.mockRestore();
    if (savedState === undefined) delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    else process.env.QA_VOICE_RECORDING_STATE_PATH = savedState;
    rmSync(root, { recursive: true, force: true });
  });

  /** After the call settles, no further frame may arrive. */
  async function expectSilentAfterEnd() {
    await Bun.sleep(TICK * 2);
    const settled = events.length;
    await Bun.sleep(TICK * 6);
    expect(events.length).toBe(settled);
  }

  it("beats during playback-wait and speaking, then recording and transcribing, then stops on the answer", async () => {
    const playback = latch();
    const speaking = latch<ReturnType<typeof prompt>>();
    const recording = latch<string | null>();
    awaitSpy.mockImplementation(() => playback.promise);
    spies.push(spyOn(tts, "speak").mockImplementation(() => speaking.promise));
    spies.push(
      spyOn(input, "waitForInput").mockImplementation(async (_t, _s, _p, options) => {
        options?.onCaptureStart?.();
        options?.onPhaseChange?.("recording");
        const answer = await recording.promise;
        options?.onPhaseChange?.("transcribing");
        await Bun.sleep(TICK * 4);
        options?.onCaptureEnd?.();
        return answer;
      }),
    );

    const pending = handleConverse({ message: "Wait for playback first", timeout_seconds: 30 }, ctx());
    await Bun.sleep(TICK * 5);
    expect(stages(events).length).toBeGreaterThanOrEqual(3);
    expect(new Set(stages(events))).toEqual(new Set(["waiting"]));

    playback.resolve();
    await Bun.sleep(TICK * 5);
    expect(stages(events)).toContain("speaking");

    speaking.resolve(prompt());
    await Bun.sleep(TICK * 5);
    expect(stages(events)).toContain("recording");

    recording.resolve("an answer");
    const result = await pending;
    expect(result.isError).toBeFalsy();
    const seen = progress(events);
    expect(seen.map((e) => e.sequence)).toEqual(seen.map((_, i) => i + 1));
    expect(stages(events)).toContain("transcribing");
    await expectSilentAfterEnd();
  });

  it("stops when the ask ends away (no answer)", async () => {
    spies.push(spyOn(tts, "speak").mockResolvedValue(prompt()));
    spies.push(
      spyOn(input, "waitForInput").mockImplementation(async (_t, _s, _p, options) => {
        options?.onCaptureStart?.();
        options?.onPhaseChange?.("recording");
        await Bun.sleep(TICK * 3);
        options?.onCaptureEnd?.();
        options?.onNoSpeech?.();
        return null;
      }),
    );
    await handleConverse({ message: "Anyone there?", timeout_seconds: 30 }, ctx());
    expect(stages(events)[0]).toBe("waiting");
    await expectSilentAfterEnd();
  });

  it("stops when the call is cancelled mid-wait", async () => {
    const abort = new AbortController();
    awaitSpy.mockImplementation(() => new Promise<void>(() => {}));
    spies.push(spyOn(tts, "speak").mockResolvedValue(prompt()));
    const pending = handleConverse(
      { message: "Cancel me while waiting", timeout_seconds: 30 },
      ctx({ disconnectSignal: abort.signal }),
    );
    await Bun.sleep(TICK * 4);
    expect(stages(events)).toContain("waiting");
    abort.abort();
    await Promise.race([pending, Bun.sleep(1000)]);
    await expectSilentAfterEnd();
  });

  it("stops when speaking the question fails", async () => {
    spies.push(spyOn(tts, "speak").mockImplementation(async () => {
      await Bun.sleep(TICK * 3);
      throw new Error("synthesis exploded");
    }));
    const result = await handleConverse({ message: "This will fail", timeout_seconds: 30 }, ctx());
    expect(result.isError).toBe(true);
    expect(stages(events)).toContain("speaking");
    await expectSilentAfterEnd();
  });

  it("a refused ask (another session owns the microphone) never starts a heartbeat", async () => {
    spies.push(
      spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
        booked: true,
        ownedByUs: false,
        owner: { pid: process.pid + 1, sessionId: "other", startedAt: new Date().toISOString() },
      }),
    );
    const speak = spyOn(tts, "speak").mockResolvedValue(prompt());
    spies.push(speak);
    await handleConverse({ message: "Refuse this", timeout_seconds: 30 }, ctx());
    expect(speak).not.toHaveBeenCalled();
    await Bun.sleep(TICK * 4);
    expect(events).toEqual([]);
  });
});
