import { expect, it } from "bun:test";
import { createOwnedBargeInMonitor } from "../soundlayer/barge-in";
import type { VoiceActivityDetector } from "../soundlayer/contracts";

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function fixture(signal?: AbortSignal, process = async () => 0) {
  const exit = deferred<void>();
  let stops = 0;
  let starts = 0;
  let onsets = 0;
  const vad: VoiceActivityDetector = {
    processChunk: process, isSpeech: p => p > 0.5,
    reset: async () => {}, silenceChunksForMode: () => 1,
  };
  const monitor = createOwnedBargeInMonitor(vad, {
    playbackStartedAtMs: 0, minSpeechChunks: 1, signal,
    onSpeechStart() { onsets++; },
  }, () => { starts++; return { exited: exit.promise, stop() { stops++; } }; });
  return { monitor, exit, get stops() { return stops; },
    get starts() { return starts; }, get onsets() { return onsets; } };
}
it("stop is terminal and idempotent; exit waits for stream and pending inference", async () => {
  const inference = deferred<number>();
  const f = fixture(undefined, () => inference.promise);
  const chunk = f.monitor.pushAudioChunk(new Uint8Array(2), 200);
  let exited = false;
  void f.monitor.exited.then(() => { exited = true; });
  f.monitor.stop(); f.monitor.stop();
  await Promise.resolve();
  expect(f.stops).toBe(1);
  expect(exited).toBe(false);
  f.exit.resolve();
  await Promise.resolve();
  expect(exited).toBe(false);
  inference.resolve(0.9);
  expect((await chunk).speechStarted).toBe(false);
  await f.monitor.exited;
  expect(f.onsets).toBe(0);
});
it("abort waits for owned exit and surfaces the abort reason", async () => {
  const controller = new AbortController();
  const f = fixture(controller.signal);
  const failure = new Error("request disconnected");
  controller.abort(failure);
  const result = f.monitor.exited.catch(error => error);
  expect(f.stops).toBe(1);
  f.exit.resolve();
  expect(await result).toBe(failure);
});
it("pre-aborted owner never starts capture", async () => {
  const controller = new AbortController(); controller.abort(new Error("cancelled"));
  const f = fixture(controller.signal);
  f.monitor.stop(); f.exit.resolve();
  await expect(f.monitor.exited).rejects.toThrow("cancelled");
  expect(f.starts).toBe(0);
});
it("startup failure is observable", async () => {
  const error = new Error("capture admission failed");
  const f = fixture(); f.monitor.stop(); f.exit.resolve(); await f.monitor.exited;
  const monitor = createOwnedBargeInMonitor({ processChunk: async () => 0,
    isSpeech: () => false, reset: async () => {}, silenceChunksForMode: () => 1 },
    { playbackStartedAtMs: 0, onSpeechStart() {} }, () => { throw error; });
  await expect(monitor.exited).rejects.toBe(error);
});
it("inference failure terminates once and surfaces only after stream exit", async () => {
  const failure = new Error("VAD failed");
  const f = fixture(undefined, async () => { throw failure; });
  await expect(f.monitor.pushAudioChunk(new Uint8Array(2), 200)).rejects.toBe(failure);
  expect(f.stops).toBe(1);
  f.exit.resolve();
  await expect(f.monitor.exited).rejects.toBe(failure);
});
it("unexpected stream end fences future onset", async () => {
  const f = fixture(undefined, async () => 0.9);
  f.exit.resolve(); await f.monitor.exited;
  expect((await f.monitor.pushAudioChunk(new Uint8Array(2), 200)).speechStarted).toBe(false);
  expect(f.onsets).toBe(0);
});

it("stream failure is surfaced and terminates once", async () => {
  const f = fixture(); const failure = new Error("stream disconnected");
  f.exit.reject(failure);
  await expect(f.monitor.exited).rejects.toBe(failure);
  f.monitor.stop(); expect(f.stops).toBe(1);
});
it("callback failure tears down capture and remains observable", async () => {
  const exit = deferred<void>(); const failure = new Error("onset failed"); let stops = 0;
  const monitor = createOwnedBargeInMonitor({ processChunk: async () => 0.9,
    isSpeech: () => true, reset: async () => {}, silenceChunksForMode: () => 1 },
    { playbackStartedAtMs: 0, minSpeechChunks: 1, onSpeechStart() { throw failure; } },
    () => ({ exited: exit.promise, stop() { stops++; } }));
  await expect(monitor.pushAudioChunk(new Uint8Array(2), 200)).rejects.toBe(failure);
  expect(stops).toBe(1); exit.resolve();
  await expect(monitor.exited).rejects.toBe(failure);
});
it("monitor recorder stub exits after a chunk callback failure", async () => {
  // Mandatory preload selects a silence process; never run this with the real device.
  expect(process.env.VOICELAYER_TEST_FAKE_REC).toBe("1");
  const { startMicChunkStream } = await import("../input");
  const failure = new Error("injected chunk failure");
  const stream = startMicChunkStream({ onChunk: async () => { throw failure; } });
  try { await expect(stream.exited).rejects.toBe(failure); }
  finally { stream.stop(); await stream.exited.catch(() => {}); }
});
