import { afterEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  RecordingSilenceAutoClosePolicy,
  clearRecordingHold,
  isRecordingHoldEngaged,
  setRecordingHold,
} from "../recording-hold";

describe("recording hold", () => {
  const roots: string[] = [];

  afterEach(() => {
    for (const root of roots.splice(0)) {
      rmSync(root, { recursive: true, force: true });
    }
  });

  function holdPath(): string {
    const root = mkdtempSync(join(tmpdir(), "voicelayer-recording-hold-"));
    roots.push(root);
    return join(root, "recording-hold");
  }

  it("stores and clears an explicit secure hold flag path", () => {
    const filePath = holdPath();

    expect(isRecordingHoldEngaged(filePath)).toBe(false);
    setRecordingHold(true, filePath);
    expect(existsSync(filePath)).toBe(true);
    expect(isRecordingHoldEngaged(filePath)).toBe(true);

    setRecordingHold(false, filePath);
    expect(existsSync(filePath)).toBe(false);
    expect(isRecordingHoldEngaged(filePath)).toBe(false);
  });

  it("clears a stale hold flag idempotently", () => {
    const filePath = holdPath();
    setRecordingHold(true, filePath);

    clearRecordingHold(filePath);
    clearRecordingHold(filePath);

    expect(isRecordingHoldEngaged(filePath)).toBe(false);
  });

  it("closes on the normal post-speech silence threshold", () => {
    const policy = new RecordingSilenceAutoClosePolicy({
      preSpeechChunks: 4,
      postSpeechSilenceChunks: 3,
    });

    expect(policy.observe({ speechDetected: true, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false })).toMatchObject({
      hasSpeech: true,
      shouldClose: true,
      reason: "post-speech-silence",
    });
  });

  it("held post-speech silence never closes and release starts a fresh countdown", () => {
    const policy = new RecordingSilenceAutoClosePolicy({
      preSpeechChunks: 4,
      postSpeechSilenceChunks: 3,
    });
    policy.observe({ speechDetected: true, holdEngaged: false });
    policy.observe({ speechDetected: false, holdEngaged: false });

    for (let index = 0; index < 10; index += 1) {
      expect(policy.observe({ speechDetected: false, holdEngaged: true }).shouldClose).toBe(false);
    }

    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(true);
  });

  it("held pre-speech silence never closes and release starts a fresh window", () => {
    const policy = new RecordingSilenceAutoClosePolicy({
      preSpeechChunks: 3,
      postSpeechSilenceChunks: 2,
    });

    for (let index = 0; index < 10; index += 1) {
      const observation = policy.observe({ speechDetected: false, holdEngaged: true });
      expect(observation).toMatchObject({ hasSpeech: false, shouldClose: false });
    }

    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false }).shouldClose).toBe(false);
    expect(policy.observe({ speechDetected: false, holdEngaged: false })).toMatchObject({
      hasSpeech: false,
      shouldClose: true,
      reason: "pre-speech-silence",
    });
  });
});
