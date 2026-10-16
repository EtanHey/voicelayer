import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

test("hook smoke reaps daemons on every exit path", () => {
  const result = spawnSync("bash", [resolve(import.meta.dir, "test_hook_orphan_daemon.sh")], {
    encoding: "utf8", timeout: 300_000,
  });
  expect(result.error).toBeUndefined();
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({
    status: 0,
    output: expect.stringContaining("PASS real:"),
  });
}, 305_000);
