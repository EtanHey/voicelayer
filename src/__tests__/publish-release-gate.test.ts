import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "fs";
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
function buildRepo(version = "2.4.0") {
  git("init", "-q", "-b", "main");
  writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "voicelayer-mcp", version }));
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
    const wrongOut = cli("record", "--proof", proofPath, "--app", app, "--out", "proof.json");
    expect(wrongOut.exitCode).toBe(1);
    expect(wrongOut.stderr.toString()).toContain("--out must be release-proofs/v2.4.0.json");
    mkdirSync(join(dir, "release-proofs"));
    const rec = cli("record", "--proof", proofPath, "--app", app, "--out", "release-proofs/v2.4.0.json");
    expect(rec.stderr.toString()).toBe("");
    expect(rec.exitCode).toBe(0);
    const written = JSON.parse(readFileSync(join(dir, "release-proofs", "v2.4.0.json"), "utf8"));
    expect(written.release).toEqual({ version: "2.4.0", gitCommit: build, buildTimeUTC: BUILD_TIME, bundleSha256: bundleDigest(app) });
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
