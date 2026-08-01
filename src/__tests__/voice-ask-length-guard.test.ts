import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { handleVoiceAsk } from "../handlers";
import * as input from "../input";
import * as recordingState from "../recording-state";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as launcher from "../voice-bar-launcher";

/**
 * AIDEV-NOTE: Regression fixture for the 2026-08-01 long-ask incident.
 *
 * Recording `2026-08-01T13-03-45-986Z-6b1bec61` — an agent sent a `voice_ask`
 * of 1,081 characters / 196 words. Measured with ffprobe against the retained
 * `agent-audio.mp3`, it synthesised **87.4 seconds** of speech that played in
 * full before the microphone opened. Etan: "My voice message was far too long
 * — killed the teleprompter."
 *
 * The real transcript is not committed: this repository is public and that text
 * is a private work conversation. The fixture reproduces the incident's measured
 * shape (character count and word count), which is what the guard keys on.
 *
 * This ask was NOT caught by the 1,200-character threshold that PR #392 merged —
 * 1,081 < 1,200. That is why the blocking tool needs its own tighter cap.
 */
export const INCIDENT_2026_08_01_CHARS = 1_081;
const INCIDENT_2026_08_01_WORDS = 196;

function buildIncidentShapedMessage(): string {
  const words: string[] = [];
  for (let i = 0; i < INCIDENT_2026_08_01_WORDS; i++) {
    // Deterministic filler; only length and word count matter to the guard.
    words.push("context".slice(0, 3 + (i % 5)));
  }
  let message = words.join(" ");
  if (message.length < INCIDENT_2026_08_01_CHARS) {
    message += "x".repeat(INCIDENT_2026_08_01_CHARS - message.length);
  }
  return message.slice(0, INCIDENT_2026_08_01_CHARS);
}

describe("voice_ask blocking-length guard", () => {
  const spies: Array<{ mockRestore: () => void }> = [];
  let speakSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let savedJournal: string | undefined;

  beforeEach(() => {
    savedJournal = process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
    process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL = "1";
    spies.push(
      spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}),
    );
    spies.push(spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined));
    spies.push(spyOn(socketClient, "isConnected").mockReturnValue(true));
    spies.push(spyOn(socketClient, "broadcast").mockImplementation(() => {}));
    spies.push(
      spyOn(recordingState, "getEffectiveRecordingState").mockReturnValue(
        "idle",
      ),
    );
    spies.push(
      spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
        booked: true,
        ownedByUs: true,
        owner: {
          pid: process.pid,
          sessionId: "length-guard-test",
          startedAt: new Date().toISOString(),
        },
      } as never),
    );
    spies.push(spyOn(input, "clearInput").mockImplementation(() => {}));
    spies.push(spyOn(input, "clearStopSignal").mockImplementation(() => {}));
    speakSpy = spyOn(tts, "speak").mockResolvedValue({
      displayText: "spoken",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" },
    } as never);
    spies.push(speakSpy);
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("answer");
    spies.push(waitForInputSpy);
  });

  afterEach(() => {
    for (const spy of spies.splice(0)) spy.mockRestore();
    if (savedJournal === undefined) {
      delete process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
    } else {
      process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL = savedJournal;
    }
  });

  // --- The incident this guard exists to prevent ---

  it("refuses the 2026-08-01 incident ask (1,081 chars / 87s of blocking speech)", async () => {
    const message = buildIncidentShapedMessage();
    expect(message.length).toBe(INCIDENT_2026_08_01_CHARS);

    const result = await handleVoiceAsk({ message });

    expect(result.isError).toBe(true);
    // Nothing may be synthesised, played, or recorded.
    expect(speakSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("refuses the incident ask even when the caller raises timeout_seconds", async () => {
    // The real incident passed timeout_seconds: 180, which is exactly why it
    // survived the converse capture timeout and played all 87 seconds.
    const result = await handleVoiceAsk({
      message: buildIncidentShapedMessage(),
      timeout_seconds: 180,
    });

    expect(result.isError).toBe(true);
    expect(speakSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("refuses an otherwise valid maximum ask when a shorter timeout cannot fit playback", async () => {
    const { VOICE_ASK_MESSAGE_MAX_CHARS } = await import("../handlers");

    const result = await handleVoiceAsk({
      message: "A".repeat(VOICE_ASK_MESSAGE_MAX_CHARS),
      timeout_seconds: 5,
    });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("limit");
    expect(speakSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("rearms a full capture timeout after prompt playback completes", async () => {
    const realSetTimeout = globalThis.setTimeout;
    const timeoutDelays: number[] = [];
    const timeoutSpy = spyOn(globalThis, "setTimeout").mockImplementation(
      ((handler: TimerHandler, delay?: number, ...args: unknown[]) => {
        timeoutDelays.push(delay ?? 0);
        return realSetTimeout(handler, delay, ...args);
      }) as typeof setTimeout,
    );

    try {
      const result = await handleVoiceAsk({
        message: "Can you confirm?",
        timeout_seconds: 5,
      });

      expect(result.isError).toBeUndefined();
      expect(timeoutDelays.filter((delay) => delay === 20_000)).toHaveLength(2);
      expect(waitForInputSpy).toHaveBeenCalled();
    } finally {
      timeoutSpy.mockRestore();
    }
  });

  // --- The refusal must be self-correcting ---

  it("tells the caller the length, the limit, the cost, and how to split", async () => {
    const result = await handleVoiceAsk({
      message: buildIncidentShapedMessage(),
    });
    const text = result.content[0].text as string;

    expect(text).toContain("1,081");
    expect(text).toMatch(/\bseconds\b/);
    expect(text).toContain("sequential voice_ask");
    expect(text).toContain("checkpoint");
    // Must never send response-bearing content to the non-blocking tool.
    expect(text).not.toMatch(/use voice_speak (instead|for this|for long)/i);
  });

  // --- Boundary behaviour ---

  it("accepts an ask at the limit and refuses one character more", async () => {
    const { VOICE_ASK_MESSAGE_MAX_CHARS } = await import("../handlers");

    const atLimit = await handleVoiceAsk({
      message: "A".repeat(VOICE_ASK_MESSAGE_MAX_CHARS),
    });
    expect(atLimit.isError).toBeUndefined();
    expect(speakSpy).toHaveBeenCalledTimes(1);

    speakSpy.mockClear();
    const overLimit = await handleVoiceAsk({
      message: "A".repeat(VOICE_ASK_MESSAGE_MAX_CHARS + 1),
    });
    expect(overLimit.isError).toBe(true);
    expect(speakSpy).not.toHaveBeenCalled();
  });

  // --- The gate must not be silently removable (see docs/plans/…-guard-delivery.md) ---

  it("keeps the blocking cap tight enough to fit the default capture timeout", async () => {
    const { VOICE_ASK_MESSAGE_MAX_CHARS } = await import("../handlers");

    // handleConverse gives playback a hard timeout of (timeout_seconds + 15)s,
    // and speak(waitForPlayback:true) awaits full playback before capture.
    // With the default timeout_seconds of 30 that is 45 seconds. At the
    // conservative rounded measured rate of ~13 chars/sec, 600 chars is about
    // 46 seconds; the exact 13.9 chars/sec median gives a ~626-character
    // ceiling. The named cap must stay below that ceiling so playback cannot
    // time out before the microphone opens.
    const MEASURED_CHARS_PER_SECOND = 13.9;
    const DEFAULT_CAPTURE_TIMEOUT_SECONDS = 45;

    expect(VOICE_ASK_MESSAGE_MAX_CHARS).toBeLessThanOrEqual(
      Math.floor(MEASURED_CHARS_PER_SECOND * DEFAULT_CAPTURE_TIMEOUT_SECONDS),
    );
    expect(VOICE_ASK_MESSAGE_MAX_CHARS).toBeLessThan(INCIDENT_2026_08_01_CHARS);
  });
});
