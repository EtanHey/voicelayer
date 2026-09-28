import { describe, expect, it } from "bun:test";
import { buildDictationReceipt } from "../dictation-receipt";

describe("dictation receipt timing", () => {
  it("rounds actual audio and monotonic post-capture processing durations", () => {
    expect(buildDictationReceipt({
      audioDurationMs: 1_234.4,
      processingStartedAtMs: 50.2,
      finalTranscriptReadyAtMs: 275.8,
    })).toEqual({
      audio_duration_ms: 1_234,
      processing_duration_ms: 226,
    });
  });

  it.each([
    { audioDurationMs: undefined, processingStartedAtMs: 1, finalTranscriptReadyAtMs: 2 },
    { audioDurationMs: 0, processingStartedAtMs: 1, finalTranscriptReadyAtMs: 2 },
    { audioDurationMs: Number.NaN, processingStartedAtMs: 1, finalTranscriptReadyAtMs: 2 },
    { audioDurationMs: 1, processingStartedAtMs: undefined, finalTranscriptReadyAtMs: 2 },
    { audioDurationMs: 1, processingStartedAtMs: 3, finalTranscriptReadyAtMs: 2 },
    { audioDurationMs: 1, processingStartedAtMs: 1, finalTranscriptReadyAtMs: 1.4 },
    { audioDurationMs: 1, processingStartedAtMs: -Number.MAX_VALUE, finalTranscriptReadyAtMs: Number.MAX_VALUE },
  ])("keeps missing or invalid timing absent", (timing) => {
    expect(buildDictationReceipt(timing)).toBeUndefined();
  });
});
