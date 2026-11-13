import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { createHash } from "crypto";
import { bundleDigest, checkReleaseRecord, releaseGateApplies, type BuildCommitFacts } from "../../scripts/t3-optf5-proof";

// R2 (post-mortem "why VoiceBar 2.3 never reached a Mac"): from v2.4.0 on, publish.yml refuses a
// tag unless release-proofs/<tag>.json holds the installed-candidate T3 Option+F5 proof for the
// build the tag carries. The hosted runner re-runs the promote path's checkProof on it.

const repoRoot = new URL("../..", import.meta.url).pathname;
const proofScript = join(repoRoot, "scripts", "t3-optf5-proof.ts");
const BUILD = "05bcc0a235712245dfc0bd08f8e657dd9277e7cd";
const TAG_COMMIT = "1111111111111111111111111111111111111111";
const BUILD_TIME = "2026-10-18T01:10:14Z";
const COMMITTED = "2026-10-18T01:00:00Z";
const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");
const BUNDLE = sha256("bundle");
const M1_HOST = { model: "MacBookPro18,3", chip: "Apple M1 Pro" }; // release-proofs/proof-hosts.json
const HOST_ARGS = ["--host-model", M1_HOST.model, "--host-chip", M1_HOST.chip]; // test-only seam

function recordFor(overrides: Record<string, unknown> = {}, release: Record<string, unknown> = {}) {
  return {
    schema: "voicelayer.t3-optf5-proof.v2",
    receipt: "release",
    bundleSha256: BUNDLE,
    evidence: { captureLineSha256: sha256("c"), speakLineSha256: sha256("s"), historyEntrySha256: sha256("h") },
    gitCommit: BUILD,
    buildTimeUTC: BUILD_TIME,
    t3Build: "T3 Code (Nightly) 0.1.10 (0.1.10)",
    timestamp: "2026-10-18T01:30:00.000Z",
    expectedTextSha256: sha256("p"),
    historyTextSha256: sha256("p"),
    speakTextCommandId: "73C05ACC-9C3D-432A-BEE4-A6F6B662954F",
    readError: false,
    machine: M1_HOST,
    ...overrides,
    release: { version: "2.4.0", gitCommit: BUILD, buildTimeUTC: BUILD_TIME, bundleSha256: BUNDLE, ...release },
  };
}

const descendant: BuildCommitFacts = { isAncestor: true, changedPaths: ["release-proofs/v2.4.0.json"], committedAtMs: Date.parse(COMMITTED) };
function gate(raw: unknown, facts: BuildCommitFacts | null = descendant, packageVersion = "2.4.0") {
  return () => checkReleaseRecord(raw, { tag: "v2.4.0", tagCommit: TAG_COMMIT, packageVersion, buildCommit: () => facts });
}

describe("release gate rule (checkReleaseRecord)", () => {
  test("a valid record on a tag that adds only release-proofs/ passes", () => {
    expect(gate(recordFor())().gitCommit).toBe(BUILD);
  });

  test("wrong commit refuses: not in the repository, not an ancestor, or a tag that changes more", () => {
    expect(gate(recordFor(), null)).toThrow("not in this repository");
    expect(gate(recordFor(), { ...descendant, isAncestor: false })).toThrow("ancestor");
    expect(gate(recordFor(), { ...descendant, changedPaths: ["release-proofs/v2.4.0.json", "src/tts.ts"] })).toThrow("src/tts.ts");
    expect(gate(recordFor({ gitCommit: TAG_COMMIT }))).toThrow("GitCommit");
    expect(gate(recordFor(), { ...descendant, changedPaths: ["release-proofs/v2.4.0.json", "release-proofs/proof-hosts.json"] })).toThrow("proof-hosts.json");
  });

  test("R3 (Codex r2): a record made through the test-only host seam is refused outside the test preload", () => {
    const overridden = recordFor({}, { hostOverride: true });
    const ctx = { tag: "v2.4.0", tagCommit: TAG_COMMIT, packageVersion: "2.4.0", buildCommit: () => descendant };
    expect(() => checkReleaseRecord(overridden, { ...ctx, testMode: false })).toThrow("test-only host override");
    expect(checkReleaseRecord(overridden, { ...ctx, testMode: true }).gitCommit).toBe(BUILD);
    expect(checkReleaseRecord(recordFor(), { ...ctx, testMode: false }).gitCommit).toBe(BUILD); // a real record is unaffected
  });

  test("R3: a record whose machine is missing or not an accepted proof host refuses", () => {
    expect(gate(recordFor({ machine: undefined }))).toThrow("not an accepted proof host");
    expect(gate(recordFor({ machine: { model: "Mac14,2", chip: "Apple M2" } }))).toThrow("not an accepted proof host");
  });

  test("wrong bundle hash refuses", () => {
    expect(gate(recordFor({}, { bundleSha256: sha256("other bundle") }))).toThrow("bundleSha256");
    expect(gate(recordFor({ bundleSha256: "not-a-sha" }))).toThrow("bundleSha256");
  });

  test("wrong version refuses (record, or package.json at the tag)", () => {
    expect(gate(recordFor({}, { version: "2.3.0" }))).toThrow("release.version");
    expect(gate(recordFor(), descendant, "2.4.1")).toThrow("package.json");
  });

  test("stale or malformed proofs refuse", () => {
    expect(gate(recordFor({ timestamp: "2026-10-18T01:00:00.000Z" }))).toThrow("stale");
    expect(gate(recordFor({}, { buildTimeUTC: "2026-10-18T00:30:00Z" }))).toThrow();
    expect(gate(recordFor({ buildTimeUTC: "2026-10-18T00:30:00Z" }, { buildTimeUTC: "2026-10-18T00:30:00Z" }))).toThrow("before its commit");
    expect(gate(recordFor({ receipt: "test" }))).toThrow("release receipt");
    expect(gate(recordFor({ schema: "voicelayer.t3-optf5-proof.v1" }))).toThrow("schema");
    expect(gate(recordFor({ historyTextSha256: sha256("other") }))).toThrow("T3 did not read");
    expect(gate(recordFor({ readError: true }))).toThrow("readError");
    const { release: _release, ...bare } = recordFor();
    expect(gate(bare)).toThrow("no release block");
    expect(gate([])).toThrow("not a JSON object");
  });

  test("version rule: the gate applies from v2.4.0 on, prereleases included; non-tags refuse", () => {
    for (const tag of ["v2.4.0", "v2.4.0-rc.1", "v2.4.1", "v2.10.0", "v3.0.0"]) expect(releaseGateApplies(tag)).toBe(true);
    for (const tag of ["v2.3.0", "v2.2.11", "v2.3.99", "v1.9.9"]) expect(releaseGateApplies(tag)).toBe(false);
    for (const tag of ["main", "2.4.0", "v2.4", "v2.4.0;x"]) expect(() => releaseGateApplies(tag)).toThrow("not a release tag");
  });

  test("a tag with a leading zero is malformed, not a gated spelling of v2.4.0", () => {
    for (const tag of ["v02.4.0", "v2.04.0", "v2.4.00"]) expect(() => releaseGateApplies(tag)).toThrow("not a release tag");
  });
});

// ---- the CLI the workflow runs, against a real git history ----------------------------------

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(bundleFixtureRoot(), "relgate-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const gitEnv = {
  ...process.env,
  GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t",
  GIT_AUTHOR_DATE: COMMITTED, GIT_COMMITTER_DATE: COMMITTED,
};
function git(...args: string[]) {
  const r = Bun.spawnSync(["git", "-C", dir, "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", ...args], {
    stdout: "pipe", stderr: "pipe", env: gitEnv,
  });
  if (r.exitCode !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr}`);
  return r.stdout.toString().trim();
}
function commitAll(message: string) {
  git("add", "-A");
  git("commit", "-q", "-m", message);
  return git("rev-parse", "HEAD");
}
function buildRepo(version = "2.4.0", withGate = false) {
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "voicelayer-mcp", version }));
  if (withGate) {
    mkdirSync(join(dir, "scripts"));
    mkdirSync(join(dir, ".github", "workflows"), { recursive: true });
    writeFileSync(join(dir, "scripts", "t3-optf5-proof.ts"), readFileSync(proofScript));
    writeFileSync(join(dir, ".github", "workflows", "publish.yml"), readFileSync(join(repoRoot, ".github", "workflows", "publish.yml")));
    mkdirSync(join(dir, "release-proofs"));
    writeFileSync(join(dir, "release-proofs", "proof-hosts.json"), readFileSync(join(repoRoot, "release-proofs", "proof-hosts.json")));
  }
  mkdirSync(join(dir, "src"));
  writeFileSync(join(dir, "src", "tts.ts"), "export {};\n");
  return commitAll("build");
}
function writeRecord(tag: string, value: unknown) {
  mkdirSync(join(dir, "release-proofs"), { recursive: true });
  writeFileSync(join(dir, "release-proofs", `${tag}.json`), typeof value === "string" ? value : JSON.stringify(value, null, 2));
}
function runGate(tag: string) {
  const r = Bun.spawnSync([process.execPath, proofScript, "release-gate", "--tag", tag, "--repo", dir], {
    stdout: "pipe", stderr: "pipe", env: process.env,
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

describe("release-gate CLI (publish.yml's first step)", () => {
  test("valid: build commit + a proof-only commit, tagged, passes", () => {
    const build = buildRepo();
    writeRecord("v2.4.0", recordFor({ gitCommit: build }, { gitCommit: build }));
    commitAll("release proof");
    git("tag", "v2.4.0");
    const r = runGate("v2.4.0");
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toContain(`PASS: release gate v2.4.0: proof for build ${build}`);
  });

  test("proof missing refuses with one line naming the file", () => {
    buildRepo();
    git("tag", "v2.4.0");
    const r = runGate("refs/tags/v2.4.0");
    expect(r.code).toBe(1);
    expect(r.err.trim().split("\n")).toEqual([
      "[t3-optf5-proof] REFUSED: npm publish release gate: release-proofs/v2.4.0.json is missing: no installed-candidate T3 Option+F5 proof for this release",
    ]);
  });

  test("a tag that also changes code after the proven build refuses", () => {
    const build = buildRepo();
    writeRecord("v2.4.0", recordFor({ gitCommit: build }, { gitCommit: build }));
    writeFileSync(join(dir, "src", "tts.ts"), "export const changed = 1;\n");
    commitAll("proof plus a code change");
    git("tag", "v2.4.0");
    const r = runGate("v2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("outside release-proofs/: src/tts.ts");
  });

  test("a proof naming a commit that is not in the history refuses", () => {
    buildRepo();
    writeRecord("v2.4.0", recordFor({}, {}));
    commitAll("release proof");
    git("tag", "v2.4.0");
    const r = runGate("v2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain(`proven build commit ${BUILD} is not in this repository`);
  });

  test("malformed JSON refuses", () => {
    buildRepo();
    writeRecord("v2.4.0", "{ not json");
    commitAll("broken proof");
    git("tag", "v2.4.0");
    const r = runGate("v2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("release-proofs/v2.4.0.json is not valid JSON");
  });

  test("a tag that is not the checked-out commit refuses", () => {
    buildRepo();
    git("tag", "v2.4.0");
    writeFileSync(join(dir, "README"), "later\n");
    commitAll("later");
    const r = runGate("v2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("does not resolve to the checked-out commit");
  });

  test("a tag older than v2.4.0 is not gated (workflow_dispatch republish of an old tag)", () => {
    buildRepo("2.3.0");
    git("tag", "v2.3.0");
    const r = runGate("v2.3.0");
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toContain("release gate not applied: v2.3.0 is older than v2.4.0");
  });

  test("an old-looking tag on a tree that packs a gated version refuses before the exemption (one line)", () => {
    buildRepo("2.4.0");
    git("tag", "v2.3.0");
    const r = runGate("v2.3.0");
    expect(r.code).toBe(1);
    expect(r.out).toBe("");
    expect(r.err.trim().split("\n")).toEqual([
      "[t3-optf5-proof] REFUSED: npm publish release gate: package.json version '2.4.0' at v2.3.0 is not 2.3.0: the package packed would not be the tagged release",
    ]);
  });

  test("an old tag that is not the checked-out commit refuses before the exemption", () => {
    buildRepo("2.3.0");
    git("tag", "v2.3.0");
    writeFileSync(join(dir, "README"), "later\n");
    commitAll("later");
    const r = runGate("v2.3.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("does not resolve to the checked-out commit");
  });

  test("a leading-zero tag refuses as malformed", () => {
    buildRepo();
    git("tag", "v02.4.0");
    const r = runGate("v02.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("'v02.4.0' is not a release tag");
  });

  test("a ref that is not a release tag refuses", () => {
    buildRepo();
    const r = runGate("main");
    expect(r.code).toBe(1);
    expect(r.err).toContain("not a release tag");
  });
});

describe("record writes the committed proof from the proven app", () => {
  test("record + commit + tag passes the gate; promote's check accepts the same file", () => {
    const build = buildRepo();
    const app = join(dir, ".app-fixture.noindex", "VoiceBar.app");
    mkdirSync(join(app, "Contents", "Resources"), { recursive: true });
    const plist = { CFBundleShortVersionString: "2.4.0", CFBundleVersion: "2.4.0", GitCommit: build, BuildTimeUTC: BUILD_TIME };
    writeFileSync(
      join(app, "Contents", "Info.plist"),
      `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n${Object.entries(plist).map(([k, v]) => `  <key>${k}</key>\n  <string>${v}</string>`).join("\n")}\n</dict>\n</plist>\n`,
    );
    writeFileSync(join(app, "Contents", "Resources", "package.json"), JSON.stringify({ version: "2.4.0" }));
    const { release: _release, ...proof } = recordFor({ gitCommit: build, bundleSha256: bundleDigest(app) });
    const proofPath = join(dir, ".app-fixture.noindex", "proof.json");
    writeFileSync(proofPath, JSON.stringify(proof));
    writeFileSync(join(dir, ".git", "info", "exclude"), ".app-fixture.noindex/\n"); // no commit between build and tag

    const cli = (...args: string[]) =>
      Bun.spawnSync([process.execPath, proofScript, ...args], { cwd: dir, stdout: "pipe", stderr: "pipe", env: process.env });
    const wrongHost = cli("record", "--proof", proofPath, "--app", app, "--out", "release-proofs/v2.4.0.json", "--host-model", "Mac14,2", "--host-chip", "Apple M2");
    expect(wrongHost.exitCode).toBe(1);
    expect(wrongHost.stderr.toString()).toContain("this Mac (Mac14,2, Apple M2) is not an accepted proof host");
    const wrongOut = cli("record", "--proof", proofPath, "--app", app, "--out", "proof.json", ...HOST_ARGS);
    expect(wrongOut.exitCode).toBe(1);
    expect(wrongOut.stderr.toString()).toContain("--out must be release-proofs/v2.4.0.json");
    expect(existsSync(join(dir, "release-proofs"))).toBe(false); // a clean checkout has no release-proofs/ yet
    const rec = cli("record", "--proof", proofPath, "--app", app, "--out", "release-proofs/v2.4.0.json", ...HOST_ARGS);
    expect(rec.stderr.toString()).toBe("");
    expect(rec.exitCode).toBe(0);
    const written = JSON.parse(readFileSync(join(dir, "release-proofs", "v2.4.0.json"), "utf8"));
    // The fixture's host came from the test-only seam, so the record says so.
    expect(written.release).toEqual({ version: "2.4.0", gitCommit: build, buildTimeUTC: BUILD_TIME, bundleSha256: bundleDigest(app), hostOverride: true });
    expect(cli("check", "--proof", join(dir, "release-proofs", "v2.4.0.json"), "--app", app).exitCode).toBe(0);

    commitAll("release proof");
    git("tag", "v2.4.0");
    expect(runGate("v2.4.0").code).toBe(0);
  });
});

describe("publish.yml wiring", () => {
  const yml = readFileSync(join(repoRoot, ".github", "workflows", "publish.yml"), "utf8");

  test("the gate is the first run step, after the checkouts and Bun, before any build or publish", () => {
    const steps = yml.split(/\n      - /).slice(1);
    const firstRun = steps.findIndex((s) => /\n\s+run: /.test(`\n${s}`));
    expect(steps[firstRun]).toContain("release-gate --tag \"$RELEASE_TAG\"");
    expect(steps[firstRun]).toContain("../workflow-tools/scripts/t3-optf5-proof.ts");
    expect(steps.slice(0, firstRun).map((s) => s.split("\n")[0])).toEqual([
      "uses: actions/checkout@v4", "uses: actions/checkout@v4", "uses: oven-sh/setup-bun@v2",
    ]);
    expect(yml).toContain("fetch-depth: 0");
  });

  test("no bypass: no extra dispatch input, no continue-on-error, no gate environment override", () => {
    expect(yml).not.toContain("continue-on-error");
    const inputs = yml.slice(yml.indexOf("inputs:"), yml.indexOf("permissions:"));
    expect(inputs.match(/^ {6}\w+:/gm)).toEqual(["      ref:"]);
    expect(yml).not.toMatch(/^\s+[A-Z_]*(SKIP|BYPASS|UNPROVEN|FORCE)[A-Z_]*:/m);
    const gateStep = yml.slice(yml.indexOf("- name: Release gate"), yml.indexOf("run: bun ../workflow-tools/scripts/t3-optf5-proof.ts release-gate"));
    expect(gateStep.match(/^ {10}[A-Z_]+:/gm)).toEqual(["          RELEASE_TAG:"]);
  });
});

// ---- the single tagging entry point (honest-mistake guard; the workflow cannot gate an ungated tree)

const tagScript = join(repoRoot, "scripts", "tag-voicebar-release.sh");
function runTag(version: string) {
  const r = Bun.spawnSync(["bash", tagScript, version], {
    cwd: dir, stdout: "pipe", stderr: "pipe",
    env: { ...gitEnv, BUN: process.execPath, GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "tag.gpgSign", GIT_CONFIG_VALUE_0: "false" },
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}
function provenRepo(version = "2.4.0") {
  const build = buildRepo(version, true);
  writeRecord(`v${version}`, recordFor({ gitCommit: build }, { gitCommit: build, version }));
  commitAll("release proof");
  return build;
}
const tags = () => git("tag", "--list");

describe("scripts/tag-voicebar-release.sh", () => {
  test("success: annotated tag created locally, push command printed, nothing pushed", () => {
    const origin = join(dir, ".origin.git");
    provenRepo();
    Bun.spawnSync(["git", "init", "-q", "--bare", origin], { env: gitEnv });
    git("remote", "add", "origin", origin);
    writeFileSync(join(dir, ".git", "info", "exclude"), ".origin.git/\n");
    const r = runTag("2.4.0");
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(git("cat-file", "-t", "refs/tags/v2.4.0")).toBe("tag");
    expect(git("rev-parse", "v2.4.0^{commit}")).toBe(git("rev-parse", "HEAD"));
    expect(r.out).toContain("NOT pushed");
    expect(r.out).toContain("  git push origin v2.4.0");
    expect(git("ls-remote", "--tags", "origin")).toBe("");
  });

  test("the script never runs git push (it only prints the command)", () => {
    const pushLines = readFileSync(tagScript, "utf8").split("\n").filter((l) => /git\s+push/.test(l) && !/^\s*(#|echo )/.test(l));
    expect(pushLines).toEqual([]);
  });

  test("refuses a dirty working tree", () => {
    provenRepo();
    writeFileSync(join(dir, "stray.txt"), "x\n");
    const r = runTag("2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("working tree is not clean");
    expect(tags()).toBe("");
  });

  test("refuses a tree without the gate script or without the gate step", () => {
    provenRepo();
    rmSync(join(dir, ".github"), { recursive: true });
    commitAll("drop workflow");
    expect(runTag("2.4.0").err).toContain("publish.yml has no release gate step");
    rmSync(join(dir, "scripts"), { recursive: true });
    commitAll("drop gate");
    const r = runTag("2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("HEAD's tree has no release gate");
    expect(tags()).toBe("");
  });

  test("refuses a version that package.json does not carry, or a malformed version", () => {
    provenRepo();
    expect(runTag("2.4.1").err).toContain("package.json at HEAD is '2.4.0', not 2.4.1");
    expect(runTag("v2.4.0").err).toContain("is not MAJOR.MINOR.PATCH");
    expect(runTag("02.4.0").err).toContain("is not MAJOR.MINOR.PATCH");
    expect(tags()).toBe("");
  });

  test("refuses without a committed proof, or with one the gate refuses", () => {
    buildRepo("2.4.0", true);
    expect(runTag("2.4.0").err).toContain("release-proofs/v2.4.0.json is not committed at HEAD");
    writeRecord("v2.4.0", recordFor({}, {})); // names a build commit not in this history
    commitAll("bad proof");
    const r = runTag("2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("is not in this repository");
    expect(r.err).toContain("the release gate refused HEAD");
    expect(tags()).toBe("");
  });

  test("Codex r2: a run that fails after creating the tag leaves no tag behind", () => {
    provenRepo();
    // stdout is closed, so the first line the script prints after `git tag` fails under `set -e`.
    const r = Bun.spawnSync(["bash", "-c", 'bash "$0" "$1" >&-', tagScript, "2.4.0"], {
      cwd: dir, stdout: "pipe", stderr: "pipe",
      env: { ...gitEnv, BUN: process.execPath, GIT_CONFIG_COUNT: "1", GIT_CONFIG_KEY_0: "tag.gpgSign", GIT_CONFIG_VALUE_0: "false" },
    });
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr.toString()).toContain("failed after creating v2.4.0; the tag was deleted");
    expect(git("tag", "-l", "v2.4.0").trim()).toBe("");
  });

  test("refuses when the tag already exists", () => {
    provenRepo();
    git("tag", "v2.4.0");
    const r = runTag("2.4.0");
    expect(r.code).toBe(1);
    expect(r.err).toContain("tag v2.4.0 already exists");
  });
});

describe("the stated limit (lead ruling: no tree change can gate an ungated tagged tree)", () => {
  test("workflow, runbook and AGENTS.md state it; none claims an unqualified no-bypass for the npm gate", () => {
    const flat = (p: string) => readFileSync(join(repoRoot, p), "utf8").replace(/\n\s*#?\s*/g, " ");
    for (const p of [".github/workflows/publish.yml", "docs/voicebar-release-runbook.md", "AGENTS.md"]) {
      expect(flat(p)).toMatch(/the gate binds every tag whose tree contains it\. A `v\*` tag on a tree without the gate is not stopped by this workflow/i);
      expect(flat(p)).toContain("tag-voicebar-release.sh");
    }
    expect(flat(".github/workflows/publish.yml")).not.toContain("no bypass");
    expect(flat("docs/voicebar-release-runbook.md")).not.toContain("There is no bypass input");
  });
});
