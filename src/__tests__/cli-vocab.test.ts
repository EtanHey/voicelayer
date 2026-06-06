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

  it("adds, lists, and removes aliases", async () => {
    const addOut: string[] = [];
    const addCode = await runVocabularyCli(
      ["add", "--wrong", "domekin", "--right", "Domica"],
      { env, stdout: (line) => addOut.push(line), stderr: () => {} },
    );

    expect(addCode).toBe(0);
    expect(addOut.join("")).toContain("Added alias: domekin -> Domica");
    expect(listVocabulary({ path: vocabPath }).aliases).toEqual([
      { from: "domekin", to: "Domica" },
    ]);

    const listOut: string[] = [];
    const listCode = await runVocabularyCli(["list"], {
      env,
      stdout: (line) => listOut.push(line),
      stderr: () => {},
    });

    expect(listCode).toBe(0);
    expect(listOut.join("")).toContain("domekin -> Domica");

    const removeOut: string[] = [];
    const removeCode = await runVocabularyCli(
      ["remove", "--wrong", "domekin"],
      {
        env,
        stdout: (line) => removeOut.push(line),
        stderr: () => {},
      },
    );

    expect(removeCode).toBe(0);
    expect(removeOut.join("")).toContain("Removed alias: domekin");
    expect(listVocabulary({ path: vocabPath }).aliases).toEqual([]);
  });

  it("returns a usage error when required flags are missing", async () => {
    const stderr: string[] = [];
    const code = await runVocabularyCli(["add", "--wrong", "domekin"], {
      env,
      stdout: () => {},
      stderr: (line) => stderr.push(line),
    });

    expect(code).toBe(1);
    expect(stderr.join("")).toContain("--right is required");
  });
});
