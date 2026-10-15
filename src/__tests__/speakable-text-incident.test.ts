import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { projectSpeakableText, type SpeakableText } from "../speakable-text";
import { projectStructuredSpeech } from "../tts/structured-speech";

const fixture = (file: string) => readFileSync(new URL(`./fixtures/tts-incident-2026-10-16/${file}`, import.meta.url), "utf8");
const sample = fixture("sample.md");
function partitions(input: string, result: SpeakableText) {
  expect(result.displayText).toBe(input);
  let source = 0, speech = 0;
  for (const range of result.ranges) {
    expect(range.source.start).toBe(source); expect(range.speech.start).toBe(speech);
    expect(range.display).toEqual(range.source);
    expect(range.source.end).toBeGreaterThanOrEqual(source);
    expect(range.speech.end).toBeGreaterThanOrEqual(speech);
    if (range.kind === "identity") expect(input.slice(source, range.source.end)).toBe(result.speechText.slice(speech, range.speech.end));
    source = range.source.end; speech = range.speech.end;
  }
  expect(source).toBe(input.length); expect(speech).toBe(result.speechText.length);
}

for (const engine of ["clone", "edge"] as const) test(`incident exact ${engine} projection, raw and after FMT1`, () => {
  const structured = projectStructuredSpeech(sample);
  expect(structured.displayText).toBe(sample);
  for (const input of [sample, structured.speechText]) {
    const result = projectSpeakableText(input, [], engine);
    expect(result.speechText).toBe(fixture(`${engine}.txt`).trimEnd());
    partitions(input, result);
  }
});

const cases: [string, string][] = [
  ['Before `{"tickets":[]}` after.', "Before tickets: an empty list after."],
  ['{"tickets": [], "meta": {}}', "tickets: an empty list, meta: an empty object"],
  ['{"tickets":[1,2],"ok":true,"next":null}', "tickets: list: 1, 2, ok: true, next: null"],
  ['{"text":"Wrong", "name":"hot_location"}', "text: Wrong, name: hot location"],
  ['["שלום", "🙂", "a\\\"b"]', "list: שלום, 🙂, a b"],
  ['{"count":9007199254740993,"value":1.25}', "count: 9007199254740993, value: 1.25"],
  ['`items[0]` and `{"tickets":`', "items open bracket 0 close bracket and open brace tickets:"],
  ['`fn({key: []})`', "fn(open brace key: an empty list close brace )"],
  ['He said "Wrong"; don\'t drop words.', "He said Wrong; don't drop words."],
  ["part1-prompt/v6/", "part one prompt slash v six"],
  ["./part1-prompt/v6/", "dot slash part one prompt slash v six"],
  ["../part1-prompt/v6/", "dot dot slash part one prompt slash v six"],
  ["C:\\part1-prompt\\v6\\", "C: slash part one prompt slash v six"],
  ["part1-prompt/v6/ part1-prompt/v6/", "part one prompt slash v six part one prompt slash v six"],
  ["5,000 mm and 1 mm, 0.5 mm or -5 mm.", "5,000 millimeters and 1 millimeter, 0.5 millimeters or -5 millimeters."],
  ["5 mmHg, 5 MM, 5 mms, 5 mm2; mmm", "5 mmHg, 5 MM, 5 mms, 5 mm two; mmm"],
  ["שלום 5,000 mm", "שלום 5,000 millimeters"],
];
for (const [input, expected] of cases) test(`clone incident family: ${input}`, () => {
  const result = projectSpeakableText(input, [], "clone");
  expect(result.speechText).toBe(expected);
  expect(result.speechText).not.toMatch(/[{}\[\]"]/);
  partitions(input, result);
});

test("Edge retains code, directory and measurement policy", () => {
  expect(projectSpeakableText('`{"tickets":[]}` part1-prompt/v6/ 5,000 mm', [], "edge").speechText)
    .toBe('{"tickets":[]} v6 5,000 mm');
});

test("dictionary overrides inside JSON and directories keep source ownership", () => {
  const rules = [{pattern: /tickets/g, replacement: "support requests"}, {pattern: /prompt/g, replacement: "instructions"}];
  const input = '{"tickets":[]} part1-prompt/v6/';
  const result = projectSpeakableText(input, rules, "clone");
  expect(result.speechText).toBe("support requests: an empty list part one instructions slash v six");
  partitions(input, result);
});

test("expanded JSON, paths, units and repeated words retain click targets", async () => {
  const { alignWordBoundariesToDisplayText: align } = await import("../tts");
  const input = '🙂 Before {"tickets":[]} after part1-prompt/v6/ then 5,000 mm after';
  for (const engine of ["clone", "edge"] as const) {
    const result = projectSpeakableText(input, [], engine);
    const spoken = result.speechText.split(/\s+/);
    const timings = spoken.map((text, i) => ({text, offset_ms: i * 100, duration_ms: 50}));
    const aligned = align(input, result.speechText, timings, result.ranges);
    expect(aligned.map(word => word.text)).toEqual(input.split(/\s+/));
    const after = aligned.filter(word => word.text === "after");
    expect(after.map(word => word.offset_ms)).toEqual(spoken.flatMap((word, i) => word === "after" ? [i * 100] : []));
    const unit = aligned.find(word => word.text === "mm")!;
    expect(unit.offset_ms).toBe(spoken.indexOf(engine === "clone" ? "millimeters" : "mm") * 100);
    const path = aligned.find(word => word.text === "part1-prompt/v6/")!;
    expect(path.offset_ms).toBe(spoken.indexOf(engine === "clone" ? "part" : "v6") * 100);
    partitions(input, result);
  }
});
