import { afterEach, expect, test } from "bun:test";
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const root = resolve(import.meta.dir, "../..");
const temporary: string[] = [];
const commit = "1234567890abcdef1234567890abcdef12345678";
const otherCommit = "abcdef1234567890abcdef1234567890abcdef12";

function run(args: string[], cwd: string, env = process.env) {
  return Bun.spawnSync(args, { cwd, env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });
}

function fixture() {
  const dir = mkdtempSync(join(root, ".test-tmp/i3-"));
  temporary.push(dir);
  mkdirSync(join(dir, "src"));
  cpSync(join(root, "src/cli"), join(dir, "src/cli"), { recursive: true });
  const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "i3-fixture", version: "1.2.3", files: manifest.files, bin: { voicelayer: manifest.bin.voicelayer } }));
  return dir;
}

function version(dir: string) {
  const result = run(["bash", join(dir, "src/cli/voicelayer.sh"), "--version", "--json"], dir);
  expect(result.exitCode).toBe(0);
  return JSON.parse(result.stdout.toString());
}

function stamp(dir: string, sha = commit) {
  return run(["python3", join(root, "scripts/release-commit-stamp.py"), "stamp", "--source", dir], dir, { ...process.env, GITHUB_SHA: sha });
}

afterEach(() => { for (const dir of temporary.splice(0)) rmSync(dir, { recursive: true, force: true }); });

test("checkout HEAD takes precedence over a stale package stamp", () => {
  const dir = fixture();
  expect(run(["git", "init", "-q"], dir).exitCode).toBe(0);
  expect(run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture"], dir).exitCode).toBe(0);
  const head = run(["git", "rev-parse", "HEAD"], dir).stdout.toString().trim();
  writeFileSync(join(dir, "build-info.json"), JSON.stringify({ gitCommit: commit }));
  expect(version(dir)).toEqual({ version: "1.2.3", gitCommit: head, source: "checkout" });
  const plain = run(["bash", join(dir, "src/cli/voicelayer.sh"), "--version"], dir);
  expect(plain.stdout.toString()).toBe("1.2.3\n");
});

test("unstamped checkout reports its exact HEAD", () => {
  const dir = fixture();
  expect(run(["git", "init", "-q"], dir).exitCode).toBe(0);
  expect(run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture"], dir).exitCode).toBe(0);
  const head = run(["git", "rev-parse", "HEAD"], dir).stdout.toString().trim();
  expect(version(dir)).toEqual({ version: "1.2.3", gitCommit: head, source: "checkout" });
});

test("unstamped package never borrows an enclosing checkout's HEAD", () => {
  expect(version(fixture())).toEqual({ version: "1.2.3", gitCommit: null, source: null });
});

test("release tooling stamps GITHUB_SHA and verifies actual packed bytes", () => {
  const dir = fixture();
  expect(stamp(dir).exitCode).toBe(0);
  const packed = run(["npm", "pack", "--ignore-scripts", "--json"], dir);
  expect(packed.exitCode).toBe(0);
  const archive = join(dir, JSON.parse(packed.stdout.toString())[0].filename);
  const verify = (sha: string) => run(["python3", join(root, "scripts/release-commit-stamp.py"), "verify", "--archive", archive], dir, { ...process.env, GITHUB_SHA: sha });
  expect(verify(commit).exitCode).toBe(0);
  expect(verify(otherCommit).exitCode).toBe(1);
  const installed = join(dir, "installed");
  mkdirSync(installed);
  expect(run(["tar", "-xzf", archive, "-C", installed], dir).exitCode).toBe(0);
  expect(version(join(installed, "package"))).toEqual({ version: "1.2.3", gitCommit: commit, source: "package" });
}, 15_000);

test("release tooling refuses missing or malformed release identity and relabelling", () => {
  const dir = fixture();
  expect(stamp(dir, "").exitCode).toBe(1);
  expect(stamp(dir, "short").exitCode).toBe(1);
  expect(stamp(dir).exitCode).toBe(0);
  expect(stamp(dir).exitCode).toBe(0);
  expect(stamp(dir, otherCommit).exitCode).toBe(1);
});

test("workflow stamps the selected commit, verifies and publishes the same archive", () => {
  const workflow = readFileSync(join(root, ".github/workflows/publish.yml"), "utf8");
  const stampIndex = workflow.indexOf("release-commit-stamp.py stamp");
  const packIndex = workflow.indexOf("npm pack --pack-destination");
  const verifyIndex = workflow.indexOf('release-commit-stamp.py verify --archive "$pack_dir/$archive"');
  const publishIndex = workflow.indexOf('npm publish "$pack_archive"');
  expect(stampIndex).toBeGreaterThan(0);
  expect(packIndex).toBeGreaterThan(stampIndex);
  expect(verifyIndex).toBeGreaterThan(packIndex);
  expect(publishIndex).toBeGreaterThan(verifyIndex);
  expect(workflow).toContain('export GITHUB_SHA="$release_commit"');
  expect(workflow).toContain('echo "pack_archive=$pack_dir/$archive" >> "$GITHUB_ENV"');
});

test("generated build-info.json is ignored by git", () => {
  const result = run(["git", "check-ignore", "build-info.json"], root);
  expect(result.exitCode).toBe(0);
  expect(result.stdout.toString().trim()).toBe("build-info.json");
});

test.each(["{", "{}", "null", "[]", '{"gitCommit":42}', '{"gitCommit":"short"}'])("malformed package stamp %s reports unknown identity", (contents) => {
  const dir = fixture();
  writeFileSync(join(dir, "build-info.json"), contents);
  expect(version(dir)).toEqual({ version: "1.2.3", gitCommit: null, source: null });
});

test("workflow commit mismatch prints expected and actual identity before failing", () => {
  const workflow = readFileSync(join(root, ".github/workflows/publish.yml"), "utf8");
  const start = workflow.indexOf("          release_commit=$(git rev-parse HEAD)");
  const end = workflow.indexOf("          export GITHUB_SHA=", start);
  expect(start).toBeGreaterThan(0);
  expect(end).toBeGreaterThan(start);
  const guard = workflow.slice(start, end).replace(/^          /gm, "");
  const result = run(["bash", "-e", "-c", guard], root, { ...process.env, GITHUB_EVENT_NAME: "push", GITHUB_SHA: otherCommit });
  const head = run(["git", "rev-parse", "HEAD"], root).stdout.toString().trim();
  expect(result.exitCode).toBe(1);
  expect(result.stderr.toString()).toContain(otherCommit);
  expect(result.stderr.toString()).toContain(head);
  expect(result.stderr.toString()).toContain("GITHUB_SHA");
  expect(run(["bash", "-e", "-c", guard], root, { ...process.env, GITHUB_EVENT_NAME: "push", GITHUB_SHA: head }).exitCode).toBe(0);
  expect(run(["bash", "-e", "-c", guard], root, { ...process.env, GITHUB_EVENT_NAME: "workflow_dispatch", GITHUB_SHA: otherCommit }).exitCode).toBe(0);
});
