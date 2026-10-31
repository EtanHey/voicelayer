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
      const selection = projectStructuredSpeech(source).speechText;
      const selected = projectSpeakableText(selection, [], engine);
      expect(selected.speechText).not.toContain(", done");
      const marker = source.match(/\[[xX]\]/)![0];
      expect(selection).toContain(marker);
      const selectedAt = selection.indexOf(marker) + 1;
      expect(selected.ranges.find(r => r.source.start <= selectedAt && r.source.end > selectedAt)?.kind).not.toBe("omission");
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

for (const engine of ["edge", "clone"] as const) {
  for (const [source, expected] of [
    ["> - [x] Call Dana", "Call Dana, done."],
    ["- [x] ✅", "✅, done."],
    ["- [x] להתקשר לדנה", "להתקשר לדנה, done."],
    ["- [x] Call Dana  \n  continued line\n- [ ] next", "Call Dana continued line, done. next."],
  ]) test(`${engine} checked task body and continuation: ${source}`, () => {
    expect(projectSpeakableText(source, [], engine).speechText).toBe(expected);
    expect(projectStructuredSpeech(source).speechText).toBe(expected);
  });
  test(`${engine} a URL cannot absorb the zero-width done insertion`, () => {
    const source = "- [x] see https://example.com/a\n- [ ] next";
    const p = projectSpeakableText(source, [], engine);
    expect(p.speechText).toBe("see example dot com slash a, done. next.");
    const inserted = p.ranges.filter(r => r.kind === "insertion" && p.speechText.slice(r.speech.start, r.speech.end).includes("done"));
    expect(inserted).toHaveLength(1);
    expect(inserted[0].display.start).toBe(inserted[0].display.end);
    const words = alignWordBoundariesToDisplayText(source, p.speechText, timings(p.speechText), p.ranges);
    expect(words.find(w => w.text === "https://example.com/a")).toMatchObject({ offset_ms: 300, duration_ms: 1400 });
    expect(words.find(w => w.text === "next")).toMatchObject({ offset_ms: 2100, duration_ms: 200 });
  });
  test(`${engine} a stray backtick cannot pair across a fenced block`, () => {
    const source = "Stray ` before.\n```ts\nconst value = 1;\n```\n- [x] Call Dana `after`";
    const selection = projectStructuredSpeech(source).speechText;
    expect(selection).toContain("Call Dana after, done.");
    expect(projectSpeakableText(source, [], engine).speechText).toContain("Call Dana after, done.");
  });
}
test("selection keeps only spans that require literal protection on a mixed code line", () => {
  const selected = projectStructuredSpeech("Write `foo` and `[x]` and `echo $1`").speechText;
  expect(selected).toBe("Write foo and `[x]` and `echo $1`");
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText(selected, [], engine).speechText).toBe(engine === "clone" ? "Write foo and open bracket x close bracket and echo $1" : "Write foo and [x] and echo $1");
  }
});

for (const engine of ["edge", "clone"] as const) test(`${engine} checked literal code keeps a separate completion at the item end`, () => {
  const source = "- [x] `echo $1`";
  const p = projectSpeakableText(source, [], engine);
  expect(p.speechText).toBe("echo $1, done.");
  const done = p.ranges.find(r => p.speechText.slice(r.speech.start, r.speech.end).includes("done"));
  expect(done).toMatchObject({ kind: "insertion", display: {start: source.length, end: source.length} });
  expect(projectSpeakableText(projectStructuredSpeech(source).speechText, [], engine).speechText).toBe("echo $1, done.");
});
test("selection literal placeholders never replace captured private-use characters", () => {
  const source = "Keep \uE0000\uE001 beside `foo` and `echo $1`";
  expect(projectStructuredSpeech(source).speechText).toBe("Keep \uE0000\uE001 beside foo and `echo $1`");
});

for (const engine of ["edge", "clone"] as const) test(`${engine} URL commas remain part of the source replacement before completion`, () => {
  const source = "- [x] see https://example.com/a,b";
  const p = projectSpeakableText(source, [], engine);
  const url = p.ranges.find(r => r.kind === "replacement" && r.display.start === source.indexOf("https://"));
  expect(url?.display.end).toBe(source.length);
  expect(p.speechText).toBe("see example dot com slash a,b, done.");
  expect(p.ranges.find(r => p.speechText.slice(r.speech.start, r.speech.end).includes("done"))?.kind).toBe("insertion");
});

for (const engine of ["edge", "clone"] as const) {
  for (const [source, expected] of [
    ["- [x] Parent\n  - [ ] Child", "Parent, done. Child."],
    ["- [ ] Parent\n  - [x] Child", "Parent. Child, done."],
    ["- [x] Parent\n  - Child", "Parent, done. Child."],
    ["- [x] Parent\n  1. Child", "Parent, done. one. Child."],
    ["- [x]\n  Call Dana", "Call Dana, done."],
  ]) test(`${engine} list boundaries keep each task's completion with its own body: ${source}`, () => {
    expect(projectSpeakableText(source, [], engine).speechText).toBe(expected);
    const selected = projectStructuredSpeech(source).speechText;
    expect(projectSpeakableText(selected, [], engine).speechText).toBe(expected);
  });
  for (const code of ["`a[0]`", "`[`", "`cost=$5 [`", "`a[0.5`", "`a[0.5]`"]) {
    test(`${engine} code brackets do not change the state of a later task: ${code}`, () => {
      const source = code + "\n- [x] Task";
      for (const read of [source, projectStructuredSpeech(source).speechText]) {
        const p = projectSpeakableText(read, [], engine);
        expect(p.speechText).toEndWith("Task, done.");
        expect(p.speechText).not.toContain("[x]");
      }
    });
  }
}

for (const engine of ["edge", "clone"] as const) {
  for (const source of ["- `[x] $5`", "- `[x] 3.14`", "- `[x] reply-draft.md`", "`- [x] $5`", "`- [x] 3.14`"]) {
    test(`${engine} protected code checkboxes never acquire completion: ${source}`, () => {
      for (const read of [source, projectStructuredSpeech(source).speechText]) {
        const p = projectSpeakableText(read, [], engine);
        expect(p.speechText).not.toContain(", done");
        expect(p.speechText).not.toContain("`");
      }
    });
  }
  test(`${engine} Bugbot wrapped empty marker shares the continuation-body completion fix`, () => {
    const source = "- [x]\n  Call Dana";
    expect(projectStructuredSpeech(source).speechText).toBe("Call Dana, done.");
    expect(projectSpeakableText(source, [], engine).speechText).toBe("Call Dana, done.");
    expect(projectSpeakableText(projectStructuredSpeech(source).speechText, [], engine).speechText).toBe("Call Dana, done.");
  });
}
