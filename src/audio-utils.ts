/**
 * Shared audio utilities used by both input.ts (recording) and stt.ts (transcription).
 *
 * Extracted to break the circular dependency: stt.ts imported calculateRMS from input.ts,
 * while input.ts imported getBackend from stt.ts.
 */

const BYTES_PER_SAMPLE = 2;

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
export function detectNativeSampleRate(): number {
  try {
    const probe = Bun.spawnSync(["rec", "-n", "stat"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    // Device info may be on stdout or stderr depending on sox version
    const stdout = probe.stdout.toString("utf-8");
    const stderr = probe.stderr.toString("utf-8");
    const combined = stdout + "\n" + stderr;
    const match = combined.match(/Sample Rate\s*:\s*(\d+)/);
    if (match) {
      const rate = parseInt(match[1], 10);
      if (rate > 0 && rate <= 192000) return rate;
    }
  } catch {}
  return 16000;
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
    const interpolated = Math.round(
      sampleLow * (1 - frac) + sampleHigh * frac,
    );
    outputView.setInt16(i * BYTES_PER_SAMPLE, interpolated, true);
  }

  return output;
}
