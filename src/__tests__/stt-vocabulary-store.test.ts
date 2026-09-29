import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { applyRules } from "../rules-engine";
import {
  addAlias,
  addPromptTerm,
  buildDictionaryDisplayEntries,
  BUILTIN_STT_DICTIONARY_ENTRIES,
  listVocabulary,
  removeAlias,
  removePromptTerm,
  vocabularyAliasesFromEntries,
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

  it("builds stable source-qualified display rows without mixing personal data into bundled rows", () => {
    const personalEntries = [
      { canonical: "Full Stack", variants: ["private pronunciation"] },
      { canonical: "Private Customer", variants: ["private alias"] },
    ];

    const first = buildDictionaryDisplayEntries(personalEntries);
    const second = buildDictionaryDisplayEntries(personalEntries);
    const bundled = first.filter((entry) => entry.source === "bundled");
    const personal = first.filter((entry) => entry.source === "personal");

    expect(first.map((entry) => entry.row_id)).toEqual(
      second.map((entry) => entry.row_id),
    );
    expect(bundled).toHaveLength(BUILTIN_STT_DICTIONARY_ENTRIES.length);
    expect(bundled.map(({ canonical, variants }) => ({ canonical, variants })))
      .toEqual(BUILTIN_STT_DICTIONARY_ENTRIES);
    expect(bundled.some((entry) => entry.canonical === "Private Customer"))
      .toBe(false);
    expect(personal).toEqual([
      {
        row_id: "personal:Full Stack",
        source: "personal",
        canonical: "Full Stack",
        variants: ["private pronunciation"],
      },
      {
        row_id: "personal:Private Customer",
        source: "personal",
        canonical: "Private Customer",
        variants: ["private alias"],
      },
    ]);
    expect(
      first.filter((entry) => entry.canonical === "Full Stack")
        .map((entry) => entry.row_id),
    ).toEqual(["bundled:Full Stack", "personal:Full Stack"]);
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

  it("warns on a cross-entry alias-key collision without moving an existing variant", () => {
    addAlias({ from: "domekin", to: "Domica" }, { path: vocabPath });
    const updated = addAlias(
      { from: "dome-kin", to: "Domica Labs" },
      { path: vocabPath },
    );

    expect(updated.changed).toBe(false);
    expect(updated.warnings).toContainEqual({
      code: "dictionary_variant_collision", canonical: "Domica Labs", existing: "Domica",
    });
    expect(updated.entries).toEqual([{ canonical: "Domica", variants: ["domekin"] }]);

    const raw = JSON.parse(readFileSync(vocabPath, "utf8"));
    expect(raw).toMatchObject({
      entries: [{ canonical: "Domica", variants: ["domekin"] }],
    });
    expect(raw.prompt_terms).toBeUndefined();
    expect(raw.aliases).toBeUndefined();
    expect(typeof raw.updated_at).toBe("string");
    expect(existsSync(`${vocabPath}.lock`)).toBe(false);
  });

  it("keeps distinct non-Latin variants from colliding through an empty key", () => {
    addAlias({ from: "שלום", to: "Greeting" }, { path: vocabPath });
    const result = addAlias({ from: "עולם", to: "World" }, { path: vocabPath });
    expect(result.changed).toBe(true);
    expect(result.entries).toEqual([
      { canonical: "Greeting", variants: ["שלום"] },
      { canonical: "World", variants: ["עולם"] },
    ]);
  });

  it("adds prompt terms with case-insensitive dedupe while preserving existing casing", () => {
    addPromptTerm("Domica", { path: vocabPath });
    const updated = addPromptTerm("domica", { path: vocabPath });

    expect(updated.entries).toEqual([{ canonical: "Domica", variants: [] }]);
  });

  it("does not treat a term's own retained split variant as a prompt-term collision", () => {
    addAlias({ from: "React.js", to: "ReactJS" }, { path: vocabPath });
    const updated = addPromptTerm("ReactJS", { path: vocabPath });
    expect(updated.changed).toBe(true);
    expect(updated.warnings?.some((warning) => warning.code === "dictionary_alias_collision")).toBeFalsy();
    expect(updated.entries).toEqual([{ canonical: "ReactJS", variants: ["React.js"] }]);
  });

  it("reuses a stored canonical when later commands vary its internal whitespace", () => {
    addAlias({ from: "FooBar", to: "Foo Bar" }, { path: vocabPath });
    const term = addPromptTerm("Foo  Bar", { path: vocabPath });
    expect(term.entries).toEqual([{ canonical: "Foo Bar", variants: ["FooBar"] }]);
    const alias = addAlias({ from: "foo bahr", to: "Foo  Bar" }, { path: vocabPath });
    expect(alias.entries).toEqual([{ canonical: "Foo Bar", variants: ["FooBar", "foo bahr"] }]);
    expect(vocabularyAliasesFromEntries(alias.entries)).toEqual([
      { from: "FooBar", to: "Foo Bar" },
      { from: "foo bahr", to: "Foo Bar" },
    ]);
  });

  it("keeps punctuation and split forms distinct from their canonical", () => {
    const updated = addAlias(
      { from: "React.js", to: "ReactJS" },
      { path: vocabPath },
    );

    expect(updated.entries).toEqual([{ canonical: "ReactJS", variants: ["React.js"] }]);
    addAlias({ from: "Cant Aloupe", to: "Cantaloupe AI" }, { path: vocabPath });
    const split = addAlias({ from: "Cant Aloupe AI", to: "Cantaloupe AI" }, { path: vocabPath });
    expect(split.entries).toContainEqual({ canonical: "Cantaloupe AI", variants: ["Cant Aloupe", "Cant Aloupe AI"] });
    expect(listVocabulary({ path: vocabPath }).entries).toEqual(split.entries);
    const aliases = Object.fromEntries(vocabularyAliasesFromEntries(split.entries).map(({ from, to }) => [from, to]));
    expect(applyRules("Cant Aloupe AI.", { aliases })).toBe("Cantaloupe AI.");
  });

  it("warns without changing the store when a variant has the same surface as its term", () => {
    addAlias({ from: "Cant Aloupe", to: "Cantaloupe AI" }, { path: vocabPath });
    const redundant = addAlias({ from: "  cantaloupe   ai ", to: "Cantaloupe AI" }, { path: vocabPath });
    expect(redundant.changed).toBe(false);
    expect(redundant.warnings).toContainEqual({ code: "same_as_canonical", canonical: "Cantaloupe AI", existing: "Cantaloupe AI" });
    expect(redundant.entries).toEqual([{ canonical: "Cantaloupe AI", variants: ["Cant Aloupe"] }]);
  });

  it("removes one surface variant without removing another with the same alias key", () => {
    writeFileSync(vocabPath, JSON.stringify({ entries: [{ canonical: "SongScript", variants: ["song strip", "song-strip"] }] }));
    const updated = removeAlias("song strip", { path: vocabPath });
    expect(updated.entries).toEqual([{ canonical: "SongScript", variants: ["song-strip"] }]);
  });

  it("rejects variants that normalize to an existing canonical term", () => {
    addPromptTerm("VoiceLayer", { path: vocabPath });

    const updated = addAlias(
      { from: "voice layer", to: "VoiceBar" },
      { path: vocabPath },
    );

    expect(updated.changed).toBe(false);
    expect(updated.warnings).toContainEqual({
      code: "dictionary_alias_collision",
      canonical: "VoiceBar",
      existing: "VoiceLayer",
    });
    expect(updated.entries).toEqual([{ canonical: "VoiceLayer", variants: [] }]);
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "VoiceLayer", variants: [] },
    ]);
  });

  it("rejects prompt terms that normalize to an existing variant on another entry", () => {
    addAlias({ from: "voicelair", to: "VoiceLayer" }, { path: vocabPath });

    const updated = addPromptTerm("Voice Lair", { path: vocabPath });

    expect(updated.changed).toBe(false);
    expect(updated.warnings).toContainEqual({
      code: "dictionary_alias_collision",
      canonical: "Voice Lair",
      existing: "VoiceLayer",
    });
    expect(updated.entries).toEqual([
      { canonical: "VoiceLayer", variants: ["voicelair"] },
    ]);
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "VoiceLayer", variants: ["voicelair"] },
    ]);
  });

  it("omits exported aliases whose source normalizes to a canonical key", () => {
    expect(
      vocabularyAliasesFromEntries([
        { canonical: "VoiceLayer", variants: [] },
        { canonical: "VoiceBar", variants: ["voice layer", "voice baar"] },
      ]),
    ).toEqual([{ from: "voice baar", to: "VoiceBar" }]);
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
