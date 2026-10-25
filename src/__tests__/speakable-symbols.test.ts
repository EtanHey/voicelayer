import { displayTokens } from "../tts/display-tokens";
import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { alignWordBoundariesToDisplayText } from "../tts";

for (const engine of ["clone", "edge"] as const) {
  test(`${engine}: prose slash alternatives keep raw text and individual timings`, () => {
    const raw = "list/paragraph completion/cancellation";
    const p = projectSpeakableText(raw, [], engine);
    expect(p.displayText).toBe(raw);
    expect(p.speechText).toBe("list paragraph completion cancellation");
    expect(projectSpeakableText("Use list/paragraph.", [], engine).speechText).toBe("Use list paragraph.");
    const spoken = p.speechText.split(" ").map((text, i) => ({text, offset_ms: i * 200, duration_ms: 150}));
    expect(alignWordBoundariesToDisplayText(raw, p.speechText, spoken, p.ranges)).toEqual([
      {text: "list", offset_ms: 0, duration_ms: 150},
      {text: "/paragraph", offset_ms: 200, duration_ms: 150},
      {text: "completion", offset_ms: 400, duration_ms: 150},
      {text: "/cancellation", offset_ms: 600, duration_ms: 150},
    ]);
  });
  test(`${engine}: structured slash syntax retains its existing projection`, () => {
    expect(projectSpeakableText("Option+F5", [], engine).speechText).toBe(engine === "edge" ? "Option+F5" : "Option+F five");
  });
}

test("silent bullet markers receive no spoken interval", () => {
  const raw = "- Archive backend\n- Your formatting";
  const p = projectSpeakableText(raw, [], "edge");
  const timings = p.speechText.split(" ").map((text, i) => ({text, offset_ms: 100 + i * 200, duration_ms: 150}));
  const result = alignWordBoundariesToDisplayText(raw, p.speechText, timings, p.ranges);
  expect(result.filter(w => w.text === "-").map(w => w.duration_ms)).toEqual([0, 0]);
});

for (const engine of ["clone", "edge"] as const) {
  test(`${engine}: protected slash projections are exact`, () => {
    const cases = [
      ["and/or", engine === "clone" ? "and slash or" : "or"],
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
    expect(p.speechText).toBe("list paragraph,completion cancellation");
    const rows = ["list", "paragraph,completion", "cancellation"].map((text, i) => ({text, offset_ms: 100 + i * 200, duration_ms: 150}));
    expect(alignWordBoundariesToDisplayText(raw, p.speechText, rows, p.ranges)).toEqual([
      {text: "list", offset_ms: 100, duration_ms: 150},
      {text: "/paragraph,completion", offset_ms: 300, duration_ms: 150},
      {text: "/cancellation", offset_ms: 500, duration_ms: 150},
    ]);
  });
}
test("Unicode-adjacent compounds retain whole display tokens", () => {
  for (const raw of ["שלlist/paragraph", "list/paragraphשלום", "élist/paragraph", "list/paragraph\u0301"]) {
    expect(displayTokens(raw).map(t => t[0])).toEqual(raw.split(/\s+/));
  }
});
