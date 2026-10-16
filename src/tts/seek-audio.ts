import { unlinkSync } from "fs";
import { throwIfAbortedSafe } from "../abort";
import { resolveBinaryAsync } from "../resolve-binary";
import { runAudioCommand } from "./long-read-audio";

let sliceCounter = 0;
export function disposeSeekSlice(file?: string): void {
  if (file) { try { unlinkSync(file); } catch {} }
}

/** Preflight a replacement without stopping the player that owns the utterance. */
export async function prepareSeekSlice(file: string, offsetMs: number, signal: AbortSignal): Promise<string | undefined> {
  throwIfAbortedSafe(signal);
  if (offsetMs === 0) return undefined;
  const slice = `${file}.${process.pid}-${++sliceCounter}.seek.wav`;
  try {
    const ffmpeg = await resolveBinaryAsync("ffmpeg");
    throwIfAbortedSafe(signal);
    if (!ffmpeg) throw new Error("ffmpeg unavailable for seek");
    await runAudioCommand([ffmpeg, "-nostdin", "-y", "-ss", String(offsetMs / 1000),
      "-i", file, "-vn", "-c:a", "pcm_s16le", slice], signal);
    return slice;
  } catch (error) {
    disposeSeekSlice(slice);
    throw error;
  }
}
