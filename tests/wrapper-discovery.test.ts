import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { withChildFixtureEnv } from "../src/__tests__/setup/child-env";

const repo = join(import.meta.dir, "..");
const intended = 'import { test, expect } from "bun:test"; test("intended fixture", () => expect(true).toBe(true));';
const counterfeit = 'import { test } from "bun:test"; test("counterfeit archive discovered", () => { throw new Error("COUNTERFEIT_ARCHIVE"); });';

function clearAgentReporterEnv(env: NodeJS.ProcessEnv) {
  // Bun's agent reporter hides passing test names that these fixtures assert.
  delete env.CLAUDECODE;
  delete env.AGENT;
  delete env.REPL_ID;
}

function put(root: string, path: string, text: string) {
  const target = join(root, path);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, text);
}

function copy(root: string, path: string) {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  copyFileSync(join(repo, path), join(root, path));
}

function fixture() {
  const root = mkdtempSync("/tmp/vl-discovery-");
  // Use the normal safety preloads in every real Bun child, including X/Y.
  put(root, "bunfig.toml", `[test]\npreload = ${JSON.stringify([
    join(repo, "src/__tests__/setup/preload.ts"),
    join(repo, "src/__tests__/setup/resolver-cache.ts"),
  ])}\n`);
  return root;
}

test("Bun bare filters discover archives while explicit files select only the intended test", () => {
  const root = fixture();
  try {
    const target = "src/__tests__/selection.test.ts";
    put(root, target, intended);
    put(root, `docs.local/archived/${target}`, counterfeit);
    const run = (path: string) => {
      const env = { ...process.env };
      clearAgentReporterEnv(env);
      return spawnSync(process.execPath, ["test", path], {
        cwd: root, env, encoding: "utf8", timeout: 10_000,
      });
    };
    const bare = run(target);
    expect(bare.error).toBeUndefined();
    expect(bare.status).toBe(1);
    expect(bare.stderr).toContain("COUNTERFEIT_ARCHIVE");
    for (const path of [`./${target}`, join(root, target)]) {
      const exact = run(path);
      expect(exact.error).toBeUndefined();
      expect(exact.status).toBe(0);
      expect(exact.stderr).toContain("1 pass");
      expect(exact.stderr).not.toContain("COUNTERFEIT_ARCHIVE");
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}, 35_000);

for (const suite of ["brew-cask-sync", "deploy-check"]) {
  test(`${suite} real hostile-Git wrapper excludes archived same-path tests`, () => {
    const root = fixture();
    try {
      for (const path of ["tests/pre-push-git-env.test.ts", "src/__tests__/setup/child-env.ts",
        ".githooks/pre-push", "scripts/guard-no-docslocal.sh"]) copy(root, path);
      const target = `src/__tests__/${suite}.test.ts`;
      const filter = suite === "brew-cask-sync"
        ? "the tap is refreshed with an explicit remote and branch" : "readRepoGitCommit";
      const count = suite === "brew-cask-sync" ? 1 : 3;
      const selected = (body: string) => 'import { test, expect } from "bun:test";\n' +
        Array.from({ length: count }, (_, i) =>
          `test(${JSON.stringify(`${filter} fixture ${i + 1}`)}, () => { ${body} });`).join("\n");
      put(root, target, selected("expect(true).toBe(true);"));
      put(root, `docs.local/archived/${target}`, selected('throw new Error("counterfeit archive discovered: COUNTERFEIT_ARCHIVE");'));
      const env = { ...process.env };
      clearAgentReporterEnv(env);
      // The archive must match the same name filter, so a bare-path regression
      // still fails instead of filtering the counterfeit out of the proof.
      const bare = spawnSync(process.execPath, ["test", target, "-t", filter], {
        cwd: root, env, encoding: "utf8", timeout: 5000,
      });
      expect(bare.error).toBeUndefined();
      expect({ status: bare.status, stderr: bare.stderr }).toEqual({
        status: 1, stderr: expect.stringContaining("COUNTERFEIT_ARCHIVE"),
      });
      const result = spawnSync(process.execPath, ["test", "./tests/pre-push-git-env.test.ts",
        "--test-name-pattern", `${suite} fixtures resist`], {
        cwd: root, env, encoding: "utf8", timeout: 15_000,
      });
      expect(result.error).toBeUndefined();
      expect({ status: result.status, stderr: result.stderr }).toEqual({
        status: 0, stderr: expect.stringContaining("1 pass"),
      });
      expect(result.stderr).not.toContain("counterfeit archive discovered");
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }, 20_000);
}

test("real cross-run wrapper excludes archived tests through its shared src tree", () => {
  const root = fixture();
  try {
    for (const path of ["tests/test_hook_orphan_daemon.sh", "tests/hook_fixture_registry.py",
      "tests/hook-term-sender.c", "scripts/supervise-test-daemon.py", "scripts/run_tests.sh",
      "scripts/apply-voicebar-f5-hidutil.sh"]) copy(root, path);
    for (const path of ["node_modules", "flow-bar", "launchd"]) mkdirSync(join(root, path));
    put(root, "tests/hook-orphan-daemon.test.ts", intended);
    // X/Y link src from this checkout; Bun's bare filter follows that link.
    put(root, "src/docs.local/archived/tests/hook-orphan-daemon.test.ts", counterfeit);
    const runRoot = join(root, "run");
    mkdirSync(runRoot);
    const result = withChildFixtureEnv({ VOICELAYER_TEST_RUN_ROOT: runRoot }, () => {
      const env = { ...process.env, PATH: `${dirname(process.execPath)}:${process.env.PATH}` };
      clearAgentReporterEnv(env);
      return spawnSync("bash", [join(root, "tests/test_hook_orphan_daemon.sh"), "--cross-run"], {
        cwd: root, env, encoding: "utf8", timeout: 20_000,
      });
    });
    expect(result.error).toBeUndefined();
    expect({ status: result.status, stdout: result.stdout, stderr: result.stderr }).toEqual({
      status: 0, stdout: expect.stringContaining("intended fixture"), stderr: "",
    });
    expect(result.stdout.match(/1 pass/g)).toHaveLength(2);
    expect(result.stdout).not.toContain("COUNTERFEIT_ARCHIVE");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}, 25_000);
