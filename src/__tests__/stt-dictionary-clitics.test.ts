import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { applyRules } from "../rules-engine";
import { cleanupTranscriptionText } from "../stt-cleanup";
import { addAlias } from "../stt-vocabulary-store";

// A fixture alias in a temporary store, never a bundled personal dictionary.
const aliases = { Liganta: "Liran Tal" };
const disabledStages = new Set(["punctuation", "numbers", "fillers", "capitalization", "techVocab", "codeTokens", "caseFormatting", "enumerators"]);
let directory: string;
let env: { QA_VOICE_STT_VOCABULARY_PATH: string; QA_VOICE_STT_COMMANDS_DIR: string };
beforeAll(() => {
  directory = mkdtempSync(join(tmpdir(), "vocab-clitics-"));
  env = { QA_VOICE_STT_VOCABULARY_PATH: join(directory, "fixture.json"), QA_VOICE_STT_COMMANDS_DIR: "" };
  addAlias({ from: "Liganta", to: "Liran Tal" }, { path: env.QA_VOICE_STT_VOCABULARY_PATH });
});
afterAll(() => rmSync(directory, { recursive: true, force: true }));

for (const [heard, correct] of [
  ["Liganta's", "Liran Tal's"], ["Liganta’s", "Liran Tal’s"],
  ["Ligantas'", "Liran Tal's"], ["Ligantas’", "Liran Tal’s"],
  ["LIGANTA'S", "Liran Tal's"], ["Liganta", "Liran Tal"],
]) {
  test(`stored alias corrects ${heard} and retains every surrounding word`, () => {
    const raw = `Keep ${heard} CLI tool and the the fu… final words.`;
    const expected = `Keep ${correct} CLI tool and the the fu… final words.`;
    expect(applyRules(raw, { aliases, disabledStages })).toBe(expected);
    expect(cleanupTranscriptionText(raw, env)).toBe(expected);
  });
}

for (const literal of [
  "Ligantas", "Liganta’d", "Liganta'll", "Liganta'something", "Liganta's…", "Liganta's-",
  "Liganta…", "Ligantas'…", "preLiganta's", "Liganta'sשלום", "Liganta's_value",
  "src/Liganta's.ts", "Liganta's@example.invalid", "Liganta's.value", "`Liganta's`",
  "```text\nLiganta's\n```", "Liranthalsilai",
]) {
  test(`leaves unrecognized or literal surface ${literal} intact`, () => {
    expect(applyRules(literal, { aliases, disabledStages })).toBe(literal);
  });
}

test("canonical spelling normalization also retains the clitic", () => {
  expect(cleanupTranscriptionText("Keep liran tal’s CLI tool.", env)).toBe("Keep Liran Tal’s CLI tool.");
});

test("a longer explicitly stored possessive alias still wins", () => {
  expect(applyRules("Liganta's CLI", {
    aliases: { ...aliases, "Liganta's": "Example's" }, disabledStages,
  })).toBe("Example's CLI");
});

test("clitics also work on numbered terms, internal apostrophes and non-Latin replacements", () => {
  expect(applyRules("gpt4’s and darcy's and noriya's tools", {
    aliases: { gpt4: "GPT-4", darcy: "D'Arcy", noriya: "נוריה" }, disabledStages,
  })).toBe("GPT-4’s and D'Arcy's and נוריה's tools");
});
