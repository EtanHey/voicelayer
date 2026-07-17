/** Truthful playback-amplitude extraction for VoiceBar waveforms. */

export const PLAYBACK_AMPLITUDE_INTERVAL_MS = 50;
export const PLAYBACK_AMPLITUDE_SAMPLE_RATE = 1000;
export const PLAYBACK_AMPLITUDE_MAX_DURATION_MS = 20 * 60 * 1000;
export const PLAYBACK_AMPLITUDE_MAX_PCM_BYTES =
  (PLAYBACK_AMPLITUDE_SAMPLE_RATE * PLAYBACK_AMPLITUDE_MAX_DURATION_MS * 2) /
  1000;
export const PLAYBACK_AMPLITUDE_MAX_ENVELOPE_SAMPLES =
  PLAYBACK_AMPLITUDE_MAX_DURATION_MS / PLAYBACK_AMPLITUDE_INTERVAL_MS;
export const PLAYBACK_AMPLITUDE_DECODE_TIMEOUT_MS = 30_000;
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

export interface PlaybackAmplitudeDecoderTask {
  result: Promise<PlaybackAmplitudeDecoderResult>;
  cancel: () => void;
}

export type AsyncPlaybackAmplitudeDecoder = (
  command: string[],
) => PlaybackAmplitudeDecoderTask;

export interface PlaybackAmplitudeExtraction {
  result: Promise<PlaybackAmplitudeEnvelope>;
  cancel: () => void;
}

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
  if (
    pcm16.byteLength === 0 ||
    pcm16.byteLength % 2 !== 0 ||
    !Number.isFinite(sampleRate) ||
    sampleRate <= 0 ||
    !Number.isFinite(intervalMs) ||
    intervalMs <= 0
  ) {
    return unavailableEnvelope();
  }

  const maximumPcmBytes =
    (sampleRate * PLAYBACK_AMPLITUDE_MAX_DURATION_MS * 2) / 1000;
  const samplesPerWindow = (sampleRate * intervalMs) / 1000;
  if (
    !Number.isSafeInteger(maximumPcmBytes) ||
    pcm16.byteLength > maximumPcmBytes ||
    !Number.isSafeInteger(samplesPerWindow) ||
    samplesPerWindow < 1
  ) {
    return unavailableEnvelope();
  }

  const sampleCount = pcm16.byteLength / 2;
  if (
    Math.ceil(sampleCount / samplesPerWindow) >
    PLAYBACK_AMPLITUDE_MAX_ENVELOPE_SAMPLES
  ) {
    return unavailableEnvelope();
  }
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
    maxBuffer: PLAYBACK_AMPLITUDE_MAX_PCM_BYTES + 1,
    timeout: PLAYBACK_AMPLITUDE_DECODE_TIMEOUT_MS,
  });
  return {
    exitCode: result.exitCode,
    stdout: new Uint8Array(result.stdout),
  };
}

function runFFmpegAsync(command: string[]): PlaybackAmplitudeDecoderTask {
  const subprocess = Bun.spawn(command, {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "ignore",
    maxBuffer: PLAYBACK_AMPLITUDE_MAX_PCM_BYTES + 1,
    timeout: PLAYBACK_AMPLITUDE_DECODE_TIMEOUT_MS,
  });
  let cancelled = false;
  return {
    result: Promise.all([
      subprocess.exited,
      new Response(subprocess.stdout).arrayBuffer(),
    ]).then(([exitCode, stdout]) => ({
      exitCode,
      stdout: new Uint8Array(stdout),
    })),
    cancel: () => {
      if (cancelled) return;
      cancelled = true;
      try {
        subprocess.kill("SIGTERM");
      } catch {}
    },
  };
}

function playbackAmplitudeCommand(audioFile: string): string[] {
  return [
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
  ];
}

export function extractPlaybackAmplitudeEnvelope(
  audioFile: string,
  runDecoder: PlaybackAmplitudeDecoder = runFFmpeg,
): PlaybackAmplitudeEnvelope {
  try {
    const result = runDecoder(playbackAmplitudeCommand(audioFile));
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

export function startPlaybackAmplitudeEnvelopeExtraction(
  audioFile: string,
  runDecoder: AsyncPlaybackAmplitudeDecoder = runFFmpegAsync,
): PlaybackAmplitudeExtraction {
  try {
    const decoder = runDecoder(playbackAmplitudeCommand(audioFile));
    return {
      cancel: decoder.cancel,
      result: decoder.result
        .then((result) => {
          if (result.exitCode !== 0 || result.stdout.byteLength === 0) {
            return unavailableEnvelope();
          }
          return buildPlaybackAmplitudeEnvelope(
            result.stdout,
            PLAYBACK_AMPLITUDE_SAMPLE_RATE,
          );
        })
        .catch(() => unavailableEnvelope()),
    };
  } catch {
    return {
      cancel: () => {},
      result: Promise.resolve(unavailableEnvelope()),
    };
  }
}

export async function extractPlaybackAmplitudeEnvelopeAsync(
  audioFile: string,
  runDecoder: AsyncPlaybackAmplitudeDecoder = runFFmpegAsync,
): Promise<PlaybackAmplitudeEnvelope> {
  return startPlaybackAmplitudeEnvelopeExtraction(audioFile, runDecoder).result;
}
