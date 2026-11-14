import { describe, expect, it } from "bun:test";
import { BUILTIN_STT_DICTIONARY_ENTRIES } from "../stt-vocabulary-store";

// Bundled vocabulary policy: publish generic developer terms; keep personal entries private.
// Settings › Dictionary (U3b) shows these rows as "Included terms". Adding a row here is a reviewed,
// public decision: extend this list in the same PR, and keep it to generic developer vocabulary.
const REVIEWED_GENERIC_DEVELOPER_TERMS = [
  "Full Stack", "Front-end", "Front", "Back-end", "Back", "Go", "Figma", "React Native", "Svelte", "Bubble",
  "Kubernetes",
];

describe("bundled dictionary", () => {
  it("ships only the reviewed generic developer terms", () => {
    expect(BUILTIN_STT_DICTIONARY_ENTRIES.map((entry) => entry.canonical)).toEqual(
      REVIEWED_GENERIC_DEVELOPER_TERMS,
    );
  });

  it("carries no personal fields", () => {
    for (const entry of BUILTIN_STT_DICTIONARY_ENTRIES) {
      expect(Object.keys(entry).sort()).toEqual(["canonical", "variants"]);
    }
  });
});

import { cleanupTranscriptionText } from "../stt-cleanup";
import { finalizeTranscriptionTextForSurface } from "../input";

const env = { ...process.env, QA_VOICE_CORRECTOR: "off", QA_VOICE_STT_POLISH: "off" };
const cases = [
  ["open text edit", "Open TextEdit"],
  ["paste into text edit", "Paste into TextEdit"],
  ["the text edit app", "The TextEdit app"],
  ["in text edit", "In TextEdit"],
  ["launch the text edit", "Launch the TextEdit"],
  ["switch to text edit", "Switch to TextEdit"],
  ["quit the text edit", "Quit the TextEdit"],
  ["from text edit", "From TextEdit"],
  ["into text edit", "Into TextEdit"],
  ["text edit window", "TextEdit window"],
  ["text edit document", "TextEdit document"],
  ["text edit doc", "TextEdit doc"],
  ["open text edit please", "Open TextEdit please"],
  ["make a text edit to the doc", "Make a text edit to the doc"],
  ["I did a quick text edit", "I did a quick text edit"],
  ["one small text edit", "1 small text edit"],
  ["a text edit", "A text edit"],
  ["edit the text please", "Edit the text please"],
  ["text editing and context editor", "Text editing and context editor"],
] as const;
for (const [raw, expected] of cases) {
  it(`uses app context for ${raw}`, async () => {
    expect(cleanupTranscriptionText(raw, env)).toBe(expected);
    for (const surface of ["dictation", "voice_ask"] as const) {
      const result = await finalizeTranscriptionTextForSurface(raw, surface, env);
      // Finalization adds terminal punctuation; compare via the same floor.
      expect(result).toBe(restoreSentencePunctuation(expected));
    }
  });
}
import { restoreSentencePunctuation } from "../stt-punctuation";
