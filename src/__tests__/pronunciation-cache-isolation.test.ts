import { expect, it } from "bun:test";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const repo = resolve(import.meta.dir, "../..");

// TESTISO2: pin the file order CI's Linux readdir produced for PR #490. A file that loads tts.ts first, then
// pronunciation.test.ts (which hot-reloads ../pronunciation), then the QPRE1 pronunciation spies: those spies
// must still reach tts.ts. Explicit paths make the order deterministic on every host.
it("pronunciation.test.ts hot-reloads leave later spies reaching an already-loaded tts.ts", () => {
  const run = spawnSync(process.execPath, ["test",
    "./src/__tests__/fixtures/early-tts-import.fixture.ts",
    "./src/__tests__/pronunciation.test.ts",
    "./src/__tests__/tts-long-read-runtime.test.ts",
    "-t", "pronunciation"], { cwd: repo, env: process.env, encoding: "utf8" });
  const output = `${run.stdout}\n${run.stderr}`;
  expect(output).toMatch(/\b0 fail\b/);
  expect(output).toMatch(/across 3 files/);
  // The fixture, every pronunciation case and the QPRE1 pronunciation-spy cases all ran (not filtered away).
  expect(Number(output.match(/\b(\d+) pass\b/)?.[1] ?? 0)).toBeGreaterThanOrEqual(10);
  expect(run.status).toBe(0);
}, 60_000);
