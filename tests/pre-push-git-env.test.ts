import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const hook = readFileSync(new URL("../.githooks/pre-push", import.meta.url), "utf8");
const guard = readFileSync(new URL("../scripts/guard-no-docslocal.sh", import.meta.url), "utf8");
const cleanEnv = Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_")));

for (const fallback of [false, true]) {
  test(`pre-push isolates fixture Git operations (${fallback ? "fallback" : "discovered variables"})`, () => {
    const root = mkdtempSync(join(tmpdir(), "voice-hook-env-"));
    try {
      const repo = join(root, "repo"), lane = join(root, "lane"), fresh = join(root, "fresh");
      const git = (args: string[]) => {
        const out = spawnSync("git", args, { env: cleanEnv, encoding: "utf8" });
        expect(out.status).toBe(0);
        return out.stdout.trim();
      };
      git(["init", "-q", repo]);
      git(["-C", repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "seed"]);
      git(["-C", repo, "worktree", "add", "-qb", "lane", lane]);
      const remote = join(root, "remote.git");
      git(["init", "--bare", "-q", remote]);
      git(["-C", lane, "config", "core.hooksPath", ".githooks"]);
      const gitDir = git(["-C", lane, "rev-parse", "--absolute-git-dir"]);
      const snapshot = () => ({
        refs: git(["-C", repo, "show-ref"]),
        config: readFileSync(join(repo, ".git/config"), "utf8"),
        index: readFileSync(join(gitDir, "index")).toString("hex"),
      });
      const before = snapshot();
      mkdirSync(join(lane, "scripts"));
      mkdirSync(join(lane, ".githooks"));
      writeFileSync(join(lane, ".githooks/pre-push"), hook, { mode: 0o755 });
      writeFileSync(join(lane, "scripts/guard-no-docslocal.sh"), guard);
      writeFileSync(join(lane, "scripts/run_tests.sh"), `env > "$RECORD"\ngit rev-parse --absolute-git-dir > "$BEFORE_INIT"\ngit init --bare -q "$FRESH"\n`);
      // Force rev-parse discovery to fail without preventing the suite's Git calls.
      const bin = join(root, "bin");
      mkdirSync(bin);
      const realGit = Bun.which("git")!;
      writeFileSync(join(bin, "git"), `#!/bin/bash\nif [ "$1 $2" = "rev-parse --local-env-vars" ]; then exit 1; fi\nexec '${realGit}' "$@"\n`, { mode: 0o755 });
      const record = join(root, "env"), beforeInit = join(root, "before-init");
      const out = spawnSync("git", ["-C", lane, "push", remote, "lane"], {
        cwd: lane, encoding: "utf8", timeout: 10000,
        env: { ...cleanEnv, HOME: root, PATH: fallback ? `${bin}:${cleanEnv.PATH}` : cleanEnv.PATH,
          GIT_DIR: gitDir, GIT_INDEX_FILE: join(gitDir, "index"), GIT_WORK_TREE: lane,
          GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "fixture.injected", GIT_CONFIG_VALUE_0: "yes",
          RECORD: record, BEFORE_INIT: beforeInit, FRESH: fresh },
      });
      expect(out.error).toBeUndefined();
      expect(out.status).toBe(0);
      const env = readFileSync(record, "utf8");
      expect(env).not.toMatch(/^GIT_(DIR|INDEX_FILE|WORK_TREE|CONFIG_COUNT)=/m);
      expect(readFileSync(beforeInit, "utf8").trim()).toBe(gitDir);
      expect(snapshot()).toEqual(before);
      expect(git(["--git-dir", fresh, "config", "--get", "core.bare"])).toBe("true");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 15_000);
}

for (const suite of ["brew-cask-sync", "deploy-check"]) {
  test(`${suite} fixtures resist inherited Git repository selection`, () => {
    const root = mkdtempSync(join(tmpdir(), "voice-hostile-git-"));
    try {
      const git = (args: string[]) => {
        const out = spawnSync("git", args, { env: cleanEnv, encoding: "utf8" });
        expect(out.status).toBe(0);
        return out.stdout;
      };
      git(["init", "-q", root]);
      git(["-C", root, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-qm", "seed"]);
      const snapshot = () => ({ refs: git(["-C", root, "show-ref"]),
        config: readFileSync(join(root, ".git/config"), "utf8"),
        index: readFileSync(join(root, ".git/index")).toString("hex") });
      const before = snapshot();
      const result = spawnSync(process.execPath, ["test", `src/__tests__/${suite}.test.ts`], {
        cwd: join(import.meta.dir, ".."), encoding: "utf8", timeout: 30000,
        env: { ...cleanEnv, VOICELAYER_STATE_DIR: join(root, "state"), GIT_DIR: join(root, ".git"), GIT_INDEX_FILE: join(root, ".git/index") },
      });
      expect(result.error).toBeUndefined();
      expect({ status: result.status, failures: result.stderr.match(/\(fail\).*/g) }).toEqual({ status: 0, failures: null });
      expect(snapshot()).toEqual(before);
    } finally { rmSync(root, { recursive: true, force: true }); }
  }, 45_000);
}
