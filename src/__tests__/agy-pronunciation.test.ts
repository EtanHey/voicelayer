import { expect, test } from "bun:test";
import { applyPronunciation, pronunciationRules } from "../pronunciation";
import { projectSpeakableText } from "../speakable-text";

for (const engine of ["edge", "clone"] as const) {
  test(`${engine}: AGY changes only engine text with one display anchor per word`, () => {
    const display = "Ask AGY now";
    const projection = projectSpeakableText(display, pronunciationRules(), engine);
    expect(projection.speechText).toBe("Ask antigravity now");
    expect(projection.displayText).toBe(display);
    const spokenWords = [...projection.speechText.matchAll(/\S+/g)];
    expect(spokenWords.map(word => {
      const range = projection.ranges.find(r => r.speech.start <= word.index && r.speech.end >= word.index + word[0].length)!;
      return display.slice(range.display.start, range.display.end);
    })).toEqual(["Ask", "AGY", "now"]);
  });
}

test("AGY pronunciation is case sensitive and Unicode whole word", () => {
  expect(applyPronunciation("AGY agy XAGY AGY2 AGY_ שלוםAGY AGYשלום (AGY)"))
    .toBe("antigravity agy XAGY AGY2 AGY_ שלוםAGY AGYשלום (antigravity)");
});
