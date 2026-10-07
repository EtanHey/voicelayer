import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { cleanupTranscriptionText, getSTTVocabularyPrompt } from "../stt-cleanup";
import * as store from "../stt-vocabulary-store";
import { runVocabularyCli } from "../cli/vocab";
import { handleSocketCommand } from "../socket-handlers";

describe("vocabulary prompt policy", () => {
  let directory: string;
  let path: string;
  let env: NodeJS.ProcessEnv;
  beforeEach(() => {
    directory = mkdtempSync(join(tmpdir(), "vocab-policy-"));
    path = join(directory, "vocabulary.json");
    env = { QA_VOICE_STT_VOCABULARY_PATH: path, QA_VOICE_STT_COMMANDS_DIR: "" };
  });
  afterEach(() => rmSync(directory, { recursive: true, force: true }));
  const write = (entries: unknown[]) => writeFileSync(path, JSON.stringify({ entries }));
  const prompt = () => getSTTVocabularyPrompt(env).split(", ");
  const cli = (args: string[]) => runVocabularyCli(args, { env, stdout: () => {}, stderr: () => {} });

  it("excludes decoder bias without removing cleanup aliases or canonical casing", () => {
    write([{ canonical: "Zerina", variants: ["zee rina"], prompt: "exclude" }]);
    expect(prompt()).not.toContain("Zerina");
    expect(cleanupTranscriptionText("call zee rina today", env)).toBe("Call Zerina today");
    expect(cleanupTranscriptionText("call ZERINA today", env)).toBe("Call Zerina today");
  });

  it("keeps absent, unknown and malformed policies byte-identical to the old default", () => {
    write([{ canonical: "Zerina", variants: [] }]);
    const before = getSTTVocabularyPrompt(env);
    for (const policy of ["include", "future-policy", null, 17, {}]) {
      write([{ canonical: "Zerina", variants: [], prompt: policy }]);
      expect(getSTTVocabularyPrompt(env)).toBe(before);
    }
  });

  it("places reserve-only entries at an explicit builtin slot in policy order", () => {
    write([
      { canonical: "TalVyn", variants: [], prompt: "reserve", prompt_after: "CLAUDE.md", prompt_order: 1 },
      { canonical: "Zerina", variants: [], prompt: "reserve", prompt_after: "CLAUDE.md", prompt_order: 0 },
    ]);
    const terms = prompt();
    const anchor = terms.indexOf("CLAUDE.md");
    expect(terms.slice(anchor + 1, anchor + 3)).toEqual(["Zerina", "TalVyn"]);
    expect(terms[0]).not.toBe("Zerina");
    expect(terms[anchor + 3]).not.toBe("Zerina");
  });

  it("reserves late entries under a full user cap and preserves the total cap", () => {
    write([
      ...Array.from({ length: 100 }, (_, i) => ({ canonical: `SyntheticTerm${i}`, variants: [] })),
      { canonical: "Zerina", variants: [], prompt: "reserve" },
    ]);
    expect(prompt()).toContain("Zerina");
    expect(getSTTVocabularyPrompt(env).length).toBeLessThanOrEqual(896);
    expect(prompt()).toContain("VoiceLayer");
  });

  it("retains a reserved entry's former user-tier position when requested", () => {
    write([{ canonical: "Zerina", variants: [], prompt: "reserve", prompt_user: true }]);
    expect(prompt()[0]).toBe("Zerina");
    expect(prompt().filter((term) => term === "Zerina")).toHaveLength(1);
    write([{ canonical: "Zerina", variants: [], prompt: "reserve", prompt_after: "missing-anchor" }]);
    expect(prompt()[0]).not.toBe("Zerina");
    expect(prompt()).toContain("Zerina");
  });

  it("applies exclusions to builtin and seed terms, not only the user tier", () => {
    write([
      { canonical: "VoiceLayer", variants: [], prompt: "exclude" },
      { canonical: "Apple Container", variants: [], prompt: "exclude" },
    ]);
    expect(prompt()).not.toContain("VoiceLayer");
    expect(prompt()).not.toContain("Apple Container");
  });

  it("writes a new term or alias with its policy in the same store mutation", () => {
    const term = store.addPromptTerm("Zerina", { path, promptPolicy: { prompt: "exclude" } });
    expect(term.entries[0]).toEqual({ canonical: "Zerina", variants: [], prompt: "exclude" });
    const alias = store.addAlias({ from: "tal vyn", to: "TalVyn" }, {
      path, promptPolicy: { prompt: "reserve", prompt_order: 1 },
    });
    expect(alias.entries[1]).toEqual({ canonical: "TalVyn", variants: ["tal vyn"], prompt: "reserve", prompt_order: 1 });
  });

  it("round-trips policy through store mutations and display snapshots", () => {
    const entry = { canonical: "Zerina", variants: ["zee rina"], prompt: "reserve", prompt_after: "CLAUDE.md", prompt_user: true, prompt_order: 0 };
    write([entry]);
    store.addAlias({ from: "zerena", to: "Zerina" }, { path });
    store.addPromptTerm("OtherTerm", { path });
    store.removeAlias("zerena", { path });
    expect(store.listVocabulary({ path }).entries[0]).toEqual(entry);
    expect(store.buildDictionaryDisplayEntries(store.listVocabulary({ path }).entries))
      .toContainEqual({ ...entry, row_id: "personal:Zerina", source: "personal" });
    expect(JSON.parse(readFileSync(path, "utf8")).entries[0]).toEqual(entry);
  });

  it("carries policy through the daemon vocab_list response and alias mutations", () => {
    const old = process.env.QA_VOICE_STT_VOCABULARY_PATH;
    process.env.QA_VOICE_STT_VOCABULARY_PATH = path;
    try {
      write([{ canonical: "Zerina", variants: [], prompt: "exclude" }]);
      handleSocketCommand({ cmd: "vocab_add", from: "zee rina", to: "Zerina" });
      expect(handleSocketCommand({ cmd: "vocab_list" })).toMatchObject({
        entries: [{ canonical: "Zerina", variants: ["zee rina"], prompt: "exclude" }],
        display_entries: expect.arrayContaining([expect.objectContaining({ canonical: "Zerina", prompt: "exclude" })]),
      });
    } finally {
      if (old === undefined) delete process.env.QA_VOICE_STT_VOCABULARY_PATH;
      else process.env.QA_VOICE_STT_VOCABULARY_PATH = old;
    }
  });

  it("sets policy on add and existing entries through the CLI, then resets it", async () => {
    expect(await cli(["add", "--term", "Zerina", "--variant", "zee rina", "--prompt", "exclude"])).toBe(0);
    expect(prompt()).not.toContain("Zerina");
    expect(await cli(["set-prompt", "--term", "Zerina", "--prompt", "reserve", "--prompt-after", "CLAUDE.md", "--prompt-user", "true", "--prompt-order", "2"])).toBe(0);
    expect(store.listVocabulary({ path }).entries[0]).toMatchObject({ prompt: "reserve", prompt_after: "CLAUDE.md", prompt_user: true, prompt_order: 2 });
    expect(await cli(["set-prompt", "--term", "Zerina", "--prompt", "include"])).toBe(0);
    expect(store.listVocabulary({ path }).entries[0]).toEqual({ canonical: "Zerina", variants: ["zee rina"], prompt: "include" });
    expect(prompt()[0]).toBe("Zerina");
    const beforeRepeat = readFileSync(path, "utf8");
    expect(await cli(["set-prompt", "--term", "Zerina", "--prompt", "include"])).toBe(0);
    expect(readFileSync(path, "utf8")).toBe(beforeRepeat);
    const output: string[] = [];
    expect(await runVocabularyCli(["list"], { env, stdout: (line) => output.push(line) })).toBe(0);
    expect(output.join("")).toContain("prompt: include");
  });

  it("rejects invalid CLI policies before mutation and missing terms", async () => {
    expect(await cli(["add", "--term", "Zerina", "--prompt", "future-policy"])).toBe(1);
    expect(store.listVocabulary({ path }).entries).toEqual([]);
    expect(await cli(["set-prompt", "--term", "Missing", "--prompt", "exclude"])).toBe(1);
    expect(await cli(["add", "--term", "Zerina", "--prompt", "reserve", "--prompt-user", "maybe"])).toBe(1);
    expect(store.listVocabulary({ path }).entries).toEqual([]);
    expect(await cli(["add", "--term", "Zerina", "--prompt", "reserve", "--prompt-order", "-1"])).toBe(1);
    expect(store.listVocabulary({ path }).entries).toEqual([]);
  });
});
