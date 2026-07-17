import { describe, expect, it } from "bun:test";
import {
  PLAYBACK_AMPLITUDE_INTERVAL_MS,
  buildPlaybackAmplitudeEnvelope,
  extractPlaybackAmplitudeEnvelope,
} from "../playback-amplitude";

function pcm16(samples: number[]): Uint8Array {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  samples.forEach((sample, index) => {
    view.setInt16(index * 2, sample, true);
  });
  return bytes;
}

describe("playback amplitude", () => {
  const maximumPcmBytes = 2_400_000;
  const maximumEnvelopeSamples = 24_000;

  it("builds one truthful zero sample for a silent window", () => {
    expect(
      buildPlaybackAmplitudeEnvelope(pcm16([0, 0]), 40),
    ).toEqual({
      source: "decoded-rms",
      sample_interval_ms: PLAYBACK_AMPLITUDE_INTERVAL_MS,
      samples: [0],
    });
  });

  it("preserves fixed-scale amplitude differences across windows", () => {
    const envelope = buildPlaybackAmplitudeEnvelope(
      pcm16([1000, 1000, 8000, 8000]),
      40,
    );

    expect(envelope.source).toBe("decoded-rms");
    expect(envelope.samples).toHaveLength(2);
    expect(envelope.samples[0]).toBeGreaterThan(0);
    expect(envelope.samples[1]).toBeGreaterThan(envelope.samples[0]);
    expect(envelope.samples[1]).toBeLessThanOrEqual(1);
  });

  it("does not peak-normalize otherwise identical quiet clips", () => {
    const quiet = buildPlaybackAmplitudeEnvelope(
      pcm16([1000, 1000]),
      40,
    );
    const loud = buildPlaybackAmplitudeEnvelope(
      pcm16([8000, 8000]),
      40,
    );

    expect(loud.samples[0]).toBeGreaterThan(quiet.samples[0]);
  });

  it("decodes files to mono PCM16 at the declared sample rate", () => {
    let receivedCommand: string[] = [];
    const envelope = extractPlaybackAmplitudeEnvelope(
      "/tmp/example audio.mp3",
      (command) => {
        receivedCommand = command;
        return { exitCode: 0, stdout: pcm16([0, 0]) };
      },
    );

    expect(receivedCommand).toEqual([
      "ffmpeg",
      "-v",
      "error",
      "-i",
      "/tmp/example audio.mp3",
      "-vn",
      "-ac",
      "1",
      "-ar",
      "1000",
      "-f",
      "s16le",
      "pipe:1",
    ]);
    expect(envelope).toEqual({
      source: "decoded-rms",
      sample_interval_ms: PLAYBACK_AMPLITUDE_INTERVAL_MS,
      samples: [0],
    });
  });

  it("reports unavailable instead of inventing motion when decode fails", () => {
    expect(
      extractPlaybackAmplitudeEnvelope("/tmp/corrupt.mp3", () => ({
        exitCode: 1,
        stdout: new Uint8Array(),
      })),
    ).toEqual({
      source: "unavailable",
      sample_interval_ms: PLAYBACK_AMPLITUDE_INTERVAL_MS,
      samples: [],
    });
  });

  it("reports unavailable for an empty successful decode", () => {
    expect(
      extractPlaybackAmplitudeEnvelope("/tmp/empty.mp3", () => ({
        exitCode: 0,
        stdout: new Uint8Array(),
      })),
    ).toEqual({
      source: "unavailable",
      sample_interval_ms: PLAYBACK_AMPLITUDE_INTERVAL_MS,
      samples: [],
    });
  });

  it("rejects truncated odd-byte PCM16 instead of decoding a partial frame", () => {
    expect(
      buildPlaybackAmplitudeEnvelope(new Uint8Array([1, 0, 1]), 1000),
    ).toEqual({
      source: "unavailable",
      sample_interval_ms: PLAYBACK_AMPLITUDE_INTERVAL_MS,
      samples: [],
    });
  });

  it("rejects non-finite sample rates and intervals", () => {
    const pcm = pcm16([1000, -1000]);

    for (const sampleRate of [Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(buildPlaybackAmplitudeEnvelope(pcm, sampleRate).source).toBe(
        "unavailable",
      );
    }
    for (const interval of [Number.NaN, Number.POSITIVE_INFINITY]) {
      expect(buildPlaybackAmplitudeEnvelope(pcm, 1000, interval).source).toBe(
        "unavailable",
      );
    }
  });

  it("rejects decoded audio beyond the 20-minute PCM duration bound", () => {
    expect(
      buildPlaybackAmplitudeEnvelope(
        new Uint8Array(maximumPcmBytes + 2),
        1000,
      ).source,
    ).toBe("unavailable");
  });

  it("rejects envelopes that would exceed the JSON sample bound", () => {
    expect(
      buildPlaybackAmplitudeEnvelope(
        new Uint8Array((maximumEnvelopeSamples + 1) * 2),
        1000,
        1,
      ).source,
    ).toBe("unavailable");
  });

  it("rejects intervals that do not contain a whole PCM sample count", () => {
    expect(
      buildPlaybackAmplitudeEnvelope(pcm16([1000, -1000]), 1000, 1.5).source,
    ).toBe("unavailable");
  });
});
