/**
 * Mid-recording microphone loss (MICDROP2, Etan 2026-10-19: "my mic died mid-transcript").
 *
 * AIDEV-NOTE: a loss is DECIDED only by OS evidence, never by the signal:
 *   - "recorder-ended": the recorder's stdout reached EOF (sox exited) before we tore it down;
 *   - "device-removed" / "device-not-alive": VoiceBar's CoreAudio listener saw the input device
 *     that was the default when the capture began leave the device list, or report
 *     kAudioDevicePropertyDeviceIsAlive = false (checked on device-list, alive and default-input
 *     changes; `input_device_lost` socket command).
 * Signal flatness and byte timing never stop or label a recording: a noise-gated live mic streams
 * exact zeros through a thinking pause. Once evidence exists, flatness only LOCATES the boundary:
 * the start of the trailing run of chunks spanning <= 2 LSB (zeros, +/-1 dither, constant DC; the
 * 06:33 take in docs.local/HALLU1/DONE.md died at ~22.3 s and sox kept streaming {-1, 0, +1}).
 * The archive always keeps every captured byte; only the STT input stops at the boundary.
 */

export type MicLossReason = "recorder-ended" | "device-removed" | "device-not-alive";
export const DEVICE_LOSS_REASONS = ["device-removed", "device-not-alive"] as const;
export type DeviceLossReason = (typeof DEVICE_LOSS_REASONS)[number];

export interface MicDisconnect {
  reason: MicLossReason;
  /** Offset into the kept recording where signal was lost; null when it never had any. */
  atMs: number | null;
  /** Leading bytes of the kept PCM handed to STT. */
  decodeBytes: number;
}

/** Widest max-min a dead device produces: zeros, +/-1 dither, or constant DC. Shared with HALLU1. */
export const DEAD_DEVICE_MAX_RANGE_LSB = 2;

/** True when 16-bit frames [first, last) of `view` span at most DEAD_DEVICE_MAX_RANGE_LSB. */
export function isDeadDevicePcm(view: DataView, firstFrame: number, lastFrame: number): boolean {
  let min = Infinity;
  let max = -Infinity;
  for (let frame = firstFrame; frame < lastFrame; frame++) {
    const sample = view.getInt16(frame * 2, true);
    if (sample < min) min = sample;
    if (sample > max) max = sample;
    if (max - min > DEAD_DEVICE_MAX_RANGE_LSB) return false;
  }
  return true;
}

export function isDeadDeviceChunk(chunk: Uint8Array): boolean {
  const view = new DataView(chunk.buffer, chunk.byteOffset, chunk.byteLength);
  return isDeadDevicePcm(view, 0, Math.floor(chunk.byteLength / 2));
}

/** Locates the loss in a finished capture's chunks (16-bit mono, kept order). Needs OS evidence. */
export function locateMicLoss(
  chunks: Uint8Array[],
  reason: MicLossReason,
  sampleRate: number,
): MicDisconnect {
  let boundary = chunks.length;
  while (boundary > 0 && isDeadDeviceChunk(chunks[boundary - 1]!)) boundary--;
  const totalBytes = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  // Never a live chunk: there is no moment it was lost, and the decode input stays whole.
  if (boundary === 0) return { reason, atMs: null, decodeBytes: totalBytes };
  const decodeBytes = chunks.slice(0, boundary).reduce((sum, chunk) => sum + chunk.byteLength, 0);
  return { reason, atMs: Math.round((decodeBytes / 2 / sampleRate) * 1000), decodeBytes };
}

export function micDisconnectClock(ms: number): string {
  const totalSeconds = Math.max(0, Math.round(ms / 1000));
  return `${Math.floor(totalSeconds / 60)}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

/** The History note. */
export function micDisconnectNote(loss: MicDisconnect): string {
  return loss.atMs === null ? "Mic produced no signal" : `Mic disconnected at ${micDisconnectClock(loss.atMs)}`;
}
