import { afterAll, afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { TEST_TMP } from "./setup/test-tmp";
import { applyPronunciation, personalPronunciationPath, pronunciationRules } from "../pronunciation";
import { projectSpeakableText } from "../speakable-text";
import { runPronunciationCli } from "../cli/pronounce";

const root = mkdtempSync(join(TEST_TMP, "pronounce-"));
const originalState = process.env.VOICELAYER_STATE_DIR;
afterEach(() => { process.env.VOICELAYER_STATE_DIR = originalState; });
afterAll(() => rmSync(root, { recursive: true, force: true }));
let index = 0;
function fixture() {
  const dir = join(root, String(++index));
  process.env.VOICELAYER_STATE_DIR = dir;
  return { env: { ...process.env }, path: personalPronunciationPath() };
}

test("private state list is missing/empty without changing speech or creating a file", () => {
  const { path } = fixture();
  expect(path).toBe(join(process.env.VOICELAYER_STATE_DIR!, "tts-pronunciations.json"));
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
  expect(() => statSync(path)).toThrow();
});

test("CLI adds, lists and removes case-sensitive whole-word pronunciations; reloads each read", () => {
  const { env, path } = fixture();
  const output: string[] = [];
  const run = (args: string[]) => runPronunciationCli(args, { env, stdout: s => output.push(s), stderr: s => output.push(s) });
  expect(run(["add", "--term", "ACMEX", "--say", "Acmex"])).toBe(0);
  expect(statSync(path).mode & 0o777).toBe(0o600);
  expect(run(["list"])).toBe(0);
  expect(output.join("")).toContain("ACMEX -> Acmex");
  const text = "ACMEX acmex XACMEX ACMEX2 ACMEX_ שלוםACMEX ACMEXשלום (ACMEX)";
  expect(applyPronunciation(text)).toBe("Acmex acmex XACMEX ACMEX2 ACMEX_ שלוםACMEX ACMEXשלום (Acmex)");
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText("ACMEX ACMEX.md reply-draft.md", pronunciationRules(), engine).speechText)
      .toBe("Acmex Acmex dot M D reply draft dot M D");
  }
  expect(run(["remove", "--term", "ACMEX"])).toBe(0);
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
  writeFileSync(path, "");
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
  writeFileSync(path, "{}");
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
  rmSync(path);
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
});

test("private spoken text is literal and state roots do not share cached entries", () => {
  const { env } = fixture();
  expect(runPronunciationCli(["add", "--term", "ACMEX", "--say", "$& Acmex"], { env, stdout: () => {} })).toBe(0);
  expect(applyPronunciation("ACMEX")).toBe("$& Acmex");
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText("ACMEX", pronunciationRules(), engine).speechText).toBe("$& Acmex");
  }
  fixture();
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
});

test("shell entry point dispatches private word-list commands without a daemon", () => {
  const { env } = fixture();
  const run = (args: string[]) => spawnSync("bash", [new URL("../cli/voicelayer.sh", import.meta.url).pathname, "pronounce", ...args], { env: { ...process.env, ...env }, encoding: "utf8" });
  expect(run(["add", "--term", "ACMEX", "--say", "Acmex"]).status).toBe(0);
  const listed = run(["list"]);
  expect(listed.status).toBe(0);
  expect(listed.stdout).toBe("ACMEX -> Acmex\n");
  expect(run(["remove", "--term", "ACMEX"]).status).toBe(0);
  expect(run(["list"]).stdout).toBe("No personal pronunciations.\n");
});

test("CLI rejects invalid input and preserves malformed private files", () => {
  const { env, path } = fixture();
  const run = (args: string[]) => runPronunciationCli(args, { env, stdout: () => {}, stderr: () => {} });
  expect(run(["add", "--term", "ACMEX"])).toBe(1);
  expect(run(["add", "--term", "ACMEX", "--say", "Acmex"])).toBe(0);
  writeFileSync(path, "{broken");
  expect(run(["add", "--term", "OTHER", "--say", "Other"])).toBe(1);
  expect(readFileSync(path, "utf8")).toBe("{broken");
  expect(applyPronunciation("ACMEX")).toBe("ACMEX");
});

test("bundled pronunciation tables contain no private or synthetic entries", () => {
  const source = readFileSync(new URL("../speakable-text.ts", import.meta.url), "utf8");
  const tables = source.slice(source.indexOf("const lexicon:"), source.indexOf("function identifier("));
  const tokens = tables.match(/[A-Za-z][A-Za-z0-9_-]*/g) ?? [];
  const privateDigests = new Set(["89a9813b2f22485c43bea6237b6c4876b524ef9c718a082d55fe782a02bba759"]);
  expect(tokens.filter(token => privateDigests.has(createHash("sha256").update(token.toLowerCase()).digest("hex")))).toEqual([]);
  expect(tokens).not.toContain("ACMEX");
});
