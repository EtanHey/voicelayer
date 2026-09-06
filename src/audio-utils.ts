/**
 * Shared audio utilities used by both input.ts (recording) and stt.ts (transcription).
 *
 * Extracted to break the circular dependency: stt.ts imported calculateRMS from input.ts,
 * while input.ts imported getBackend from stt.ts.
 */

import { resolveRecorderBinary } from "./recorder-binary";

const BYTES_PER_SAMPLE = 2;
const DEFAULT_NATIVE_INPUT_FORMAT = { sampleRate: 16000, channels: 1 };

/**
 * Proof that the probe actually reached the device. `parseNativeInputFormat`
 * answers 16 kHz mono for junk as readily as for a real 16 kHz mono device, so
 * without this marker a permission denial or a missing binary would be cached
 * as if it were a measurement.
 */
const NATIVE_FORMAT_MARKER = /Sample Rate\s*:\s*\d+/;

/**
 * sox's own report that the format we asked for is not the device's.
 *
 * Verified against sox 14.4.2 on macOS (`rec -V2 … -q -`, which keeps these
 * warnings while still suppressing the progress meter):
 *   rec WARN formats: can't set sample rate 8000; using 48000
 *   rec WARN formats: can't set 4 channels; using 1
 * A matching request prints nothing. The "using N" half is the device's real
 * value, so a mismatch does not merely invalidate the cache — it corrects it.
 */
const SOX_RATE_MISMATCH = /can'?t set sample rate\s+\d+;\s*using\s+(\d+)/i;
const SOX_CHANNEL_MISMATCH = /can'?t set\s+\d+\s+channels?;\s*using\s+(\d+)/i;

/**
 * `rec` stderr that means the cached format can no longer be trusted but
 * carries no replacement value — drop the cache and re-probe on the next press.
 * Over-matching is cheap here (one extra probe); under-matching leaves the
 * recorder pinned to a format the device no longer has.
 */
const RECORDER_DEVICE_FAILURE =
  /(\bFAIL\b|\berror\b|can ?'?t open|cannot open|no such device|no default)/i;

export interface NativeInputFormat {
  sampleRate: number;
  channels: number;
}

/** Raw output of one `rec` probe, or null if it could not be run at all. */
export interface NativeInputProbeOutput {
  stderr: string;
  stdout: string;
}

export type NativeInputFormatProbe = () => NativeInputProbeOutput | null;

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
 * Parse the native input preamble emitted by `rec`.
 * Extracts sample rate and channel count, capped to supported bounds with
 * DEFAULT_NATIVE_INPUT_FORMAT fallback for missing or out-of-range values.
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

/**
 * AIDEV-NOTE: Use "trim 0 0" (record zero seconds) NOT "stat" — stat processes
 * the full audio stream and blocks forever. trim 0 0 opens the device, prints
 * the preamble (with Sample Rate), then exits immediately.
 */
function probeArgs(): string[] | null {
  // AIDEV-NOTE: R-014 — never fall back to PATH `rec`. `resolveRecorderBinary()`
  // returning null means "sox is not installed"; spawning the bare name would
  // still open the microphone if `rec` is on PATH. The test stub is the other
  // success path, and it never returns null.
  const recBin = resolveRecorderBinary();
  if (!recBin) return null;
  return [recBin, "-n", "trim", "0", "0"];
}

/** Blocking probe. Only ever runs on a cold cache — see `detectNativeInputFormat`. */
const defaultProbe: NativeInputFormatProbe = () => {
  try {
    const args = probeArgs();
    if (!args) return null;
    const probe = Bun.spawnSync(args, {
      stdout: "pipe",
      stderr: "pipe",
    });
    return {
      // Device preamble (Input File, Channels, Sample Rate) goes to stderr
      stderr: probe.stderr.toString("utf-8"),
      stdout: probe.stdout.toString("utf-8"),
    };
  } catch (_err) {
    return null;
  }
};

let probeSync: NativeInputFormatProbe = defaultProbe;

/** The device format, or null when it has never been measured / was invalidated. */
let cachedNativeInputFormat: NativeInputFormat | null = null;

export function __setNativeInputFormatProbesForTests(overrides: {
  sync?: NativeInputFormatProbe;
}): void {
  if (overrides.sync) probeSync = overrides.sync;
}

export function __resetNativeInputFormatProbesForTests(): void {
  probeSync = defaultProbe;
}

/**
 * Turn raw probe output into a format, or null when the probe never reached
 * the device. Null is the "do not cache this" signal.
 */
function readProbeOutput(
  output: NativeInputProbeOutput | null,
): NativeInputFormat | null {
  if (!output) return null;
  const combined = `${output.stderr}\n${output.stdout}`;
  if (!NATIVE_FORMAT_MARKER.test(combined)) return null;
  return parseNativeInputFormat(combined);
}

/**
 * Detect the native sample rate and channel count of the default input device.
 *
 * AIDEV-NOTE: Some devices only support specific rates or channel counts.
 * Recording at the native format avoids sox-side format coercion when piping
 * to stdout; the recorder downmixes/resamples the resulting PCM explicitly.
 *
 * AIDEV-NOTE: the result is cached for the life of the daemon because this used
 * to run `rec -n trim 0 0` on EVERY F5 press — 160-220 ms of opening the mic
 * just to read its sample rate, in front of a capture that was already losing
 * the speaker's opening words (docs.local/recon-2026-09-06/capture-start-latency.md).
 * A stale cache is corrected from the recorder's own stderr — see
 * `noteRecorderStderrForNativeInputFormat`. A probe that fails is NOT cached,
 * so a device that is briefly unavailable does not pin the default format for
 * the life of the daemon.
 */
export function detectNativeInputFormat(): NativeInputFormat {
  if (cachedNativeInputFormat) return cachedNativeInputFormat;
  const format = readProbeOutput(probeSync());
  if (!format) return DEFAULT_NATIVE_INPUT_FORMAT;
  cachedNativeInputFormat = format;
  return format;
}

export function detectNativeSampleRate(): number {
  return detectNativeInputFormat().sampleRate;
}

/** Force the next `detectNativeInputFormat()` to re-probe the device. */
export function resetNativeInputFormatCache(): void {
  cachedNativeInputFormat = null;
}

/** The cached format without probing — diagnostics only. */
export function peekNativeInputFormatCache(): NativeInputFormat | null {
  return cachedNativeInputFormat;
}

/**
 * Feed `rec`'s stderr back in after a recording.
 *
 * Two things can be in there. sox may report that the format we asked for was
 * not the device's, naming the value it used instead — that corrects the cache
 * outright, no probe needed. Anything else that reads as a device failure just
 * drops the cache so the next press re-measures.
 *
 * AIDEV-NOTE: this is what keeps the cached format honest when the microphone
 * is swapped, which is the one case nothing else on this side can see. The
 * Settings > Audio picker writes the macOS default input device via CoreAudio
 * from Swift (flow-bar/Sources/VoiceBarUI/PillContextMenuController.swift
 * `selectInputDevice`) and never tells the daemon, and macOS switches the
 * default on its own when e.g. AirPods connect. sox does not fail on a
 * mismatch — it silently coerces — so without the `-V2` warnings the recorder
 * would keep resampling against a format the device no longer has, which is
 * exactly the streaming buffer-overrun the recorder spawn's note warns about.
 *
 * @returns the device's real format when sox named it, `"invalidated"` when the
 *   cache was merely dropped, or null when the stderr said nothing relevant.
 */
export function noteRecorderStderrForNativeInputFormat(
  stderr: string,
): NativeInputFormat | "invalidated" | null {
  if (!stderr) return null;

  const rate = stderr.match(SOX_RATE_MISMATCH);
  const channels = stderr.match(SOX_CHANNEL_MISMATCH);
  if (rate || channels) {
    const base = cachedNativeInputFormat ?? DEFAULT_NATIVE_INPUT_FORMAT;
    // Reuse the bounds-checking in parseNativeInputFormat rather than trusting
    // the warning's digits.
    const corrected = parseNativeInputFormat(
      `Sample Rate : ${rate ? rate[1] : base.sampleRate}\n` +
        `Channels : ${channels ? channels[1] : base.channels}`,
    );
    cachedNativeInputFormat = corrected;
    return corrected;
  }

  if (RECORDER_DEVICE_FAILURE.test(stderr)) {
    resetNativeInputFormatCache();
    return "invalidated";
  }

  return null;
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
 * Downmix interleaved PCM16 audio to mono by keeping each frame's dominant peak.
 * This preserves valid anti-phase stereo input instead of averaging it into
 * silence before VAD/STT. Partial trailing frames are intentionally dropped via
 * Math.floor.
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
    let dominantSample = 0;
    let dominantAbs = -1;
    const frameOffset = frame * frameBytes;
    for (let channel = 0; channel < channels; channel++) {
      const sample = inputView.getInt16(
        frameOffset + channel * BYTES_PER_SAMPLE,
        true,
      );
      const sampleAbs = Math.abs(sample);
      if (sampleAbs > dominantAbs) {
        dominantSample = sample;
        dominantAbs = sampleAbs;
      }
    }
    outputView.setInt16(frame * BYTES_PER_SAMPLE, dominantSample, true);
  }

  return output;
}
