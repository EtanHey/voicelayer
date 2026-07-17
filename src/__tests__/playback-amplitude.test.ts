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
});
