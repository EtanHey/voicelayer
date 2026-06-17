import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { runVocabularyCli } from "../cli/vocab";
import { listVocabulary } from "../stt-vocabulary-store";

describe("voicelayer vocab CLI", () => {
  let tempDir = "";
  let vocabPath = "";
  let env: NodeJS.ProcessEnv;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "voicelayer-cli-vocab-"));
    vocabPath = join(tempDir, "stt-vocabulary.json");
    env = {
      ...process.env,
      QA_VOICE_STT_VOCABULARY_PATH: vocabPath,
    };
  });

  afterEach(() => {
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
  });

  it("adds, lists, and removes canonical entries with variants", async () => {
    const addOut: string[] = [];
    const addCode = await runVocabularyCli(
      [
        "add",
        "--term",
        "Domica",
        "--variant",
        "domekin",
        "--variant",
        "domika",
      ],
      { env, stdout: (line) => addOut.push(line), stderr: () => {} },
    );

    expect(addCode).toBe(0);
    expect(addOut.join("")).toContain("Added term: Domica");
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "Domica", variants: ["domekin", "domika"] },
    ]);

    const variantCode = await runVocabularyCli(
      ["add-variant", "--term", "Domica", "--variant", "domi car"],
      { env, stdout: () => {}, stderr: () => {} },
    );
    expect(variantCode).toBe(0);

    const listOut: string[] = [];
    const listCode = await runVocabularyCli(["list"], {
      env,
      stdout: (line) => listOut.push(line),
      stderr: () => {},
    });

    expect(listCode).toBe(0);
    expect(listOut.join("")).toContain("Domica");
    expect(listOut.join("")).toContain("  variants: domekin, domika, domi car");

    const removeOut: string[] = [];
    const removeCode = await runVocabularyCli(
      ["remove", "--term", "Domica"],
      {
        env,
        stdout: (line) => removeOut.push(line),
        stderr: () => {},
      },
    );

    expect(removeCode).toBe(0);
    expect(removeOut.join("")).toContain("Removed term: Domica");
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([]);
  });

  it("keeps --wrong and --right as a back-compat add path", async () => {
    const stdout: string[] = [];
    const code = await runVocabularyCli(
      ["add", "--wrong", "domekin", "--right", "Domica"],
      { env, stdout: (line) => stdout.push(line), stderr: () => {} },
    );

    expect(code).toBe(0);
    expect(stdout.join("")).toContain("Added variant: domekin -> Domica");
    expect(listVocabulary({ path: vocabPath }).entries).toEqual([
      { canonical: "Domica", variants: ["domekin"] },
    ]);
  });

  it("returns a usage error when required flags are missing", async () => {
    const stderr: string[] = [];
    const code = await runVocabularyCli(["add-variant", "--term", "Domica"], {
      env,
      stdout: () => {},
      stderr: (line) => stderr.push(line),
    });

    expect(code).toBe(1);
    expect(stderr.join("")).toContain("--variant is required");
  });
});
