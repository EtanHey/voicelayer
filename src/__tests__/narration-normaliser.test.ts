import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";

const cases = [
  ["₪180/h", "one hundred eighty shekels per hour"],
  ["$3.50 and € 2.75 or £9.99", "three point five zero dollars and two point seven five euros or nine point nine nine pounds"],
  ["¥1 and ₪0.05", "one yen and zero point zero five shekels"],
  ["$1,200.50USD", "one thousand two hundred point five zero dollars"],
  ["$3.50USD and €2,000.50", "three point five zero dollars and two thousand point five zero euros"],
  ["3.5 seconds and 3.14 radians", "three point five seconds and three point one four radians"],
  ["180/h, 2.50/kg and 1/unit", "one hundred eighty per hour, two point five zero per kilogram and one per unit"],
  ["Section 10.3 and 10.3.2; 3.14 or -0.05", "Section ten point three and ten point three point two; three point one four or minus zero point zero five"],
  ["See 10.3. Then 0.25%.", "See ten point three. Then zero point two five%."],
  ["reply-draft.md", "reply draft dot M D"],
  ["1/2 at 10:30 on 2026.10.15", "1/2 at 10:30 on 2026.10.15"],
  ["https://example.com/10.3", "example dot com slash 10.3"],
] as const;

for (const engine of ["edge", "clone"] as const) for (const [display, speech] of cases) {
  test(`${engine} narration: ${display}`, () => {
    const result = projectSpeakableText(display, [], engine);
    expect(result.speechText).toBe(speech);
    expect(result.displayText).toBe(display);
    let source = 0, spoken = 0;
    for (const range of result.ranges) {
      expect(range.source.start).toBe(source);
      expect(range.speech.start).toBe(spoken);
      source = range.source.end; spoken = range.speech.end;
    }
    expect(source).toBe(display.length);
    expect(spoken).toBe(speech.length);
  });
}

test("normalised amounts and rates survive an unrelated private dictionary rule", () => {
  const rules = [{ pattern: /\bACMEX\b/g, replacement: "Acmex" }];
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText("₪180/h, 180/h ACMEX", rules, engine).speechText)
      .toBe("one hundred eighty shekels per hour, one hundred eighty per hour Acmex");
  }
});
