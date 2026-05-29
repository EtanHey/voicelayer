import { describe, expect, it } from "bun:test";
import { createBargeInMonitor } from "../soundlayer/barge-in";
import type { VoiceActivityDetector } from "../soundlayer";

function scriptedVad(probabilities: number[]): VoiceActivityDetector {
  return {
    async processChunk() {
      return probabilities.shift() ?? 0;
    },
    isSpeech(probability) {
      return probability >= 0.5;
    },
    silenceChunksForMode() {
      return 1;
    },
    async reset() {},
  };
}

describe("SoundLayer barge-in monitor", () => {
  it("rejects echo-like speech during the playback settle window", async () => {
    const onsets: number[] = [];
    const monitor = createBargeInMonitor(scriptedVad([0.92]), {
      playbackStartedAtMs: 1_000,
      settleMs: 120,
      minSpeechChunks: 1,
      onSpeechStart: (onset) => onsets.push(onset.onset_ms),
    });

    const decision = await monitor.pushAudioChunk(new Uint8Array(1024), 1_064);

    expect(decision).toEqual({
      speechStarted: false,
      rejectedReason: "settle-window",
    });
    expect(onsets).toEqual([]);
    expect(monitor.getMetrics()).toMatchObject({
      processed_chunks: 1,
      false_interrupts: 1,
      confirmed_interrupts: 0,
      false_interrupt_rate: 1,
    });
  });

  it("confirms user onset after the settle window and required speech chunks", async () => {
    const onsets: number[] = [];
    const monitor = createBargeInMonitor(scriptedVad([0.93, 0.89]), {
      playbackStartedAtMs: 1_000,
      settleMs: 120,
      minSpeechChunks: 2,
      onSpeechStart: (onset) => onsets.push(onset.onset_ms),
    });

    await expect(
      monitor.pushAudioChunk(new Uint8Array(1024), 1_160),
    ).resolves.toEqual({
      speechStarted: false,
      rejectedReason: "confirmation-window",
    });
    await expect(
      monitor.pushAudioChunk(new Uint8Array(1024), 1_192),
    ).resolves.toMatchObject({
      speechStarted: true,
      onset_ms: 160,
      probability: 0.89,
    });

    expect(onsets).toEqual([160]);
    expect(monitor.getMetrics()).toMatchObject({
      processed_chunks: 2,
      false_interrupts: 0,
      confirmed_interrupts: 1,
      false_interrupt_rate: 0,
    });
  });
});
