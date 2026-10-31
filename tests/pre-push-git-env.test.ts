import { withChildFixtureEnv } from "../src/__tests__/setup/child-env";
import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync, type SpawnSyncReturns } from "node:child_process";

const hook = readFileSync(new URL("../.githooks/pre-push", import.meta.url), "utf8");
const guard = readFileSync(new URL("../scripts/guard-no-docslocal.sh", import.meta.url), "utf8");
const cleanEnv = { ...process.env };
for (const key of Object.keys(cleanEnv)) if (key.startsWith("GIT_")) delete cleanEnv[key];

function assertChildSucceeded(label: string, result: SpawnSyncReturns<string>, elapsedMs: number): void {
  const stdout = result.stdout ?? "", stderr = result.stderr ?? "";
  if (!result.error && result.status === 0 && !/\(fail\)/.test(stderr)) return;
  throw new Error(`${label}: elapsed=${elapsedMs.toFixed(1)}ms status=${result.status} signal=${result.signal} error=${result.error ?? "none"}\nstdout:\n${stdout}\nstderr:\n${stderr}`);
}

test("nested startup failures include stdout, stderr and elapsed time", () => {
  const root = mkdtempSync(join(tmpdir(), "voice-child-failure-"));
  try {
    const startup = join(root, "fail.ts");
    writeFileSync(startup, 'console.log("startup stdout marker"); throw new Error("startup stderr marker");');
    const started = performance.now();
    const result = spawnSync(process.execPath, ["test", "--preload", startup,
      "./src/__tests__/deploy-check.test.ts", "-t", "readRepoGitCommit"], {
      cwd: join(import.meta.dir, ".."), encoding: "utf8", timeout: 5000, env: cleanEnv,
    });
    const elapsed = performance.now() - started;
    const fail = () => assertChildSucceeded("startup probe", result, elapsed);
    for (const detail of ["startup stdout marker", "startup stderr marker", "status=1", "elapsed="]) {
      expect(fail).toThrow(detail);
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
}, 15_000);

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

// Full suites stay in ordinary discovery. Repeat only Git-creating fixtures
// here, under hostile selectors; their own assertions verify fixture identity.
for (const { suite, filter, passes } of [
  { suite: "brew-cask-sync", filter: "the tap is refreshed with an explicit remote and branch", passes: 1 },
  { suite: "deploy-check", filter: "readRepoGitCommit", passes: 3 },
]) {
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
      const started = performance.now();
      const result = withChildFixtureEnv({ VOICELAYER_STATE_DIR: join(root, "state") }, () => spawnSync(process.execPath, ["test", `./src/__tests__/${suite}.test.ts`, "-t", filter], {
        cwd: join(import.meta.dir, ".."), encoding: "utf8", timeout: 30000,
        env: { ...cleanEnv, VOICELAYER_STATE_DIR: join(root, "state"), GIT_DIR: join(root, ".git"), GIT_INDEX_FILE: join(root, ".git/index") },
      }));
      assertChildSucceeded(suite, result, performance.now() - started);
      // A stale filter must fail rather than silently running zero fixtures.
      expect(result.stderr).toMatch(new RegExp(`^ ${passes} pass$`, "m"));
      expect(snapshot()).toEqual(before);
    } finally { rmSync(root, { recursive: true, force: true }); }
  }, 45_000);
}
