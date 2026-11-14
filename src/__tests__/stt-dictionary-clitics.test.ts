import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { applyRules } from "../rules-engine";
import { cleanupTranscriptionText } from "../stt-cleanup";
import { addAlias } from "../stt-vocabulary-store";

// A fixture alias in a temporary store, never a bundled personal dictionary.
const aliases = { Zelmora: "Garden Tool" };
const possessiveAliasSources = new Set(["zelmora"]);
const disabledStages = new Set(["punctuation", "numbers", "fillers", "capitalization", "techVocab", "codeTokens", "caseFormatting", "enumerators"]);
let directory: string;
let env: { QA_VOICE_STT_VOCABULARY_PATH: string; QA_VOICE_STT_COMMANDS_DIR: string };
beforeAll(() => {
  directory = mkdtempSync(join(tmpdir(), "vocab-clitics-"));
  env = { QA_VOICE_STT_VOCABULARY_PATH: join(directory, "fixture.json"), QA_VOICE_STT_COMMANDS_DIR: "" };
  addAlias({ from: "Zelmora", to: "Garden Tool" }, { path: env.QA_VOICE_STT_VOCABULARY_PATH });
});
afterAll(() => rmSync(directory, { recursive: true, force: true }));

for (const [heard, correct] of [
  ["Zelmora's", "Garden Tool's"], ["Zelmora’s", "Garden Tool’s"],
  ["ZELMORA'S", "Garden Tool'S"], ["Zelmora’S", "Garden Tool’S"], ["Zelmora", "Garden Tool"],
]) {
  test(`stored alias corrects ${heard} and retains every surrounding word`, () => {
    const raw = `Keep ${heard} CLI tool and the the fu… final words.`;
    const expected = `Keep ${correct} CLI tool and the the fu… final words.`;
    expect(applyRules(raw, { aliases, possessiveAliasSources, disabledStages })).toBe(expected);
    expect(cleanupTranscriptionText(raw, env)).toBe(expected);
  });
}

for (const literal of [
  "Zelmoras", "Zelmoras'", "Zelmoras’", "SQLites'", "SQLites’", "Zelmora’d", "Zelmora'll", "Zelmora'something", "Zelmora's…", "Zelmora's-",
  "Zelmora…", "Zelmoras'…", "preZelmora's", "Zelmora'sשלום", "Zelmora's_value",
  "src/Zelmora's.ts", "Zelmora's@example.com", "Zelmora's.value", "`Zelmora's`",
  "Velnora literal", "Velnora plain",
]) {
  test(`leaves unrecognized or literal surface ${literal} intact`, () => {
    expect(applyRules(literal, { aliases, possessiveAliasSources, disabledStages })).toBe(literal);
  });
}

test("a stored canonical term without an alias hit does not opt into possessives", () => {
  expect(cleanupTranscriptionText("Keep garden tool’s CLI tool.", env)).toBe("Keep garden tool’s CLI tool.");
});

test("a longer explicitly stored possessive alias still wins", () => {
  expect(applyRules("Zelmora's CLI", {
    aliases: { ...aliases, "Zelmora's": "Example's" }, possessiveAliasSources, disabledStages,
  })).toBe("Example's CLI");
});

test("clitics also work on numbered terms, internal apostrophes and non-Latin replacements", () => {
  expect(applyRules("gpt4’s and darcy's and noriya's tools", {
    aliases: { gpt4: "GPT-4", darcy: "D'Arcy", noriya: "נוריה" },
    possessiveAliasSources: new Set(["gpt4", "darcy", "noriya"]), disabledStages,
  })).toBe("GPT-4’s and D'Arcy's and נוריה's tools");
});

for (const raw of [
  "He said 'talk to the Zelmoras' and left.", "He said ‘talk to the Zelmoras’ and left.",
  "Keep Zelmoras' CLI tool.", "Keep Zelmoras’ CLI tool.",
]) {
  test(`stored aliases conserve plural words and closing quotes: ${raw}`, () => {
    expect(applyRules(raw, { aliases, possessiveAliasSources, disabledStages })).toBe(raw);
    expect(cleanupTranscriptionText(raw, env)).toBe(raw);
  });
}

const emptyVocabulary = { QA_VOICE_STT_VOCABULARY_PATH: "", QA_VOICE_STT_COMMANDS_DIR: "" };
test("the built-in carabiner alias still applies without a possessive", () => {
  expect(cleanupTranscriptionText("Keep carabiner config.", emptyVocabulary)).toBe("Keep Karabiner config.");
});

for (const raw of ["Zelmoras'", "Zelmoras’", "SQLites'", "SQLites’"]) {
  test(`cleanup conserves the complete plural surface ${raw}`, () => {
    expect(cleanupTranscriptionText(raw, env)).toBe(raw);
    expect(cleanupTranscriptionText(raw, emptyVocabulary)).toBe(raw);
  });
}

for (const [raw, expected] of [
  ["the ollamas' configs", "The ollamas' configs"],
  ["both SQLites' locks", "Both SQLites' locks"],
  ["she said 'use ollamas' yesterday", "She said 'use ollamas' yesterday"],
  ["she said ‘use ollamas’ yesterday", "She said ‘use ollamas’ yesterday"],
  ["I said 'ComfyUIs' twice", "I said 'ComfyUIs' twice"],
  ["I said ‘ComfyUIs’ twice", "I said ‘ComfyUIs’ twice"],
]) {
  test(`review probe changes only existing sentence capitalization: ${raw}`, () => {
    expect(cleanupTranscriptionText(raw, emptyVocabulary)).toBe(expected);
  });
}

for (const raw of [
  "Keep carabiner's config.", "Keep carabiner’s config.", "Keep claude md's rules.",
  "Keep gpts' outputs.", "Keep the ollamas' configs.", "Keep both SQLites' locks.",
  "She said 'use ollamas' yesterday.", "She said ‘use ollamas’ yesterday.",
  "I said 'ComfyUIs' twice.", "I said ‘ComfyUIs’ twice.",
  "Keep sqlite's locks and ollama’S configs.", "Keep gpt's outputs and comfyui’s tools.",
]) {
  test(`empty vocabulary leaves built-in possessives and plurals untouched: ${raw}`, () => {
    expect(cleanupTranscriptionText(raw, emptyVocabulary)).toBe(raw);
  });
}

test("possessives require explicit stored-alias authority even with a warm pattern cache", () => {
  const raw = "Zelmora'S plan";
  expect(applyRules(raw, { aliases, disabledStages })).toBe(raw);
  expect(applyRules(raw, { aliases, possessiveAliasSources, disabledStages })).toBe("Garden Tool'S plan");
  expect(applyRules(raw, { aliases, disabledStages })).toBe(raw);
});
