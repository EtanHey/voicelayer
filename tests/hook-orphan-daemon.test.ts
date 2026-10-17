import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const script = resolve(import.meta.dir, "test_hook_orphan_daemon.sh");
const hasCompiler = !!Bun.which("cc");
if (!hasCompiler) console.warn("SKIP HO3 native sender helper: cc toolchain missing");

test.skipIf(!hasCompiler)("independent hook test roots isolate fixtures and reap daemons on every exit path", () => {
  const native = spawnSync("bash", [script, "--native-check"], { encoding: "utf8", timeout: 15_000 });
  expect({ status: native.status, output: native.stdout + native.stderr }).toEqual({ status: 0, output: expect.any(String) });
  const result = spawnSync("bash", [script, process.env.HOOK_CROSS_RUN_CHILD ? "--concurrent" : "--cross-run"], {
    encoding: "utf8", timeout: 300_000,
  });
  if (process.env.HOOK_CROSS_RUN_CHILD || process.env.HOOK_KEEP_EVIDENCE === "1" || result.stdout?.includes("EXTERNAL_INTERFERENCE")) console.log(result.stdout + result.stderr);
  expect(result.error).toBeUndefined();
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({
    status: 0,
    output: expect.stringContaining("PASS real:"),
  });
}, 305_000);

test("native TERM attribution never retries internal/unknown senders or a second external hit", () => {
  const result = spawnSync("bash", [script, "--policy-check"], { encoding: "utf8" });
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({ status: 0, output: expect.stringContaining("PASS attribution:") });
});
