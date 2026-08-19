import { describe, expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const buildApp = join(repoRoot, "flow-bar", "build-app.sh");

function runBuildApp(args: string[], env: Record<string, string> = {}) {
  return Bun.spawnSync(["bash", buildApp, ...args], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      ...process.env,
      // Refusal has to happen before any build work, so nothing here builds.
      VOICEBAR_TEST_BREW_CASK_REGISTERED: "1",
      ...env,
    },
  });
}

function decode(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

describe("build-app.sh refuses to desynchronise a brew-managed Mac", () => {
  test("writing into the brew-managed /Applications bundle is refused", () => {
    const result = runBuildApp([]);
    const stderr = decode(result.stderr);

    expect(result.exitCode).toBe(1);
    expect(stderr).toContain("managed by Homebrew");
    expect(stderr).toContain("Nothing has been built or installed");
    expect(stderr).toContain("--install-path");
    expect(stderr).toContain("voicelayer update");
    // The refusal must precede the build, not follow it.
    expect(decode(result.stdout)).not.toContain("Building VoiceBar");
  });

  test("an explicit --install-path elsewhere is never refused", () => {
    const result = runBuildApp(
      ["--install-path", "/tmp/VoiceBar-guard-test.app"],
      { VOICEBAR_BUILD_APP_SOURCE_ONLY: "1" },
    );

    expect(decode(result.stderr)).not.toContain("managed by Homebrew");
  });

  test("a Mac with no cask registration builds into /Applications as before", () => {
    const result = runBuildApp([], {
      VOICEBAR_TEST_BREW_CASK_REGISTERED: "0",
      VOICEBAR_BUILD_APP_SOURCE_ONLY: "1",
    });

    expect(decode(result.stderr)).not.toContain("managed by Homebrew");
  });

  test("the deliberate resident-swap override warns that brew's ledger is now stale", () => {
    const body = readFileSync(buildApp, "utf8");

    expect(body).toContain("VOICEBAR_ALLOW_BREW_MANAGED_INSTALL");
    expect(body).toContain("VOICEBAR_BREW_LEDGER_WILL_DRIFT=1");
    expect(body).toContain("Put this Mac back with:  voicelayer update");
  });

  test("the resident-swap verify gates carry the override explicitly", () => {
    const verify = readFileSync(
      join(repoRoot, "scripts", "voicelayer-verify.sh"),
      "utf8",
    );
    const autoF5 = readFileSync(
      join(repoRoot, "scripts", "auto-f5-verify.sh"),
      "utf8",
    );

    expect(verify).toContain("VOICEBAR_ALLOW_BREW_MANAGED_INSTALL=1 ./build-app.sh");
    expect(autoF5).toContain(
      "VOICEBAR_ALLOW_BREW_MANAGED_INSTALL=1 bash flow-bar/build-app.sh",
    );
  });
});
