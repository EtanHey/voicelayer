import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";

// Adapted R01 corpus: full clone paths, bounded URLs, complete hex literals,
// unchanged prose numbers, and ordered table cells (no invented/repeated headers).
const corpus: [string, string][] = [
  ["INCIDENT-INVENTORY.md", "incident inventory dot M D"],
  ["Export the audio as MP3 or WAV.", "Export the audio as M P three or wave."],
  ["/Users/dev/app/qwen3_tts/qwen3_tts.py", "slash Users slash dev slash app slash qwen three T T S slash qwen three T T S dot P Y"],
  ["./src/components/TeleprompterView.tsx", "dot slash src slash components slash teleprompter view dot T S X"],
  ["../config/settings.yaml", "dot dot slash config slash settings dot yammel"],
  [".env.local and .gitignore", "dot E N V dot local and dot git ignore"],
  ["mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16", "M L X community slash qwen three T T S twelve hertz zero point six B base B F sixteen"],
  ["VOICE-CLONE-PROMPT-CACHE", "voice clone prompt cache"],
  ["PYTORCH_ENABLE_MPS_FALLBACK=1", "pytorch enable M P S fallback equals 1"],
  ["generate_custom_voice(ref_audio, ref_text)", "generate custom voice(ref audio, ref text)"],
  ["parseHTMLAndJSONResponse", "parse H T M L and JSON response"],
  ["Qwen3TTSForConditionalGeneration", "qwen three T T S for conditional generation"],
  ["mlx-audio-io and magic-string", "M L X audio I O and magic string"],
  ["v2.2.43", "version two point two point forty-three"],
  ["^0.5.1-rc.2", "caret zero point five point one release candidate two"],
  ["python>=3.10 and mlx>=0.32.0", "python greater than or equal to three point ten and M L X greater than or equal to zero point thirty-two point zero"],
  ["Fixed in commit d0e50f5 and 910c47c.", "Fixed in commit dee zero ee five zero eff five and nine one zero see four seven see."],
  ["cdcff72e9765342b84a5e4b5d98ca5cb050a5500", "commit see dee see eff eff seven two"],
  ["Address 0x7fff5fbff8c0 sampled token 1995.", "Address zero X seven eff eff eff five eff bee eff eff eight see zero sampled token 1995."],
  ["Encode H264 video with AAC or FLAC in UTF8.", "Encode H two sixty-four video with A A C or flack in U T F eight."],
  ["Compare fp32, bf16, int8, and Q4_K_M weights.", "Compare F P thirty-two, B F sixteen, int eight, and Q four K M weights."],
  ["https://github.com/Blaizzy/mlx-audio/issues/910", "link to github dot com"],
  ["POST http://localhost:8880/v1/audio/speech", "POST localhost port eight eight eight zero slash version one slash audio slash speech"],
  ["uv tool install --force mlx-audio --prerelease=allow", "U V tool install dash dash force M L X audio dash dash prerelease equals allow"],
  ["Check if `repetition_penalty >= 1.5` in _generate_icl.", "Check if repetition penalty greater than or equal to one point five in generate I C L."],
  ["```python\nmodel = load_model(\"Qwen3\")\n```", "code block"],
  ["| Model | Latency |\n|---|---|\n| Qwen3 | 97ms |", "Model, Latency. qwen three, ninety-seven milliseconds."],
  ["- Install espeak-ng\n- Run KPipeline", "Install espeak N G. Run K pipeline."],
  ["Send a REST API payload via gRPC to AWS S3.", "Send a rest A P I payload via G R P C to A W S S three."],
  ["Compiled for macOS 14 arm64 on M4 Max GPU.", "Compiled for mac O S 14 arm sixty-four on M four Max G P U."],
  ["שגיאה בקובץ INCIDENT-INVENTORY.md בגרסה v2.2.43", "שגיאה בקובץ incident inventory dot M D בגרסה version two point two point forty-three"],
  ["הרץ את הפקודה --join_audio כדי לשמור קובץ MP3", "הרץ את הפקודה dash dash join audio כדי לשמור קובץ M P three"],
];
for (const [display, speech] of corpus) test(display, () => {
  const result = projectSpeakableText(display);
  expect(result.displayText).toBe(display);
  expect(result.speechText).toBe(speech);
});

for (const engine of ["edge", "clone"] as const) {
  for (const [display, edge, clone] of [
    ["Completed: [x] done", "Completed: done", "Completed: done"],
    ["[ [x], y ]", "[ [x], y ]", "open bracket open bracket x close bracket , y close bracket"],
    ["{key: [x]}", "{key: [x]}", "open brace key: open bracket x close bracket close brace"],
    ["Use `[x]` here.", "Use [x] here.", "Use open bracket x close bracket here."],
    ['The token "[x]" means checked.', 'The token "[x]" means checked.', "The token open bracket x close bracket means checked."],
  ]) test(`${engine} handles checkbox edges: ${display}`, () => {
    const result = projectSpeakableText(display, [], engine);
    expect(result.displayText).toBe(display);
    expect(result.speechText).toBe(engine === "clone" ? clone : edge);
    const start = display.indexOf("[x]");
    const ranges = result.ranges.filter(range => range.source.start < start + 3 && range.source.end > start);
    expect(ranges.length).toBeGreaterThan(0);
    expect(ranges.every(range => range.kind === "omission")).toBe(display.startsWith("Completed:"));
  });
  for (const marker of ["[ ]", "[x]", "[X]"]) for (const punctuation of [".", ",", ";", ":", "!", "?", ")"]) {
    test(`${engine} silences ${marker} before ${punctuation} and keeps source ranges`, () => {
      const display = `Check ${marker}${punctuation} then go`;
      const result = projectSpeakableText(display, [], engine);
      expect(result.displayText).toBe(display);
      expect(result.speechText).toBe(`Check ${punctuation} then go`);
      const omitted = result.ranges.filter(range => range.source.start < 6 + marker.length && range.source.end > 6);
      expect(omitted.length).toBeGreaterThan(0);
      expect(omitted.every(range => range.kind === "omission")).toBe(true);
      const punctuationRange = result.ranges.find(range => range.source.start <= 6 + marker.length && range.source.end > 6 + marker.length)!;
      expect(punctuationRange.kind).toBe("identity");
      expect(result.speechText[punctuationRange.speech.start + 6 + marker.length - punctuationRange.source.start]).toBe(punctuation);
      let source = 0, speech = 0;
      for (const range of result.ranges) {
        expect(range.source.start).toBe(source); expect(range.speech.start).toBe(speech);
        expect(range.display).toEqual(range.source);
        source = range.source.end; speech = range.speech.end;
      }
      expect(source).toBe(display.length); expect(speech).toBe(result.speechText.length);
    });
  }
  const checkboxes: [string, string][] = [
    ["1. [ ] Buy milk", "one. Buy milk."],
    ["- [x] Done", "Done."],
    ["2. [X] Call Dana", "two. Call Dana."],
    ["1. [ ]Buy milk", "one. Buy milk."],
    ['Etan said "[ ] x" here', engine === "clone" ? "Etan said x here" : 'Etan said " x" here'],
    ["Before [ ] unchecked [x] checked [X] checked after", "Before unchecked checked checked after"],
    ["[ ]\n[x]\t[X]", ""],
    ["Done [x]. Next", "Done . Next"],
    ["Ready [X]!", "Ready !"],
    ["Pending [ ];", "Pending ;"],
    ["Done [x])", "Done )"],
    ["- [x];", ";."],
    ['Task lists: "1. [ ] x" is no longer spoken "one. an empty list x".', engine === "clone"
      ? "Task lists: 1. x is no longer spoken one. an empty list x."
      : 'Task lists: "1. x" is no longer spoken "one. an empty list x".'],
  ];
  for (const [display, speech] of checkboxes) test(`${engine} silences checkbox tokens: ${display}`, () => {
    const result = projectSpeakableText(display, [], engine);
    expect(result.displayText).toBe(display);
    expect(result.speechText).toBe(speech);
    for (const marker of display.matchAll(/\[[ xX]\]/g)) {
      const ranges = result.ranges.filter(range => range.source.start < marker.index + marker[0].length && range.source.end > marker.index);
      expect(ranges.length).toBeGreaterThan(0);
      expect(ranges.every(range => range.kind === "omission")).toBe(true);
    }
  });
  for (const [display, clone, edge] of [
    ["`[ ]`", "an empty list", "[ ]"],
    ["const a = []", "const a equals an empty list", "const a equals []"],
    ["const a = [ ];", "const a equals an empty list;", "const a equals [ ];"],
    ["x = [x], y", "x equals open bracket x close bracket , y", "x equals [x], y"],
    ["return [ ];", "return an empty list;", "return [ ];"],
    ["arr[x];", "arr open bracket x close bracket ;", "arr[x];"],
    ["x + [x];", "x + open bracket x close bracket ;", "x + [x];"],
    ["foo[] arr[ ]", "foo an empty list arr an empty list", "foo[] arr[ ]"],
    ["arr[x] arr[X]", "arr open bracket x close bracket arr open bracket X close bracket", "arr[x] arr[X]"],
    ["[x](https://example.com)", "x", "x"],
  ]) test(`${engine} preserves code brackets and link labels: ${display}`, () => {
    expect(projectSpeakableText(display, [], engine).speechText).toBe(engine === "clone" ? clone : edge);
  });
}

test("ranges partition original and spoken UTF-16, including repeated words and emoji", () => {
  for (const display of [...corpus.map(([text]) => text), "🙂 MP3 MP3 שלום", "", " \r\n ", "שלוםMP3 עולם_חדש"]) {
    for (const engine of ["edge", "clone"] as const) {
    const result = projectSpeakableText(display, [], engine);
    let source = 0, speech = 0;
    for (const range of result.ranges) {
      expect(range.source.start).toBe(source);
      expect(range.speech.start).toBe(speech);
      expect(range.display).toEqual(range.source);
      if (range.kind === "identity") expect(display.slice(range.display.start, range.display.end))
        .toBe(result.speechText.slice(range.speech.start, range.speech.end));
      source = range.source.end; speech = range.speech.end;
    }
    expect(source).toBe(display.length); expect(speech).toBe(result.speechText.length);
    }
  }
  expect(projectSpeakableText("שלוםMP3 עולם_חדש").speechText).toBe("שלוםMP3 עולם_חדש");
});

test("ordinary prose, Hebrew, decimals and negative numbers survive", () => {
  const text = "Hello, don't cut 3.14 or -5. שָׁלוֹם 123!";
  expect(projectSpeakableText(text).speechText).toBe(text);
});

for (const text of ["Is that OK with you?", "The meeting is at 3 PM tomorrow.", "US AM PM ID TV UK CEO ABC XYZ", "Meet on 2026.10.15 please.", "$3.50 and € 2.75 or £9.99; $3.50USD and €2,000.50", "3.5 seconds and 3.14 radians", "2026-10-15, 15.10.2026, 10/15/2026 and 1/2", "At 3:50PM or 10:30 AM and 23:59:02 or 10AM."]) test(`prose passthrough: ${text}`, () => {
  for (const engine of ["edge", "clone"] as const) expect(projectSpeakableText(text, [], engine).speechText).toBe(text);
});
test("only explicit versions expand; Edge leaves initialisms for its frontend", () => {
  expect(projectSpeakableText("version 2.2.43, release 3.10, >=3.10 and v2.2.43").speechText).toBe("version two point two point forty-three, release three point ten, greater than or equal to three point ten and version two point two point forty-three");
  expect(projectSpeakableText("MP3 S3 API XYZ OK", [], "edge").speechText).toBe("MP3 S3 API XYZ OK");
  expect(projectSpeakableText("MP3 S3 API XYZ OK", [], "clone").speechText).toBe("M P three S three A P I XYZ OK");
});

test("sticky replacement preserves a nonzero match offset on Bun 1.3.9", () => {
  // Bun 1.3.9 String.replace ignores sticky lastIndex; RegExp @@replace honors it.
  const input = "Read API.";
  const sticky = /API/y;
  sticky.lastIndex = 5;
  expect(sticky[Symbol.replace](input, "custom")).toBe("Read custom.");
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText(input, [{pattern: /API/g, replacement: "custom"}], engine).speechText)
      .toBe("Read custom.");
  }
});

test("a dictionary rule for a whole slash compound wins over the prose slash split", () => {
  const rules = [{pattern: /read\/write/g, replacement: "custom"}];
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText("read/write", rules, engine).speechText).toBe("custom");
    expect(projectSpeakableText("Use read/write mode, not client/server.", rules, engine).speechText)
      .toBe("Use custom mode, not client slash server.");
  }
});

test("a rule on one half of a prose slash compound keeps every word, in order", () => {
  const read = {pattern: /\bread\b/gi, replacement: "reed"}, write = {pattern: /\bwrite\b/gi, replacement: "right"};
  const cases: [typeof read[], string][] = [
    [[read], "Use reed slash write mode, not client slash server."],
    [[write], "Use read slash right mode, not client slash server."],
    [[read, write], "Use reed slash right mode, not client slash server."],
  ];
  for (const engine of ["edge", "clone"] as const) for (const [rules, spoken] of cases) {
    expect(projectSpeakableText("Use read/write mode, not client/server.", rules, engine).speechText).toBe(spoken);
  }
});

test("a whole-compound rule reserves its slash only when it applies in rule order", () => {
  // Rule shapes from pronunciation.ts: whole word, case-insensitive.
  const read = {pattern: /\bread\b/gi, replacement: "reed"};
  const compound = {pattern: /\bread\/write\b/gi, replacement: "custom"};
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText("Use read/write mode.", [read, compound], engine).speechText).toBe("Use reed slash write mode.");
    expect(projectSpeakableText("Use read/write mode.", [compound, read], engine).speechText).toBe("Use custom mode.");
    expect(projectSpeakableText("Use read/write mode.", [compound, {pattern: /\bcustom\b/gi, replacement: "chosen"}], engine).speechText)
      .toBe("Use chosen mode.");
    // Emphasis merges the sentence into one span; a part rule there still leaves the slash spoken.
    expect(projectSpeakableText("*Use read/write now*", [read, compound], engine).speechText).toBe("Use reed slash write now");
    expect(projectSpeakableText("*Use read/write now*", [compound, read], engine).speechText).toBe("Use custom now");
  }
});

test("dictionary rules win, including phrases and chained replacements", () => {
  const rules = [{pattern: /\bMP3 audio\b/gi, replacement: "custom voice"},
    {pattern: /\bcustom\b/gi, replacement: "Chosen"}, {pattern: /\bAPI\b/g, replacement: "ay pee eye"}];
  expect(projectSpeakableText("MP3 audio and API", rules).speechText).toBe("Chosen voice and ay pee eye");
  const fileRules = [{pattern: /\bTypeScript\b/gi, replacement: "Type Script"}];
  expect(projectSpeakableText("/app/src/TypeScript.ts TypeScript.md", fileRules).speechText).toBe("slash app slash src slash Type Script dot T S Type Script dot M D");
  expect(projectSpeakableText("TypeScript.ts", [{pattern: /\bTypeScript\.ts\b/g, replacement: "custom file"}]).speechText).toBe("custom file");
  expect(projectSpeakableText("https://github.com/API", [{pattern: /\bgithub\b/gi, replacement: "git hub"}, {pattern: /\bAPI\b/g, replacement: "custom"}]).speechText).toBe("git hub dot com slash custom");
});

test("bounded URLs, Windows basenames, Base64, and markdown link labels", () => {
  expect(projectSpeakableText("[API](https://example.com/a) https://example.com/a?q=secret").speechText)
    .toBe("A P I link to example dot com");
  expect(projectSpeakableText("C:\\app\\foo_bar.ts Base64").speechText).toBe("C: slash app slash foo bar dot T S base sixty-four");
});

test("table syntax is distinct from code operators and preserves empty cells", () => {
  expect(projectSpeakableText("`a || b` and `a | b`").speechText).toBe("a or b and a pipe b");
  expect(projectSpeakableText("Name | Value\n--- | ---\nMP3 |\n| S3").speechText).toBe("Name, Value. M P three. S three.");
  expect(projectSpeakableText("| A | B | C |\n|---|---|---|\n| MP3 | | S3 |").speechText).toBe("A, B, C. M P three, , S three.");
});

test("does not verbalize filename prose, split Hebrew-adjacent digits, or corrupt link punctuation", () => {
  expect(projectSpeakableText("e.g. this is _important_ and HTTP/2").speechText).toBe("e.g. this is important and H T T P two");
  expect(projectSpeakableText("שָׁלוֹםMP3 גרסה2.2.43").speechText).toBe("שָׁלוֹםMP3 גרסה2.2.43");
});

test("range partitions survive combined edits and ordered YAML replacements", () => {
  let seed = 7;
  const random = (n: number) => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % n; };
  const tokens = ["MP3", "API", "🙂", "שלוםMP3", "$3.50USD", "10:30AM", "2026-10-15", "1/2", "\r\n", "--flag_name", "`", "|", "- ", "TypeScript.ts", "v2.2.43", "/a/TypeScript.ts", "https://github.com/API"];
  for (let sample = 0; sample < 100; sample++) {
    const source = Array.from({length: 10}, () => tokens[random(tokens.length)]).join(" ");
    for (const engine of ["edge", "clone"] as const) {
    const result = projectSpeakableText(source, [{pattern: /\bAPI\b/g, replacement: "custom API"}, {pattern: /\bcustom\b/g, replacement: "chosen"}, {pattern: /\bTypeScript\b/g, replacement: "Type Script"}], engine);
    let original = 0, spoken = 0;
    for (const span of result.ranges) {
      expect(span.source.start).toBe(original); expect(span.speech.start).toBe(spoken);
      expect(span.source.end).toBeGreaterThanOrEqual(original); expect(span.speech.end).toBeGreaterThanOrEqual(spoken);
      original = span.source.end; spoken = span.speech.end;
    }
    expect(original).toBe(source.length); expect(spoken).toBe(result.speechText.length);
    }
  }
});

test("filename near-misses beside Hebrew stay below 50 ms in-process", () => {
  // The bounded 24-A case fails first on the old regex before larger cases run.
  for (const length of [24, 40, 1994]) for (const engine of ["edge", "clone"] as const) {
    const input = "file." + "A".repeat(length) + "א";
    const start = performance.now();
    const result = projectSpeakableText(input, [], engine);
    expect(performance.now() - start).toBeLessThan(50);
    expect(result.speechText).toBe(input);
  }
});

test("local 2,000-character pass stays below 10 ms at p95 after warmup", () => {
  const input = corpus.map(([text]) => text).join(" ").repeat(3).slice(0, 2000);
  for (const engine of ["edge", "clone"] as const) {
  for (let i = 0; i < 20; i++) projectSpeakableText(input, [], engine);
  const times = Array.from({length: 100}, () => { const start = performance.now(); projectSpeakableText(input, [], engine); return performance.now() - start; }).sort((a,b) => a-b);
  expect(times[95]).toBeLessThan(10);
  }
});
