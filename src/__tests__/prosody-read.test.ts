import { describe, expect, it } from "bun:test";
import type { WordBoundary } from "../socket-protocol";
import { projectSpeakableText } from "../speakable-text";
import { PAUSE, planProsody, type ProsodySegment } from "../tts/prosody";
import { createProsodyRead, isStructuredPlan, PROSODY_SAMPLE_RATE, sliceProjection, type ProsodyReadEngine } from "../tts/prosody-read";
import { projectStructuredSpeech } from "../tts/structured-speech";

const RATE = PROSODY_SAMPLE_RATE;
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
  it("chunk 0 is the engine's own file, delivered before anything is decoded", async () => {
    const { engine, calls } = fakeEngine(), p = plan(doc);
    const read = createProsodyRead(p, engine, new AbortController().signal);
    const first = await read.chunk(0);
    expect(first.audioFile).toBe("seg-0.mp3");
    expect(first.spokenText).toBe("Status.");
    expect(calls.encoded).toEqual([]);
    expect(calls.synthesized[0]).toMatchObject({ kind: "heading", emphasis: true });
    await read.close();
  });
  it("later chunks splice their segments into one encoded MP3; segment files are removed", async () => {
    const { engine, calls } = fakeEngine(), p = plan(doc);
    const read = createProsodyRead(p, engine, new AbortController().signal);
    await read.chunk(0);
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
    const first = await read.chunk(0), second = await read.chunk(1);
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
