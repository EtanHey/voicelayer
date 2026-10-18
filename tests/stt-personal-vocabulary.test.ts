import { afterEach, describe, expect, it } from "bun:test";
import { createHash } from "crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { TEST_TMP } from "../src/__tests__/setup/test-tmp";
import { cleanupTranscriptionText, getSTTVocabularyPrompt } from "../src/stt-cleanup";
import { correctTranscriptionText } from "../src/stt-corrector";
import { addAlias, getSTTVocabularyPath, listVocabulary, migrateVocabularySeed, removePromptTerm } from "../src/stt-vocabulary-store";

import fingerprints from "./fixtures/personal-vocabulary-fingerprints.json";
const removedFingerprints = new Set(fingerprints.private);
const digest = (value: string) => createHash("sha256").update(value.toLowerCase()).digest("hex");
const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
  const root = mkdtempSync(join(TEST_TMP, "personal-vocab-"));
  roots.push(root);
  const path = join(root, "stt-vocabulary.json");
  const env = { QA_VOICE_STT_VOCABULARY_PATH: path, QA_VOICE_STT_COMMANDS_DIR: "" };
  return { root, path, env, seed: `${path}.seed.json` };
}

describe("personal vocabulary boundary", () => {
  it("contains no sensitive personal identifiers in published source or eval fixtures", () => {
    const violations: string[] = [];
    function visit(root: string) {
      const files = /\.(swift|sh|md)$/.test(root) ? [{ name: "", isDirectory: () => false, isFile: () => true }] : readdirSync(root, { withFileTypes: true });
      for (const file of files) {
        const path = file.name ? join(root, file.name) : root;
        if (file.isDirectory()) visit(path);
        else if (file.isFile() && /\.(ts|py|sh|json|jsonl|swift|md|plist)$/.test(path)) {
          const text = readFileSync(path, "utf8");
          const surfaces = [...text.matchAll(/[\p{L}\p{N}_~-]+|["']([^"'\n]+)["']/gu)]
            .flatMap((match) => [match[0], match[1] ?? "", ...(match[0].match(/[\p{L}\p{N}_~-]+/gu) ?? [])]);
          if (surfaces.some((surface) => removedFingerprints.has(digest(surface)))) violations.push(path);
        }
      }
    }
    for (const root of ["src", "flow-bar/Sources", "flow-bar/Tests", "flow-bar/bundle", "flow-bar/Package.swift", "flow-bar/build-app.sh", "scripts", "launchd", "README.md", "eval/fixtures"]) visit(join(import.meta.dir, "..", root));
    expect(violations).toEqual([]);
  });

  it("contains none of the moved alias or priority surfaces in bundled vocabulary tables", () => {
    const text = readFileSync(join(import.meta.dir, "../src/stt-cleanup.ts"), "utf8");
    const tables = [
      text.slice(text.indexOf("const BUILTIN_STT_ALIASES:"), text.indexOf("function sortAliasesBySourceLength")),
      text.slice(text.indexOf("const STT_VOCABULARY_PRIORITY_TERMS:"), text.indexOf("// Budget (chars) reserved")),
    ].join("\n");
    const removed = new Set(fingerprints.all);
    const literals = [...tables.matchAll(/"([^"\n]+)"|([\p{L}\p{N}_~-]+)\s*:/gu)]
      .map((match) => match[1] ?? match[2]);
    expect(literals.filter((literal) => removed.has(digest(literal)))).toEqual([]);
  });

  it("applies a personal alias only after it is added to the store", () => {
    const { path, env } = fixture();
    expect(cleanupTranscriptionText("use vella service", env)).toBe("Use vella service");
    addAlias({ from: "vella service", to: "VelaService" }, { path });
    expect(cleanupTranscriptionText("use vella service", env)).toBe("Use VelaService");
    expect(correctTranscriptionText("use vella service", { mode: "rules", env }).text).toBe("Use VelaService");
  });

  it("retains the preload vocabulary path when a caller supplies an empty env", () => {
    expect(getSTTVocabularyPath({ env: {} })).toBe(process.env.QA_VOICE_STT_VOCABULARY_PATH!);
  });

  it("keeps ordinary prompt-only entries from changing sentence casing", () => {
    const { path, env } = fixture();
    writeFileSync(path, JSON.stringify({ entries: [{ canonical: "word", variants: [] }] }));
    expect(cleanupTranscriptionText("word stays here", env)).toBe("Word stays here");
  });

  it("imports a private seed once before the first cleanup, retaining user entries", () => {
    const { path, env, seed } = fixture();
    addAlias({ from: "existing alias", to: "ExistingTerm" }, { path });
    writeFileSync(seed, JSON.stringify({ id: "fixture-v1", entries: [
      { canonical: "VelaService", variants: ["vella service"], prompt: "reserve", prompt_order: 0, prompt_user: false },
      { canonical: "Noria", variants: ["noriya"], prompt: "exclude" },
    ] }));
    expect(cleanupTranscriptionText("use vella service and existing alias", env)).toBe("Use VelaService and ExistingTerm");
    expect(getSTTVocabularyPrompt(env)).toContain("VelaService");
    expect(getSTTVocabularyPrompt(env)).not.toContain("Noria");
    const first = readFileSync(path, "utf8");
    expect(listVocabulary({ path }).entries).toHaveLength(3);
    expect(readFileSync(path, "utf8")).toBe(first);
    removePromptTerm("VelaService", { path });
    expect(listVocabulary({ path }).entries.map((entry) => entry.canonical)).not.toContain("VelaService");
  });

  it("retains the migration receipt across later CLI mutations", () => {
    const { path, seed } = fixture();
    writeFileSync(seed, JSON.stringify({ id: "fixture-v1", entries: [{ canonical: "Vela", variants: ["vella"] }] }));
    expect(listVocabulary({ path }).entries).toHaveLength(1);
    removePromptTerm("Vela", { path });
    addAlias({ from: "other alias", to: "OtherTerm" }, { path });
    expect(listVocabulary({ path }).entries.map((entry) => entry.canonical)).toEqual(["OtherTerm"]);
  });

  it("does not overwrite an existing user's alias ownership or prompt exclusion", () => {
    const { path, seed } = fixture();
    writeFileSync(path, JSON.stringify({ entries: [{ canonical: "Mine", variants: ["shared"], prompt: "exclude" }] }));
    writeFileSync(seed, JSON.stringify({ id: "fixture-v1", entries: [
      { canonical: "Mine", variants: ["new variant"], prompt: "reserve" },
      { canonical: "Other", variants: ["shared"] },
    ] }));
    const entries = listVocabulary({ path }).entries;
    expect(entries.find((entry) => entry.canonical === "Mine")).toMatchObject({ variants: ["shared", "new variant"], prompt: "exclude" });
    expect(entries.find((entry) => entry.canonical === "Other")?.variants).toEqual([]);
  });

  it("preserves user-tier spelling while restoring the former canonical spelling", () => {
    const { path, env, seed } = fixture();
    writeFileSync(path, JSON.stringify({ entries: [{ canonical: "velaservice", variants: ["vella"] }] }));
    writeFileSync(seed, JSON.stringify({ id: "fixture-v1", entries: [
      { canonical: "VelaService", variants: [], prompt: "reserve", prompt_order: 0, prompt_user: false },
    ] }));
    expect(cleanupTranscriptionText("use vella", env)).toBe("Use VelaService");
    expect(getSTTVocabularyPrompt(env).split(", ")[0]).toBe("velaservice");
    expect(listVocabulary({ path }).entries[0].canonical).toBe("velaservice");
  });

  it("rejects an invalid seed without recording completion or changing the store", () => {
    const { path, seed } = fixture();
    const original = JSON.stringify({ entries: [{ canonical: "Mine", variants: [] }] });
    writeFileSync(path, original);
    writeFileSync(seed, JSON.stringify({ id: "fixture-v1", entries: [{ canonical: "Invalid" }] }));
    expect(() => migrateVocabularySeed({ path })).toThrow("invalid vocabulary seed");
    expect(listVocabulary({ path }).entries[0].canonical).toBe("Mine");
    expect(readFileSync(path, "utf8")).toBe(original);
  });
});
