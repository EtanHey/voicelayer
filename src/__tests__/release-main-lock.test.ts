import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { bundleFixtureRoot } from "./setup/bundle-fixtures";
import { fixtureGit, makeMainFixture, type MainFixture } from "./setup/release-main-fixture";

// Release lock (T15): nothing is tagged, signed, uploaded, tapped or published from a commit
// that is not on origin/main. Fixtures are a temporary repo with a local bare "origin"; the
// real remote is never contacted.

const repo = resolve(import.meta.dir, "../..");
const yml = readFileSync(join(repo, ".github", "workflows", "publish.yml"), "utf8");
const SUBPROCESS_TIMEOUT_MS = 60_000;

let parent: string;
let fx: MainFixture;
beforeEach(() => {
  parent = mkdtempSync(join(bundleFixtureRoot(), "rellock-"));
  fx = makeMainFixture(parent);
});
afterEach(() => {
  rmSync(parent, { recursive: true, force: true });
});

function run(script: string, args: string[], extraEnv: Record<string, string> = {}) {
  const r = Bun.spawnSync(["/bin/bash", join(fx.root, "scripts", script), ...args], {
    cwd: fx.root, stdout: "pipe", stderr: "pipe", env: { ...process.env, ...extraEnv },
  });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
}

describe("scripts/tag-voicebar-release.sh", () => {
  test("refuses a HEAD that is on a side branch, and creates no tag", () => {
    const side = fx.sideCommit();
    const r = run("tag-voicebar-release.sh", ["2.4.0"]);
    expect(r.code).toBe(1);
    expect(r.err).toContain(`[tag-voicebar-release] REFUSED: HEAD ${side} is not on origin/main`);
    expect(fixtureGit(fx.root, "tag", "--list")).toBe("");
  }, SUBPROCESS_TIMEOUT_MS);

  test("a main commit passes the lock (and is stopped only by a later, unrelated check)", () => {
    const r = run("tag-voicebar-release.sh", ["2.4.0"]);
    expect(r.err).not.toContain("origin/main");
    expect(r.err).toContain("REFUSED");
  }, SUBPROCESS_TIMEOUT_MS);

  test("refuses when main cannot be fetched (fails closed)", () => {
    fixtureGit(fx.root, "remote", "set-url", "origin", join(parent, "missing.git"));
    const r = run("tag-voicebar-release.sh", ["2.4.0"]);
    expect(r.code).toBe(1);
    expect(r.err).toContain("cannot fetch origin main");
  }, SUBPROCESS_TIMEOUT_MS);
});

describe("scripts/release-voicebar.sh", () => {
  // A stubbed `bash` stands in for the signing build, so a pass case never builds or signs.
  function stubEnv() {
    const hook = join(parent, "stub.sh");
    writeFileSync(hook, 'bash() { printf "build\\n" >> "$RELLOCK_TRACE"; return 73; }\n');
    return { BASH_ENV: hook, RELLOCK_TRACE: join(parent, "trace") };
  }
  const out = () => join(parent, "artifacts.noindex");

  test("refuses a side-branch build commit before cleanup, build or signing", () => {
    const side = fx.sideCommit();
    const env = stubEnv();
    const r = run("release-voicebar.sh", ["--skip-tap-check", "--output-dir", out()], env);
    expect(r.code).toBe(1);
    expect(r.err).toContain(`[release-voicebar] REFUSED: build commit HEAD ${side} is not on origin/main`);
    expect(r.out).not.toContain("Building notarized");
    expect(existsSync(env.RELLOCK_TRACE)).toBe(false);
    expect(existsSync(out())).toBe(false);
  }, SUBPROCESS_TIMEOUT_MS);

  test("a main commit passes the lock and reaches the build step", () => {
    const env = stubEnv();
    const r = run("release-voicebar.sh", ["--skip-tap-check", "--output-dir", out()], env);
    expect(r.err).not.toContain("origin/main");
    expect(r.out).toContain("Building notarized");
    expect(readFileSync(env.RELLOCK_TRACE, "utf8")).toBe("build\n");
  }, SUBPROCESS_TIMEOUT_MS);
});

describe("build-app signer admission", () => {
  for (const staged of [false, true]) {
    test(`direct release entry refuses side branch before compiler (staged=${staged})`, () => {
      fx.sideCommit();
      mkdirSync(join(parent, "artifacts.noindex"));
      const hook = join(parent, "compiler-hook.sh");
      const trace = join(parent, "compiler-trace");
      writeFileSync(hook, 'swift() { echo compiler >> "$RELLOCK_TRACE"; exit 73; }\n');
      const r = Bun.spawnSync(["/bin/bash", join(fx.root, "flow-bar/build-app.sh"),
        "--install-path", join(parent, "artifacts.noindex/VoiceBar.app"), "--no-stop", "--no-relaunch"], {
        cwd: fx.root, stdout: "pipe", stderr: "pipe", env: { ...process.env,
          BASH_ENV: hook, RELLOCK_TRACE: trace, VOICEBAR_REQUIRE_NOTARIZATION: "1",
          VOICEBAR_RELEASE_STAGED: staged ? "1" : "0" },
      });
      expect(r.exitCode).toBe(1);
      expect(r.stderr.toString()).toContain("is not on origin/main");
      expect(existsSync(trace)).toBe(false);
    }, SUBPROCESS_TIMEOUT_MS);
  }

  test("main HEAD with modified tracked source refuses before wrapper build", () => {
    writeFileSync(join(fx.root, "package.json"), readFileSync(join(fx.root, "package.json"), "utf8") + "\n");
    const hook = join(parent, "build-hook.sh");
    const trace = join(parent, "build-trace");
    writeFileSync(hook, 'bash() { echo build >> "$RELLOCK_TRACE"; return 73; }\n');
    const r = run("release-voicebar.sh", ["--skip-tap-check", "--output-dir", join(parent, "dirty.noindex")],
      { BASH_ENV: hook, RELLOCK_TRACE: trace });
    expect(r.code).toBe(1);
    expect(r.err).toContain("source checkout is dirty");
    expect(existsSync(trace)).toBe(false);
  }, SUBPROCESS_TIMEOUT_MS);
});

describe("scripts/promote-voicebar-release.sh", () => {
  function fakeApp(gitCommit: string | null) {
    const app = join(parent, "VoiceBar.app");
    mkdirSync(join(app, "Contents"), { recursive: true });
    const key = gitCommit === null ? "" : `<key>GitCommit</key><string>${gitCommit}</string>`;
    writeFileSync(
      join(app, "Contents", "Info.plist"),
      `<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>${key}</dict></plist>\n`,
    );
    writeFileSync(join(parent, "VoiceBar.zip"), "zip");
    return app;
  }
  function promote(app: string) {
    // gh and curl stubs record any call: a refusal must make none.
    const bin = join(parent, "bin");
    mkdirSync(bin, { recursive: true });
    for (const name of ["gh", "curl"]) {
      writeFileSync(join(bin, name), `#!/usr/bin/env bash\necho "${name} $*" >> "${join(parent, "calls.log")}"\nexit 2\n`);
      chmodSync(join(bin, name), 0o755);
    }
    return run("promote-voicebar-release.sh", [
      "--version", "2.4.0", "--app", app, "--zip", join(parent, "VoiceBar.zip"),
      "--tap-root", join(parent, "tap"), "--formula-sha256", "a".repeat(64), "--t3-proof", join(parent, "proof.json"),
    ], { PATH: `${bin}:${process.env.PATH}` });
  }
  const calls = () => (existsSync(join(parent, "calls.log")) ? readFileSync(join(parent, "calls.log"), "utf8") : "");

  test("refuses an app built from a side-branch commit, before any upload or tap write", () => {
    const side = fx.sideCommit();
    const r = promote(fakeApp(side));
    expect(r.code).toBe(1);
    expect(r.err).toContain(`[promote-voicebar-release] REFUSED: proven build commit ${side} is not on origin/main`);
    expect(calls()).toBe("");
  }, SUBPROCESS_TIMEOUT_MS);

  test("refuses an app whose build commit is unknown or missing", () => {
    expect(promote(fakeApp("1".repeat(40))).err).toContain("is not a commit in this repository");
    expect(promote(fakeApp(null)).err).toContain("no full-SHA GitCommit in Info.plist");
    expect(calls()).toBe("");
  }, SUBPROCESS_TIMEOUT_MS);

  test("an app built from a main commit passes the lock (later checks refuse this fake bundle)", () => {
    const r = promote(fakeApp(fx.mainSha));
    expect(r.err).not.toContain("origin/main");
    expect(r.code).not.toBe(0);
  }, SUBPROCESS_TIMEOUT_MS);
});

describe(".github/workflows/publish.yml", () => {
  const steps = yml.split(/\n      - /).slice(1);
  const index = (needle: string) => steps.findIndex((s) => s.includes(needle));

  test("the publish job runs in the npm-release environment and keeps id-token: write at both levels", () => {
    const job = yml.slice(yml.indexOf("\njobs:"));
    expect(job).toMatch(/\n  publish:\n    runs-on: ubuntu-latest\n    # .*\n(    # .*\n)*    environment: npm-release\n/);
    expect(yml.match(/^\s+id-token: write$/gm)?.length).toBe(2);
  });

  test("the ancestor-of-main refusal is the first step after the source checkout, before the gate and every publish step", () => {
    const refuse = index("name: Refuse commits not on main");
    expect(refuse).toBe(1);
    expect(steps[0]).toContain("actions/checkout@v4");
    expect(steps[refuse]).toContain("git fetch --no-tags origin main:refs/remotes/origin/main");
    expect(steps[refuse]).toContain('git merge-base --is-ancestor "$commit" refs/remotes/origin/main');
    expect(steps[refuse]).toContain("exit 1");
    expect(refuse).toBeLessThan(index("name: Release gate"));
    expect(refuse).toBeLessThan(index("npm publish"));
    expect(refuse).toBeLessThan(index("bun test"));
  });
});
