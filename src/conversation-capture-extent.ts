import { VAD_CHUNK_SAMPLES } from "./vad-constants";

/** Valid frame-aligned PCM16 extent, using the recorder's full-chunk and final-tail rounding. */
export function normalizedCaptureByteLength(nativeBytes: number, sampleRate: number, channels: number): number {
  const ratio = sampleRate / 16000;
  const chunkFrames = Math.ceil(VAD_CHUNK_SAMPLES * ratio);
  const frames = nativeBytes / (channels * 2);
  const fullChunks = Math.floor(frames / chunkFrames);
  const finalFrames = frames - fullChunks * chunkFrames;
  return 2 * (fullChunks * Math.floor(chunkFrames / ratio) + Math.floor(finalFrames / ratio));
}
