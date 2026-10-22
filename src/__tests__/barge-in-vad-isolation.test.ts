import { describe, expect, it, spyOn } from "bun:test";
import { IsolatedSileroVoiceActivityDetector, VAD_CHUNK_BYTES, processVADChunk, resetVAD } from "../vad";
import { createBargeInMonitor } from "../soundlayer/barge-in";
import { createDefaultSoundLayer } from "../soundlayer/default";

// Generated PCM only: exercise the real ONNX recurrence/context, never a mic.
function pcm(seed: number): Uint8Array {
  const chunk = new Uint8Array(VAD_CHUNK_BYTES);
  const view = new DataView(chunk.buffer);
  for (let i = 0; i < chunk.length / 2; i++) {
    view.setInt16(i * 2, Math.round(Math.sin((i + seed * 31) * 0.13) * 12000), true);
  }
  return chunk;
}
const firstChunk = pcm(1);
const chunks = [firstChunk, pcm(2), pcm(3), pcm(4)];
async function baseline(): Promise<number[]> {
  await resetVAD();
  const vad = new IsolatedSileroVoiceActivityDetector();
  const scores: number[] = [];
  for (const chunk of chunks) scores.push(await vad.processChunk(chunk));
  return scores;
}

describe("barge-in VAD ownership", () => {
  it("keeps B identical to its independent baseline when A processes and resets", async () => {
    const expected = await baseline();
    await resetVAD();
    const a = new IsolatedSileroVoiceActivityDetector();
    const b = new IsolatedSileroVoiceActivityDetector();
    const actual: number[] = [];
    for (const chunk of chunks) {
      await a.processChunk(pcm(99));
      await a.reset();
      actual.push(await b.processChunk(chunk));
    }
    expect(actual).toEqual(expected);
  });

  it("keeps B recurrence intact across monitor A stop and live recording resets", async () => {
    const expected = await baseline();
    await resetVAD();
    const a = new IsolatedSileroVoiceActivityDetector();
    const b = new IsolatedSileroVoiceActivityDetector();
    const monitor = createBargeInMonitor(a, {
      playbackStartedAtMs: 0, settleMs: 10000, onSpeechStart() {},
    });
    const actual = [await b.processChunk(firstChunk)];
    await monitor.pushAudioChunk(pcm(99), 0);
    monitor.stop();
    await a.reset();
    await processVADChunk(pcm(77));
    await resetVAD();
    for (const chunk of chunks.slice(1)) actual.push(await b.processChunk(chunk));
    expect(actual).toEqual(expected);
  });

  it("allocates different VAD owners for default monitors and layer.vad", async () => {
    const owners: IsolatedSileroVoiceActivityDetector[] = [];
    const spy = spyOn(IsolatedSileroVoiceActivityDetector.prototype, "processChunk").mockImplementation(function (this: IsolatedSileroVoiceActivityDetector) {
      owners.push(this);
      return Promise.resolve(0);
    });
    const layer = createDefaultSoundLayer();
    const options = { playbackStartedAtMs: 0, onSpeechStart() {} };
    const a = layer.bargeIn!.monitorDuringPlayback(options);
    const b = layer.bargeIn!.monitorDuringPlayback(options);
    try {
      await a.pushAudioChunk(pcm(1), 0);
      const ownerA = owners.at(-1);
      await b.pushAudioChunk(pcm(2), 0);
      const ownerB = owners.at(-1);
      expect(ownerA).not.toBe(ownerB);
      expect(ownerA).not.toBe(layer.vad);
      expect(ownerB).not.toBe(layer.vad);
      a.stop();
      const before = owners.length;
      await a.pushAudioChunk(pcm(3), 0);
      expect(owners.length).toBe(before);
      await b.pushAudioChunk(pcm(4), 0);
      expect(owners.at(-1)).toBe(ownerB);
    } finally {
      a.stop(); b.stop();
      await Promise.all([a.exited, b.exited]);
      spy.mockRestore();
    }
  });
});
