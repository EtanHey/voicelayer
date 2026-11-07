import { describe, expect, it } from "bun:test";
import { BUILTIN_STT_DICTIONARY_ENTRIES } from "../stt-vocabulary-store";

// AGENTS.md: "The bundled dictionary carries common developer terms, not my personal entries."
// Settings › Dictionary (U3b) shows these rows as "Included terms". Adding a row here is a reviewed,
// public decision: extend this list in the same PR, and keep it to generic developer vocabulary.
const REVIEWED_GENERIC_DEVELOPER_TERMS = [
  "Full Stack", "Front-end", "Front", "Back-end", "Back", "Go", "Figma", "React Native", "Svelte", "Bubble",
  "Kubernetes", "TextEdit",
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

it("normalizes TextEdit only when its bundled surface matches", async () => {
  const env = { ...process.env, QA_VOICE_CORRECTOR: "off", QA_VOICE_STT_POLISH: "off" };
  expect(cleanupTranscriptionText("open text edit please", env)).toBe("Open TextEdit please");
  expect(cleanupTranscriptionText("edit the text please", env)).toBe("Edit the text please");
  expect(cleanupTranscriptionText("text editing and context editor", env)).toBe("Text editing and context editor");
  for (const surface of ["dictation", "voice_ask"] as const) {
    expect(await finalizeTranscriptionTextForSurface("open text edit please", surface, env))
      .toBe("Open TextEdit please.");
  }
});
