import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const script = join(import.meta.dir, "../scripts/vercel-ignore-build.sh");
let repo: string;

function git(...args: string[]) {
  const result = Bun.spawnSync(["git", ...args], {
    cwd: repo,
    env: { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_GLOBAL: "/dev/null" },
  });
  expect(result.exitCode).toBe(0);
  return result.stdout.toString().trim();
}

function commit(path: string) {
  writeFileSync(join(repo, path), crypto.randomUUID());
  git("add", ".");
  git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
    "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-m", "fixture");
  return git("rev-parse", "HEAD");
}

function run(ref: string, base = "") {
  return Bun.spawnSync(["bash", script], {
    cwd: join(repo, "site"),
    env: { ...process.env, VERCEL_GIT_COMMIT_REF: ref, VERCEL_GIT_PREVIOUS_SHA: base },
  }).exitCode;
}

beforeEach(() => {
  repo = mkdtempSync(join(import.meta.dir, "../.test-tmp/vercel-"));
  mkdirSync(join(repo, "site"));
  git("init", "--initial-branch=main");
  commit("site/index.html");
});

afterEach(() => rmSync(repo, { recursive: true, force: true }));

test("feature branches skip even with site changes", () => {
  commit("site/index.html");
  expect(run("feature/site")).toBe(0);
});

test("tags and missing refs skip", () => {
  expect(run("v1.0.0")).toBe(0);
  expect(run("")).toBe(0);
});

test("main builds site changes using HEAD parent", () => {
  commit("site/index.html");
  expect(run("main")).toBe(1);
});

test("main skips changes outside site", () => {
  commit("README.md");
  expect(run("main")).toBe(0);
});

test("explicit previous SHA includes site changes before the last commit", () => {
  const base = git("rev-parse", "HEAD");
  commit("site/index.html");
  commit("README.md");
  expect(run("main", base)).toBe(1);
});

test("explicit previous SHA skips non-site changes", () => {
  const base = git("rev-parse", "HEAD");
  commit("README.md");
  expect(run("main", base)).toBe(0);
});

test("missing explicit base builds", () => {
  commit("README.md");
  expect(run("main", "1111111111111111111111111111111111111111")).toBe(1);
});

test("missing HEAD parent builds on the initial commit", () => {
  expect(run("main")).toBe(1);
});
