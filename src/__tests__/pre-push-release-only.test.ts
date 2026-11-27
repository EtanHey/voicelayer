import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "fs";
import { dirname, join } from "path";
import { createHash } from "crypto";

// Release-speed plan, change 1: .githooks/pre-push skips the Swift + bun suites for a push that
// carries only the release (release-proofs/, the release gate's own allow-list) AND whose release
// gate passes. Everything else runs the full suites exactly as before. These run the REAL hook
// through a real `git push` to a real bare remote; the suite is a stub that leaves a marker, so
// "the suite ran" is observable. The safe side (anything else still runs the suite) comes first.

const repoRoot = new URL("../..", import.meta.url).pathname;
const SUBPROCESS_TEST_TIMEOUT_MS = 60_000;
const BUILD_TIME = "2026-10-18T01:10:14Z";
const COMMITTED = "2026-10-18T01:00:00Z";
const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");
const M1_HOST = { model: "MacBookPro18,3", chip: "Apple M1 Pro" };

function recordFor(build: string, version = "2.4.0") {
  return {
    schema: "voicelayer.t3-optf5-proof.v2",
    receipt: "release",
    bundleSha256: sha256("bundle"),
    evidence: { captureLineSha256: sha256("c"), speakLineSha256: sha256("s"), historyEntrySha256: sha256("h") },
    gitCommit: build,
    buildTimeUTC: BUILD_TIME,
    t3Build: "T3 Code (Nightly) 0.1.10 (0.1.10)",
    timestamp: "2026-10-18T01:30:00.000Z",
    expectedTextSha256: sha256("p"),
    historyTextSha256: sha256("p"),
    speakTextCommandId: "73C05ACC-9C3D-432A-BEE4-A6F6B662954F",
    readError: false,
    machine: M1_HOST,
    release: { version, gitCommit: build, buildTimeUTC: BUILD_TIME, bundleSha256: sha256("bundle") },
  };
}

let root: string;
let work: string;
let origin: string;
let marker: string;
beforeEach(() => {
  root = mkdtempSync(join(bundleFixtureRoot(), "ppro-"));
  work = join(root, "w");
  origin = join(root, "o.git");
  marker = join(root, "suite-ran");
});
afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

// Spread into every spawn as `{ ...process.env, ...fixtureEnv() }` (spawn-env isolation guard).
const fixtureEnv = (): Record<string, string> => {
  const clean: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (v !== undefined && !k.startsWith("GIT_")) clean[k] = v;
  return {
    ...clean, HOME: root, SUITE_MARKER: marker,
    GIT_CEILING_DIRECTORIES: bundleFixtureRoot(), // a fixture git call must never walk up into the enclosing checkout
    GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t",
    GIT_AUTHOR_DATE: COMMITTED, GIT_COMMITTER_DATE: COMMITTED,
  };
};
function git(...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", work, "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false", ...args], { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...fixtureEnv() } });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.toString().trim();
}
function put(path: string, text: string) {
  mkdirSync(dirname(join(work, path)), { recursive: true });
  writeFileSync(join(work, path), text);
}
function commitAll(message: string) {
  git("add", "-A");
  git("commit", "-q", "-m", message);
  return git("rev-parse", "HEAD");
}
function push(...refspecs: string[]) {
  const r = Bun.spawnSync(["git", "-C", work, "push", "origin", ...refspecs], { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...fixtureEnv() } });
  return { code: r.exitCode, err: r.stderr.toString(), suiteRan: existsSync(marker) };
}

/** A repo shaped like the release checkout: the real hook and its helpers, a stub suite, a proven build on main pushed to origin. */
function releaseRepo() {
  mkdirSync(work, { recursive: true });
  Bun.spawnSync(["git", "init", "-q", "--bare", origin], { env: { ...process.env, ...fixtureEnv() } });
  Bun.spawnSync(["git", "init", "-q", "-b", "main", work], { env: { ...process.env, ...fixtureEnv() } });
  for (const file of [
    ".githooks/pre-push", "scripts/guard-no-docslocal.sh", "scripts/queue-heavy-suite.py", "scripts/t3-optf5-proof.ts",
    "scripts/release_only_diff.py", "scripts/pre_push_release_only.py", "release-proofs/proof-hosts.json",
  ]) {
    mkdirSync(dirname(join(work, file)), { recursive: true });
    copyFileSync(join(repoRoot, file), join(work, file));
  }
  chmodSync(join(work, ".githooks/pre-push"), 0o755);
  put("scripts/run_tests.sh", 'touch "$SUITE_MARKER"\nexit 0\n');
  put("package.json", JSON.stringify({ name: "voicelayer-mcp", version: "2.4.0" }));
  put("src/tts.ts", "export {};\n");
  const build = commitAll("build");
  git("remote", "add", "origin", origin);
  expect(push("main").code).toBe(0); // before the hook is installed
  rmSync(marker, { force: true });
  git("config", "core.hooksPath", ".githooks");
  return build;
}
const writeProof = (build: string, tag = "v2.4.0", version = "2.4.0") =>
  put(`release-proofs/${tag}.json`, JSON.stringify(recordFor(build, version), null, 2));

describe("the hook still runs the full suites for everything that is not a gated release-only push", () => {
  test("a code change in the diff runs the suite (even beside a valid proof)", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "proof");
    writeProof(build);
    put("src/tts.ts", "export const changed = 1;\n");
    commitAll("proof plus code");
    const r = push("proof");
    expect(r.code).toBe(0);
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("full suites run");
    expect(r.err).toContain("src/tts.ts");
    expect(r.err).not.toContain("RELEASE-ONLY PUSH");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a package.json version bump alone runs the suite (it is not in the gate's allow-list)", () => {
    releaseRepo();
    git("checkout", "-q", "-b", "bump");
    put("package.json", JSON.stringify({ name: "voicelayer-mcp", version: "2.4.1" }));
    commitAll("bump");
    const r = push("bump");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("package.json");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("changing proof-hosts.json (reviewed code) runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "hosts");
    writeProof(build);
    put("release-proofs/proof-hosts.json", '{"hosts":[]}\n');
    commitAll("hosts");
    const r = push("hosts");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("proof-hosts.json");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a proof-only diff whose release gate REFUSES runs the suite (proof names a build that is not in the history)", () => {
    releaseRepo();
    git("checkout", "-q", "-b", "badproof");
    writeProof("1111111111111111111111111111111111111111");
    commitAll("bad proof");
    const r = push("badproof");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("the release gate refused v2.4.0");
    expect(r.err).not.toContain("RELEASE-ONLY PUSH");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a proof for a version package.json does not carry runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "wrongver");
    writeProof(build, "v2.4.9", "2.4.9");
    commitAll("proof for the wrong version");
    const r = push("wrongver");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("the release gate refused v2.4.9");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a deleted proof runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "del");
    writeProof(build);
    commitAll("proof");
    expect(push("del").suiteRan).toBe(false);
    git("rm", "-q", "release-proofs/v2.4.0.json");
    commitAll("delete the proof");
    const r = push("del");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("only added or modified");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("deleting a remote ref runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "gone");
    writeProof(build);
    commitAll("proof");
    push("gone");
    rmSync(marker, { force: true });
    const r = push(":gone");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("a ref deletion");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a dirty tracked tree runs the suite (the gate reads the working tree)", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "dirty");
    writeProof(build);
    commitAll("proof");
    put("src/tts.ts", "export const unsaved = 1;\n");
    const r = push("dirty");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("tracked files are modified");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("pushing a commit that is not the checked-out HEAD runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "other");
    writeProof(build);
    commitAll("proof");
    git("checkout", "-q", "main");
    const r = push("other");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("not the checked-out HEAD");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a push of two refs runs the suite unless BOTH are release-only", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "proofb");
    writeProof(build);
    commitAll("proof");
    git("branch", "codeb", "main");
    const r = push("proofb", "main:refs/heads/codeb2");
    expect(r.suiteRan).toBe(true); // main:codeb2 has an empty diff, which is never release-only
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a tag whose tree changed code after the proven build runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "release");
    writeProof(build);
    put("src/tts.ts", "export const sneaked = 1;\n");
    commitAll("proof plus a code change");
    git("tag", "-a", "-m", "VoiceLayer v2.4.0", "v2.4.0");
    const r = push("v2.4.0");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("the release gate refused v2.4.0");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a non-release tag runs the suite", () => {
    releaseRepo();
    git("tag", "-a", "-m", "scratch", "scratch-tag");
    const r = push("scratch-tag");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("not a vMAJOR.MINOR.PATCH release tag");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  // ---- Codex review r1 bypasses: each of these skipped the suites on 90748ee6 ----

  test("B1: a force-update that DROPS code the remote branch has, behind a valid proof, runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "feat");
    put("src/tts.ts", "export const feature = 1;\n");
    commitAll("feature code");
    expect(push("feat").suiteRan).toBe(true);
    rmSync(marker, { force: true });
    git("reset", "-q", "--hard", "main"); // the rewrite discards the feature commit
    writeProof(build);
    commitAll("proof only, built on main");
    const r = push("--force", "feat");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("does not contain the remote tip");
    expect(r.err).not.toContain("RELEASE-ONLY PUSH");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("B1: a remote tip this checkout has never seen runs the suite (not diffed against main)", () => {
    const build = releaseRepo();
    // someone else pushes code to feat2; this checkout never fetches it
    const other = join(root, "other");
    Bun.spawnSync(["git", "clone", "-q", "-b", "main", origin, other], { env: { ...process.env, ...fixtureEnv() } });
    const og = (...args: string[]) => Bun.spawnSync(["git", "-C", other, "-c", "commit.gpgsign=false", ...args], { env: { ...process.env, ...fixtureEnv() }, stdout: "pipe", stderr: "pipe" });
    og("checkout", "-q", "-b", "feat2");
    writeFileSync(join(other, "src/tts.ts"), "export const theirs = 1;\n");
    og("commit", "-q", "-am", "their code");
    expect(og("push", "-q", "origin", "feat2").exitCode).toBe(0);
    git("checkout", "-q", "-b", "feat2");
    writeProof(build);
    commitAll("proof only");
    const r = push("--force", "feat2");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("is not in this checkout");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("B1: a new branch with no <remote>/main to diff against runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "proof");
    writeProof(build);
    commitAll("proof");
    git("update-ref", "-d", "refs/remotes/origin/main");
    const r = push("proof");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("no refs/remotes/origin/main");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("B2: a tag older than v2.4.0 (the gate exits 0 without verifying any proof) runs the suite", () => {
    releaseRepo();
    git("checkout", "-q", "-b", "oldtag");
    put("package.json", JSON.stringify({ name: "voicelayer-mcp", version: "2.3.5" }));
    put("src/tts.ts", "export const unreviewed = 1;\n");
    commitAll("code under an old-looking tag");
    git("tag", "-a", "-m", "VoiceLayer v2.3.5", "v2.3.5");
    const r = push("v2.3.5");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("without affirming an installed-candidate proof");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("B2: a tag whose proof commit also DELETES a release-proofs file runs the suite (the gate's path check allows deletes)", () => {
    releaseRepo();
    git("checkout", "-q", "-b", "release");
    put("release-proofs/old-note.json", "{}\n");
    const build = commitAll("a file under release-proofs in the proven build");
    writeProof(build);
    git("rm", "-q", "release-proofs/old-note.json");
    commitAll("proof plus a deletion");
    git("tag", "-a", "-m", "VoiceLayer v2.4.0", "v2.4.0");
    const r = push("v2.4.0");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("only added or modified");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("S4: a proof that is a symlink (the gate would follow it) runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "linkproof");
    writeProof(build, "real"); // a valid proof body at release-proofs/real.json
    symlinkSync("real.json", join(work, "release-proofs", "v2.4.0.json"));
    commitAll("proof as a symlink to a valid-looking file");
    const r = push("linkproof");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("git mode 120000");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("S4: a gitlink (submodule entry) under release-proofs/ runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "gitlink");
    writeProof(build);
    git("add", "release-proofs/v2.4.0.json");
    git("update-index", "--add", "--cacheinfo", `160000,${build},release-proofs/sub`);
    git("commit", "-q", "-m", "proof plus a gitlink");
    mkdirSync(join(work, "release-proofs/sub")); // an empty submodule directory keeps the tree clean
    const r = push("gitlink");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("git mode 160000");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("S5: a bun test file under release-proofs/ beside a valid proof runs the suite", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "sneaky");
    writeProof(build);
    put("release-proofs/sneaky.test.ts", "import { test } from 'bun:test'; test('x', () => {});\n");
    commitAll("proof plus a test file");
    const r = push("sneaky");
    expect(r.suiteRan).toBe(true);
    expect(r.err).toContain("sneaky.test.ts");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("no stdin from git (a manual run of the hook) runs the suite", () => {
    releaseRepo();
    const r = Bun.spawnSync(["bash", ".githooks/pre-push"], { cwd: work, stdout: "pipe", stderr: "pipe", env: { ...process.env, ...fixtureEnv() }, stdin: new TextEncoder().encode("") });
    expect(r.exitCode).toBe(0);
    expect(existsSync(marker)).toBe(true);
    expect(r.stderr.toString()).toContain("git sent no refs on stdin");
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

describe("a gated release-only push skips the suites and says so", () => {
  test("proof-only branch (new branch: diff against origin/main): suite skipped, one loud line", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "proof");
    writeProof(build);
    commitAll("release: v2.4.0 installed-candidate proof");
    const r = push("proof");
    expect(r.code).toBe(0);
    expect(r.suiteRan).toBe(false);
    const loud = r.err.split("\n").filter((l) => l.includes("RELEASE-ONLY PUSH"));
    expect(loud.length).toBe(1);
    expect(loud[0]).toContain("SKIPPED by rule, not by --no-verify");
    expect(loud[0]).toContain("release gate passed");
    expect(git("ls-remote", "origin", "refs/heads/proof")).not.toBe(""); // and the push really happened
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a proof commit on top of an already-pushed feature branch is diffed against the remote tip, not main", () => {
    releaseRepo();
    git("checkout", "-q", "-b", "feature");
    put("src/tts.ts", "export const feature = 1;\n");
    const build = commitAll("feature code"); // the proven build: its own code already ran the suites
    expect(push("feature").suiteRan).toBe(true); // code: the suite runs, as before
    rmSync(marker, { force: true });
    writeProof(build);
    commitAll("proof on top");
    const r = push("feature");
    expect(r.code).toBe(0);
    expect(r.suiteRan).toBe(false);
    expect(r.err).toContain("RELEASE-ONLY PUSH");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("tag push of a proof-only descendant of the proven build: suite skipped (the gate is the proof)", () => {
    const build = releaseRepo();
    git("checkout", "-q", "-b", "proof");
    writeProof(build);
    commitAll("release proof");
    git("tag", "-a", "-m", "VoiceLayer v2.4.0", "v2.4.0");
    const r = push("v2.4.0");
    expect(r.code).toBe(0);
    expect(r.suiteRan).toBe(false);
    expect(r.err).toContain("RELEASE-ONLY PUSH");
    expect(git("ls-remote", "--tags", "origin")).toContain("refs/tags/v2.4.0");
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

describe("wiring", () => {
  test("the hook runs the release-only check after the docs.local guard and before the suite queue, and never mentions bypass flags as a mechanism", () => {
    const hook = readFileSync(join(repoRoot, ".githooks/pre-push"), "utf8");
    const guard = hook.indexOf("guard-no-docslocal.sh");
    const check = hook.indexOf("pre_push_release_only.py");
    const queue = hook.indexOf("queue-heavy-suite.py");
    expect(guard).toBeGreaterThan(-1);
    expect(check).toBeGreaterThan(guard);
    expect(queue).toBeGreaterThan(check);
    expect(hook).not.toContain("--no-verify ||");
  });
});
