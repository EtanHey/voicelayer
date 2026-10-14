import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "./setup/test-tmp";
import { synthesizeWithRetry } from "../tts-health";
import { runAudioCommand, assembleLongReadHistory } from "../tts/long-read-audio";
import * as qwen from "../tts/qwen3";

const originalSpawn = Bun.spawn;
const spies: ReturnType<typeof spyOn>[] = [];
afterEach(() => { Bun.spawn = originalSpawn; for (const spy of spies.splice(0)) spy.mockRestore(); });

describe("long-read synthesis adapters", () => {
  it("edge abort reaps its exact child and skips all retries", async () => {
    const controller = new AbortController(); let count = 0, killed = false;
    let exit!: (code: number) => void;
    Bun.spawn = (() => {
      count++;
      return { pid: 91234, exited: new Promise<number>((r) => { exit = r; }), kill: () => { killed = true; exit(143); } };
    }) as any;
    const pending = synthesizeWithRetry("hello", "fixture", "+0%", join(TEST_TMP, "edge-abort.mp3"), "fixture.py", 1, controller.signal);
    controller.abort();
    await expect(pending).rejects.toHaveProperty("name", "AbortError");
    expect(killed).toBe(true); expect(count).toBe(1);
  });

  it("already-aborted edge work cannot spawn a child", async () => {
    const controller = new AbortController(); controller.abort();
    const spawn = spyOn(Bun, "spawn"); spies.push(spawn);
    await expect(synthesizeWithRetry("hello", "fixture", "+0%", join(TEST_TMP, "abort.mp3"), "fixture.py", 1, controller.signal)).rejects.toHaveProperty("name", "AbortError");
    expect(spawn).not.toHaveBeenCalled();
  });

  it("Qwen3 forwards the generation signal to fetch and propagates cancellation", async () => {
    spies.push(spyOn(qwen, "loadProfile").mockReturnValue({ name: "fixture", engine: "qwen3-tts", model_path: "", reference_clips: [], reference_clip: "fixture.wav", reference_text: "reference", fallback: "jenny", created: "" }));
    spies.push(spyOn(qwen, "buildDaemonRequestHeaders").mockReturnValue({ Authorization: "Bearer fixture" }));
    let received: AbortSignal | undefined;
    const fetch = spyOn(globalThis, "fetch").mockImplementation(async (_url, options) => {
      received = options!.signal as AbortSignal;
      return await new Promise<Response>((_resolve, reject) => received!.addEventListener("abort", () => reject(received!.reason), { once: true }));
    }); spies.push(fetch);
    const controller = new AbortController(); const pending = qwen.synthesizeCloned("hello", "fixture", controller.signal);
    expect(received).toBeDefined(); controller.abort();
    await expect(pending).rejects.toHaveProperty("name", "AbortError");
    expect(received!.aborted).toBe(true); expect(fetch).toHaveBeenCalledTimes(1);
  });

  it("audio conversion cancellation reaps an owned real process", async () => {
    const controller = new AbortController(); let childPid = 0;
    Bun.spawn = ((argv: string[], options: any) => {
      const child = originalSpawn(argv, options); childPid = child.pid; return child;
    }) as any;
    const pending = runAudioCommand([process.execPath, "-e", "setInterval(() => {}, 1000)"], controller.signal);
    controller.abort(); await expect(pending).rejects.toHaveProperty("name", "AbortError");
    expect(() => process.kill(childPid, 0)).toThrow();
  });
});

describe("long-read replay audio with real ffmpeg, no speaker", () => {
  it("keeps exactly the heard ranges after a seek, checked against decoded signal energy", async () => {
    const dir = mkdtempSync(join(TEST_TMP, "seek-history-"));
    try {
      const source = join(dir, "source.wav"), output = join(dir, "history.mp3");
      await runAudioCommand(["ffmpeg", "-nostdin", "-y", "-f", "lavfi", "-i",
        "aevalsrc=if(lt(t\\,0.5)\\,0\\,0.5*sin(2*PI*440*t)):s=16000:d=1", source]);
      const chunk = { audioFile: source, durationMs: 1000, wordBoundaries: [] };
      await assembleLongReadHistory([
        { chunk, text: "tone tail", startMs: 500, playedMs: 200 },
        { chunk, text: "silent prefix", playedMs: 200 },
      ], output);
      const pcm = Bun.spawnSync(["ffmpeg", "-v", "error", "-i", output, "-f", "f32le", "-ac", "1", "-ar", "16000", "pipe:1"]);
      expect(pcm.exitCode).toBe(0);
      const samples = new Float32Array(pcm.stdout.buffer, pcm.stdout.byteOffset, pcm.stdout.byteLength / 4);
      const rms = (from: number, to: number) => Math.sqrt(samples.slice(from, to).reduce((sum, x) => sum + x*x, 0) / (to-from));
      expect(samples.length / 16000).toBeCloseTo(0.4, 1);
      expect(rms(400, 2400)).toBeGreaterThan(0.2);
      expect(rms(4000, 6000)).toBeLessThan(0.01);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
  it("concatenates full chunks and trims the stopped tail using an independent duration probe", async () => {
    const dir = mkdtempSync(join(TEST_TMP, "long-read-audio-"));
    try {
      const first = join(dir, "one.mp3"), second = join(dir, "two.mp3"), output = join(dir, "replay.mp3");
      for (const path of [first, second]) {
        await runAudioCommand(["ffmpeg", "-nostdin", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1", path]);
      }
      await assembleLongReadHistory([
        { chunk: { audioFile: first, durationMs: 1000, wordBoundaries: [] }, text: "one", playedMs: 1000 },
        { chunk: { audioFile: second, durationMs: 1000, wordBoundaries: [] }, text: "two", playedMs: 250 },
      ], output);
      const probe = Bun.spawnSync(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", output]);
      expect(probe.exitCode).toBe(0);
      const duration = Number(probe.stdout.toString().trim());
      expect(duration).toBeGreaterThanOrEqual(1.25); expect(duration).toBeLessThan(1.35);
    } finally { rmSync(dir, { recursive: true, force: true }); }
  });
});
