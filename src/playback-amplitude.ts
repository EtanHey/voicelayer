/** Truthful playback-amplitude extraction for VoiceBar waveforms. */

export const PLAYBACK_AMPLITUDE_INTERVAL_MS = 50;
export const PLAYBACK_AMPLITUDE_SAMPLE_RATE = 1000;
const PLAYBACK_AMPLITUDE_DBFS_FLOOR = -60;
const PCM16_FULL_SCALE = 32768;

export type PlaybackAmplitudeEnvelope =
  | {
      source: "decoded-rms";
      sample_interval_ms: number;
      samples: number[];
    }
  | {
      source: "unavailable";
      sample_interval_ms: number;
      samples: [];
    };

export interface PlaybackAmplitudeDecoderResult {
  exitCode: number;
  stdout: Uint8Array;
}

export type PlaybackAmplitudeDecoder = (
  command: string[],
) => PlaybackAmplitudeDecoderResult;

function unavailableEnvelope(): PlaybackAmplitudeEnvelope {
  return {
    source: "unavailable",
    sample_interval_ms: PLAYBACK_AMPLITUDE_INTERVAL_MS,
    samples: [],
  };
}

function normalizedRMS(sumSquares: number, sampleCount: number): number {
  if (sampleCount <= 0 || sumSquares <= 0) return 0;
  const rms = Math.sqrt(sumSquares / sampleCount) / PCM16_FULL_SCALE;
  if (!Number.isFinite(rms) || rms <= 0) return 0;
  const dbfs = 20 * Math.log10(rms);
  const normalized =
    (dbfs - PLAYBACK_AMPLITUDE_DBFS_FLOOR) /
    -PLAYBACK_AMPLITUDE_DBFS_FLOOR;
  return Math.round(Math.max(0, Math.min(1, normalized)) * 10_000) / 10_000;
}

export function buildPlaybackAmplitudeEnvelope(
  pcm16: Uint8Array,
  sampleRate: number,
  intervalMs = PLAYBACK_AMPLITUDE_INTERVAL_MS,
): PlaybackAmplitudeEnvelope {
  const sampleCount = Math.floor(pcm16.byteLength / 2);
  if (
    sampleCount === 0 ||
    pcm16.byteLength % 2 !== 0 ||
    !Number.isFinite(sampleRate) ||
    sampleRate <= 0 ||
    !Number.isFinite(intervalMs) ||
    intervalMs <= 0
  ) {
    return unavailableEnvelope();
  }

  const samplesPerWindow = Math.max(
    1,
    Math.round((sampleRate * intervalMs) / 1000),
  );
  const view = new DataView(
    pcm16.buffer,
    pcm16.byteOffset,
    sampleCount * 2,
  );
  const samples: number[] = [];

  for (let start = 0; start < sampleCount; start += samplesPerWindow) {
    const end = Math.min(sampleCount, start + samplesPerWindow);
    let sumSquares = 0;
    for (let index = start; index < end; index++) {
      const sample = view.getInt16(index * 2, true);
      sumSquares += sample * sample;
    }
    samples.push(normalizedRMS(sumSquares, end - start));
  }

  return {
    source: "decoded-rms",
    sample_interval_ms: intervalMs,
    samples,
  };
}

function runFFmpeg(command: string[]): PlaybackAmplitudeDecoderResult {
  const result = Bun.spawnSync(command, {
    stdout: "pipe",
    stderr: "ignore",
  });
  return {
    exitCode: result.exitCode,
    stdout: new Uint8Array(result.stdout),
  };
}

export function extractPlaybackAmplitudeEnvelope(
  audioFile: string,
  runDecoder: PlaybackAmplitudeDecoder = runFFmpeg,
): PlaybackAmplitudeEnvelope {
  try {
    const result = runDecoder([
      "ffmpeg",
      "-v",
      "error",
      "-i",
      audioFile,
      "-vn",
      "-ac",
      "1",
      "-ar",
      String(PLAYBACK_AMPLITUDE_SAMPLE_RATE),
      "-f",
      "s16le",
      "pipe:1",
    ]);
    if (result.exitCode !== 0 || result.stdout.byteLength === 0) {
      return unavailableEnvelope();
    }
    return buildPlaybackAmplitudeEnvelope(
      result.stdout,
      PLAYBACK_AMPLITUDE_SAMPLE_RATE,
    );
  } catch {
    return unavailableEnvelope();
  }
}
