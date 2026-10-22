import { expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { bundleFixtureRoot } from "./setup/bundle-fixtures";

const bundleId = "com.voicelayer.voicebar";
const scriptsRoot = new URL("../../scripts/", import.meta.url);
const scriptNames: [string, string] = ["verify-voicebar-hotkey-health.sh", "voicelayer-dedupe-voicebar.sh"];
// Isolated real-directory fixtures; OS effects are stubbed, never the classifier.
function fixture() {
  const root = mkdtempSync(join(bundleFixtureRoot(), "bundle-discovery-"));
  const bin = join(root, "bin"), candidates = join(root, "candidates");
  const app = join(candidates, "Applications/VoiceBar.app");
  mkdirSync(bin); mkdirSync(join(root, "lib"));
  mkdirSync(join(root, "Library/LaunchAgents"), { recursive: true });
  const plist = (path: string, id: string | null) => {
    mkdirSync(join(path, "Contents"), { recursive: true });
    writeFileSync(join(path, "Contents/Info.plist"), `<plist version="1.0"><dict>${id === null ? "" : `<key>CFBundleIdentifier</key><string>${id}</string>`}</dict></plist>`);
  };
  plist(app, bundleId);
  writeFileSync(join(root, "Library/LaunchAgents/com.voicelayer.voicebar.plist"),
    `<plist version="1.0"><dict><key>Program</key><string>${app}/Contents/MacOS/VoiceBar</string></dict></plist>`);
  const stub = (name: string, body: string) =>
    writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o700 });
  stub("find", [
    'roots=(); for root in "$@"; do',
    '  case "$root" in "$VB_TEST_CANDIDATES"|"$VB_TEST_CANDIDATES"/*) roots+=("$root");; esac',
    'done; [[ "${#roots[@]}" -gt 0 ]] || exit 0',
    '/usr/bin/find "${roots[@]}" -maxdepth 6 -name VoiceBar.app -type d -prune',
  ].join("\n"));
  stub("mdfind", 'printf "%s\\n" "$VB_TEST_SPOTLIGHT"');
  // Honor the unreadable fixture even when a Linux runner is root.
  stub("plutil", '/usr/bin/python3 -c \'import os,plistlib,sys; p=sys.argv[-1]; sys.exit(77) if os.stat(p).st_mode & 0o444 == 0 else plistlib.load(open(p,"rb"))\' "$@"');
  writeFileSync(join(bin, "PlistBuddy"), `#!/usr/bin/python3
import os, plistlib, sys
path = sys.argv[-1]
if path == os.environ.get("VB_TEST_READ_FAILURE"):
    sys.exit(74)
with open(path, "rb") as file:
    value = plistlib.load(file)
try:
    for key in sys.argv[2].split()[1].split(":")[1:]:
        value = value[int(key)] if isinstance(value, list) else value[key]
except (KeyError, IndexError):
    print('Print: Entry, "' + sys.argv[2].split()[1] + '", Does Not Exist', file=sys.stderr)
    sys.exit(1)
print(value)
`, { mode: 0o700 });
  stub("codesign", [
    'if [[ "$1" == --verify ]]; then exit "${VB_TEST_VERIFY_STATUS:-0}"; fi',
    'if [[ -f "${@: -1}/unsigned" ]]; then echo "TeamIdentifier=-" >&2; exit 0; fi',
    'printf "Authority=%s\\nTeamIdentifier=%s\\n" "${VB_TEST_AUTHORITY:-Developer ID Application: Fixture}" "${VB_TEST_TEAM:-PPN23G925Y}" >&2',
  ].join("\n"));
  stub("defaults", "exit 1");
  stub("grep", 'if [[ "$1" == -rlE ]]; then /usr/bin/grep "$1" "$2" "$HOME/Library/LaunchAgents"; else /usr/bin/grep "$@"; fi');
  stub("hidutil", "echo '({ HIDKeyboardModifierMappingSrc = 30064771134;\nHIDKeyboardModifierMappingDst = 30064771181;\n},{ HIDKeyboardModifierMappingSrc = 51539607759;\nHIDKeyboardModifierMappingDst = 30064771181; })'");
  stub("launchctl", "exit 1");
  stub("pgrep", "exit 1");
  stub("osascript", '[[ "$*" == *"get the name of every login item"* ]] && exit 0; echo forbidden >&2; exit 90');
  for (const name of ["mv", "cp", "rm", "pkill", "open", "ps", "ioreg"]) {
    stub(name, 'echo "forbidden OS effect: $0" >&2; exit 90');
  }
  for (const lib of ["voicebar-launchagent.sh", "voicebar-bundle-identity.sh"]) {
    writeFileSync(join(root, "lib", lib), readFileSync(new URL(`lib/${lib}`, scriptsRoot)));
  }
  for (const name of scriptNames) {
    // Same isolated script-copy pattern as voicebar-dedupe.test.ts; no product override.
    writeFileSync(join(root, name), readFileSync(new URL(name, scriptsRoot), "utf8")
      .replaceAll("/Applications/VoiceBar.app", app));
  }
  const run = (name: string, overrides: Record<string, string> = {}) => Bun.spawnSync(
    ["/bin/bash", join(root, name), name === scriptNames[0] ? "--allow-stopped" : "--dry-run"],
    { env: { ...process.env, HOME: root, PATH: `${bin}:/usr/bin:/bin`, TMPDIR: candidates,
      PLIST_BUDDY: join(bin, "PlistBuddy"), VOICEBAR_PLIST_BUDDY: join(bin, "PlistBuddy"),
      VOICEBAR_CANONICAL_APP: app, VB_TEST_CANDIDATES: candidates, VB_TEST_SPOTLIGHT: app,
      ...overrides } },
  );
  return { root, app, candidates, plist, run };
}

test("both discovery paths preserve inert directories and valid missing/other IDs", () => {
  const f = fixture();
  try {
    const inert = join(f.candidates, "tmp/inert/VoiceBar.app");
    const missing = join(f.candidates, "tmp/missing/VoiceBar.app");
    const other = join(f.candidates, "tmp/other/VoiceBar.app");
    mkdirSync(inert, { recursive: true });
    f.plist(missing, null); f.plist(other, "com.example.other");
    for (const name of scriptNames) {
      // Stale Spotlight hits must be reclassified too.
      const result = f.run(name, { VB_TEST_SPOTLIGHT: [f.app, missing, other].join("\n") });
      expect(result.exitCode).toBe(0);
      expect(result.stderr.toString()).toBe("");
      for (const path of [inert, missing, other]) {
        expect(existsSync(path)).toBe(true);
        expect(result.stdout.toString()).not.toContain(path);
      }
    }
    expect(existsSync(join(f.root, ".voicelayer"))).toBe(false);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
}, 16_000);

for (const renamed of [false, true]) {
  test(`matching ID remains a duplicate and dedupe-plan entry (Spotlight renamed=${renamed})`, () => {
    const f = fixture();
    try {
      const duplicate = join(f.candidates, "tmp/build.noindex", renamed ? "Renamed.app" : "VoiceBar.app");
      f.plist(duplicate, bundleId);
      if (!renamed) writeFileSync(join(duplicate, "unsigned"), "");
      const env = { VB_TEST_SPOTLIGHT: renamed ? `${f.app}\n${duplicate}` : f.app };
      const health = f.run(scriptNames[0], env);
      expect(health.exitCode).toBe(1);
      expect(health.stderr.toString()).toContain("expected exactly one canonical VoiceBar bundle");
      expect(health.stderr.toString()).toContain(duplicate);
      const dedupe = f.run(scriptNames[1], env);
      expect(dedupe.exitCode).toBe(0);
      expect(dedupe.stdout.toString()).toContain(`would run: mv ${duplicate} `);
      expect(existsSync(duplicate)).toBe(true);
      expect(existsSync(join(f.root, ".voicelayer"))).toBe(false);
    } finally { rmSync(f.root, { recursive: true, force: true }); }
  }, 16_000);
}

for (const failure of ["malformed", "unreadable", "read-error"]) {
  test(`both scripts refuse unknown ${failure} metadata before planning`, () => {
    const f = fixture();
    const candidate = join(f.candidates, "tmp/unknown/VoiceBar.app");
    const info = join(candidate, "Contents/Info.plist");
    try {
      f.plist(candidate, bundleId);
      if (failure === "malformed") writeFileSync(info, "this is not a plist");
      if (failure === "unreadable") chmodSync(info, 0o000);
      for (const name of scriptNames) {
        // Read-error forces a failed extraction of a real, otherwise valid plist.
        const result = f.run(name, failure === "read-error" ? { VB_TEST_READ_FAILURE: info } : {});
        expect(result.exitCode).toBe(1);
        expect(result.stderr.toString()).toContain("VoiceBar bundle identity unknown");
        expect(result.stderr.toString()).toContain(candidate);
        expect(result.stdout.toString()).not.toContain("6. Plan / Apply");
        expect(existsSync(candidate)).toBe(true);
      }
    } finally {
      chmodSync(info, 0o600);
      rmSync(f.root, { recursive: true, force: true });
    }
  }, 16_000);
}

test("canonical identity and existing health signature gates remain strict", () => {
  const f = fixture();
  try {
    for (const id of [null, "com.example.other"]) {
      f.plist(f.app, id);
      for (const name of scriptNames) {
        const result = f.run(name);
        expect(result.exitCode).toBe(1);
        expect(result.stdout.toString()).not.toContain("6. Plan / Apply");
      }
    }
    f.plist(f.app, bundleId);
    const signatureFailures: Record<string, string>[] = [
      { VB_TEST_TEAM: "OTHER" }, { VB_TEST_AUTHORITY: "Apple Development: Fixture" },
    ];
    for (const env of signatureFailures) {
      for (const name of scriptNames) expect(f.run(name, env).exitCode).toBe(1);
    }
    const invalidSignature = f.run(scriptNames[0], { VB_TEST_VERIFY_STATUS: "1" });
    expect(invalidSignature.exitCode).toBe(1);
    expect(invalidSignature.stderr.toString()).toContain("canonical app signature verification failed");
  } finally { rmSync(f.root, { recursive: true, force: true }); }
}, 16_000);

test("dedupe can select a renamed matching source but never a signed other-ID folder", () => {
  const f = fixture();
  try {
    rmSync(f.app, { recursive: true });
    const renamed = join(f.candidates, "build.noindex/Archived.app");
    const other = join(f.candidates, "other/VoiceBar.app");
    f.plist(other, "com.example.other");
    const absent = f.run(scriptNames[1], { VB_TEST_SPOTLIGHT: other });
    expect(absent.exitCode).toBe(1);
    expect(absent.stdout.toString()).toContain("Cannot safely pick a canonical app");
    f.plist(renamed, bundleId);
    const result = f.run(scriptNames[1], { VB_TEST_SPOTLIGHT: `${other}\n${renamed}` });
    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString()).toContain(`Developer-ID build found at: ${renamed}`);
    expect(result.stdout.toString()).toContain(`would run: cp -R ${renamed} ${f.app}`);
    expect(result.stdout.toString()).not.toContain(`would run: mv ${other} `);
    expect(existsSync(other)).toBe(true);
    expect(existsSync(f.app)).toBe(false);
  } finally { rmSync(f.root, { recursive: true, force: true }); }
}, 16_000);
