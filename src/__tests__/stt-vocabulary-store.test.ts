import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  addAlias,
  addPromptTerm,
  listVocabulary,
  removeAlias,
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
      prompt_terms: [],
      aliases: [],
    });
  });

  it("adds aliases, stamps updated_at, and dedupes by source without changing source casing", () => {
    addAlias({ from: "domekin", to: "Domica" }, { path: vocabPath });
    const updated = addAlias(
      { from: "DOMEKIN", to: "Domica Labs" },
      { path: vocabPath },
    );

    expect(updated.aliases).toEqual([
      { from: "domekin", to: "Domica Labs" },
    ]);
    expect(updated.prompt_terms).toEqual([]);
    expect(typeof updated.updated_at).toBe("string");
    expect(Number.isNaN(Date.parse(updated.updated_at!))).toBe(false);

    const raw = JSON.parse(readFileSync(vocabPath, "utf8"));
    expect(raw).toMatchObject({
      prompt_terms: [],
      aliases: [{ from: "domekin", to: "Domica Labs" }],
    });
    expect(typeof raw.updated_at).toBe("string");
    expect(existsSync(`${vocabPath}.lock`)).toBe(false);
  });

  it("adds prompt terms with case-insensitive dedupe while preserving existing casing", () => {
    addPromptTerm("Domica", { path: vocabPath });
    const updated = addPromptTerm("domica", { path: vocabPath });

    expect(updated.prompt_terms).toEqual(["Domica"]);
    expect(updated.aliases).toEqual([]);
  });

  it("removes aliases by source case-insensitively", () => {
    addAlias({ from: "song strip", to: "SongScript" }, { path: vocabPath });

    const updated = removeAlias("SONG STRIP", { path: vocabPath });

    expect(updated.aliases).toEqual([]);
    expect(listVocabulary({ path: vocabPath }).aliases).toEqual([]);
  });

  it("rejects invalid aliases and unsafe broad alias sources", () => {
    expect(() =>
      addAlias({ from: "", to: "Domica" }, { path: vocabPath }),
    ).toThrow(/from/i);
    expect(() =>
      addAlias({ from: "Domica", to: "Domica" }, { path: vocabPath }),
    ).toThrow(/different/i);
    expect(() =>
      addAlias({ from: "codecs", to: "Codex" }, { path: vocabPath }),
    ).toThrow(/unsafe/i);
  });

  it("rejects empty prompt terms", () => {
    expect(() => addPromptTerm(" ", { path: vocabPath })).toThrow(/term/i);
  });
});
