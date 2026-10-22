import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { resolve } from "node:path";

test("hook fixture PID receipts are published only after all bytes are written", () => {
  const result = spawnSync("python3", [resolve(import.meta.dir, "hook_pid_publication_test.py")], {
    env: { ...process.env, PYTHONDONTWRITEBYTECODE: "1" }, encoding: "utf8", timeout: 15_000,
  });
  expect({ status: result.status, output: result.stdout + result.stderr }).toEqual({
    status: 0, output: expect.stringContaining("OK"),
  });
}, 20_000);
