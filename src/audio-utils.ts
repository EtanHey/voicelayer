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
