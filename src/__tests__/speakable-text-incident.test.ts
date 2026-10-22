import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { projectSpeakableText, type SpeakableText } from "../speakable-text";
import { projectStructuredSpeech } from "../tts/structured-speech";

const fixture = (file: string) => readFileSync(new URL(`./fixtures/tts-incident-2026-10-16/${file}`, import.meta.url), "utf8");
// Invented moon-garden exercise; preserves the original regression syntax only.
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
  ['{"text":"Wrong", "name":"moon_garden"}', "text: Wrong, name: moon garden"],
  ['["שלום", "🙂", "a\\\"b"]', "list: שלום, 🙂, a b"],
  ['{"count":9007199254740993,"value":1.25}', "count: 9007199254740993, value: 1.25"],
  ['{"text":""} {} []', "text: empty string an empty object an empty list"],
  ['{"x":1}{"x":2}', "x: 1 x: 2"],
  ['{}[]', "an empty object an empty list"],
  ['{"text":"a\\u0000b"}', "text: a control zero b"],
  ['`items[0]` and `{"tickets":`', "items open bracket 0 close bracket and open brace tickets:"],
  ['`fn({key: []})`', "fn( open brace key: an empty list close brace )"],
  ['He said "Wrong"; don\'t drop words.', "He said Wrong; don't drop words."],
  ["part2-layout/v4/", "part two layout slash v four"],
  ["Read part2-layout/v4/.", "Read part two layout slash v four."],
  ["Read part2-layout/v4/, then.", "Read part two layout slash v four, then."],
  ["./part2-layout/v4/", "dot slash part two layout slash v four"],
  ["../part2-layout/v4/", "dot dot slash part two layout slash v four"],
  ["C:\\part2-layout\\v4\\", "C: slash part two layout slash v four"],
  ["part2-layout/v4/ part2-layout/v4/", "part two layout slash v four part two layout slash v four"],
  ["5,000 mm and 1 mm, 0.5 mm or -5 mm.", "5,000 millimeters and 1 millimeter, 0.5 millimeters or -5 millimeters."],
  ["5 mmHg, 5 MM, 5 mms, 5 mm2; mmm", "5 mm hg, 5 MM, 5 mms, 5 mm two; mmm"],
  ["שלום 5,000 mm", "שלום 5,000 millimeters"],
  ["5,00 mm and 5..0 mm", "5,00 mm and 5..0 mm"],
];
for (const [input, expected] of cases) test(`clone incident family: ${input}`, () => {
  const result = projectSpeakableText(input, [], "clone");
  expect(result.speechText).toBe(expected);
  expect(result.speechText).not.toMatch(/[{}\[\]"]/);
  partitions(input, result);
});

test("Edge retains code, directory and measurement policy", () => {
  expect(projectSpeakableText('`{"tickets":[]}` part2-layout/v4/ 5,000 mm', [], "edge").speechText)
    .toBe('{"tickets":[]} v4 5,000 mm');
  expect(projectSpeakableText("part2-layout/v4/", [{pattern: /layout/g, replacement: "custom instructions"}], "edge").speechText).toBe("v4/");
  expect(projectSpeakableText("https://github.com/API/", [{pattern: /API/g, replacement: "custom"}], "edge").speechText).toBe("github dot com slash custom/");
});

test("dictionary overrides inside JSON and directories keep source ownership", () => {
  const rules = [{pattern: /tickets/g, replacement: "support requests"}, {pattern: /layout/g, replacement: "instructions"}];
  const input = '{"tickets":[]} part2-layout/v4/';
  const result = projectSpeakableText(input, rules, "clone");
  expect(result.speechText).toBe("support requests: an empty list part two instructions slash v four");
  partitions(input, result);
  expect(projectSpeakableText("part2-layout/v4/", [{pattern: /part2-layout\/v4\//g, replacement: "chosen folder"}]).speechText).toBe("chosen folder");
  expect(projectSpeakableText("part2-layout/v4/", [{pattern: /part2-layout/g, replacement: "chosen folder"}]).speechText).toBe("chosen folder slash v four");
  expect(projectSpeakableText("5,000 mm", [{pattern: /mm/g, replacement: "custom unit"}]).speechText).toBe("5,000 custom unit");
});

test("clone symbol safety also applies to dictionary output", () => {
  const input = "Read API now";
  const rules = [{pattern: /API/g, replacement: '{"tickets":[]}'}];
  const result = projectSpeakableText(input, rules, "clone");
  expect(result.speechText).not.toMatch(/[{}\[\]"“”]/);
  expect(projectSpeakableText(input, rules, "edge").speechText).toBe('Read {"tickets":[]} now');
  partitions(input, result);
});

test("clone JSON/code scan uses less than 50 ms CPU at 2,000 characters", () => {
  const inputs = ['{"tickets":[]}'.repeat(140), "[".repeat(999) + "1" + "]".repeat(999), "{".repeat(2000)];
  for (const input of inputs) {
    projectSpeakableText(input); // Warm JIT tiers before measuring each input.
    let bestCpu = Infinity;
    for (let attempt = 0; attempt < 3; attempt++) {
      const start = process.cpuUsage();
      const result = projectSpeakableText(input);
      // Best warm call reduces host/JIT noise without relaxing the work budget.
      const cpu = process.cpuUsage(start);
      bestCpu = Math.min(bestCpu, cpu.user + cpu.system);
      expect(result.speechText).not.toMatch(/[{}\[\]"]/);
      partitions(input, result);
    }
    expect(bestCpu).toBeLessThan(50_000);
  }
});

test("expanded JSON, paths, units and repeated words retain click targets", async () => {
  const { alignWordBoundariesToDisplayText: align } = await import("../tts");
  const input = '🙂 Before {"tickets":[]} after part2-layout/v4/ then 5,000 mm after';
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
    const path = aligned.find(word => word.text === "part2-layout/v4/")!;
    expect(path.offset_ms).toBe(spoken.indexOf(engine === "clone" ? "part" : "v4") * 100);
    partitions(input, result);
  }
});

// Round 2: every clone path component survives, not only explicit directories.
for (const [input, clone, edge] of [
  ["part2-layout/v4", "part two layout slash v four", "v4"],
  ["/app/src/config.json", "slash app slash src slash config dot JSON", "config dot JSON"],
  ["C:\\app\\src\\config.json", "C: slash app slash src slash config dot JSON", "config dot JSON"],
  ["C:/app/src/config.json", "C: slash app slash src slash config dot JSON", "C:config dot JSON"],
  ["app\\src\\config.json", "app slash src slash config dot JSON", "app\\src\\config dot JSON"],
  ["./part2-layout/v4/config.json", "dot slash part two layout slash v four slash config dot JSON", "config dot JSON"],
  ["Read /app/src/config.json.", "Read slash app slash src slash config dot JSON.", "Read config dot JSON."],
] as const) test(`round 2 full path: ${input}`, () => {
  for (const [engine, expected] of [["clone", clone], ["edge", edge]] as const) {
    const result = projectSpeakableText(input, [], engine);
    expect(result.speechText).toBe(expected);
    partitions(input, result);
  }
});

test("round 2 path dictionary overrides preserve the other components", () => {
  const rules = [{pattern: /config/g, replacement: "settings"}];
  for (const suffix of ["", "/"]) {
    const result = projectSpeakableText(`/app/src/config.json${suffix}`, rules);
    expect(result.speechText).toBe("slash app slash src slash settings dot JSON");
    partitions(`/app/src/config.json${suffix}`, result);
  }
});

test("round 2 full clone paths retain Hebrew components verbatim", () => {
  for (const [input, speech] of [["/app/שלום/config.json", "slash app slash שלום slash config dot JSON"],
    ["שלום/config.json", "שלום slash config dot JSON"]]) {
    const result = projectSpeakableText(input);
    expect(result.speechText).toBe(speech);
    partitions(input, result);
  }
});

test("round 2 JSON spelling follows the dictionary rather than jason", () => {
  for (const engine of ["clone", "edge"] as const) {
    expect(projectSpeakableText("JSON json config.json config.jsonl", [], engine).speechText)
      .toBe("JSON JSON config dot JSON config dot JSON L");
    expect(projectSpeakableText("JSON config.json", [{pattern: /JSON/gi, replacement: "J S O N"}], engine).speechText)
      .toBe("J S O N config dot J S O N");
  }
});

for (const body of ['hello \\"world\\" after', 'hello wo\\u0072ld after', 'hello \\"world\\" after again']) test(`round 2 granular JSON escapes: ${body}`, async () => {
  const { alignWordBoundariesToDisplayText: align } = await import("../tts");
  const input = `Before {"message":"${body}"} tail`;
  const result = projectSpeakableText(input);
  const speech = "Before message: hello world after" + (body.endsWith("again") ? " again" : "") + " tail";
  expect(result.speechText).toBe(speech);
  const timings = speech.split(/\s+/).map((text, i) => ({text, offset_ms: i * 100, duration_ms: 50}));
  const aligned = align(input, speech, timings, result.ranges);
  expect(aligned.map(word => word.text)).toEqual(input.split(/\s+/));
  expect(aligned[2].offset_ms).toBe(300); // original escaped world token
  expect(aligned[3].offset_ms).toBe(400); // literal after retains its own onset
  if (body.endsWith("again")) expect(aligned[4].offset_ms).toBe(500);
  expect(aligned.at(-1)!.offset_ms).toBe(timings.at(-1)!.offset_ms);
  partitions(input, result);
});
