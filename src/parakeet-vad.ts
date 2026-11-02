/** Offline empty-response guard. Never shares the live capture's RNN state. */
import { createHash } from "crypto";

// A blind Whisper retry on measured VAD-negative empties reintroduced likely
// hallucinated words. Use the lowest tested SPEED threshold so quiet speech
// can still request fallback. Detector-negative is not acoustic silence proof.
export const PARAKEET_EMPTY_SPEECH_THRESHOLD = 0.3;
export interface ParakeetSpeechEvidence {
  status: "COMPLETE" | "UNKNOWN";
  threshold: number;
  inputSha256?: string;
  frames?: number;
  analyzedFrames?: number;
  speechFrames?: number;
  maxProbability?: number;
  /** Actual per-window outputs, including partial analysis on failure. */
  probabilities?: number[];
  errorType?: string;
}

export async function probeParakeetSpeech(path: string): Promise<ParakeetSpeechEvidence> {
  const threshold = PARAKEET_EMPTY_SPEECH_THRESHOLD;
  const probabilities: number[] = [];
  let inputSha256: string | undefined, frames: number | undefined;
  let analyzedFrames = 0, speechFrames = 0, maxProbability = 0;
  try {
    if (process.env.VOICELAYER_TEST_ISOLATED === "1") throw new Error("Inject VAD under the test preload");
    const bytes = new Uint8Array(await Bun.file(path).arrayBuffer());
    inputSha256 = createHash("sha256").update(bytes).digest("hex");
    // Reuse the same strict geometry check as the decoder router. This import
    // is lazy: neither an ordinary test nor a status read loads ONNX/model data.
    const { parakeetWavInfo } = await import("./parakeet-backend");
    const info = parakeetWavInfo(bytes);
    frames = info.frames;
    const data = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    let offset = 12, begin = -1;
    while (offset + 8 <= bytes.length) {
      const size = data.getUint32(offset + 4, true);
      if (Buffer.from(bytes.subarray(offset, offset + 4)).toString() === "data") { begin = offset + 8; break; }
      offset += 8 + size + size % 2;
    }
    if (begin < 0) throw new Error("Missing PCM data");
    const { createVADSession, VAD_CHUNK_SAMPLES } = await import("./vad");
    const session = await createVADSession();
    for (let frame = 0; frame < info.frames; frame += VAD_CHUNK_SAMPLES) {
      const count = Math.min(VAD_CHUNK_SAMPLES, info.frames - frame);
      const chunk = new Uint8Array(VAD_CHUNK_SAMPLES * 2);
      chunk.set(bytes.subarray(begin + frame * 2, begin + (frame + count) * 2));
      const probability = await session.process(chunk);
      if (!Number.isFinite(probability) || probability < 0 || probability > 1) throw new Error("Invalid speech probability");
      probabilities.push(probability);
      maxProbability = Math.max(maxProbability, probability);
      if (probability >= threshold) speechFrames += count;
      analyzedFrames += count;
    }
    return { status: "COMPLETE", threshold, frames, analyzedFrames, speechFrames, maxProbability, inputSha256, probabilities };
  } catch (error) {
    return { status: "UNKNOWN", threshold, inputSha256, frames, analyzedFrames, speechFrames, maxProbability, probabilities,
      errorType: error instanceof Error ? error.name : "unknown" };
  }
}
