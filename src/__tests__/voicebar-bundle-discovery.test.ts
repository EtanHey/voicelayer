import { expect, test } from "bun:test";
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readlinkSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
  const effects = join(root, "effects.log");
  writeFileSync(effects, "");
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
  stub("launchctl", '[[ "$1" == print ]] && exit 1; echo "$0 $*" >> "$VB_TEST_EFFECTS"; exit 90');
  stub("pgrep", "exit 1");
  stub("osascript", '[[ "$*" == *"get the name of every login item"* ]] && exit 0; echo "$0 $*" >> "$VB_TEST_EFFECTS"; exit 90');
  for (const name of ["mv", "cp", "rm", "mkdir", "pkill", "open", "ps", "ioreg"]) {
    stub(name, 'echo "$0 $*" >> "$VB_TEST_EFFECTS"; echo "forbidden OS effect: $0" >&2; exit 90');
  }
  for (const lib of ["voicebar-launchagent.sh", "voicebar-bundle-identity.sh"]) {
    writeFileSync(join(root, "lib", lib), readFileSync(new URL(`lib/${lib}`, scriptsRoot)));
  }
  for (const name of scriptNames) {
    // Same isolated script-copy pattern as voicebar-dedupe.test.ts; no product override.
    writeFileSync(join(root, name), readFileSync(new URL(name, scriptsRoot), "utf8")
      .replaceAll("/Applications/VoiceBar.app", app));
  }
  const run = (name: string, overrides: Record<string, string> = {}, mode = "--dry-run") => Bun.spawnSync(
    ["/bin/bash", join(root, name), name === scriptNames[0] ? "--allow-stopped" : mode],
    { env: { ...process.env, HOME: root, PATH: `${bin}:/usr/bin:/bin`, TMPDIR: candidates,
      PLIST_BUDDY: join(bin, "PlistBuddy"), VOICEBAR_PLIST_BUDDY: join(bin, "PlistBuddy"),
      VOICEBAR_CANONICAL_APP: app, VB_TEST_CANDIDATES: candidates, VB_TEST_SPOTLIGHT: app,
      VB_TEST_EFFECTS: effects, ...overrides } },
  );
  return { root, app, candidates, plist, run, stub, effects };
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

test("dedupe normalizes TMPDIR trailing slashes without duplicate plans", () => {
  const f = fixture();
  try {
    const duplicate = join(f.candidates, "tmp/VoiceBar.app");
    f.plist(duplicate, bundleId);
    for (const suffix of ["", "/", "//", "///"]) {
      const result = f.run(scriptNames[1], { TMPDIR: f.candidates + suffix, VB_TEST_SPOTLIGHT: duplicate });
      expect(result.exitCode).toBe(0);
      expect(result.stdout.toString().match(/would run: mv /g) ?? []).toHaveLength(1);
      expect(result.stdout.toString()).toContain(`would run: mv ${duplicate} `);
      expect(readFileSync(f.effects, "utf8")).toBe("");
    }
    f.stub("find", 'printf "%s\\n" "$@" > "$HOME/find-args"');
    for (const tmpdir of ["", "/", "///"]) {
      expect(f.run(scriptNames[1], { TMPDIR: tmpdir }).exitCode).toBe(0);
      expect(readFileSync(join(f.root, "find-args"), "utf8").split("\n").includes("/")).toBe(Boolean(tmpdir));
    }
  } finally { rmSync(f.root, { recursive: true, force: true }); }
}, 16_000);

for (const prefix of [false, true]) {
  test(`dedupe refuses failed inventory before effects (canonical prefix=${prefix})`, () => {
    const f = fixture();
    try {
      const omitted = join(f.candidates, "unknown/VoiceBar.app");
      f.plist(omitted, bundleId);
      writeFileSync(join(omitted, "Contents/Info.plist"), "malformed metadata");
      f.stub("sort", `/bin/cat >/dev/null\n${prefix ? 'printf "%s\\n" "$VOICEBAR_CANONICAL_APP"' : ""}\nexit 76`);
      for (const mode of ["--dry-run", "--apply"]) {
        const result = f.run(scriptNames[1], {}, mode);
        expect(result.exitCode).toBe(1);
        expect(result.stderr.toString()).toContain("bundle inventory failed");
        expect(result.stdout.toString()).not.toContain("6. Plan / Apply");
        expect(readFileSync(f.effects, "utf8")).toBe("");
        expect(readFileSync(join(omitted, "Contents/Info.plist"), "utf8")).toBe("malformed metadata");
      }
    } finally { rmSync(f.root, { recursive: true, force: true }); }
  }, 16_000);
}

for (const occupant of ["regular-file", "dangling-link", "file-link"]) {
  test(`dedupe refuses occupied canonical ${occupant} before plans/effects`, () => {
    const f = fixture();
    try {
      rmSync(f.app, { recursive: true });
      const target = join(f.root, "unrelated-target");
      if (occupant === "regular-file") writeFileSync(f.app, "preserve canonical file");
      else {
        if (occupant === "file-link") writeFileSync(target, "preserve unrelated target");
        symlinkSync(target, f.app);
      }
      const renamed = join(f.candidates, "build.noindex/Renamed.app");
      f.plist(renamed, bundleId);
      const entryInode = lstatSync(f.app).ino;
      const targetInode = existsSync(target) ? lstatSync(target).ino : null;
      for (const mode of ["--dry-run", "--apply"]) {
        const result = f.run(scriptNames[1], { VB_TEST_SPOTLIGHT: renamed }, mode);
        expect(result.exitCode).toBe(1);
        expect(result.stderr.toString()).toContain("occupied canonical path");
        expect(result.stdout.toString()).not.toContain("6. Plan / Apply");
        expect(result.stdout.toString()).not.toMatch(/would run:.*(quit|pkill|bootout|mv|cp)/);
        expect(readFileSync(f.effects, "utf8")).toBe("");
        expect(lstatSync(f.app).ino).toBe(entryInode);
        if (targetInode !== null) expect(lstatSync(target).ino).toBe(targetInode);
        if (occupant === "regular-file") expect(readFileSync(f.app, "utf8")).toBe("preserve canonical file");
        else {
          expect(lstatSync(f.app).isSymbolicLink()).toBe(true);
          expect(readlinkSync(f.app)).toBe(target);
          if (occupant === "file-link") expect(readFileSync(target, "utf8")).toBe("preserve unrelated target");
          else expect(existsSync(target)).toBe(false);
        }
      }
    } finally { rmSync(f.root, { recursive: true, force: true }); }
  }, 16_000);
}

test("canonical directory symlink follows target identity and retains signature gates", () => {
  const f = fixture();
  try {
    rmSync(f.app, { recursive: true });
    const target = join(f.root, "target/Renamed.app");
    f.plist(target, bundleId); symlinkSync(target, f.app);
    const result = f.run(scriptNames[1]);
    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString()).toContain(`Canonical already in place and Developer-ID: ${f.app}`);
    expect(f.run(scriptNames[1], { VB_TEST_TEAM: "OTHER" }).exitCode).toBe(1);
    f.plist(target, "com.example.other");
    expect(f.run(scriptNames[1]).exitCode).toBe(1);
    expect(readlinkSync(f.app)).toBe(target);
    expect(readFileSync(f.effects, "utf8")).toBe("");
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
