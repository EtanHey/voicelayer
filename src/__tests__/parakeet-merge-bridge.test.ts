import { expect, test } from "bun:test";
import { join } from "path";

test("V34b merge bridge preserves a straddling token exactly once without modifying the runtime", async () => {
  const proc = Bun.spawn(["python3", "-B", join(import.meta.dir, "parakeet-merge-bridge.py")], {
    env: process.env, stdout: "pipe", stderr: "pipe",
  });
  const [stdout, stderr, code] = await Promise.all([
    new Response(proc.stdout).text(), new Response(proc.stderr).text(), proc.exited,
  ]);
  expect(stderr).toBe("");
  expect(code).toBe(0);
  expect(stdout).toContain("V34b: straddling tokens retained once");
});
