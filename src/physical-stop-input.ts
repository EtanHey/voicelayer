export const STOP_CAPTURE_DRAIN_MS = 250;
export const STOP_POLL_MS = 50;
// 250ms drain + 50ms poll + 50ms IPC/scheduling margin. An audio-relative
// approximation, not a reconstructed key-down clock. See docs.local/P5b/DONE.md.
export const PHYSICAL_STOP_WINDOW_MS = STOP_CAPTURE_DRAIN_MS + STOP_POLL_MS + 50;

export function physicalStopInput(pcmData: Uint8Array, physicalPress: boolean, sampleRate = 16_000) {
  const frames = pcmData.byteLength / 2;
  const windowStartFrame = Math.max(0, frames - Math.floor(sampleRate * PHYSICAL_STOP_WINDOW_MS / 1000));
  const candidateFrames: number[] = [];
  const keep = (reason: string) => ({ pcmData, reason, candidateFrames, windowStartFrame });
  if (!physicalPress) return keep("nonmanual");
  if (!Number.isInteger(sampleRate) || sampleRate < 1000 || !Number.isInteger(frames) || frames === 0) return keep("invalid-pcm");

  // Inspect only the final second, retaining 20ms of local noise context.
  // 1ms RMS bins reject isolated sample glitches; a 5ms quiet interval separates
  // impulses so ringing within one click is not counted as several clicks.
  const step = Math.max(1, Math.round(sampleRate / 1000));
  const start = Math.max(0, frames - sampleRate);
  const view = new DataView(pcmData.buffer, pcmData.byteOffset, pcmData.byteLength);
  const bins: number[] = [];
  for (let frame = start; frame < frames; frame += step) {
    const end = Math.min(frames, frame + step);
    let sum = 0;
    for (let j = frame; j < end; j++) sum += view.getInt16(j * 2, true) ** 2;
    bins.push(Math.sqrt(sum / (end - frame)));
  }
  const begin = Math.max(20, Math.ceil((windowStartFrame - start) / step));
  for (let i = begin; i < bins.length; i++) {
    const context = bins.slice(i - 20, i - 3).sort((a, b) => a - b);
    const base = context[Math.floor(context.length / 2)]!;
    const prior = Math.max(1, ...bins.slice(i - 2, i));
    if (bins[i]! < Math.max(200, base * 6) || bins[i]! < prior * 3) continue;
    const onsetThreshold = Math.max(60, base * 3);
    let onset = i;
    for (let j = Math.max(begin, i - 10); j <= i; j++) {
      if (bins[j]! >= onsetThreshold) { onset = j; break; }
    }
    candidateFrames.push(start + onset * step);
    // A sharp rise without a prompt return to background is not a clear click.
    let end = i + 1;
    const limit = Math.min(bins.length - 4, i + 81);
    while (end < limit && Math.max(...bins.slice(end, end + 5)) > Math.max(100, base * 2)) end++;
    if (end >= limit) return keep("unclear-transient");
    i = end + 4;
  }
  if (candidateFrames.length === 0) return keep("no-clear-transient");
  if (candidateFrames.length !== 1) return keep("ambiguous-transients");
  const cutFrame = Math.max(windowStartFrame, candidateFrames[0]! - Math.round(sampleRate * 0.005));
  return { ...keep("cut"), pcmData: pcmData.slice(0, cutFrame * 2) };
}
