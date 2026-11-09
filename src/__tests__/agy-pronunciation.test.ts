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
    .toBe("antigravity aggy XAGY AGY2 AGY_ שלוםAGY AGYשלום (antigravity)");
});

for (const engine of ["edge", "clone"] as const) {
  for (const [text, word] of [
    ["I used AGY yesterday", "antigravity"], ["Agy is great", "antigravity"],
    ["run `AGY --agent video-qa`", "aggy"], ["$ AGY run x", "aggy"],
    ["```sh\nagy run x\n```", "aggy"], ["/opt/homebrew/bin/agy", "aggy"],
    ["agy", "aggy"], ["AGY --agent x", "aggy"],
    ["AGY runs the review", "antigravity"], ["AGY handles it\nthen more", "antigravity"],
  ]) test(`${engine}: context ${text}`, () => {
    expect(projectSpeakableText(text, pronunciationRules(), engine).speechText).toContain(word);
  });
}

import { updatePersonalPronunciation } from "../pronunciation";
test("personal agy wins in prose, inline, paths and fences for both engines", () => {
  updatePersonalPronunciation("agy", "custom command");
  try {
    for (const engine of ["edge", "clone"] as const) for (const text of ["AGY is great", "`agy -p`", "/bin/agy", "```sh\nAGY run\n```"])
      expect(projectSpeakableText(text, pronunciationRules(), engine).speechText).toContain("custom command");
  } finally { updatePersonalPronunciation("agy", undefined); }
});
