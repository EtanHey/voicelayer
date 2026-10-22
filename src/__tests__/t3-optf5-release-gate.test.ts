import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "fs";
import { join } from "path";
import { createHash } from "crypto";
import { bundleDigest } from "../../scripts/t3-optf5-proof";

// T3GATE1 (2026-10-18): the 2.2.45 T3 Option+F5 regression shipped because publication never
// required the installed-candidate T3 proof. The tap-check (final, pre-cask-bump) mode of
// scripts/verify-voicebar-release.sh now refuses without a matching proof, with no bypass.
// The proof is produced from the installed app's real artifacts by scripts/t3-optf5-proof.ts,
// which never presses keys itself.

const SUBPROCESS_TEST_TIMEOUT_MS = 15_000;

const repoRoot = new URL("../..", import.meta.url).pathname;
const verifyScript = join(repoRoot, "scripts", "verify-voicebar-release.sh");
const proofScript = join(repoRoot, "scripts", "t3-optf5-proof.ts");
const releaseScript = join(repoRoot, "scripts", "release-voicebar.sh");
const promoteScript = join(repoRoot, "scripts", "promote-voicebar-release.sh");
const version: string = JSON.parse(readFileSync(join(repoRoot, "package.json"), "utf8")).version;

const COMMIT = "05bcc0a235712245dfc0bd08f8e657dd9277e7cd";
const OTHER_COMMIT = "1111111111111111111111111111111111111111";
const BUILD_TIME = "2026-10-18T01:10:14Z";
const AFTER_BUILD = "2026-10-18T01:30:00.000Z";
const BEFORE_BUILD = "2026-10-18T00:59:00.000Z";
const SYNTHETIC = "T3 gate synthetic paragraph seven, amber lantern.";
const sha256 = (text: string) => createHash("sha256").update(text, "utf8").digest("hex");
const UUID = "73C05ACC-9C3D-432A-BEE4-A6F6B662954F";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(bundleFixtureRoot(), "t3gate-"));
});
afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

function writeInfoPlist(path: string, fields: Record<string, string>) {
  const body = Object.entries(fields)
    .map(([k, v]) => `  <key>${k}</key>\n  <string>${v}</string>`)
    .join("\n");
  writeFileSync(
    path,
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n<dict>\n${body}\n</dict>\n</plist>\n`,
  );
}

// The synthetic daemon only keeps a timer alive. It exits once the bun test process that wrote
// it is gone (or after 10 minutes), so an interrupted hook cannot leak it or its fixture parent
// (the parent shell's `wait` returns when this child exits).
const SYNTHETIC_DAEMON = `const owner = ${process.pid};
setInterval(() => { try { process.kill(owner, 0); } catch { process.exit(0); } }, 250);
setTimeout(() => process.exit(0), 600_000); // synthetic daemon
`;

function makeApp(root: string, commit = COMMIT, buildTime = BUILD_TIME) {
  const app = join(root, "VoiceBar.app");
  mkdirSync(join(app, "Contents", "Resources"), { recursive: true });
  writeInfoPlist(join(app, "Contents", "Info.plist"), {
    CFBundleShortVersionString: version,
    CFBundleVersion: version,
    GitCommit: commit,
    BuildTimeUTC: buildTime,
  });
  writeFileSync(join(app, "Contents", "Resources", "package.json"), JSON.stringify({ version }));
  mkdirSync(join(app, "Contents", "Resources", "src"));
  writeFileSync(join(app, "Contents", "Resources", "src", "mcp-server-daemon.ts"), SYNTHETIC_DAEMON);
  return app;
}

function zipApp(root: string) {
  rmSync(join(root, "VoiceBar.zip"), { force: true });
  const r = Bun.spawnSync(["zip", "-qry", "VoiceBar.zip", "VoiceBar.app"], { cwd: root, stdout: "pipe", stderr: "pipe", env: process.env });
  if (r.exitCode !== 0) throw new Error(`zip failed: ${r.stderr}`);
  return createHash("sha256").update(readFileSync(join(root, "VoiceBar.zip"))).digest("hex");
}

function writeCask(sha: string) {
  writeFileSync(join(dir, "tap", "Casks", "voicebar.rb"), `cask "voicebar" do\n  version "${version}"\n  sha256 "${sha}"\nend\n`);
}

// executableSymlink: make the candidate's executable the same symlink the fake installed
// VoiceBar uses, so its contents are identical to the installed bundle's.
function makeReleaseFixture(opts: { executableSymlink?: string } = {}) {
  const app = makeApp(dir);
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  if (opts.executableSymlink) symlinkSync(opts.executableSymlink, join(app, "Contents", "MacOS", "VoiceBar"));
  else writeFileSync(join(app, "Contents", "MacOS", "VoiceBar"), "candidate-binary\n");
  const zipSha = zipApp(dir);
  mkdirSync(join(dir, "tap", "Formula"), { recursive: true });
  mkdirSync(join(dir, "tap", "Casks"), { recursive: true });
  writeFileSync(
    join(dir, "tap", "Formula", "voicelayer.rb"),
    `class Voicelayer < Formula\n  url "https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-${version}.tgz"\nend\n`,
  );
  writeCask(zipSha);
  const bin = join(dir, "bin");
  mkdirSync(bin);
  writeFileSync(
    join(bin, "codesign"),
    `#!/usr/bin/env bash
case "$*" in
  *-dvvv*) printf 'Authority=Developer ID Application: Etan Heyman (PPN23G925Y)\\nTeamIdentifier=PPN23G925Y\\nRuntime Version=14.0.0\\n' >&2 ;;
  *-r-*) printf 'designated => certificate leaf[subject.OU] = "PPN23G925Y"\\n' >&2 ;;
  *) exit 2 ;;
esac
`,
  );
  writeFileSync(join(bin, "xcrun"), "#!/usr/bin/env bash\n[[ \"$1\" == stapler ]] && exit 0\nexit 2\n");
  writeFileSync(join(bin, "xattr"), "#!/usr/bin/env bash\nexit 0\n");
  for (const tool of ["codesign", "xcrun", "xattr"]) chmodSync(join(bin, tool), 0o755);
  return app;
}

// A release receipt for the fixture candidate. The bundle digest is the candidate's own, as
// if the identical bundle had been installed and exercised.
function proof(overrides: Record<string, unknown> = {}) {
  return {
    schema: "voicelayer.t3-optf5-proof.v2",
    receipt: "release",
    bundleSha256: bundleDigest(join(dir, "VoiceBar.app")),
    evidence: {
      captureLineSha256: sha256("capture"),
      speakLineSha256: sha256("speak"),
      historyEntrySha256: sha256("history"),
    },
    gitCommit: COMMIT,
    buildTimeUTC: BUILD_TIME,
    t3Build: "T3 Code (Alpha) 0.0.45 (0.0.45)",
    timestamp: AFTER_BUILD,
    expectedTextSha256: sha256(SYNTHETIC),
    historyTextSha256: sha256(SYNTHETIC),
    speakTextCommandId: UUID,
    readError: false,
    ...overrides,
  };
}

function writeProof(value: unknown) {
  const path = join(dir, "t3-proof.json");
  writeFileSync(path, typeof value === "string" ? value : JSON.stringify(value, null, 2));
  return path;
}

function runVerify(args: string[], env: Record<string, string> = {}) {
  const result = Bun.spawnSync(
    [
      "bash",
      verifyScript,
      "--version",
      version,
      "--app",
      join(dir, "VoiceBar.app"),
      "--zip",
      join(dir, "VoiceBar.zip"),
      "--tap-root",
      join(dir, "tap"),
      ...args,
    ],
    {
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, PATH: `${join(dir, "bin")}:${process.env.PATH}`, ...env },
    },
  );
  return { code: result.exitCode, out: result.stdout.toString(), err: result.stderr.toString() };
}

describe("release delivery refuses without a matching T3 Option+F5 proof", () => {
  test("no proof: the final (cask-bump) verification refuses", () => {
    makeReleaseFixture();
    const r = runVerify([]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("T3 Option+F5 proof");
    expect(r.out).not.toContain("PASS");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("no proof: there is no bypass environment variable", () => {
    makeReleaseFixture();
    for (const name of [
      "VOICEBAR_SKIP_T3_PROOF",
      "VOICEBAR_ALLOW_MISSING_T3_PROOF",
      "VOICEBAR_T3_PROOF_BYPASS",
      "T3_PROOF_BYPASS",
      "SKIP_T3_PROOF",
    ]) {
      const r = runVerify([], { [name]: "1" });
      expect(r.code).not.toBe(0);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("missing proof file refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", join(dir, "absent.json")]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("T3 Option+F5 proof");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("wrong GitCommit refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ gitCommit: OTHER_COMMIT }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("GitCommit");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("expected/history hash mismatch refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ historyTextSha256: sha256("something else") }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("sha256");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("stale proof (older than the candidate build) refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ timestamp: BEFORE_BUILD }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("stale");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("readError, missing UUID, missing T3 build, bad schema and garbage all refuse", () => {
    makeReleaseFixture();
    const bad: unknown[] = [
      proof({ readError: true }),
      proof({ readError: "false" }),
      proof({ speakTextCommandId: "" }),
      proof({ speakTextCommandId: "not-a-uuid" }),
      proof({ t3Build: "" }),
      proof({ schema: "something-else" }),
      proof({ expectedTextSha256: "abc", historyTextSha256: "abc" }),
      proof({ timestamp: "yesterday" }),
      "{not json",
    ];
    for (const value of bad) {
      const r = runVerify(["--t3-proof", writeProof(value)]);
      expect(r.code).not.toBe(0);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a candidate without GitCommit or BuildTimeUTC cannot be matched and refuses", () => {
    makeReleaseFixture();
    writeInfoPlist(join(dir, "VoiceBar.app", "Contents", "Info.plist"), {
      CFBundleShortVersionString: version,
      CFBundleVersion: version,
    });
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("proof whose buildTimeUTC differs from the candidate (same commit rebuilt) refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ buildTimeUTC: "2026-10-18T01:09:00Z" }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("BuildTimeUTC");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a ZIP that does not contain the proven app refuses", () => {
    makeReleaseFixture();
    // Same version, different build inside the distributable.
    const other = mkdtempSync(join(dir, "other-"));
    makeApp(other, OTHER_COMMIT);
    mkdirSync(join(other, "VoiceBar.app", "Contents", "MacOS"), { recursive: true });
    writeFileSync(join(other, "VoiceBar.app", "Contents", "MacOS", "VoiceBar"), "other-binary\n");
    writeCask(zipApp(other));
    writeFileSync(join(dir, "VoiceBar.zip"), readFileSync(join(other, "VoiceBar.zip")));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("VoiceBar.zip");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a ZIP whose bundled daemon source differs from the proven app refuses", () => {
    makeReleaseFixture();
    const src = join(dir, "VoiceBar.app", "Contents", "Resources", "src");
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, "mcp-server-daemon.ts"), "export const proven = true;\n");
    zipApp(dir);
    writeFileSync(join(src, "mcp-server-daemon.ts"), "export const proven = false;\n");
    writeCask(createHash("sha256").update(readFileSync(join(dir, "VoiceBar.zip"))).digest("hex"));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("mcp-server-daemon.ts");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a ZIP with an extra file the proven app lacks refuses", () => {
    makeReleaseFixture();
    writeFileSync(join(dir, "VoiceBar.app", "Contents", "Resources", "extra.js"), "1\n");
    zipApp(dir);
    rmSync(join(dir, "VoiceBar.app", "Contents", "Resources", "extra.js"));
    writeCask(createHash("sha256").update(readFileSync(join(dir, "VoiceBar.zip"))).digest("hex"));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("extra.js");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a cask sha256 that is not the ZIP's refuses", () => {
    makeReleaseFixture();
    writeCask("0".repeat(64));
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("sha256");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("equal plist identity but different bundle contents refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ bundleSha256: sha256("another bundle") }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("bundle");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a test (non-release) receipt refuses", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof({ receipt: "test" }))]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("release receipt");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("missing evidence-excerpt hashes refuse", () => {
    makeReleaseFixture();
    for (const evidence of [undefined, {}, { captureLineSha256: sha256("c"), speakLineSha256: "x", historyEntrySha256: sha256("h") }]) {
      const r = runVerify(["--t3-proof", writeProof(proof({ evidence }))]);
      expect(r.code).not.toBe(0);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("valid matching proof passes", () => {
    makeReleaseFixture();
    const r = runVerify(["--t3-proof", writeProof(proof())]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.out).toContain("T3 Option+F5 proof");
    expect(r.out).toContain("PASS");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("artifact-only mode (--skip-tap-check) without a proof is not delivery and passes", () => {
    makeReleaseFixture();
    const r = runVerify(["--skip-tap-check"]);
    expect(r.code).toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("artifact-only mode still checks a proof when one is given", () => {
    makeReleaseFixture();
    const r = runVerify(["--skip-tap-check", "--t3-proof", writeProof(proof({ gitCommit: OTHER_COMMIT }))]);
    expect(r.code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("release-voicebar.sh refuses --upload: a fresh build can never carry a proof", () => {
    // The bad --version makes any script that does not refuse --upload at parse time exit at the
    // version check, before build-app.sh. Never run this script without a pre-build exit.
    const r = Bun.spawnSync(["bash", releaseScript, "--upload", "--skip-tap-check", "--version", "0.0.0-never"], {
      stdout: "pipe",
      stderr: "pipe",
      env: process.env,
    });
    expect(r.exitCode).not.toBe(0);
    expect(r.stderr.toString()).toContain("promote-voicebar-release.sh");
    expect(r.stdout.toString()).not.toContain("Building notarized");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("release-voicebar.sh forwards --t3-proof to the verifier", () => {
    const text = readFileSync(releaseScript, "utf8");
    expect(text).toMatch(/VERIFY_ARGS\+=\(--t3-proof/);
  });

  test("CI publication does not depend on native T3 proof", () => {
    const publish = readFileSync(join(repoRoot, ".github", "workflows", "publish.yml"), "utf8");
    expect(publish).not.toContain("t3-proof");
    expect(publish).not.toContain("t3-optf5");
  });
});

describe("promote-voicebar-release.sh is the only delivery path and requires the proof", () => {
  const FORMULA_BYTES = "synthetic published npm tarball";
  const FORMULA_SHA = sha256(FORMULA_BYTES);
  const git = (cwd: string, ...args: string[]) =>
    Bun.spawnSync(["git", ...args], {
      cwd,
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t" },
    });

  // A tap clone with a bare "origin", at the previous release, and a gh stub whose uploads
  // land in a local "release" store that `release download` serves back.
  function promoteFixture() {
    makeReleaseFixture();
    const remote = join(dir, "tap-remote.git");
    git(dir, "init", "-q", "--bare", "-b", "main", remote);
    rmSync(join(dir, "tap"), { recursive: true, force: true });
    git(dir, "clone", "-q", remote, join(dir, "tap"));
    const tap = join(dir, "tap");
    mkdirSync(join(tap, "Formula"), { recursive: true });
    mkdirSync(join(tap, "Casks"), { recursive: true });
    writeFileSync(
      join(tap, "Formula", "voicelayer.rb"),
      `class Voicelayer < Formula\n  url "https://registry.npmjs.org/voicelayer-mcp/-/voicelayer-mcp-0.0.1.tgz"\n  sha256 "${"a".repeat(64)}"\n  license "Apache-2.0"\nend\n`,
    );
    writeFileSync(join(tap, "Casks", "voicebar.rb"), `cask "voicebar" do\n  version "0.0.1"\n  sha256 "${"b".repeat(64)}"\nend\n`);
    git(tap, "add", ".");
    git(tap, "commit", "-q", "-m", "previous release");
    git(tap, "push", "-q", "origin", "HEAD:main");
    const store = join(dir, "release-store");
    mkdirSync(store);
    writeFileSync(
      join(dir, "bin", "gh"),
      `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "${join(dir, "gh.log")}"
if [[ "$1 $2" == "release view" ]]; then [[ -f "${store}/VoiceBar.zip" ]] && printf 'VoiceBar.zip'; exit 0; fi
if [[ "$1 $2" == "release upload" ]]; then
  [[ -f "${store}/VoiceBar.zip" && "$*" != *--clobber* ]] && exit 1
  cp "$4" "${store}/VoiceBar.zip"; exit 0
fi
if [[ "$1 $2" == "release download" ]]; then cat "${store}/VoiceBar.zip"; exit 0; fi
exit 2
`,
    );
    chmodSync(join(dir, "bin", "gh"), 0o755);
    writeFileSync(join(dir, "bin", "curl"), `#!/usr/bin/env bash\nprintf '%s' '${FORMULA_BYTES}'\n`);
    chmodSync(join(dir, "bin", "curl"), 0o755);
    return { tap, remote, store };
  }

  function runPromote(args: string[]) {
    const r = Bun.spawnSync(
      [
        "bash", promoteScript,
        "--version", version,
        "--app", join(dir, "VoiceBar.app"),
        "--zip", join(dir, "VoiceBar.zip"),
        "--tap-root", join(dir, "tap"),
        "--formula-sha256", FORMULA_SHA,
        ...args,
      ],
      {
        stdout: "pipe",
        stderr: "pipe",
        env: {
          ...process.env,
          PATH: `${join(dir, "bin")}:${process.env.PATH}`,
          GIT_AUTHOR_NAME: "t", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "t", GIT_COMMITTER_EMAIL: "t@t",
        },
      },
    );
    const ghLog = join(dir, "gh.log");
    return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString(), gh: existsSync(ghLog) ? readFileSync(ghLog, "utf8") : "" };
  }

  const remoteLog = (remote: string) => git(remote, "log", "--format=%s", "main").stdout.toString();

  test("no proof: nothing is uploaded and the tap is untouched", () => {
    const { tap, remote } = promoteFixture();
    const r = runPromote([]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("T3 Option+F5 proof");
    expect(r.gh).toBe("");
    expect(git(tap, "status", "--porcelain").stdout.toString()).toBe("");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("mismatched proof: nothing is uploaded and the tap is untouched", () => {
    const { tap, remote } = promoteFixture();
    const r = runPromote(["--t3-proof", writeProof(proof({ gitCommit: OTHER_COMMIT }))]);
    expect(r.code).not.toBe(0);
    expect(r.gh).toBe("");
    expect(git(tap, "status", "--porcelain").stdout.toString()).toBe("");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a dirty tap is refused before anything is published", () => {
    const { tap } = promoteFixture();
    writeFileSync(join(tap, "Casks", "voicebar.rb"), "hand edit\n");
    const r = runPromote(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("tap");
    expect(r.gh).toBe("");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("valid proof: uploads the verified ZIP, then commits and pushes formula and cask together", () => {
    const { tap, remote } = promoteFixture();
    const zipSha = createHash("sha256").update(readFileSync(join(dir, "VoiceBar.zip"))).digest("hex");
    const r = runPromote(["--t3-proof", writeProof(proof())]);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    expect(r.gh).toContain(`release upload v${version} ${join(dir, "VoiceBar.zip")}`);
    expect(r.gh).toContain(`release download v${version}`);
    const cask = readFileSync(join(tap, "Casks", "voicebar.rb"), "utf8");
    expect(cask).toContain(`version "${version}"`);
    expect(cask).toContain(`sha256 "${zipSha}"`);
    const formula = readFileSync(join(tap, "Formula", "voicelayer.rb"), "utf8");
    expect(formula).toContain(`voicelayer-mcp-${version}.tgz`);
    expect(formula).toContain(`sha256 "${FORMULA_SHA}"`);
    expect(formula).toContain('license "Apache-2.0"');
    expect(git(tap, "status", "--porcelain").stdout.toString()).toBe("");
    expect(remoteLog(remote)).toContain(version);
    const pushed = git(remote, "show", "--name-only", "--format=", "main").stdout.toString();
    expect(pushed).toContain("Casks/voicebar.rb");
    expect(pushed).toContain("Formula/voicelayer.rb");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a rejected tap push retries the existing release commit without uploading again", () => {
    const { tap, remote } = promoteFixture();
    const hook = join(remote, "hooks", "pre-receive");
    writeFileSync(hook, "#!/bin/sh\nexit 1\n");
    chmodSync(hook, 0o755);
    const args = ["--t3-proof", writeProof(proof())];
    expect(runPromote(args).code).not.toBe(0);
    const head = git(tap, "rev-parse", "HEAD").stdout.toString().trim();
    expect(git(tap, "log", "-1", "--format=%s").stdout.toString()).toContain(version);
    expect(remoteLog(remote).trim()).toBe("previous release");
    rmSync(hook);
    const retry = runPromote(args);
    expect(retry.err).toBe("");
    expect(retry.code).toBe(0);
    expect(git(remote, "rev-parse", "main").stdout.toString().trim()).toBe(head);
    expect(git(tap, "rev-parse", "HEAD").stdout.toString().trim()).toBe(head);
    expect(retry.gh.match(/release upload/g)?.length).toBe(1);
    // A retry after a lost successful push response is also harmless.
    expect(runPromote(args).code).toBe(0);
    expect(git(remote, "rev-parse", "main").stdout.toString().trim()).toBe(head);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("unrelated unpushed tap commits are refused before upload", () => {
    const { tap, remote } = promoteFixture();
    writeFileSync(join(tap, "unrelated"), "not part of this release");
    git(tap, "add", ".");
    git(tap, "commit", "-q", "-m", "unrelated");
    const r = runPromote(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.gh).not.toContain("release upload");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a same-version pending release commit with different checksums is refused", () => {
    const { tap, remote } = promoteFixture();
    const hook = join(remote, "hooks", "pre-receive");
    writeFileSync(hook, "#!/bin/sh\nexit 1\n");
    chmodSync(hook, 0o755);
    const args = ["--t3-proof", writeProof(proof())];
    expect(runPromote(args).code).not.toBe(0);
    const cask = join(tap, "Casks", "voicebar.rb");
    writeFileSync(cask, readFileSync(cask, "utf8").replace(/sha256 "[a-f0-9]+"/, `sha256 "${"c".repeat(64)}"`));
    git(tap, "add", ".");
    git(tap, "commit", "-q", "--amend", "--no-edit");
    rmSync(hook);
    const retry = runPromote(args);
    expect(retry.code).not.toBe(0);
    expect(retry.err).toContain("pending");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("promotion refuses a tap checked out on a non-default branch", () => {
    const { tap, remote } = promoteFixture();
    git(tap, "checkout", "-q", "-b", "unrelated-branch");
    const r = runPromote(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.gh).not.toContain("release upload");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a published asset that differs is never overwritten and the tap is untouched", () => {
    const { tap, remote, store } = promoteFixture();
    writeFileSync(join(store, "VoiceBar.zip"), "other bytes");
    const r = runPromote(["--t3-proof", writeProof(proof())]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("published");
    expect(r.gh).not.toContain("release upload");
    expect(readFileSync(join(store, "VoiceBar.zip"), "utf8")).toBe("other bytes");
    expect(git(tap, "status", "--porcelain").stdout.toString()).toBe("");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("an incorrect published npm checksum refuses before committing the tap", () => {
    const { tap, remote } = promoteFixture();
    const r = runPromote(["--t3-proof", writeProof(proof()), "--formula-sha256", "f".repeat(64)]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("published");
    expect(git(tap, "status", "--porcelain").stdout.toString()).toBe("");
    expect(remoteLog(remote).trim()).toBe("previous release");
  }, SUBPROCESS_TEST_TIMEOUT_MS);
});

// ---- proof producer ------------------------------------------------------------------------

const captureLine = (pid: number, ms: number, outcome = "completed", app = "com.t3tools.t3code", utf16 = SYNTHETIC.length) =>
  `${localStamp(ms)} VoiceBar[${pid}:97212876] [VoiceBar][diag] selection_capture appActive=false appKeyWindowTitle=not_recorded ax_read=${outcome === "completed" ? "text" : "not_attempted"} frontmostApp=${app} host_structure=not_observed line_breaks=0 outcome=${outcome} path=ax utf16_count=${utf16} voiceMode=idle`;
const speakLine = (id: string) =>
  `[socket-client] Command from VoiceBar: {"cmd":"speak_text","id":"${id}"} bytes=176`;

function localStamp(ms: number) {
  // VoiceBar's NSLog prefix is local wall-clock time.
  const d = new Date(ms);
  const p = (n: number, w = 2) => String(n).padStart(w, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}.${p(d.getMilliseconds(), 3)}`;
}

const sleepSync = (ms: number) => Bun.sleepSync(ms);

// A real running "installed VoiceBar": a symlink to bash at <app>/Contents/MacOS/VoiceBar, so
// `ps` shows the bundle executable path, with a child whose command names mcp-server-daemon.
// The child is a real Bun process running a timer-only synthetic script; no audio/devices.
// The producer accepts only `<dir>/bun run <script>`, as the real VoiceBar launches it. The
// runner's execPath need not be named bun (vite-plus's shim runs `bun.native`), so the daemon
// runs through a `bun` symlink to it.
let fixtureBunDir: string | undefined;
function fixtureBun(): string {
  fixtureBunDir ??= mkdtempSync(join(bundleFixtureRoot(), "t3bun-"));
  const bun = join(fixtureBunDir, "bun");
  if (!existsSync(bun)) symlinkSync(process.execPath, bun);
  return bun;
}

// Every fake VoiceBar still running; afterAll reaps any a failed or timed-out test left behind.
const liveFakeVoiceBars = new Set<ReturnType<typeof Bun.spawn>>();

function launchFakeVoiceBar(app: string, interpreter = "/bin/bash", script = join(app, "Contents", "Resources", "src", "mcp-server-daemon.ts")) {
  mkdirSync(join(app, "Contents", "MacOS"), { recursive: true });
  if (!existsSync(join(app, "Contents", "MacOS", "VoiceBar"))) symlinkSync(interpreter, join(app, "Contents", "MacOS", "VoiceBar"));
  const proc = Bun.spawn(
    [join(app, "Contents", "MacOS", "VoiceBar"), "-c", '"$1" run "$2" & wait', "fixture", fixtureBun(), script],
    { stdout: "ignore", stderr: "ignore", env: process.env },
  );
  liveFakeVoiceBars.add(proc);
  sleepSync(300); // let the daemon-like child appear
  return proc;
}

const childPids = (pid: number) =>
  Bun.spawnSync(["pgrep", "-P", String(pid)], { stdout: "pipe", env: process.env })
    .stdout.toString()
    .split("\n")
    .filter(Boolean)
    .map(Number);

async function stopFakeVoiceBar(proc: ReturnType<typeof Bun.spawn>) {
  const children = childPids(proc.pid);
  for (const child of children) process.kill(child, "SIGKILL");
  proc.kill("SIGKILL");
  await proc.exited;
  for (const child of children) {
    while (Bun.spawnSync(["kill", "-0", String(child)], { env: process.env }).exitCode === 0) sleepSync(20);
  }
  liveFakeVoiceBars.delete(proc);
}

let runtimeRoot: string;
let installedApp: string;
let voiceBar: ReturnType<typeof Bun.spawn>;

// The start second the producer reads: `ps lstart` in C locale (processStartMs), with the TZ
// runProducer pins. bun test parses dates in UTC, so ps must print UTC too.
function psStartSecond(pid: number): number {
  const out = Bun.spawnSync(["ps", "-o", "lstart=", "-p", String(pid)], {
    stdout: "pipe",
    env: { ...process.env, TZ: "Etc/UTC", LC_ALL: "C", LANG: "C" },
  });
  return Math.floor(Date.parse(out.stdout.toString().trim()) / 1000);
}

// The producer requires VoiceBar and its daemon child to start in a whole second strictly after
// the bundle's ctime. A fixed sleep cannot guarantee that on Linux: procps derives lstart from a
// whole-second boot time, so it reads 0.7-1.7 s earlier than the real spawn (the #445 and #448
// Ubuntu failures). Relaunch until the producer's own start source shows a later second.
async function launchAfterInstall(app: string) {
  const ctimeSecond = (path: string) => Math.floor(statSync(path).ctimeMs / 1000);
  const installed = Math.max(
    ctimeSecond(join(app, "Contents", "Info.plist")),
    ctimeSecond(join(app, "Contents", "Resources", "src", "mcp-server-daemon.ts")),
  );
  const deadline = Date.now() + 10_000;
  for (;;) {
    const proc = launchFakeVoiceBar(app);
    const pids = [proc.pid, ...childPids(proc.pid)];
    if (pids.length > 1 && pids.every((pid) => psStartSecond(pid) > installed)) return proc;
    await stopFakeVoiceBar(proc);
    if (Date.now() > deadline) throw new Error(`fake VoiceBar never started after install second ${installed}`);
    sleepSync(250);
  }
}

beforeAll(async () => {
  runtimeRoot = mkdtempSync(join(bundleFixtureRoot(), "t3rt-"));
  installedApp = makeApp(join(runtimeRoot, "installed"));
  voiceBar = await launchAfterInstall(installedApp);
}, SUBPROCESS_TEST_TIMEOUT_MS);
afterAll(async () => {
  for (const proc of [...liveFakeVoiceBars]) await stopFakeVoiceBar(proc);
  rmSync(runtimeRoot, { recursive: true, force: true });
  if (fixtureBunDir) rmSync(fixtureBunDir, { recursive: true, force: true });
});

function producerFixture(app = installedApp) {
  const t3 = join(dir, "T3 Code (Alpha).app");
  mkdirSync(join(t3, "Contents"), { recursive: true });
  writeInfoPlist(join(t3, "Contents", "Info.plist"), {
    CFBundleIdentifier: "com.t3tools.t3code",
    CFBundleName: "T3 Code (Alpha)",
    CFBundleShortVersionString: "0.0.45",
    CFBundleVersion: "0.0.45",
  });
  // A complete, valid keypress from BEFORE start: it must never count.
  const earlier = Date.now() - 60_000;
  const log = join(dir, "voicebar-err.log");
  writeFileSync(log, `${captureLine(voiceBar.pid, earlier)}\n${speakLine("00000000-0000-4000-8000-000000000000")}\n`);
  const history = join(dir, "voicelayer-history.json");
  writeFileSync(history, JSON.stringify([{ id: 0, file: "x.mp3", text: SYNTHETIC, voice: "v", timestamp: earlier + 400 }]));
  const expected = join(dir, "expected.txt");
  writeFileSync(expected, SYNTHETIC);
  const state = join(dir, "state.json");
  const out = join(dir, "proof.json");
  return { installed: app, t3, log, history, expected, state, out };
}

function runProducer(args: string[], env: Record<string, string> = {}) {
  // bun test runs in UTC; the producer parses VoiceBar's local-time log prefix, so pin both.
  const r = Bun.spawnSync([process.execPath, proofScript, ...args], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, TZ: "Etc/UTC", ...env },
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

function start(f: ReturnType<typeof producerFixture>, env: Record<string, string> = {}) {
  return runProducer([
    "start",
    "--state", f.state,
    "--app", f.installed,
    "--t3-app", f.t3,
    "--voicebar-log", f.log,
    "--history-file", f.history,
    "--expected-text-file", f.expected,
  ], env);
}

function finish(f: ReturnType<typeof producerFixture>) {
  return runProducer(["finish", "--state", f.state, "--out", f.out]);
}

function simulateKeypress(
  f: ReturnType<typeof producerFixture>,
  opts: { outcome?: string; app?: string; pid?: number; ids?: string[]; text?: string; utf16?: number; speakBeforeCapture?: boolean } = {},
) {
  const now = Date.now();
  const capture = captureLine(opts.pid ?? voiceBar.pid, now, opts.outcome, opts.app, opts.utf16);
  const speaks = (opts.ids ?? [UUID]).map(speakLine);
  const lines = opts.speakBeforeCapture ? [...speaks, capture] : [capture, ...speaks];
  writeFileSync(f.log, readFileSync(f.log, "utf8") + lines.join("\n") + "\n");
  const history = JSON.parse(readFileSync(f.history, "utf8"));
  if (opts.text !== undefined || opts.ids?.length !== 0) {
    history.push({ id: 1, file: "y.mp3", text: opts.text ?? SYNTHETIC, voice: "v", timestamp: now + 400 });
  }
  writeFileSync(f.history, JSON.stringify(history));
}

// These four tests exercise macOS-only process facts (/bin/zsh, macOS `ps lstart` and ctime
// semantics). The producer itself runs only on the Mac with the resident, so the Ubuntu CI job
// cannot evaluate them; the macOS pre-push hook runs them (lead ruling, 2026-10-18). Nothing
// else in this file is platform-gated.
const MACOS_PROCESS_SEMANTICS = "macOS process semantics; covered by the macOS hook";
const SKIP_MACOS_PROCESS_TESTS = process.platform !== "darwin";
const macosProcessTest = test.skipIf(SKIP_MACOS_PROCESS_TESTS);
if (SKIP_MACOS_PROCESS_TESTS) console.warn(`[t3-optf5-release-gate] skipping 4 producer tests: ${MACOS_PROCESS_SEMANTICS}`);

describe("t3-optf5-proof producer reads the installed app's real artifacts", () => {
  test("on macOS the macOS-process producer tests are not skipped, so the hook must run them", () => {
    expect(SKIP_MACOS_PROCESS_TESTS).toBe(process.platform !== "darwin");
    if (process.platform === "darwin") expect(SKIP_MACOS_PROCESS_TESTS).toBe(false);
  });

  // T3GATE1.3: the producer requires `<dir>/bun run <script>`. Under a shim whose execPath is
  // `bun.native` (vite-plus), spawning process.execPath named the daemon `bun.native run`, and
  // every producer test failed in the pre-push hook while passing under a plain `bun`.
  test("the fixture daemon runs as `bun run <script>` whatever the runner's executable is named", () => {
    const script = join(installedApp, "Contents", "Resources", "src", "mcp-server-daemon.ts");
    const [daemon] = childPids(voiceBar.pid);
    const command = Bun.spawnSync(["ps", "-o", "command=", "-p", String(daemon)], { stdout: "pipe", env: process.env })
      .stdout.toString().trim();
    expect(command.match(/^(?:\S*\/)?bun run (.+)$/)?.[1]).toBe(script);
  });

  test("start + operator keypress + finish yields a proof the release gate accepts", () => {
    const f = producerFixture();
    const s = start(f);
    expect(s.err).toBe("");
    expect(s.code).toBe(0);
    simulateKeypress(f);
    const r = finish(f);
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
    const p = JSON.parse(readFileSync(f.out, "utf8"));
    expect(p).toMatchObject({
      schema: "voicelayer.t3-optf5-proof.v2",
      // Collected from fixture paths under the test preload: never a release receipt.
      receipt: "test",
      bundleSha256: bundleDigest(installedApp),
      gitCommit: COMMIT,
      buildTimeUTC: BUILD_TIME,
      expectedTextSha256: sha256(SYNTHETIC),
      historyTextSha256: sha256(SYNTHETIC),
      speakTextCommandId: UUID,
      readError: false,
    });
    expect(p.t3Build).toContain("0.0.45");
    expect(JSON.stringify(p)).not.toContain(SYNTHETIC);
    const log = readFileSync(f.log, "utf8").trimEnd().split("\n");
    const history = JSON.parse(readFileSync(f.history, "utf8"));
    expect(p.evidence).toEqual({
      captureLineSha256: sha256(log[log.length - 2]),
      speakLineSha256: sha256(log[log.length - 1]),
      historyEntrySha256: sha256(JSON.stringify(history[history.length - 1])),
    });

    // The candidate is byte-identical to the installed bundle (same executable symlink).
    makeReleaseFixture({ executableSymlink: "/bin/bash" });
    expect(bundleDigest(join(dir, "VoiceBar.app"))).toBe(p.bundleSha256);
    // A test receipt never passes the gate...
    const refused = runVerify(["--t3-proof", f.out]);
    expect(refused.code).not.toBe(0);
    expect(refused.err).toContain("release receipt");
    // ...and the same evidence as a release receipt binds to exactly this bundle.
    const asRelease = writeProof({ ...p, receipt: "release" });
    const gate = runVerify(["--t3-proof", asRelease]);
    expect(gate.err).toBe("");
    expect(gate.code).toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("the producer's proof refuses a candidate with equal plist identity but different contents", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f);
    expect(finish(f).code).toBe(0);
    const p = JSON.parse(readFileSync(f.out, "utf8"));
    makeReleaseFixture(); // same GitCommit/BuildTimeUTC, executable is "candidate-binary"
    const r = runVerify(["--t3-proof", writeProof({ ...p, receipt: "release" })]);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("bundle");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("outside the test preload, path overrides are refused before anything is read", () => {
    // The preload's spawn wrapper restores its isolation keys in every child env, so the key
    // is removed by `env -u` inside the child, the way a run outside the preload sees it.
    const env = { ...process.env, TZ: "Etc/UTC" };
    for (const override of [["--voicebar-log", join(dir, "x.log")], ["--history-file", join(dir, "h.json")], ["--app", join(dir, "VoiceBar.app")]]) {
      const r = Bun.spawnSync(
        ["env", "-u", "VOICELAYER_TEST_RUN_ROOT", process.execPath, proofScript, "start", "--state", join(dir, "s.json"), "--t3-app", join(dir, "T3.app"),
          "--expected-text-file", join(dir, "e.txt"), ...override],
        { stdout: "pipe", stderr: "pipe", env },
      );
      expect(r.exitCode).not.toBe(0);
      expect(r.stderr.toString()).toContain("override");
      expect(existsSync(join(dir, "s.json"))).toBe(false);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a complete valid keypress logged before start is never counted", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("Option+F5 was not received");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a capture whose length is not the expected paragraph's is not this keypress", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { utf16: SYNTHETIC.length + 7 });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("utf16_count");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a speak_text from before the capture makes the window ambiguous", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { ids: [UUID], speakBeforeCapture: true });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a failed T3 read is a read error and exits non-zero", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { outcome: "capture_failed", ids: [] });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("read error");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("history text that differs from the expected paragraph exits non-zero and the gate refuses it", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { text: "T3 gate synthetic paragraph seven" });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("sha256");
    makeReleaseFixture({ executableSymlink: "/bin/bash" });
    expect(runVerify(["--t3-proof", writeProof({ ...JSON.parse(readFileSync(f.out, "utf8")), receipt: "release" })]).code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("two speak_text commands in one window are ambiguous and refuse", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { ids: [UUID, "758CE9C3-D434-4FEC-9B90-8173721553E0"] });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a capture from another frontmost app is not T3 proof", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { app: "com.apple.Safari" });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a capture logged by a different VoiceBar process is not proof for the installed app", () => {
    const f = producerFixture();
    expect(start(f).code).toBe(0);
    simulateKeypress(f, { pid: voiceBar.pid + 100_000 });
    const r = finish(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("VoiceBar");
    expect(existsSync(f.out)).toBe(false);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("no running VoiceBar from the installed bundle refuses at start", () => {
    const notRunning = makeApp(join(dir, "not-running"));
    const f = producerFixture(notRunning);
    const r = start(f);
    expect(r.code).not.toBe(0);
    expect(r.err).toContain("running");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a VoiceBar process older than the installed bundle (swapped, not relaunched) refuses", async () => {
    const swapped = makeApp(join(dir, "swapped"));
    const old = launchFakeVoiceBar(swapped);
    try {
      sleepSync(1_100);
      // Re-install the bundle under the running process.
      writeInfoPlist(join(swapped, "Contents", "Info.plist"), {
        CFBundleShortVersionString: version,
        CFBundleVersion: version,
        GitCommit: COMMIT,
        BuildTimeUTC: BUILD_TIME,
      });
      const f = producerFixture(swapped);
      const r = start(f);
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("older than the installed bundle");
    } finally {
      await stopFakeVoiceBar(old);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  macosProcessTest("an old VoiceBar still running after a staged bundle was moved into place refuses", async () => {
    // Stage B first (its files' ctime predates the launch), launch A, then rename B over A.
    const root = mkdtempSync(join(dir, "swap-"));
    const staged = makeApp(join(root, "staged"));
    mkdirSync(join(staged, "Contents", "MacOS"), { recursive: true });
    symlinkSync("/bin/zsh", join(staged, "Contents", "MacOS", "VoiceBar"));
    const live = makeApp(join(root, "live"));
    sleepSync(1_100);
    const old = launchFakeVoiceBar(live);
    try {
      Bun.spawnSync(["mv", live, join(root, "live-old.app")], { env: process.env });
      Bun.spawnSync(["mv", staged, live], { env: process.env });
      const f = producerFixture(live);
      const r = start(f);
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("not the executable installed at");
    } finally {
      await stopFakeVoiceBar(old);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("ps start-time collection forces C locale even under de_DE", () => {
    const bin = join(dir, "bin");
    mkdirSync(bin);
    writeFileSync(join(bin, "ps"), `#!/bin/bash
if [[ "$*" == *lstart=* && ( "$LC_ALL" != C || "$LANG" != C ) ]]; then
  printf 'So. 18 Okt. 04:21:50 2026\\n'; exit 0
fi
exec /bin/ps "$@"
`);
    chmodSync(join(bin, "ps"), 0o755);
    const r = start(producerFixture(), { PATH: `${bin}:${process.env.PATH}`, LC_ALL: "de_DE.UTF-8", LANG: "de_DE.UTF-8" });
    expect(r.err).toBe("");
    expect(r.code).toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  macosProcessTest("a stale daemon after its script is replaced refuses even with an unchanged plist and executable", async () => {
    const app = makeApp(join(dir, "daemon-swap"));
    sleepSync(1_100);
    const old = launchFakeVoiceBar(app);
    try {
      sleepSync(1_100);
      writeFileSync(join(app, "Contents", "Resources", "src", "mcp-server-daemon.ts"), "// newer daemon\n");
      const r = start(producerFixture(app));
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("mcp-server-daemon");
      expect(existsSync(join(dir, "state.json"))).toBe(false);
    } finally {
      await stopFakeVoiceBar(old);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  macosProcessTest("a daemon child using a script outside the installed Resources refuses", async () => {
    const app = makeApp(join(dir, "outside-daemon"));
    sleepSync(1_100);
    const outside = join(dir, "mcp-server-daemon.ts");
    writeFileSync(outside, SYNTHETIC_DAEMON);
    const child = launchFakeVoiceBar(app, "/bin/bash", outside);
    try {
      const r = start(producerFixture(app));
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("mcp-server-daemon");
    } finally {
      await stopFakeVoiceBar(child);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  macosProcessTest("a daemon script symlink escaping Resources refuses", async () => {
    const app = makeApp(join(dir, "linked-daemon"));
    const script = join(app, "Contents", "Resources", "src", "mcp-server-daemon.ts");
    const outside = join(dir, "mcp-server-daemon.ts");
    writeFileSync(outside, `${SYNTHETIC_DAEMON}// outside bundle\n`);
    rmSync(script);
    symlinkSync(outside, script);
    sleepSync(1_100);
    const child = launchFakeVoiceBar(app);
    try {
      const r = start(producerFixture(app));
      expect(r.code).not.toBe(0);
      expect(r.err).toContain("Resources");
    } finally {
      await stopFakeVoiceBar(child);
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("a T3 app that is not com.t3tools.t3code is refused at start", () => {
    const f = producerFixture();
    writeInfoPlist(join(f.t3, "Contents", "Info.plist"), { CFBundleIdentifier: "com.example.other", CFBundleShortVersionString: "1" });
    expect(start(f).code).not.toBe(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  test("the producer never synthesizes a keypress", () => {
    const text = readFileSync(proofScript, "utf8");
    for (const forbidden of ["CGEvent", "osascript", "key code", "keystroke", "cliclick", "hidutil"]) {
      expect(text).not.toContain(forbidden);
    }
  });
});
