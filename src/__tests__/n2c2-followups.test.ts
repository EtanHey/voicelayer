import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { alignWordBoundariesToDisplayText } from "../tts";

const cases = [
  ["R1 code link labels", "[`reply-draft.md`](https://example.com)", "reply draft dot M D"],
  ["R2 doubly quoted checklist", ">> - [x] a\n>> - [ ] b", "a, done. b."],
  ["F1 Hebrew units", "גרסה 2.5GB", "גרסה 2.5GB"],
  ["F2 Hebrew filename", "קובץ 1/day.json כאן", "קובץ 1/day.json כאן"],
  ["F3 unpaired backtick", "`$5 unpaired", "$5 unpaired"],
  ["F4 protected version", "# `v1.2` notes", "v1.2 notes"],
  ["F5 decimal comma spacing", "1.5,2.5", "one point five, two point five"],
  ["F6 numbered selection", "1. [x] numbered\n2. [ ] next", "one. numbered, done. two. next."],
  ["F7 quote continuation", "> - [x] a\n>   wrapped", "a wrapped, done."],
] as const;

for (const engine of ["edge", "clone"] as const) {
  for (const [name, source, expected] of cases) test(`${engine} ${name}`, () => {
    // R1 is specifically the raw voice_speak path. All others cover both paths.
    const reads = name.startsWith("R1") ? [source] : [source, projectStructuredSpeech(source).speechText];
    for (const read of reads) {
      const p = projectSpeakableText(read, [], engine);
      expect(p.speechText).toBe(expected);
      expect(p.speechText).not.toMatch(/[`\u2013\u2014]/);
      let display = 0, speech = 0;
      for (const range of p.ranges) {
        expect(range.display.start).toBe(display);
        expect(range.speech.start).toBe(speech);
        display = range.display.end; speech = range.speech.end;
      }
      expect(display).toBe(read.length);
      expect(speech).toBe(p.speechText.length);
    }
  });

  for (const [source, expected] of [
    ["[`src/foo.ts:12`](src/foo.ts#L12) next", engine === "edge" ? "foo dot T S:12 next" : "src slash foo dot T S:12 next"],
    ["[`3.14`](https://x.io) next", "3.14 next"],
    ["![`a.png`](https://x.io/a.png) next", "a dot P N G next"],
  ]) test(`${engine} raw link label and next-word alignment: ${source}`, () => {
    const p = projectSpeakableText(source, [], engine);
    expect(p.speechText).toBe(expected);
    const timings = p.speechText.split(/\s+/).map((text, i) => ({text, offset_ms: i * 100, duration_ms: 80}));
    const words = alignWordBoundariesToDisplayText(source, p.speechText, timings, p.ranges, true);
    expect(words.find(w => w.text === "next")?.offset_ms).toBe(timings.at(-1)!.offset_ms);
  });
}

for (const engine of ["edge", "clone"] as const) {
  test(`${engine} link syntax inside code stays lexical`, () => {
    expect(projectSpeakableText("`[a.md](https://x.io)`", [], engine).speechText).toBe("[a.md](https://x.io)");
  });
  test(`${engine} list numbering stays consistent after a selection intro`, () => {
    const selected = projectStructuredSpeech("Steps:\n1. [x] numbered\n2. [ ] next").speechText;
    expect(projectSpeakableText(selected, [], engine).speechText).toBe("Steps: one. numbered, done. two. next.");
  });
}

for (const engine of ["edge", "clone"] as const) {
  for (const [source, expected] of [
    ["``$5 unpaired `v1.2` notes", "$5 unpaired v1.2 notes"],
    ["`$5 unpaired\nprice $5", "$5 unpaired price five dollars"],
    ["`$5 ``\nprice $5", "$5 price five dollars"],
    ["> - [x] a\n>\n> next", "a, done. next"],
    ["> - [x] a\n>> new quote", "a, done. new quote"],
  ]) test(`${engine} literal and quote continuation boundaries: ${source}`, () => {
    for (const read of [source, projectStructuredSpeech(source).speechText]) {
      expect(projectSpeakableText(read, [], engine).speechText).toBe(expected);
    }
  });
}

for (const engine of ["edge", "clone"] as const) {
  for (const [source, expected] of [
    ["Escaped \\` before $5", "Escaped \\ before five dollars"],
    ["Escaped \\` then [`reply-draft.md`](https://example.com) $5", "Escaped \\ then reply draft dot M D five dollars"],
  ]) test(`${engine} escaped backticks cannot protect later prose: ${source}`, () => {
    expect(projectSpeakableText(source, [], engine).speechText).toBe(expected);
  });
}
