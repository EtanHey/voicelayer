/**
 * Lane B (2.4): every synthesis goes through the one NarrationSource. A fake NarrationLayer
 * adapter installed at the seam receives reads, voice_speak and cloned voices; nothing else is
 * asked to synthesize. This is the proof that the NarrationLayer swap is one adapter file.
 */
import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { writeFileSync } from "fs";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import { createEngineNarrationSource } from "../narration/engines";
import { narrationSource, setNarrationSource, type NarrationRequest, type NarrationSource } from "../narration/source";
import { deferredFixture as deferred } from "./long-read-fixture-barriers";
import { TEST_TMP } from "./setup/test-tmp";

let requests: NarrationRequest[];
let previous: NarrationSource | undefined;
let restore: (() => void)[];

const fakeNarrationLayer: NarrationSource = {
  id: "fake-narrationlayer",
  async synthesize(request) {
    requests.push(request);
    writeFileSync(request.outFile, "fake narration audio");
    const words = request.text.split(/\s+/).filter(Boolean);
    return { audioFile: request.outFile, durationMs: words.length * 300, engine: "narrationlayer", voice: request.voice,
      wordBoundaries: words.map((text, i) => ({ text, offset_ms: i * 300, duration_ms: 250 })) };
  },
};

beforeEach(() => {
  requests = [];
  previous = setNarrationSource(fakeNarrationLayer);
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    if (argv.some(arg => arg.startsWith("--text="))) throw new Error(`edge-tts must not be spawned: ${argv.join(" ")}`);
    const exit = deferred<number>();
    if (argv[0] === "which" || argv.includes("-version")) exit.resolve(0);
    else exit.resolve(0); // players finish at once
    return { pid: 4242, exited: exit.promise, kill() { exit.resolve(143); }, stdout: new Blob(["ffmpeg"]).stream() };
  }) as any);
  const extract = spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue(
    { result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }), cancel: () => {} } as any);
  const cast = spyOn(socket, "broadcast").mockImplementation(() => {});
  restore = [() => spawn.mockRestore(), () => extract.mockRestore(), () => cast.mockRestore()];
});

afterEach(async () => {
  tts.stopPlayback();
  await tts.awaitCurrentPlayback().catch(() => {});
  for (const undo of restore) undo();
  if (previous) setNarrationSource(previous);
});

describe("NarrationSource: the single synthesis seam", () => {
  it("the default source is today's engines", () => {
    expect(previous?.id).toBe("voicelayer-engines");
  });

  it("an Option+F5-style long read synthesizes every chunk through the source", async () => {
    const text = Array.from({ length: 60 }, (_, i) => `Sentence number ${i} talks about Codex and Claude.`).join(" ");
    const handle = tts.speakLongRead(text, { engine: "edge", voice: "en-US-AndrewNeural", rate: "+0%" });
    await handle.done;
    expect(requests.length).toBeGreaterThan(1);
    expect(requests.every(request => request.engine === "edge" && request.voice === "en-US-AndrewNeural" && request.rate === "+0%")).toBe(true);
    expect(requests.map(request => request.text).join(" ").replace(/\s+/g, " ")).toContain("Sentence number 59 talks about Codex");
  });

  it("voice_speak's short path synthesizes through the source", async () => {
    await tts.speak("A short status update from the agent.", { mode: "announce", voice: "en-US-AndrewNeural", waitForPlayback: true });
    expect(requests).toHaveLength(1);
    expect(requests[0]).toMatchObject({ engine: "edge", text: "A short status update from the agent." });
  });

  it("restores the source it replaced", () => {
    const before = narrationSource();
    const swapped = setNarrationSource(before);
    expect(swapped).toBe(before);
  });
});

describe("the default engine adapter", () => {
  it("routes edge voices to edge-tts and cloned voices to the clone engine, null when the clone is unavailable", async () => {
    const calls: string[] = [];
    const source = createEngineNarrationSource({
      async edge(text, voice, rate, outFile) {
        calls.push(`edge:${voice}:${rate}`);
        return { audioFile: outFile, durationMs: 900, wordBoundaries: [{ text, offset_ms: 0, duration_ms: 900 }] };
      },
      async clone(_text, voice) { calls.push(`clone:${voice}`); return voice === "theo" ? new Uint8Array([1, 2, 3]) : null; },
    });
    const out = `${TEST_TMP}/narration-clone.mp3`;
    expect(await source.synthesize({ text: "Hi", engine: "edge", voice: "en-US-AndrewNeural", rate: "+10%", outFile: out }))
      .toMatchObject({ engine: "edge-tts", durationMs: 900 });
    expect(await source.synthesize({ text: "Hi", engine: "clone", voice: "theo", rate: "+0%", outFile: out }))
      .toMatchObject({ engine: "qwen3-tts", audioFile: out, wordBoundaries: [] });
    expect(await source.synthesize({ text: "Hi", engine: "clone", voice: "missing", rate: "+0%", outFile: out })).toBeNull();
    expect(calls).toEqual(["edge:en-US-AndrewNeural:+10%", "clone:theo", "clone:missing"]);
  });
});
