import { expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, symlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// Complete scripts, with only absolute host paths relocated. The entire PATH is
// fixture-owned: no host app, brew, launchctl, process discovery or audio access.
function fixture(script: string, fault = "", managed = true, qa = false) {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "script-exit-"));
  const bin = join(root, "bin"), app = join(root, "Applications/VoiceBar.app");
  const original = qa ? join(root, "qa.noindex/VoiceBarQA.app") : app;
  for (const dir of [bin, app, original, join(root, "scripts/lib"), join(root, "flow-bar"), join(root, "launchd"), join(root, "home")])
    mkdirSync(dir, { recursive: true });
  for (const tool of ["bash", "cat", "chmod", "cp", "dirname", "basename", "id", "mkdir", "awk", "sort", "uniq", "tr", "sed", "grep", "date", "env", "wc", "paste", "head", "tail", "readlink", "seq", "mv", "rm"])
    symlinkSync(Bun.which(tool)!, join(bin, tool));
  const stub = (name: string, body: string) => writeFileSync(join(bin, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
  const relocate = (source: string) => {
    mkdirSync(join(root, source, ".."), { recursive: true });
    writeFileSync(join(root, source), readFileSync(source, "utf8").replaceAll("/usr/libexec/PlistBuddy", join(bin, "PlistBuddy")).replaceAll("/Applications", join(root, "Applications"))
      .replaceAll("/Library/LaunchAgents /Library/LaunchDaemons", `${root}/system-agents ${root}/system-daemons`), { mode: 0o755 });
  };
  for (const file of ["scripts/lib/update-gate.sh", "scripts/lib/noindex-path.sh", "scripts/lib/voicebar-launchagent.sh", "scripts/lib/voicebar-bundle-identity.sh", "scripts/lib/brew-cask-sync.sh", "scripts/install-voicebar-autostart.sh", "scripts/voicelayer-dedupe-voicebar.sh", script]) relocate(file);
  for (const bundle of new Set([app, original])) {
    mkdirSync(join(bundle, "Contents"));
    writeFileSync(join(bundle, "Contents/Info.plist"), "fixture");
  }
  stub("PlistBuddy", "echo com.voicelayer.voicebar");
  copyFileSync("launchd/com.voicelayer.voicebar.plist", join(root, "launchd/com.voicelayer.voicebar.plist"));
  writeFileSync(join(root, "running"), "101\n");
  writeFileSync(join(root, "calls"), "");
  stub("pgrep", '[[ -s "$TEST_ROOT/running" ]] || exit 1; if [[ "$1" == -x ]]; then cat "$TEST_ROOT/running"; elif [[ "$1" == -afl ]]; then printf "101 %s/Contents/MacOS/VoiceBar\\n" "$TEST_ORIGINAL_APP"; else exit 1; fi');
  stub("ps", '[[ -s "$TEST_ROOT/running" ]] || exit 0; if [[ "$1" == -p ]]; then printf "%s/Contents/MacOS/VoiceBar\\n" "$TEST_ORIGINAL_APP"; else printf "101 1 %s/Contents/MacOS/VoiceBar\\n" "$TEST_ORIGINAL_APP"; fi');
  stub("launchctl", 'echo "launchctl $*" >> "$TEST_ROOT/calls"; case "$1" in list|print) [[ "$TEST_MANAGED" == 1 && ! -f "$TEST_ROOT/unloaded" ]];; bootout) : > "$TEST_ROOT/unloaded";; bootstrap) /bin/rm -f "$TEST_ROOT/unloaded";; kickstart) [[ "$TEST_FAULT" != kickstart ]] || exit 45; echo 202 > "$TEST_ROOT/running";; *) exit 0;; esac');
  stub("open", 'echo "open $*" >> "$TEST_ROOT/calls"; app="$1"; [[ "$app" != -a ]] || app="$TEST_APP"; [[ -d "$app" ]] || exit 1; echo 202 > "$TEST_ROOT/running"');
  stub("bun", `if [[ "$1" == */src/update-gate-installer.ts ]]; then
    if [[ "$2" == --validate ]]; then echo validate >> "$TEST_ROOT/calls"; [[ "$TEST_FAULT" != validate ]]; exit; fi
    echo gate-quit >> "$TEST_ROOT/calls"; : > "$TEST_ROOT/running"
    export VOICELAYER_INSTALL_OPERATION=fixture TEST_GATE_CHILD_PID=$$
    echo "gate-child $$" >> "$TEST_ROOT/calls"; shift; exec "$@"
  fi
  echo "bun $*" >> "$TEST_ROOT/calls"`);
  stub("git", 'case "$*" in *rev-parse*--git-common-dir*) echo "$TEST_ROOT/.git";; *rev-parse*--show-toplevel*) echo "$TEST_ROOT";; *rev-parse*) echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;; *branch*) echo fixture;; esac');
  stub("swift", 'echo compiler >> "$TEST_ROOT/calls"; exit 42');
  stub("sleep", ':');
  for (const tool of ["pkill", "brew", "osascript", "lsof", "xattr", "mdfind", "find", "plutil", "defaults", "codesign", "python3"]) stub(tool, `echo "${tool} $*" >> "$TEST_ROOT/calls"
    case "${tool}" in
      pkill) echo forbidden-force-stop >&2; exit 99;;
      mdfind) printf '%s\\n' "$TEST_APP" "$TEST_ORIGINAL_APP";;
      codesign) echo 'Authority=Developer ID Application: Fixture' >&2; echo 'TeamIdentifier=PPN23G925Y' >&2;;
      defaults) echo com.voicelayer.voicebar;;
      plutil) [[ "$TEST_FAULT" != plist ]];;
      *) exit 0;;
    esac`);
  if (fault === "build-success") {
    mkdirSync(join(root, "flow-bar/bundle"), { recursive: true });
    mkdirSync(join(root, "src"));
    for (const file of ["package.json", "bun.lock", "flow-bar/bundle/Info.plist", "flow-bar/bundle/VoiceBar.entitlements",
      "scripts/install-voicebar-f5-hidutil.sh", "scripts/apply-voicebar-f5-hidutil.sh", "launchd/com.voicelayer.f5-to-f18-hidutil.plist"])
      copyFileSync(file, join(root, file));
    relocate("launchd/install.sh");
    for (const check of ["check-voicebar-qa-free.sh", "check-voicebar-test-free.sh"])
      writeFileSync(join(root, "scripts", check), '#!/bin/bash\necho bundle-check >> "$TEST_ROOT/calls"\n', { mode: 0o755 });
    stub("swift", 'echo compiler >> "$TEST_ROOT/calls"; mkdir -p "$TEST_ROOT/built"; echo fixture > "$TEST_ROOT/built/VoiceBar"; [[ "$*" != *--show-bin-path* ]] || echo "$TEST_ROOT/built"');
    stub("bun", readFileSync(join(bin, "bun"), "utf8") + `
      if [[ "$1" == install ]]; then
        mkdir -p "$TEST_APP/Contents/Resources/node_modules/zod" "$TEST_APP/Contents/Resources/node_modules/@modelcontextprotocol/sdk"
        echo fixture > "$TEST_APP/Contents/Resources/node_modules/fixture.dylib"
      elif [[ "$1" == -e ]]; then echo 1.0.0; fi`);
    stub("find", '[[ "$*" != *-print0* ]] || printf "%s\\0" "$TEST_APP/Contents/Resources/node_modules/fixture.dylib"');
    stub("file", "echo Mach-O");
    stub("security", 'echo "$VOICEBAR_CODESIGN_IDENTITY"');
    stub("codesign", `echo "codesign $*" >> "$TEST_ROOT/calls"
      printf '%s\\n' "Authority=$VOICEBAR_CODESIGN_IDENTITY" 'Authority=Developer ID Certification Authority' 'Authority=Apple Root CA' 'TeamIdentifier=PPN23G925Y' >&2`);
    for (const tool of ["ditto", "rsync", "spctl"]) stub(tool, `echo "${tool} $*" >> "$TEST_ROOT/calls"`);
  }
  // Non-compiler callers use a fake build that can fail, signal its parent or
  // reopen VoiceBar. The build caller itself always runs the complete real file.
  if (script !== "flow-bar/build-app.sh") writeFileSync(join(root, "flow-bar/build-app.sh"), `#!/bin/bash
    echo build >> "$TEST_ROOT/calls"
    case "$TEST_FAULT" in build) exit 42;; signal) /bin/kill -TERM "$PPID"; exit 42;; signal-self) echo "signal-verify $TEST_GATE_CHILD_PID" >> "$TEST_ROOT/calls"; /bin/kill -TERM "$TEST_GATE_CHILD_PID"; exit 0;; esac
    if [[ "$TEST_FAULT" != kickstart && "\${TEST_UPDATE:-0}" != 1 ]]; then echo 202 > "$TEST_ROOT/running"; fi
  `, { mode: 0o755 });
  const env = { ...process.env, HOME: join(root, "home"), PATH: bin, TEST_ROOT: root, TEST_APP: app,
    TEST_ORIGINAL_APP: original, TEST_MANAGED: managed ? "1" : "0", TEST_FAULT: fault,
    VOICELAYER_INSTALL_OPERATION: "", VOICEBAR_CODESIGN_IDENTITY: "Developer ID Application: Fixture (PPN23G925Y)", VOICELAYER_TEST_BUN_CANDIDATES: join(bin, "bun"),
    VOICELAYER_VERIFY_CHANGED_FILES_FILE: join(root, "changed"), VOICEBAR_LEGACY_LOG_DIR: join(root, "legacy"),
    PLIST_BUDDY: join(bin, "PlistBuddy"), VOICEBAR_PLIST_BUDDY: join(bin, "PlistBuddy"), VOICELAYER_VERIFY_SKIP_BUILD: fault === "skip-build" ? "1" : "0", VOICELAYER_VERIFY_REPO_ROOT: "", VOICEBAR_TEST_BREW_CASK_REGISTERED: "0" };
  writeFileSync(join(root, "changed"), "flow-bar/example.swift\n");
  if (script === "scripts/voicelayer-update.sh") {
    for (const helper of ["install-voicebar-f5-hidutil.sh", "verify-voicebar-hotkey-health.sh"])
      writeFileSync(join(root, "scripts", helper), '#!/bin/bash\necho postflight >> "$TEST_ROOT/calls"\n[[ ! -s "$TEST_ROOT/running" ]]\n', { mode: 0o755 });
    Object.assign(env, { TEST_UPDATE: "1", BREW_CASK_SYNC_BREW_BIN: join(bin, "brew"),
      BREW_CASK_SYNC_TEST_APP_VERSION: "1.0.0", BREW_CASK_SYNC_TEST_CASK_VERSION: "1.0.0",
      BREW_CASK_SYNC_TEST_OFFERED_VERSION: "1.0.0", BREW_CASK_SYNC_TEST_FORMULA_VERSION: "",
      VOICELAYER_UPDATE_TEST_INSTALL_TYPE: "git-checkout", VOICELAYER_UPDATE_TEST_BREW_CASK_INSTALLED: "0" });
  }
  const run = (args: string[] = [], viaSymlink = false) => {
    const entryRoot = viaSymlink ? `${root}-link` : root;
    if (viaSymlink) symlinkSync(root, entryRoot);
    const child = Bun.spawnSync(["/bin/bash", join(entryRoot, script), ...args], { env: { ...process.env, ...env }, cwd: root,
      stdin: new TextEncoder().encode("y\ny\n"), stdout: "pipe", stderr: "pipe", timeout: 15000 });
    return { exit: child.exitCode, out: child.stdout.toString(), err: child.stderr.toString(),
      running: readFileSync(join(root, "running"), "utf8").trim(), calls: readFileSync(join(root, "calls"), "utf8") };
  };
  return { run, root, app, original };
}

for (const managed of [false, true]) for (const fault of ["", "build", "validate", "kickstart", "signal", "skip-build"])
  test(`real verify restores owner on ${fault || "success"}, launchd=${managed}`, () => {
    const result = fixture("scripts/voicelayer-verify.sh", fault, managed).run();
    expect(result.calls).toContain("gate-quit");

    expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ running: "202" });
    if (fault === "build" || fault === "signal") expect(result.calls).toContain("build");
    if (["build", "validate", "signal"].includes(fault)) expect(result.exit).not.toBe(0);
    else expect(result.exit).toBe(0);
    if (fault === "skip-build") expect(result.calls).not.toContain("build\n");
    if (!fault) expect(result.calls).not.toContain("launchctl kickstart");
    if (fault === "kickstart" && managed) expect(result.calls).toContain("open ");
  }, 20000);

for (const managed of [false, true]) for (const fault of ["build", "validate", "signal-self"])
  test(`symlink verify restores owner on ${fault}, launchd=${managed}`, () => {
    const result = fixture("scripts/voicelayer-verify.sh", fault, managed).run([], true);
    expect(result.calls).toContain("gate-quit");
    expect(result.exit).toBe(fault === "build" ? 42 : fault === "validate" ? 1 : 143);
    if (fault === "signal-self") {
      const childPid = result.calls.match(/^gate-child (\d+)$/m)?.[1];
      expect(childPid).toBeDefined();
      expect(result.calls).toContain(`signal-verify ${childPid}\n`);
    }
    expect({ running: result.running, err: result.err }).toMatchObject({ running: "202" });
    expect(result.calls).toContain(managed ? "launchctl kickstart" : "open ");
  }, 20000);

for (const [script, args] of [
  ["flow-bar/build-app.sh", []],
  ["scripts/install-voicebar-autostart.sh", []],
  ["scripts/voicelayer-dedupe-voicebar.sh", ["--apply"]],
  ["scripts/voicelayer-update.sh", ["--no-stop"]],
  ["launchd/install.sh", []],
] satisfies [string, string[]][]) test(`symlink gate caller restores after validation failure: ${script}`, () => {
  const result = fixture(script, "validate").run(args, true);
  expect(result.calls).toContain("gate-quit");
  expect({ exit: result.exit, running: result.running, err: result.err }).toMatchObject({ exit: 1, running: "202" });
});

for (const args of [[], ["--preserve-load-state"]]) for (const fault of ["", "plist"])
  test(`real autostart ${args.join(" ") || "default"} restores on ${fault || "success"}`, () => {
    const result = fixture("scripts/install-voicebar-autostart.sh", fault).run(args);
    expect(result.calls).toContain("gate-quit");
  expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ running: "202" });
    expect(result.exit).toBe(fault ? 1 : 0);
  });

for (const noStop of [true, false]) test(`real dedupe apply restores owner, no-stop=${noStop}`, () => {
  const result = fixture("scripts/voicelayer-dedupe-voicebar.sh").run(["--apply", ...(noStop ? ["--no-stop"] : [])]);
  expect(result.calls).toContain("gate-quit");
  expect(result.calls).not.toContain("pkill ");
  expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ running: "202" }); expect(result.exit).toBe(0);
});

test("real resident-target build restores the original QA bundle after compiler failure", () => {
  const f = fixture("flow-bar/build-app.sh", "", false, true), result = f.run();
  expect(result.calls).toContain("gate-quit");
  expect(result.calls).toContain("compiler");
  expect(result.exit).toBe(42); expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ running: "202" });
  expect(result.calls).toContain(`open ${f.original}`);
  expect(result.out).toContain("Leaving the running VoiceBar instance alone");
});

for (const fault of ["", "build", "validate"]) test(`real update --no-stop restores owner on ${fault || "success"}`, () => {
  const result = fixture("scripts/voicelayer-update.sh", fault).run(["--no-stop"]);
  expect(result.calls).toContain("gate-quit");
  expect({ exit: result.exit, err: result.err, running: result.running, out: result.out }).toMatchObject({ running: "202", exit: fault === "build" ? 42 : fault ? 1 : 0 });
  if (fault === "skip-build") expect(result.calls).not.toContain("build\n");
    if (!fault) expect(result.calls).toContain("postflight");
});

for (const fault of ["", "validate"]) test(`real retired-agent cleanup restores owner on ${fault || "success"}`, () => {
  const result = fixture("launchd/install.sh", fault).run();
  expect(result.calls).toContain("gate-quit");
  expect({ running: result.running, exit: result.exit, err: result.err }).toMatchObject({ running: "202", exit: fault ? 1 : 0 });
});

test("dedupe restores the verified canonical bundle when the original QA bundle moves to backup", () => {
  const f = fixture("scripts/voicelayer-dedupe-voicebar.sh", "", false, true), result = f.run(["--apply", "--no-stop"]);
  expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ exit: 0, running: "202" });
  expect(result.calls).toContain(`open ${f.app}`);
  expect(result.calls).not.toContain(`open ${f.original}`);
});

test("recovery does not start a VoiceBar that was dormant before preserve-load-state", () => {
  const f = fixture("scripts/install-voicebar-autostart.sh");
  writeFileSync(join(f.root, "running"), "");
  const result = f.run(["--preserve-load-state"]);
  expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ exit: 0, running: "" });
  expect(result.calls).not.toContain("open ");
  expect(result.calls).not.toContain("launchctl kickstart");
});

test("update --no-stop restores the verified canonical bundle after nested dedupe moves the original QA bundle", () => {
  const f = fixture("scripts/voicelayer-update.sh", "", false, true), result = f.run(["--no-stop"]);
  expect({ exit: result.exit, err: result.err, running: result.running }).toMatchObject({ exit: 0, running: "202" });
  expect(result.calls).toContain(`open ${f.app}`);
  expect(result.calls).not.toContain(`open ${f.original}`);
});

test("real resident-target build success restores the original QA bundle after the gate quit", () => {
  const f = fixture("flow-bar/build-app.sh", "build-success", false, true), result = f.run();
  expect(result.calls).toContain("gate-quit");
  expect(result.calls).toContain("validate");
  expect(result.calls).toContain("compiler");
  expect({ exit: result.exit, err: result.err, out: result.out }).toMatchObject({ exit: 0 });
  expect(result.out).toContain(`[build-app] Done: ${f.app}`);
  expect(result.out).toContain("the original bundle is restored on exit if the gate quit it");
  expect(result.running).toBe("202");
  expect(result.calls.split("\n").filter(line => line.startsWith("open "))).toEqual([`open ${f.original}`]);
  expect(result.calls).not.toContain("launchctl kickstart");
});
