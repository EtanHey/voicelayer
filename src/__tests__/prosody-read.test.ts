import { describe, expect, it, spyOn } from "bun:test";
import * as binaries from "../resolve-binary";
import type { WordBoundary } from "../socket-protocol";
import { projectSpeakableText } from "../speakable-text";
import { PROSODY_POLICY, planProsody, type ProsodySegment } from "../tts/prosody";
import { createProsodyRead, decodeAudioToPCM, encodePCMToMp3, isStructuredPlan, PROSODY_SAMPLE_RATE, sliceProjection, type ProsodyReadEngine } from "../tts/prosody-read";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { ttsFilePath } from "../paths";
import { unlinkSync } from "node:fs";
import { fixtureCheckpoint } from "./long-read-fixture-barriers";

const RATE = PROSODY_SAMPLE_RATE;
const PAUSE = PROSODY_POLICY.pauses;
const plan = (text: string) => planProsody({ readText: text, projection: projectSpeakableText(text, [], "edge") });

/** Engine fake: each segment is 100 ms silence, one 300 ms tone per word, 200 ms silence. Files are names in a map. */
function fakeEngine() {
  const files = new Map<string, { pcm: Float32Array; words: WordBoundary[] }>();
  const calls = { synthesized: [] as ProsodySegment[], decoded: [] as string[], encoded: [] as string[], unlinked: [] as string[] };
  let counter = 0;
  const engine: ProsodyReadEngine = {
    async synthesize(segment) {
      calls.synthesized.push(segment);
      const words = segment.text.split(/\s+/);
      const pcm = new Float32Array(Math.round(RATE * (0.1 + 0.3 * words.length + 0.2)));
      const boundaries = words.map((text, i) => {
        const start = Math.round(RATE * (0.1 + 0.3 * i));
        for (let j = start; j < start + RATE * 0.3; j++) pcm[j] = 0.3 * Math.sin(2 * Math.PI * (j - start) / 48);
        return { text, offset_ms: 100 + 300 * i, duration_ms: 300 };
      });
      const audioFile = `seg-${counter++}.mp3`;
      files.set(audioFile, { pcm, words: boundaries });
      return { audioFile, words: boundaries, durationMs: pcm.length * 1000 / RATE };
    },
    async decode(audioFile) { calls.decoded.push(audioFile); return files.get(audioFile)!.pcm; },
    async encode(pcm) {
      const audioFile = `chunk-${counter++}.mp3`;
      files.set(audioFile, { pcm, words: [] }); calls.encoded.push(audioFile);
      return audioFile;
    },
    unlink(audioFile) { calls.unlinked.push(audioFile); files.delete(audioFile); },
  };
  return { engine, calls, files };
}

describe("isStructuredPlan: prosody engages only when the text has structure", () => {
  it("plain prose of any length stays on the existing chunker", () => {
    expect(isStructuredPlan(plan("New long read."))).toBe(false);
    expect(isStructuredPlan(plan(Array.from({ length: 40 }, (_, i) => `Sentence ${i} has enough words.`).join(" ")))).toBe(false);
    expect(isStructuredPlan(plan("This is **very** important to me."))).toBe(false);
  });
  it("headings, labels, lists and paragraphs engage it", () => {
    for (const raw of ["## Status\nGreen.", "**Next:** merge", "- one\n- two", "One paragraph.\n\nAnother one.", "1. First"]) {
      expect(isStructuredPlan(plan(raw))).toBe(true);
    }
  });
});

describe("createProsodyRead", () => {
  const doc = "## Status\n\nThe build is green.\n\n- One\n- Two\n- Three";
  for (const failure of ["stop", "decode"] as const) it(`S2 overlapping clone decoding is reaped after ${failure}`, async () => {
    const text = "## Status\n" + "- Keep every complete word in the archive.\n".repeat(8);
    const p = planProsody({ readText: text, projection: projectSpeakableText(text, [], "clone"), engine: "clone", listNumbers: "inline" });
    const { engine, calls, files } = fakeEngine(), controller = new AbortController();
    const decode = engine.decode;
    let rejectDecode!: (error: Error) => void, decoding = 0;
    engine.decode = async (file, signal) => {
      if (file !== "seg-1.mp3") return decode(file, signal);
      decoding++;
      try { return await new Promise<Float32Array>((_resolve, reject) => {
        rejectDecode = reject;
        signal.addEventListener("abort", () => reject(new Error("stopped decoder")), { once: true });
      }); } finally { decoding--; }
    };
    const read = createProsodyRead(p, engine, controller.signal, 1, { overlapDecode: true });
    const first = await read.chunk(0);
    read.firstAudioStarted(first.audioFile);
    const second = read.chunk(1);
    void second.catch(() => {});
    await fixtureCheckpoint();
    expect(decoding).toBe(1);
    if (failure === "stop") controller.abort(); else rejectDecode(new Error("decoder failed"));
    await expect(second).rejects.toThrow(failure === "stop" ? "stopped decoder" : "decoder failed");
    const count = calls.synthesized.length;
    await read.close();
    expect(decoding).toBe(0);
    expect(calls.synthesized).toHaveLength(count);
    expect([...files.keys()]).toEqual([first.audioFile]);
    engine.unlink(first.audioFile);
  });
  it("S2 reuses a complete prepared clone opening without resynthesizing its segments", async () => {
    const text = "## Status\n" + "- This item contains enough words to cover preparation of another request.\n".repeat(6);
    const p = planProsody({ readText: text, projection: projectSpeakableText(text, [], "clone"), engine: "clone", listNumbers: "inline" });
    const { engine, calls, files } = fakeEngine();
    const signal = new AbortController().signal;
    const preparing = createProsodyRead(p, engine, signal, 1, { lookahead: 0 });
    const prepared = await preparing.chunk(0);
    await preparing.close();
    expect(p.chunks[0].end).toBe(1);
    expect(calls.synthesized).toHaveLength(p.chunks[0].end);
    const read = createProsodyRead(p, engine, signal, 1, { prepared });
    const first = await read.chunk(0);
    expect(first).toBe(prepared);
    read.firstAudioStarted(first.audioFile);
    for (let i = 1; i < p.chunks.length; i++) engine.unlink((await read.chunk(i)).audioFile);
    await read.close();
    expect(calls.synthesized).toEqual(p.segments);
    expect(files.has(first.audioFile)).toBe(true);
    engine.unlink(first.audioFile);
    expect(files.size).toBe(0);
  });
  it("S2 closes an unadmitted prepared opening exactly once without starting synthesis", async () => {
    const { engine, calls, files } = fakeEngine(), p = plan(doc);
    const preparing = createProsodyRead(p, engine, new AbortController().signal, 1, { lookahead: 0 });
    const prepared = await preparing.chunk(0);
    await preparing.close();
    const count = calls.synthesized.length, controller = new AbortController();
    const read = createProsodyRead(p, engine, controller.signal, 1, { prepared });
    controller.abort();
    await read.close(); await read.close();
    expect(calls.synthesized).toHaveLength(count);
    expect(calls.unlinked.filter(file => file === prepared.audioFile)).toHaveLength(1);
    expect(files.size).toBe(0);
  });
  it("chunk 0 is the engine's own file, delivered before anything is decoded (B3)", async () => {
    const { engine, calls } = fakeEngine(), p = plan(doc);
    const read = createProsodyRead(p, engine, new AbortController().signal);
    const first = await read.chunk(0);
    expect(first.audioFile).toBe("seg-0.mp3");
    expect(first.spokenText).toBe("Status.");
    expect(calls.encoded).toEqual([]);
    // Chunk 0's tail is measured only after its player has actually started.
    await new Promise((r) => setTimeout(r, 5));
    expect(calls.decoded).not.toContain("seg-0.mp3");
    read.firstAudioStarted(first.audioFile);
    await read.chunk(1);
    expect(calls.decoded).toContain("seg-0.mp3");
    expect(calls.synthesized[0]).toMatchObject({ kind: "heading", emphasis: true });
    await read.close();
  });
  it("later chunks splice their segments into one encoded MP3; segment files are removed", async () => {
    const { engine, calls } = fakeEngine(), p = plan(doc);
    const read = createProsodyRead(p, engine, new AbortController().signal);
    read.firstAudioStarted((await read.chunk(0)).audioFile);
    const second = await read.chunk(1);
    expect(second.audioFile).toMatch(/^chunk-\d+\.mp3$/);
    expect(calls.encoded).toContain(second.audioFile);
    expect(second.spokenText).toBe(p.segments.slice(p.chunks[1].first, p.chunks[1].end).map((s) => s.text).join(" "));
    for (let i = p.chunks[1].first; i < p.chunks[1].end; i++) expect(calls.unlinked).toContain(`seg-${i}.mp3`);
    // Inside the chunk, consecutive utterances are separated by exactly their planned pause.
    const [a, b] = second.words;
    const firstLast = second.words.findIndex((w, i) => i > 0 && w.offset_ms - (second.words[i - 1].offset_ms + second.words[i - 1].duration_ms) > 5);
    expect(firstLast).toBeGreaterThan(0);
    const gap = second.words[firstLast].offset_ms - (second.words[firstLast - 1].offset_ms + second.words[firstLast - 1].duration_ms);
    expect(gap).toBeCloseTo(p.segments[p.chunks[1].first].pauseMs, 0);
    expect(a.offset_ms).toBeLessThan(b.offset_ms);
    await read.close();
  });
  it("the pause across a chunk join counts the raw chunk 0's measured tail", async () => {
    const { engine } = fakeEngine(), p = plan(doc);
    const read = createProsodyRead(p, engine, new AbortController().signal);
    const first = await read.chunk(0);
    read.firstAudioStarted(first.audioFile);
    const second = await read.chunk(1);
    const lastWord = first.words.at(-1)!;
    const tailMs = first.durationMs - (lastWord.offset_ms + lastWord.duration_ms);
    expect(tailMs + second.words[0].offset_ms).toBeCloseTo(p.chunks[0].trailingPauseMs, 0);
    expect(p.chunks[0].trailingPauseMs).toBe(PAUSE.paragraph);
    await read.close();
  });
  it("close() after a stop removes engine files that were never delivered", async () => {
    const { engine, calls, files } = fakeEngine(), p = plan(doc), controller = new AbortController();
    const read = createProsodyRead(p, engine, controller.signal);
    await read.chunk(0);
    controller.abort();
    await read.close();
    expect([...files.keys()].filter((f) => f.startsWith("seg-") && f !== "seg-0.mp3")).toEqual([]);
    expect(calls.unlinked).not.toContain("seg-0.mp3"); // delivered: the long-read runtime owns it now
  });
  it("selection reads plan from the structured display", () => {
    const structure = projectStructuredSpeech("## Choose\n- Red apple\n- Green pear");
    const p = planProsody({ readText: structure.speechText, projection: projectSpeakableText(structure.speechText, [], "edge"), structure });
    expect(isStructuredPlan(p)).toBe(true);
    expect(p.chunks[0].text).toBe("Choose");
  });
  it("S1 clone word coordinates and structural gaps survive final MP3 encoding", async () => {
    const text = "## Choose\n1. Red apple\n2. Green pear";
    const p = planProsody({ readText: text, projection: projectSpeakableText(text, [], "clone"), listNumbers: "inline" });
    const { engine } = fakeEngine();
    const files: string[] = [];
    engine.encode = async (pcm, signal) => {
      const file = ttsFilePath(process.pid, 900000 + files.length); files.push(file);
      await encodePCMToMp3(pcm, file, signal); return file;
    };
    const signal = new AbortController().signal;
    const read = createProsodyRead(p, engine, signal);
    try {
      const first = await read.chunk(0); read.firstAudioStarted(first.audioFile);
      const second = await read.chunk(1);
      const tailMs = first.durationMs - first.words.at(-1)!.offset_ms - first.words.at(-1)!.duration_ms;
      expect(tailMs + second.words[0].offset_ms).toBeGreaterThanOrEqual(PAUSE.h2);
      const endOfItem = second.words[2].offset_ms + second.words[2].duration_ms;
      expect(second.words[3].offset_ms - endOfItem).toBeGreaterThanOrEqual(PAUSE.shortItem);
      const decoded = await decodeAudioToPCM(second.audioFile, signal);
      expect(decoded.length / 24).toBeCloseTo(second.durationMs, 0);
      for (const [from, to] of [[0, second.words[0].offset_ms - 30], [endOfItem + 30, second.words[3].offset_ms - 30]]) {
        const gap = decoded.slice(Math.ceil(from * 24), Math.floor(to * 24));
        expect(gap.length).toBeGreaterThan(0);
        expect(gap.every(sample => Math.abs(sample) < 0.005)).toBe(true);
      }
    } finally { await read.close(); for (const file of files) unlinkSync(file); }
  });
});

describe("sliceProjection: a chunk aligns against the whole projection, never a re-projection of its text", () => {
  for (const raw of ["2. Alpha.\n3. Beta.", "## Status\n\nThe build is green.\n\n1. Merge now\n2. Wait", "| A | B |\n| --- | --- |\n| x | y |\n\nAfter (see it) done."]) it(JSON.stringify(raw.slice(0, 24)), () => {
    const projection = projectSpeakableText(raw, [], "edge");
    const p = planProsody({ readText: raw, projection });
    for (const chunk of p.chunks) {
      const slice = sliceProjection(projection, chunk.read);
      expect(slice.displayText).toBe(chunk.text);
      let display = 0, speech = 0;
      for (const range of slice.ranges) {
        expect(range.display.start).toBe(display); expect(range.speech.start).toBe(speech);
        if (range.kind === "identity") expect(slice.speechText.slice(range.speech.start, range.speech.end)).toBe(slice.displayText.slice(range.display.start, range.display.end));
        display = range.display.end; speech = range.speech.end;
      }
      expect(display).toBe(slice.displayText.length); expect(speech).toBe(slice.speechText.length);
      const letters = (t: string) => t.replace(/[^\p{L}\p{N}]/gu, "");
      expect(letters(slice.speechText)).toBe(letters(p.segments.slice(chunk.first, chunk.end).map((s) => s.text).join(" ")));
    }
  });
  it("the bare list number keeps the whole projection's spoken form", () => {
    const raw = "2. Alpha.\n3. Beta.";
    const projection = projectSpeakableText(raw, [], "edge");
    const p = planProsody({ readText: raw, projection });
    expect(sliceProjection(projection, p.chunks[0].read)).toMatchObject({ displayText: "2.", speechText: "two." });
  });
});

describe("B1: chunk 0's tail decode is owned by the read", () => {
  const doc = "## Status\n\nThe build is green.";
  /** Chunk 0's tail decoder only settles when released (or killed through its signal). */
  function heldDecoder() {
    const base = fakeEngine();
    let pending = 0;
    const releases: (() => void)[] = [];
    const decode = base.engine.decode;
    base.engine.decode = (audioFile, signal) => audioFile !== "seg-0.mp3" ? decode(audioFile, signal) : new Promise((resolve, reject) => {
      pending++;
      const settle = (ok: boolean) => { pending--; ok ? resolve(new Float32Array(24000)) : reject(new Error("killed")); };
      releases.push(() => settle(true));
      signal.addEventListener("abort", () => settle(false), { once: true });
    });
    return { ...base, pending: () => pending, release: () => releases.splice(0).forEach((r) => r()) };
  }
  it("close() cancels and awaits a still-running tail decode", async () => {
    const held = heldDecoder(), p = plan(doc);
    const read = createProsodyRead(p, held.engine, new AbortController().signal);
    read.firstAudioStarted((await read.chunk(0)).audioFile);
    expect(held.pending()).toBe(1);
    await read.close();
    expect(held.pending()).toBe(0);
  });
  it("abort cancels the tail decode, and a later chunk never waits on it", async () => {
    const held = heldDecoder(), p = plan(doc), controller = new AbortController();
    const read = createProsodyRead(p, held.engine, controller.signal);
    read.firstAudioStarted((await read.chunk(0)).audioFile);
    const second = read.chunk(1); second.catch(() => {});
    controller.abort();
    await expect(second).rejects.toThrow();
    await read.close();
    expect(held.pending()).toBe(0);
  });
  it("if chunk 0 never starts playing, later chunks still resolve (no deadlock)", async () => {
    const { engine, calls } = fakeEngine(), p = plan(doc);
    const read = createProsodyRead(p, engine, new AbortController().signal);
    await read.chunk(0);
    read.firstAudioUnavailable();
    const second = await read.chunk(1);
    expect(second.audioFile).toMatch(/\.mp3$/);
    expect(calls.decoded).not.toContain("seg-0.mp3");
    await read.close();
  });
});

describe("B2: ffmpeg children are killed and reaped on every exceptional path", () => {
  for (const [name, child, run, message] of [
    ["encoder stdin EPIPE", (exited: Promise<number>, kill: () => void) => ({ pid: 1, stdin: { write() { throw Error("EPIPE synthetic encoder closed stdin"); }, end() {} }, stdout: new Blob([]).stream(), exited, kill }),
      () => encodePCMToMp3(new Float32Array([0.1]), "synthetic.mp3", new AbortController().signal), "EPIPE"],
    ["decoder stdout rejection", (exited: Promise<number>, kill: () => void) => ({ pid: 1, stdout: new ReadableStream({ start(c) { c.error(Error("synthetic decoder stdout failure")); } }), exited, kill }),
      () => decodeAudioToPCM("synthetic.mp3", new AbortController().signal), "stdout failure"],
  ] as const) it(name, async () => {
    const spawn = Bun.spawn;
    const resolver = spyOn(binaries, "resolveBinaryAsync").mockResolvedValue("ffmpeg");
    let killed = false, exited = false, release!: () => void;
    const done = new Promise<number>((r) => { release = () => { exited = true; r(0); }; });
    Bun.spawn = (() => child(done, () => { killed = true; release(); })) as any;
    try {
      await expect(run()).rejects.toThrow(message);
      expect(killed).toBe(true);
      expect(exited).toBe(true);
    } finally { release(); Bun.spawn = spawn; resolver.mockRestore(); }
  });
});

describe("Macroscope #562: a chunk starting inside an atomic replacement keeps its speech", () => {
  const letters = (t: string) => t.replace(/[^\p{L}\p{N}]/gu, "");
  for (const raw of ["Intro.\n\n  1. Pick up the blue basket.\n  2. Walk to the gate.", "## Head\n\t1. First item here\n\t2. Second item here"]) it(JSON.stringify(raw), async () => {
    const { alignWordBoundariesToDisplayText } = await import("../tts");
    const projection = projectSpeakableText(raw, [], "edge");
    const p = planProsody({ readText: raw, projection });
    for (const chunk of p.chunks) {
      const synthesized = p.segments.slice(chunk.first, chunk.end).map((s) => s.text).join(" ");
      const slice = sliceProjection(projection, chunk.read);
      // The spoken marker ("one.") is synthesized, and the slice used for highlight timing must carry it too.
      expect(letters(slice.speechText)).toBe(letters(synthesized));
      const words = synthesized.split(/\s+/).map((text, i) => ({ text, offset_ms: 100 + 300 * i, duration_ms: 250 }));
      const timed = alignWordBoundariesToDisplayText(chunk.text, slice.speechText, words, slice.ranges, true);
      expect(timed.length).toBe(chunk.text.match(/\S+/g)!.length);
    }
  });
});
