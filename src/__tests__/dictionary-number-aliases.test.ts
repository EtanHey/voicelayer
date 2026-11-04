import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { cleanupTranscriptionText } from "../stt-cleanup";
import { finalizeTranscriptionTextForSurface } from "../input";
import { applyRules } from "../rules-engine";
import { TEST_TMP } from "./setup/test-tmp";

describe("Dictionary variants copied from normalized transcripts", () => {
  let root: string;
  let vocabularyPath: string;
  beforeAll(() => {
    root = mkdtempSync(join(TEST_TMP, "dictionary-numbers-"));
    vocabularyPath = join(root, "vocabulary.json");
    writeFileSync(vocabularyPath, JSON.stringify({ entries: [
      { canonical: "6.1 Sol", variants: ["6 point 1 sol"] },
      { canonical: "FixtureRunner", variants: ["fixture runner"] },
      { canonical: "8 point 2 preview", variants: ["8 point 2", "preview fixture"] },
    ] }));
  });
  afterAll(() => rmSync(root, { recursive: true, force: true }));

  const env = () => ({ QA_VOICE_STT_VOCABULARY_PATH: vocabularyPath });
  const raw = "and make it a codex six point one sol on extra high please";
  const expected = "And make it a codex 6.1 Sol on extra high please";

  it("matches the exact number-word dictation with the displayed digit variant", () => {
    expect(cleanupTranscriptionText(raw, env())).toBe(expected);
  });

  it("still matches a digit variant directly", () => {
    expect(cleanupTranscriptionText(raw.replace("six point one", "6 point 1"), env())).toBe(expected);
  });

  it("keeps a nonnumeric variant and all surrounding retractions unchanged", () => {
    expect(cleanupTranscriptionText("keep fu… fixture runner no fixture runner now", env()))
      .toBe("Keep fu… FixtureRunner no FixtureRunner now");
  });

  it.each(["8 point 2", "preview fixture"])("does not reapply a variant inside the canonical from %s", (variant) => {
    expect(cleanupTranscriptionText(`use ${variant} and two workers`, env()))
      .toBe("Use 8 point 2 preview and 2 workers");
  });

  it("does not reapply a late alias to its own source-like canonical", () => {
    expect(cleanupTranscriptionText("use eight point two and two workers", env()))
      .toBe("Use 8 point 2 preview and 2 workers");
  });

  it("preserves possessives, code, and unfinished variants on the normalized pass", () => {
    expect(cleanupTranscriptionText("use six point one sol’s and `six point one sol` and six point one sol…", env()))
      .toBe("Use 6.1 Sol’s and`six point 1 sol`and 6 point 1 sol…");
  });

  it("retains the alias policy callback on the normalized pass", () => {
    expect(applyRules("use six point one sol", {
      aliases: { "6 point 1 sol": "6.1 Sol" },
      shouldApplyAlias: () => false,
    })).toBe("Use 6 point 1 sol");
  });

  it("respects disabled aliases and number formatting", () => {
    const aliases = { "6 point 1 sol": "6.1 Sol" };
    expect(applyRules(raw, { aliases, disabledStages: new Set(["aliases"]) }))
      .toBe("And make it a codex 6 point 1 sol on extra high please");
    expect(applyRules(raw, { aliases, disabledStages: new Set(["numbers"]) })).toBe("And make it a codex six point one sol on extra high please");
  });

  it("applies the Dictionary through common dictation finalization with polish off", async () => {
    expect(await finalizeTranscriptionTextForSurface(raw, "dictation", {
      ...env(), QA_VOICE_CORRECTOR: "off", QA_VOICE_STT_POLISH: "off",
    })).toBe(`${expected}.`);
  });
});
