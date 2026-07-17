import { existsSync, unlinkSync } from "fs";
import { recordingHoldFilePath, safeWriteFileSync } from "./paths";

export function setRecordingHold(
  engaged: boolean,
  filePath: string = recordingHoldFilePath(),
): void {
  if (!engaged) {
    clearRecordingHold(filePath);
    return;
  }
  safeWriteFileSync(filePath, `engaged ${new Date().toISOString()}\n`);
}

export function isRecordingHoldEngaged(
  filePath: string = recordingHoldFilePath(),
): boolean {
  return existsSync(filePath);
}

export function clearRecordingHold(
  filePath: string = recordingHoldFilePath(),
): void {
  try {
    unlinkSync(filePath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw error;
    }
  }
}

export interface RecordingSilenceAutoCloseThresholds {
  preSpeechChunks: number;
  postSpeechSilenceChunks: number;
}

export interface RecordingSilenceObservation {
  hasSpeech: boolean;
  shouldClose: boolean;
  reason: "pre-speech-silence" | "post-speech-silence" | null;
}

/**
 * Pure VAD countdown state. HOLD resets both silence windows on every observed
 * chunk, so release always starts a fresh full countdown.
 */
export class RecordingSilenceAutoClosePolicy {
  private readonly preSpeechChunks: number;
  private readonly postSpeechSilenceChunks: number;
  private preSpeechSilence = 0;
  private postSpeechSilence = 0;
  private detectedSpeech = false;

  constructor(thresholds: RecordingSilenceAutoCloseThresholds) {
    this.preSpeechChunks = Math.max(1, thresholds.preSpeechChunks);
    this.postSpeechSilenceChunks = Math.max(
      1,
      thresholds.postSpeechSilenceChunks,
    );
  }

  observe(input: {
    speechDetected: boolean;
    holdEngaged: boolean;
  }): RecordingSilenceObservation {
    if (input.speechDetected) {
      this.detectedSpeech = true;
      this.preSpeechSilence = 0;
      this.postSpeechSilence = 0;
    }

    if (input.holdEngaged) {
      this.preSpeechSilence = 0;
      this.postSpeechSilence = 0;
      return this.observation(false, null);
    }

    if (input.speechDetected) {
      return this.observation(false, null);
    }

    if (this.detectedSpeech) {
      this.postSpeechSilence += 1;
      const shouldClose = this.postSpeechSilence >= this.postSpeechSilenceChunks;
      return this.observation(
        shouldClose,
        shouldClose ? "post-speech-silence" : null,
      );
    }

    this.preSpeechSilence += 1;
    const shouldClose = this.preSpeechSilence >= this.preSpeechChunks;
    return this.observation(
      shouldClose,
      shouldClose ? "pre-speech-silence" : null,
    );
  }

  private observation(
    shouldClose: boolean,
    reason: RecordingSilenceObservation["reason"],
  ): RecordingSilenceObservation {
    return {
      hasSpeech: this.detectedSpeech,
      shouldClose,
      reason,
    };
  }
}
