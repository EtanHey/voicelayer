import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { spawnSync } from "node:child_process";

const repo = resolve(import.meta.dir, "..");

test("package and hook roots cover every tracked Bun test", () => {
  const command = JSON.parse(readFileSync(resolve(repo, "package.json"), "utf8")).scripts.test;
  const [bun, action, ...roots] = command.trim().split(/\s+/);
  expect([bun, action]).toEqual(["bun", "test"]);
  expect(roots.length).toBeGreaterThan(0);
  for (const root of roots) expect(root).toMatch(/^\.\/[\w/-]+$/);
  const tracked = spawnSync("git", ["ls-files", "-z", "*.test.ts", "*.test.tsx",
    "*.test.js", "*.test.jsx", "*_test.ts", "*_test.tsx", "*_test.js", "*_test.jsx",
    "*.spec.ts", "*.spec.tsx", "*.spec.js", "*.spec.jsx",
    "*_spec.ts", "*_spec.tsx", "*_spec.js", "*_spec.jsx"], { cwd: repo, encoding: "utf8" });
  expect(tracked.status).toBe(0);
  const files = tracked.stdout.split("\0").filter(Boolean);
  expect(files.length).toBeGreaterThan(0);
  const prefixes = roots.map((root: string) => root.replace(/\/+$/, "").slice(2) + "/");
  expect(files.filter(file => !prefixes.some((prefix: string) => file.startsWith(prefix)))).toEqual([]);
  const gate = readFileSync(resolve(repo, "scripts/run_tests.sh"), "utf8");
  const gateRoots = gate.match(/^\s*VOICELAYER_FIXTURE_DIR="\$FIXTURE_DIR" bun test (.+)$/m);
  expect(gateRoots).not.toBeNull();
  expect(gateRoots![1].trim().split(/\s+/)).toEqual(roots);
});
