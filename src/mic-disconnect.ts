/**
 * Mid-recording microphone loss (MICDROP2, Etan 2026-10-19: "my mic died mid-transcript").
 *
 * AIDEV-NOTE: a loss is DECIDED only by OS evidence, never by the signal:
 *   - "recorder-ended": the recorder's stdout reached EOF (sox exited) before we tore it down;
 *   - "device-removed" / "device-not-alive": VoiceBar's CoreAudio listener saw this capture's
 *     input device leave the device list or report kAudioDevicePropertyDeviceIsAlive = false
 *     (`input_device_lost`, bound to the capture's `capture_id`; stale reports are rejected).
 * Signal flatness and byte timing never stop or label a recording: a noise-gated live mic streams
 * exact zeros through a thinking pause. The loss time shown is the observed one: the end of the
 * kept audio, which the recorder delivered before the evidence. Audio before it stays in the decode
 * input even when flat, because a gated pause before an unplug is indistinguishable from a dead
 * device (Sol R1 #4). The start of the trailing run of chunks spanning <= 2 LSB (zeros, +/-1
 * dither, constant DC; HALLU1's 06:33 take) is only journaled, as an estimate of the last signal.
 */

export type MicLossReason = "recorder-ended" | "device-removed" | "device-not-alive";
export const DEVICE_LOSS_REASONS = ["device-removed", "device-not-alive"] as const;
export type DeviceLossReason = (typeof DEVICE_LOSS_REASONS)[number];

export interface MicDisconnect {
  reason: MicLossReason;
  /** Observed loss time: the length of the kept recording. Null when it never carried signal. */
  atMs: number | null;
  /** Estimate only (journal): where the trailing flat run starts. Null when never live. */
  lastSignalMs: number | null;
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

/** Describes the loss in a finished capture's chunks (16-bit mono, kept order). Needs OS evidence. */
export function locateMicLoss(
  chunks: Uint8Array[],
  reason: MicLossReason,
  sampleRate: number,
): MicDisconnect {
  const ms = (list: Uint8Array[]) =>
    Math.round((list.reduce((sum, chunk) => sum + chunk.byteLength, 0) / 2 / sampleRate) * 1000);
  let boundary = chunks.length;
  while (boundary > 0 && isDeadDeviceChunk(chunks[boundary - 1]!)) boundary--;
  // Never a live chunk: there is no moment it was lost.
  if (boundary === 0) return { reason, atMs: null, lastSignalMs: null };
  return { reason, atMs: ms(chunks), lastSignalMs: ms(chunks.slice(0, boundary)) };
}

export function micDisconnectClock(ms: number): string {
  const totalSeconds = Math.max(0, Math.round(ms / 1000));
  return `${Math.floor(totalSeconds / 60)}:${String(totalSeconds % 60).padStart(2, "0")}`;
}

/** The History note. */
export function micDisconnectNote(loss: MicDisconnect): string {
  return loss.atMs === null ? "Mic produced no signal" : `Mic disconnected at ${micDisconnectClock(loss.atMs)}`;
}
