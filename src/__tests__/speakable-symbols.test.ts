import reviewProbes from "./fixtures/speakable-symbols-probes.json";
import protectedProbes from "./fixtures/speakable-symbols-main.json";
import { combineHistoryTimings } from "../tts/history-timings";
import { longReadDocument } from "../tts/long-read";
import { chunkTextForTTS } from "../tts";
import { displayTokens } from "../tts/display-tokens";
import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { alignWordBoundariesToDisplayText } from "../tts";

for (const engine of ["clone", "edge"] as const) {
  test(`${engine}: prose slash alternatives keep raw text and individual timings`, () => {
    const raw = "list/paragraph completion/cancellation";
    const p = projectSpeakableText(raw, [], engine);
    expect(p.displayText).toBe(raw);
    expect(p.speechText).toBe("list or paragraph completion or cancellation");
    expect(projectSpeakableText("Use list/paragraph.", [], engine).speechText).toBe("Use list or paragraph.");
    const spoken = p.speechText.split(" ").map((text, i) => ({text, offset_ms: i * 200, duration_ms: 150}));
    expect(alignWordBoundariesToDisplayText(raw, p.speechText, spoken, p.ranges)).toEqual([
      {text: "list", offset_ms: 0, duration_ms: 150},
      {text: "/paragraph", offset_ms: 200, duration_ms: 350},
      {text: "completion", offset_ms: 600, duration_ms: 150},
      {text: "/cancellation", offset_ms: 800, duration_ms: 350},
    ]);
  });
  test(`${engine}: structured slash syntax retains its existing projection`, () => {
    expect(projectSpeakableText("Option+F5", [], engine).speechText).toBe(engine === "edge" ? "Option+F5" : "Option+F five");
  });
}

test("history skips line-start bullets but interpolates mid-line operators", () => {
  for (const marker of ["-", "+", "*", "•", "◦", "▪", "‣"]) for (const separator of ["\n  ", " "]) {
    const result = combineHistoryTimings([{text: `before${separator}${marker} after`, durationMs: 1000, aligned: [
      {text: "before", word_index: 0, offset_ms: 0, duration_ms: 100},
      {text: "after", word_index: 2, offset_ms: 600, duration_ms: 100},
    ]}])!;
    expect(result[1].offset_ms).toBe(separator.includes("\n") ? null : 100);
    expect(result[1].duration_ms).toBe(separator.includes("\n") ? null : 500);
  }
});

test("stray backtick across chunks preserves document token parity", () => {
  const filler = "This sentence is filler text that keeps the chunk long enough to split here. ";
  for (const count of [6, 12]) {
    const text = "Press the ` key to open the console. " + filler.repeat(count) + "Then use list/paragraph with `code` later.";
    const chunks = chunkTextForTTS(text);
    expect(chunks.length).toBeGreaterThan(1);
    const doc = longReadDocument(text, chunks);
    const tokens = displayTokens(doc.text).map(t => t[0]);
    expect(tokens).toEqual(chunks.flatMap(t => displayTokens(t).map(t => t[0])));
    chunks.forEach((chunk, i) => expect(tokens.slice(doc.chunk_word_starts[i], doc.chunk_word_starts[i + 1])).toEqual(displayTokens(chunk).map(t => t[0])));
  }
});

for (const engine of ["edge", "clone"] as const) {
  test(`${engine}: general alphabetic alternatives`, () => {
    for (const [raw, spoken] of [["client/server", "client or server"], ["and/or", "and or"], ["List/Paragraph", "List or Paragraph"], ["read/write", "read or write"], ["lists/paragraph", "lists or paragraph"]]) {
      expect(projectSpeakableText(raw, [], engine).speechText).toBe(spoken);
      expect(displayTokens(raw).map(t => t[0])).toEqual(raw.split(/(?=\/)/));
    }
  });
  test(`${engine}: route suffixes and Markdown targets stay lexical`, () => {
    for (const suffix of ["?q=1", "#x", "%20x", "@v1", ":foo", ".ts", "/more"]) {
      const raw = "list/paragraph" + suffix;
      expect(displayTokens(raw).map(t => t[0])).toEqual([raw]);
    }
    expect(displayTokens("[x](list/paragraph)").map(t => t[0])).toEqual(["[x](list/paragraph)"]);
  });
}

for (const engine of ["clone", "edge"] as const) {
  test(`${engine}: protected slash projections are exact`, () => {
    const cases = [
      ["`Use list/paragraph here`", engine === "clone" ? "Use list slash paragraph here" : "Use paragraph here"],
      ["`list/paragraph`", engine === "clone" ? "list slash paragraph" : "paragraph"],
      ["https://example.com/list/paragraph", "example dot com slash list slash paragraph"],
      ["/list/paragraph", engine === "clone" ? "slash list slash paragraph" : "paragraph"],
      ["./list/paragraph", engine === "clone" ? "dot slash list slash paragraph" : "paragraph"],
      ["src/input.ts", engine === "clone" ? "src slash input dot T S" : "input dot T S"],
      ["1/2", "1/2"], ["10/26/2026", "10/26/2026"],
    ];
    for (const [raw, speech] of cases) {
      expect(projectSpeakableText(raw, [], engine).speechText).toBe(speech);
      expect(displayTokens(raw).map(t => t[0])).toEqual(raw.split(/\s+/));
    }
  });
  test(`${engine}: repeated compounds have independent intervals`, () => {
    const raw = "list/paragraph,completion/cancellation";
    const p = projectSpeakableText(raw, [], engine);
    expect(p.speechText).toBe("list or paragraph,completion or cancellation");
    const rows = ["list", "or", "paragraph,completion", "or", "cancellation"].map((text, i) => ({text, offset_ms: 100 + i * 200, duration_ms: 150}));
    expect(alignWordBoundariesToDisplayText(raw, p.speechText, rows, p.ranges)).toEqual([
      {text: "list", offset_ms: 100, duration_ms: 150},
      {text: "/paragraph,completion", offset_ms: 300, duration_ms: 350},
      {text: "/cancellation", offset_ms: 700, duration_ms: 350},
    ]);
  });
}
test("Unicode-adjacent compounds retain whole display tokens", () => {
  for (const raw of ["שלlist/paragraph", "list/paragraphשלום", "élist/paragraph", "list/paragraph\u0301", "😀list/paragraph", "list/paragraph😀", "list/paragraph\u200d", "\u200dlist/paragraph"]) {
    expect(displayTokens(raw).map(t => t[0])).toEqual(raw.split(/\s+/));
  }
});

test("review protected probes retain exact origin/main projections", () => {
  for (const row of protectedProbes) for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText(row.raw, [], engine).speechText).toBe(row[engine]);
    expect(displayTokens(row.raw).map(t => t[0])).toEqual(row.raw.split(/\s+/));
  }
});

test("complete review probe speech regression set", () => {
  for (const row of reviewProbes) for (const engine of ["edge", "clone"] as const)
    expect(projectSpeakableText(row.raw, [], engine).speechText).toBe(row[engine]);
});

for (const row of protectedProbes.slice(-10)) {
  test(`fix3 main-identical speech and tokens: ${JSON.stringify(row.raw)}`, () => {
    for (const engine of ["edge", "clone"] as const)
      expect(projectSpeakableText(row.raw, [], engine).speechText).toBe(row[engine]);
    expect(displayTokens(row.raw).map(t => t[0])).toEqual(row.raw.split(/\s+/));
  });
}
