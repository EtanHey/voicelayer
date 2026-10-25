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
    for (const raw of ["https://example.com/list/paragraph", "/list/paragraph", "./list/paragraph", "src/input.ts", "1/2", "10/26/2026"]) {
      const p = projectSpeakableText(raw, [], engine);
      expect(p.displayText).toBe(raw);
      expect(p.speechText).not.toBe("list paragraph");
      if (/^\d/.test(raw)) expect(p.speechText).toBe(raw);
    }
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
