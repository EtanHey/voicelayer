import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

const script = resolve(import.meta.dir, "test_hook_orphan_daemon.sh");
const native = spawnSync("bash", [script, "--native-check"], { encoding: "utf8", timeout: 15_000 });
if (native.status === 77) console.warn(native.stdout);

test.skipIf(native.status === 77)("independent hook test roots isolate fixtures and reap daemons on every exit path", () => {
  const result = spawnSync("bash", [script, process.env.HOOK_CROSS_RUN_CHILD ? "--concurrent" : "--cross-run"], {
    encoding: "utf8", timeout: 300_000,
  });
  if (process.env.HOOK_CROSS_RUN_CHILD || process.env.HOOK_KEEP_EVIDENCE === "1") console.log(result.stdout + result.stderr);
  expect(result.error).toBeUndefined();
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({
    status: 0,
    output: expect.stringContaining("PASS real:"),
  });
}, 305_000);

test.skipIf(native.status === 77)("native TERM attribution never retries internal/unknown senders or a second external hit", () => {
  const result = spawnSync("bash", [script, "--policy-check"], { encoding: "utf8" });
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({ status: 0, output: expect.stringContaining("PASS attribution:") });
});
