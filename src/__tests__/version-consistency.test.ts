import { describe, expect, test } from "bun:test";
import {
  chmodSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";

const repoRoot = join(import.meta.dir, "..", "..");
const script = join(repoRoot, "scripts", "voicelayer-version-check.sh");
const packageVersion = JSON.parse(
  readFileSync(join(repoRoot, "package.json"), "utf8"),
).version;

function plist(version: string) {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${version}</string>
</dict>
</plist>
`;
}

function fixture(options: {
  caskVersion?: string;
  plistVersion?: string;
  gitTag?: string;
  staplerExit?: number;
} = {}) {
  const root = mkdtempSync(join(tmpdir(), "voicelayer-version-check-"));
  const tapRoot = join(root, "homebrew-layers");
  const appPath = join(root, "VoiceBar.app");
  const binDir = join(root, "bin");

  mkdirSync(join(tapRoot, "Casks"), { recursive: true });
  mkdirSync(join(appPath, "Contents"), { recursive: true });
  mkdirSync(binDir, { recursive: true });

  writeFileSync(
    join(tapRoot, "Casks", "voicebar.rb"),
    `cask "voicebar" do
  version "${options.caskVersion ?? packageVersion}"
  sha256 "abc123"
end
`,
  );
  writeFileSync(
    join(appPath, "Contents", "Info.plist"),
    plist(options.plistVersion ?? packageVersion),
  );

  const fakeXcrun = join(binDir, "xcrun");
  writeFileSync(
    fakeXcrun,
    `#!/usr/bin/env bash
if [[ "$1" == "stapler" && "$2" == "validate" ]]; then
  exit ${options.staplerExit ?? 0}
fi
echo "unexpected xcrun invocation: $*" >&2
exit 64
`,
  );
  chmodSync(fakeXcrun, 0o755);

  return {
    env: {
      ...process.env,
      PATH: `${binDir}:${process.env.PATH ?? ""}`,
      VOICEBAR_VERSION_CHECK_TAP_ROOT: tapRoot,
      VOICEBAR_APP_PATH: appPath,
      VOICEBAR_VERSION_CHECK_GIT_TAG: options.gitTag ?? `v${packageVersion}`,
    },
  };
}

function run(env: Record<string, string | undefined>) {
  return Bun.spawnSync(["bash", script], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
    env,
  });
}

function text(bytes: Uint8Array) {
  return new TextDecoder().decode(bytes);
}

describe("voicelayer-version-check.sh", () => {
  test("passes only when package, Info.plist, cask, git tag, and stapled resident app align", () => {
    const result = run(fixture().env);

    expect(result.exitCode).toBe(0);
    expect(text(result.stdout)).toContain(
      `PASS: VoiceBar ${packageVersion} version and notarization guard`,
    );
  });

  test("fails loudly when the Homebrew cask version drifts", () => {
    const result = run(fixture({ caskVersion: "0.0.0" }).env);

    expect(result.exitCode).toBe(1);
    expect(text(result.stderr)).toContain(
      `Casks/voicebar.rb version is '0.0.0', expected '${packageVersion}'`,
    );
  });

  test("fails loudly when the checked-in VoiceBar Info.plist version drifts", () => {
    const result = run(fixture({ plistVersion: "0.0.0" }).env);

    expect(result.exitCode).toBe(1);
    expect(text(result.stderr)).toContain(
      `Info.plist CFBundleShortVersionString is '0.0.0', expected '${packageVersion}'`,
    );
  });

  test("fails loudly when the git tag is not the package version", () => {
    const result = run(fixture({ gitTag: "v0.0.0" }).env);

    expect(result.exitCode).toBe(1);
    expect(text(result.stderr)).toContain(
      `git tag is 'v0.0.0', expected 'v${packageVersion}'`,
    );
  });

  test("fails loudly when the resident app has no stapled notarization ticket", () => {
    const result = run(fixture({ staplerExit: 1 }).env);

    expect(result.exitCode).toBe(1);
    expect(text(result.stderr)).toContain(
      "resident VoiceBar.app does not have a valid stapled notarization ticket",
    );
  });
});
