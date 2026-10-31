import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { alignWordBoundariesToDisplayText } from "../tts";
import { planProsody } from "../tts/prosody";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { structuredReadDisplay } from "../tts/structured-display";

const timings = (speech: string) => speech.split(/\s+/).map((text, i) => ({ text, offset_ms: i * 300, duration_ms: 200 }));
for (const engine of ["edge", "clone"] as const) {
  for (const [source, expected] of [
    ["1. [ ] Buy milk\n2. [x] Call Dana", "one, Buy milk. two, Call Dana, done."],
    ["- [x] Call Dana\n+ [ ] Buy milk\n* [X] Send note.", "Call Dana, done. Buy milk. Send note, done."],
    ["1) [X] Call Dana.\n2) [x] Buy milk!", "one, Call Dana, done. two, Buy milk, done."],
    ["- [ ] Buy milk\n- [ ] Send note", "Buy milk. Send note."],
    ["- [x] Call Dana,   \r\n+ [ ] Buy milk", "Call Dana, done. Buy milk."],
  ]) test(`${engine} completed tasks use a comma: ${source}`, () => {
    const projection = projectSpeakableText(source, [], engine);
    const plan = planProsody({ readText: source, projection, engine, listNumbers: "inline" });
    expect(plan.speechText).toBe(engine === "edge" ? expected.replace(/\b(one|two),/g, "$1.") : expected);
    expect(projection.displayText).toBe(source);
    expect(projection.speechText).not.toContain("\u2014");
    expect(projection.displayText).not.toContain("\u2014");
    expect(projection.speechText).not.toMatch(/bracket [xX] close bracket|\[[xX]\]/);
  });

  test(`${engine} backtick checkboxes remain literal and never acquire done`, () => {
    for (const source of ["- `[x]` Call Dana", "`2. [x] Call Dana`", "``alpha\n- [X] Call Dana\nbeta``"]) {
      const result = projectSpeakableText(source, [], engine);
      expect(result.speechText).not.toContain(", done");
      const at = source.search(/\[[xX]\]/) + 1;
      expect(result.ranges.find(r => r.source.start <= at && r.source.end > at)?.kind).not.toBe("omission");
    }
  });

  test(`${engine} spoken-only done has no display span and cannot shift the next highlight`, () => {
    const source = "- [x] Call Dana\n- [ ] Buy milk";
    const p = projectSpeakableText(source, [], engine);
    expect(p.speechText).toBe("Call Dana, done. Buy milk.");
    const inserted = p.ranges.filter(r => r.kind === "insertion" && p.speechText.slice(r.speech.start, r.speech.end).includes("done"));
    expect(inserted).toHaveLength(1);
    expect(inserted[0].display.start).toBe(inserted[0].display.end);
    const words = alignWordBoundariesToDisplayText(source, p.speechText, timings(p.speechText), p.ranges);
    expect(words.filter(w => w.duration_ms).map(w => [w.text, w.offset_ms, w.duration_ms]))
      .toEqual([["Call", 0, 200], ["Dana", 300, 200], ["Buy", 900, 200], ["milk", 1200, 200]]);
    expect(words.some(w => w.text.includes("done"))).toBe(false);
    let display = 0, speech = 0;
    for (const range of p.ranges) {
      expect(range.display.start).toBe(display); expect(range.speech.start).toBe(speech);
      display = range.display.end; speech = range.speech.end;
    }
    expect(display).toBe(source.length); expect(speech).toBe(p.speechText.length);
  });

  test(`${engine} selection formatter shows done and keeps its timing with the displayed word`, () => {
    const source = "- [x] Call Dana\n- [ ] Buy milk";
    const structure = projectStructuredSpeech(source);
    expect(structure.displayText).toBe(source);
    expect(structure.speechText).toBe("Call Dana, done. Buy milk.");
    const display = structuredReadDisplay(structure, [structure.speechText], 400)[0]!;
    expect(display.text).toBe(structure.speechText);
    expect(display.text).not.toContain("\u2014");
    const p = projectSpeakableText(display.text, [], engine);
    const words = alignWordBoundariesToDisplayText(display.text, p.speechText, timings(p.speechText), p.ranges, true);
    expect(words.map(w => [w.text, w.offset_ms])).toEqual([["Call", 0], ["Dana,", 300], ["done.", 600], ["Buy", 900], ["milk.", 1200]]);
  });

  test(`${engine} numbered selection keeps mixed checkbox state without duplicating done`, () => {
    const structure = projectStructuredSpeech("1. [ ] Buy milk\n2. [X] Call Dana");
    expect(structure.speechText).toBe("1. Buy milk. 2. Call Dana, done.");
    const p = projectSpeakableText(structure.speechText, [], engine);
    const plan = planProsody({ readText: structure.speechText, projection: p, structure, engine, listNumbers: "inline" });
    expect(plan.speechText.match(/\bdone\b/g)).toHaveLength(1);
    expect(plan.speechText).toContain("Call Dana, done.");
    expect(plan.speechText).not.toContain("\u2014");
  });

  test(`${engine} empty task bodies and link labels do not gain completion speech`, () => {
    for (const source of ["1. [x]", "- [x](https://example.com)"]) {
      expect(projectSpeakableText(source, [], engine).speechText).not.toContain(", done");
      expect(projectStructuredSpeech(source).speechText).not.toContain(", done");
    }
  });
}
