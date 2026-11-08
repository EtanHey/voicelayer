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
import { ASK_UTTERANCE_POLICY, planUtterances, synthesizeBounded } from "../narration/utterances";
import { deferredFixture as deferred } from "./long-read-fixture-barriers";
import { TEST_TMP } from "./setup/test-tmp";

let requests: NarrationRequest[];
let ffmpegCalls: string[][];
let failAssembly = false;
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
  requests = []; ffmpegCalls = []; failAssembly = false;
  previous = setNarrationSource(fakeNarrationLayer);
  const spawn = spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
    if (argv.some(arg => arg.startsWith("--text="))) throw new Error(`edge-tts must not be spawned: ${argv.join(" ")}`);
    if (argv.includes("-filter_complex")) {
      ffmpegCalls.push(argv);
      if (!failAssembly) writeFileSync(argv.at(-1)!, "assembled narration");
    }
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

describe("bounded utterances with pauses (voice_ask narration)", () => {
  const ask = "Lane B finished the engine. Should I push the branch now, or wait for the paused-ask stack, the capture-end fix and the review round first? Tell me which.";

  it("plans at most 14 words per utterance, sentence and clause pauses, and never loses a word", () => {
    const plan = planUtterances(ask);
    expect(plan.map(u => u.text).join(" ")).toBe(ask.split(/\s+/).join(" "));
    expect(plan.every(u => u.text.split(" ").length <= ASK_UTTERANCE_POLICY.maxWords)).toBe(true);
    expect(plan[0]).toEqual({ text: "Lane B finished the engine.", pauseAfterMs: 550 });
    expect(plan.some(u => u.pauseAfterMs === 250)).toBe(true);
    expect(plan.at(-1)!.pauseAfterMs).toBe(0);
    expect(planUtterances("Question?")).toEqual([{ text: "Question?", pauseAfterMs: 0 }]);
    const run = Array.from({ length: 31 }, (_, i) => `w${i}`).join(" ");
    expect(planUtterances(run).map(u => u.text.split(" ").length)).toEqual([14, 14, 3]);
    // A cap split without punctuation is synthesis-only: no silence (#818 P1).
    expect(planUtterances(run).map(u => u.pauseAfterMs)).toEqual([0, 0, 0]);
  });

  it("#818 P1 / k06-23: a split at the 14-word cap with no punctuation adds NO silence; pauses fall on punctuation", () => {
    // The reviewer's input: the cap lands between "really" and "fast".
    const plan = planUtterances("one two three four five six seven eight nine ten eleven twelve thirteen really fast");
    expect(plan.map(u => u.text).join(" ")).toBe("one two three four five six seven eight nine ten eleven twelve thirteen really fast");
    expect(plan.length).toBe(2);
    expect(plan[0].pauseAfterMs).toBe(0);
    // Etan's "fast -- really fast": the pause lands on the dash, never inside "really fast".
    const dash = planUtterances("we measured it and it was fast -- really fast and then it stopped completely right there");
    const before = dash.findIndex(u => u.text.endsWith("--"));
    expect(before).toBeGreaterThanOrEqual(0);
    expect(dash[before].pauseAfterMs).toBe(250);
    for (const [i, u] of dash.entries()) {
      if (u.pauseAfterMs > 0 && i < dash.length - 1) expect(/[.!?…,;:—–]$|--$/.test(u.text)).toBe(true);
    }
    expect(dash.map(u => u.text).join(" ")).toBe("we measured it and it was fast -- really fast and then it stopped completely right there");
  });

  it("synthesizes each utterance through the source and offsets word timings by audio plus pauses", async () => {
    const assembled: Array<Array<{ file: string } | { silenceMs: number }>> = [];
    const audio = await synthesizeBounded({ text: "One two. Three four.", engine: "edge", voice: "v", rate: "+0%", outFile: `${TEST_TMP}/b.mp3` }, {
      source: fakeNarrationLayer, probeMs: () => 0, dispose: () => {},
      assemble: async (parts, outFile) => { assembled.push(parts); writeFileSync(outFile, "x"); },
    });
    expect(requests.map(r => r.text)).toEqual(["One two.", "Three four."]);
    expect(assembled[0].map(part => "silenceMs" in part ? part.silenceMs : "audio")).toEqual(["audio", 550, "audio"]);
    // First utterance: 2 words x 300 ms = 600 ms, then a 550 ms pause.
    expect(audio!.wordBoundaries.map(w => [w.text, w.offset_ms])).toEqual([["One", 0], ["two.", 300], ["Three", 1150], ["four.", 1450]]);
    expect(audio!.durationMs).toBe(600 + 550 + 600);
  });

  it("the real voice_ask prompt path (converse) speaks bounded utterances assembled with pauses", async () => {
    await tts.speak(ask, { mode: "converse", voice: "en-US-AndrewNeural", waitForPlayback: true });
    expect(requests.length).toBe(planUtterances(ask).length);
    expect(requests.every(r => r.text.split(" ").length <= 14)).toBe(true);
    expect(ffmpegCalls).toHaveLength(1);
    expect(ffmpegCalls[0].join(" ")).toContain("anullsrc=r=24000:cl=mono");
    expect(ffmpegCalls[0].join(" ")).toContain("-t 0.550");
  });

  it("an assembly failure speaks the ask as one whole request (the prompt is never lost)", async () => {
    failAssembly = true;
    await tts.speak(ask, { mode: "converse", voice: "en-US-AndrewNeural", waitForPlayback: true });
    // The utterances were synthesized, assembly failed, and the whole (speakable) prompt was requested once.
    const whole = requests.at(-1)!.text;
    expect(requests.slice(0, -1).map(r => r.text).join(" ")).toBe(whole);
    expect(planUtterances(whole).length).toBeGreaterThan(1);
  });

  it("voice_speak (not an ask) keeps one request", async () => {
    await tts.speak(ask, { mode: "announce", voice: "en-US-AndrewNeural", waitForPlayback: true });
    expect(requests).toHaveLength(1);
    expect(ffmpegCalls).toHaveLength(0);
  });
});
