import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  addAlias,
  addPromptTerm,
  listVocabulary,
  removeAlias,
  removePromptTerm,
} from "../stt-vocabulary-store";

describe("stt-vocabulary-store", () => {
  let tempDir = "";
  let vocabPath = "";

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "voicelayer-vocab-store-"));
    vocabPath = join(tempDir, "stt-vocabulary.json");
  });

  afterEach(() => {
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
  });

  it("lists an empty snapshot when the vocabulary file does not exist", () => {
    expect(listVocabulary({ path: vocabPath })).toEqual({
      updated_at: null,
      entries: [],
    });
  });

  it("migrates old prompt_terms and aliases losslessly into canonical entries", () => {
    writeFileSync(
      vocabPath,
      JSON.stringify({
        updated_at: "2026-06-17T10:00:00.000Z",
        prompt_terms: ["Domica", "SongScript", "domica"],
        aliases: [
          { from: "domekin", to: "Domica" },
          { from: "song strip", to: "SongScript" },
          { from: "song-strip", to: "SongScript" },
        ],
      }),
    );

    expect(listVocabulary({ path: vocabPath })).toEqual({
      updated_at: "2026-06-17T10:00:00.000Z",
      entries: [
        { canonical: "Domica", variants: ["domekin"] },
        { canonical: "SongScript", variants: ["song strip", "song-strip"] },
      ],
    });
  });

  it("adds variants, stamps updated_at, and dedupes by alias key without changing casing", () => {
    addAlias({ from: "domekin", to: "Domica" }, { path: vocabPath });
    const updated = addAlias(
      { from: "dome-kin", to: "Domica Labs" },
      { path: vocabPath },
    );

    expect(updated.entries).toEqual([
      { canonical: "Domica Labs", variants: ["domekin"] },
    ]);
    expect(typeof updated.updated_at).toBe("string");
    expect(Number.isNaN(Date.parse(updated.updated_at!))).toBe(false);

    const raw = JSON.parse(readFileSync(vocabPath, "utf8"));
    expect(raw).toMatchObject({
      entries: [{ canonical: "Domica Labs", variants: ["domekin"] }],
    });
    expect(raw.prompt_terms).toBeUndefined();
    expect(raw.aliases).toBeUndefined();
    expect(typeof raw.updated_at).toBe("string");
    expect(existsSync(`${vocabPath}.lock`)).toBe(false);
  });

  it("adds prompt terms with case-insensitive dedupe while preserving existing casing", () => {
    addPromptTerm("Domica", { path: vocabPath });
    const updated = addPromptTerm("domica", { path: vocabPath });

    expect(updated.entries).toEqual([{ canonical: "Domica", variants: [] }]);
  });

  it("ignores variants that normalize to the same alias key as their canonical", () => {
    const updated = addAlias(
      { from: "React.js", to: "ReactJS" },
      { path: vocabPath },
    );

    expect(updated.entries).toEqual([{ canonical: "ReactJS", variants: [] }]);
  });

  it("warns when near-duplicate canonicals are added", () => {
    addPromptTerm("VoiceLayer", { path: vocabPath });

    const updated = addPromptTerm("VoiceLayers", { path: vocabPath });

    expect(updated.warnings).toContainEqual({
      code: "near_duplicate_canonical",
      canonical: "VoiceLayers",
      existing: "VoiceLayer",
    });
    expect(updated.entries.map((entry) => entry.canonical)).toEqual([
      "VoiceLayer",
      "VoiceLayers",
    ]);
  });

  it("removes aliases by source case-insensitively", () => {
    addAlias({ from: "song strip", to: "SongScript" }, { path: vocabPath });

    const updated = removeAlias("SONG STRIP", { path: vocabPath });

    expect(updated.entries).toEqual([{ canonical: "SongScript", variants: [] }]);
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "SongScript", variants: [] },
    ]);
  });

  it("rejects invalid aliases and unsafe broad alias sources", () => {
    expect(() =>
      addAlias({ from: "", to: "Domica" }, { path: vocabPath }),
    ).toThrow(/from/i);
    expect(() =>
      addAlias({ from: "codecs", to: "Codex" }, { path: vocabPath }),
    ).toThrow(/unsafe/i);
  });

  it("rejects empty prompt terms", () => {
    expect(() => addPromptTerm(" ", { path: vocabPath })).toThrow(/term/i);
  });

  it("removes prompt terms case-insensitively and reports removal", () => {
    addPromptTerm("Domica", { path: vocabPath });
    addPromptTerm("SongScript", { path: vocabPath });
    addAlias({ from: "domekin", to: "Domica" }, { path: vocabPath });

    const updated = removePromptTerm("DOMICA", { path: vocabPath });

    expect(updated.removed).toBe(true);
    expect(updated.entries).toEqual([{ canonical: "SongScript", variants: [] }]);
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "SongScript", variants: [] },
    ]);
  });

  it("reports removed: false when the prompt term is absent", () => {
    addPromptTerm("Domica", { path: vocabPath });

    const updated = removePromptTerm("missing", { path: vocabPath });

    expect(updated.removed).toBe(false);
    expect(updated.changed).toBe(false);
    expect(updated.entries).toEqual([{ canonical: "Domica", variants: [] }]);
  });

  it("rejects empty prompt term removal", () => {
    expect(() => removePromptTerm(" ", { path: vocabPath })).toThrow(/term/i);
  });
});
