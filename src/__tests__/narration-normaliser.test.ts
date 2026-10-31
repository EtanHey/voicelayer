import { expect, test } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { projectStructuredSpeech } from "../tts/structured-speech";

const cases = [
  ["₪180/h", "one hundred eighty shekels per hour"],
  ["$3.50 and € 2.75 or £9.99", "three point five zero dollars and two point seven five euros or nine point nine nine pounds"],
  ["¥1 and ₪0.05", "one yen and zero point zero five shekels"],
  ["$1,200.50USD", "one thousand two hundred point five zero dollars"],
  ["$3.50USD and €2,000.50", "three point five zero dollars and two thousand point five zero euros"],
  ["3.5 seconds and 3.14 radians", "three point five seconds and three point one four radians"],
  ["Balance 1,234.56", "Balance one thousand two hundred thirty-four point five six"],
  ["$1.5M", "$1.5M"],
  ["$-5.00 and -$5.00", "minus five point zero zero dollars and minus five point zero zero dollars"],
  ["$3 EUR and €3 USD", "$3 EUR and €3 USD"],
  ["3.14.txt", "3.14 dot text"],
  ["180/h, 2.50/kg and 1/unit", "one hundred eighty per hour, two point five zero per kilogram and one per unit"],
  ["Section 10.3 and 10.3.2; 3.14 or -0.05", "Section ten point three and 10.3.2; three point one four or minus zero point zero five"],
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

const roundTwoCases = [
  ["$5-$10", "five dollars-ten dollars"],
  ["US$5", "US five dollars"],
  ["-$5 and ($-5) and -5 and -5.5", "minus five dollars and (minus five dollars) and minus five and minus five point five"],
  ["$1.00", "one point zero zero dollars"],
  ["$5/hr.", "five dollars per hour."],
  ["12,34.5", "12,34.5"],
  ["₪180/H and ₪180/h/day and $5.txt and $5.5.5", "₪180/H and ₪180/h/day and $5.txt and $5.5.5"],
  ["1.5,2.5", "one point five,two point five"],
  ["192.168.1.1 and 0.0.0.0:8080 and node 22.11.0 and 2.2.58", "192.168.1.1 and 0.0.0.0:8080 and node 22.11.0 and 2.2.58"],
  ["v2.2.58", "version two point two point fifty-eight"],
  ["שלום 3.14 עולם", "שלום 3.14 עולם"],
  ["מחיר ₪180/h and 180/h and -5", "מחיר ₪180/h and 180/h and -5"],
  ["3) גרסה 3.14 נשמרת!", "3. גרסה 3.14 נשמרת!"],
] as const;
for (const engine of ["edge", "clone"] as const) {
  for (const [source, speech] of roundTwoCases) test(`${engine} round two boundaries: ${source}`, () => {
    expect(projectSpeakableText(source, [], engine).speechText).toBe(speech);
  });
  test(`${engine} rates never consume a filename suffix`, () => {
    expect(projectSpeakableText("1/day.json", [], engine).speechText)
      .toBe("1 slash day dot JSON");
  });
  for (const source of ["`echo $1`", "`awk '{print $2}'`", "`3.14`", "`₪180/h`", "`180/h`", "`reply-draft.md`", "run `cost=$5` now"]) {
    test(`${engine} inline code remains literal in raw and selection reads: ${source}`, () => {
      const selected = projectStructuredSpeech(source).speechText;
      for (const read of [source, selected]) {
        const speech = projectSpeakableText(read, [], engine).speechText;
        expect(speech).toBe(source.replace(/`/g, ""));
        expect(speech).not.toContain("`");
      }
    });
  }
}
