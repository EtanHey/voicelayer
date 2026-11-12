import { expect, test } from "bun:test";
import { mkdirSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";

test("Parakeet worker keeps the words at the end of a take that stops mid-speech", async () => {
  const work = testTmp("parakeet-chunk-plan"); mkdirSync(work, { recursive: true });
  const proc = Bun.spawn(["python3", "-B", join(import.meta.dir, "parakeet-chunk-plan.py"), work], {
    env: process.env, stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  expect(stderr).toBe("");
  expect(code).toBe(0);
  expect(stdout).toContain("T1: short final windows never decoded alone; every word kept once");
});
