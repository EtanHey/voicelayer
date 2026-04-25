/**
 * Shared audio utilities used by both input.ts (recording) and stt.ts (transcription).
 *
 * Extracted to break the circular dependency: stt.ts imported calculateRMS from input.ts,
 * while input.ts imported getBackend from stt.ts.
 */

import { resolveBinary } from "./resolve-binary";

const BYTES_PER_SAMPLE = 2;
const DEFAULT_NATIVE_INPUT_FORMAT = { sampleRate: 16000, channels: 1 };

export interface NativeInputFormat {
  sampleRate: number;
  channels: number;
}

/**
 * Calculate RMS energy of a 16-bit signed PCM audio buffer.
 *
 * AIDEV-NOTE: This is NOT used for voice activity detection (energy-based VAD
 * was removed in Phase 2 — Silero VAD replaced it). This function is only
 * retained for Wispr Flow WebSocket volume data in stt.ts.
 */
export function calculateRMS(buffer: Uint8Array): number {
  const view = new DataView(
    buffer.buffer,
    buffer.byteOffset,
    buffer.byteLength,
  );
  const numSamples = Math.floor(buffer.byteLength / BYTES_PER_SAMPLE);
  if (numSamples === 0) return 0;

  let sumSquares = 0;
  for (let i = 0; i < numSamples; i++) {
    const sample = view.getInt16(i * BYTES_PER_SAMPLE, true); // little-endian
    sumSquares += sample * sample;
  }

  return Math.sqrt(sumSquares / numSamples);
}

/**
 * Detect the native sample rate of the default audio input device.
 * Runs `rec -n stat` which reports device info to stderr.
 * Returns the device rate, or 16000 as fallback.
 *
 * AIDEV-NOTE: Some devices (e.g., AirPods) only support specific rates (24kHz).
 * Sox can't set arbitrary rates on these devices and will silently resample,
 * which causes buffer overruns and data loss when piping to stdout.
 * Recording at the native rate avoids this entirely.
 */
export function parseNativeInputFormat(output: string): NativeInputFormat {
  const rateMatch = output.match(/Sample Rate\s*:\s*(\d+)/);
  const channelsMatch = output.match(/Channels\s*:\s*(\d+)/);
  const sampleRate = rateMatch ? parseInt(rateMatch[1], 10) : 16000;
  const channels = channelsMatch ? parseInt(channelsMatch[1], 10) : 1;

  return {
    sampleRate:
      sampleRate > 0 && sampleRate <= 192000
        ? sampleRate
        : DEFAULT_NATIVE_INPUT_FORMAT.sampleRate,
    channels:
      channels > 0 && channels <= 16
        ? channels
        : DEFAULT_NATIVE_INPUT_FORMAT.channels,
  };
}

export function detectNativeInputFormat(): NativeInputFormat {
  try {
    // AIDEV-NOTE: Use "trim 0 0" (record zero seconds) NOT "stat" — stat processes
    // the full audio stream and blocks forever. trim 0 0 opens the device, prints
    // the preamble (with Sample Rate), then exits immediately.
    const recBin =
      resolveBinary("rec", ["/opt/homebrew/bin/rec", "/usr/local/bin/rec"]) ||
      "rec";
    const probe = Bun.spawnSync([recBin, "-n", "trim", "0", "0"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    // Device preamble (Input File, Channels, Sample Rate) goes to stderr
    const stderr = probe.stderr.toString("utf-8");
    const stdout = probe.stdout.toString("utf-8");
    return parseNativeInputFormat(stderr + "\n" + stdout);
  } catch {}
  return DEFAULT_NATIVE_INPUT_FORMAT;
}

export function detectNativeSampleRate(): number {
  return detectNativeInputFormat().sampleRate;
}

/**
 * Downsample (or upsample) 16-bit signed PCM audio between sample rates.
 * Uses linear interpolation — good enough for VAD and STT.
 *
 * @param input - Raw 16-bit signed PCM bytes at fromRate
 * @param fromRate - Source sample rate (e.g., 24000)
 * @param toRate - Target sample rate (e.g., 16000)
 * @returns Resampled 16-bit signed PCM bytes at toRate
 */
export function resamplePCM16(
  input: Uint8Array,
  fromRate: number,
  toRate: number,
): Uint8Array {
  if (fromRate === toRate) return input;

  const inputView = new DataView(
    input.buffer,
    input.byteOffset,
    input.byteLength,
  );
  const inputSamples = Math.floor(input.byteLength / BYTES_PER_SAMPLE);
  if (inputSamples === 0) return new Uint8Array(0);

  const ratio = fromRate / toRate;
  const outputSamples = Math.floor(inputSamples / ratio);
  const output = new Uint8Array(outputSamples * BYTES_PER_SAMPLE);
  const outputView = new DataView(output.buffer);

  for (let i = 0; i < outputSamples; i++) {
    const srcIdx = i * ratio;
    const low = Math.floor(srcIdx);
    const high = Math.min(low + 1, inputSamples - 1);
    const frac = srcIdx - low;
    const sampleLow = inputView.getInt16(low * BYTES_PER_SAMPLE, true);
    const sampleHigh = inputView.getInt16(high * BYTES_PER_SAMPLE, true);
    const interpolated = Math.round(sampleLow * (1 - frac) + sampleHigh * frac);
    outputView.setInt16(i * BYTES_PER_SAMPLE, interpolated, true);
  }

  return output;
}

/**
 * Downmix interleaved PCM16 audio to mono by averaging each frame.
 *
 * @param input - Raw PCM16 interleaved audio
 * @param channels - Number of interleaved channels in input
 * @returns Mono PCM16 audio
 */
export function downmixPCM16ToMono(
  input: Uint8Array,
  channels: number,
): Uint8Array {
  if (channels <= 1) return input;

  const inputView = new DataView(
    input.buffer,
    input.byteOffset,
    input.byteLength,
  );
  const frameBytes = channels * BYTES_PER_SAMPLE;
  const frameCount = Math.floor(input.byteLength / frameBytes);
  const output = new Uint8Array(frameCount * BYTES_PER_SAMPLE);
  const outputView = new DataView(output.buffer);

  for (let frame = 0; frame < frameCount; frame++) {
    let sum = 0;
    const frameOffset = frame * frameBytes;
    for (let channel = 0; channel < channels; channel++) {
      sum += inputView.getInt16(
        frameOffset + channel * BYTES_PER_SAMPLE,
        true,
      );
    }
    outputView.setInt16(
      frame * BYTES_PER_SAMPLE,
      Math.round(sum / channels),
      true,
    );
  }

  return output;
}
