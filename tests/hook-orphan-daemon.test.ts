import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const script = resolve(import.meta.dir, "test_hook_orphan_daemon.sh");
const hasCompiler = !!Bun.which("cc");
if (!hasCompiler) console.warn("SKIP HO3 native sender helper: cc toolchain missing");

for (const name of ["cross-untagged", "unscoped-negative"]) {
  for (const phase of ["ongoing", "final"]) {
    test.skipIf(!hasCompiler)(`late TERM to ${name} fails ${phase} monitoring`, () => {
      const result = spawnSync("bash", [script, "--protected-term-check", name, phase], {
        encoding: "utf8", timeout: 20_000,
      });
      expect(result.error).toBeUndefined();
      expect(result.stdout).toContain(`PASS one-off protection check: ${name}`);
      expect(result.status).toBe(1);
      expect(result.stdout).toContain("FAIL protected TERM:");
      expect(result.stderr).toContain(phase === "ongoing"
        ? "protected fixture received TERM; native sender above"
        : "protected fixture TERM after lifecycle");
    }, 25_000);
  }
}

test.skipIf(!hasCompiler)("independent hook test roots isolate fixtures and reap daemons on every exit path", () => {
  const native = spawnSync("bash", [script, "--native-check"], { encoding: "utf8", timeout: 15_000 });
  expect({ status: native.status, output: native.stdout + native.stderr }).toEqual({ status: 0, output: expect.any(String) });
  const result = spawnSync("bash", [script, process.env.HOOK_CROSS_RUN_CHILD ? "--concurrent" : "--cross-run"], {
    encoding: "utf8", timeout: 300_000,
  });
  if (process.env.HOOK_CROSS_RUN_CHILD || process.env.HOOK_KEEP_EVIDENCE === "1" || result.status !== 0) console.log(result.stdout + result.stderr);
  expect(result.error).toBeUndefined();
  expect(result.stdout).toContain("PASS monitored set equals protected fixtures:");
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({
    status: 0,
    output: expect.stringContaining("PASS real:"),
  });
}, 305_000);

test("native TERM attribution immediately fails every protected sender without retry", () => {
  const result = spawnSync("bash", [script, "--policy-check"], { encoding: "utf8" });
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({ status: 0, output: expect.stringContaining("PASS attribution: every protected TERM fails immediately; no retry") });
  expect(result.stdout).toContain("FAIL protected TERM: sender_pid=42 sender_executable=/python sender_entrypoint=foreign.py sender_in_run=0");
  expect(result.stdout).not.toContain("EXTERNAL_INTERFERENCE");
});
