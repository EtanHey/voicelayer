import { describe, expect, test } from "bun:test";
import { join } from "path";

// The preload is the suite's isolation layer. A run started with git's
// repository selectors in its environment (a git hook, a rebase --exec) must not
// hand them to any test, or a helper's `git config` / `git commit` lands in
// another repository: that is how "Test User" reached the real .git/config.
describe("preload drops inherited GIT_* variables", () => {
  test("a child started with the preload sees none of them", () => {
    const preload = join(import.meta.dir, "setup", "preload.ts");
    const probe = Bun.spawnSync(
      [process.execPath, "--preload", preload, "-e",
        "console.log(JSON.stringify(Object.keys(process.env).filter((k) => k.startsWith('GIT_')).sort()))"],
      {
        env: {
          PATH: process.env.PATH ?? "",
          HOME: process.env.HOME ?? "",
          GIT_COMMON_DIR: "/nonexistent/.git",
          GIT_CONFIG: "/nonexistent/.git/config",
          GIT_DIR: "/nonexistent/.git",
          GIT_WORK_TREE: "/nonexistent",
          GIT_INDEX_FILE: "/nonexistent/.git/index",
        },
        stdout: "pipe",
        stderr: "pipe",
      },
    );
    expect(new TextDecoder().decode(probe.stdout).trim().split("\n").at(-1)).toBe("[]");
  });
});
