import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { installerProcessIdentity } from "../update-gate-installer-participant";
import { bundleFixtureRoot } from "./setup/bundle-fixtures";
const saved = { ...process.env };
const outsideFixtures: string[] = [];
afterEach(() => {
  for (const path of outsideFixtures.splice(0)) rmSync(path, { recursive: true, force: true });
  for (const key of ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF"])
    if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
});
const caskTest = (name: string, body: () => void | Promise<void>) => test(name, body, 30000);
const lease = { generation: 1, operationId: "11111111-1111-4111-8111-111111111111",
  ownerId: "22222222-2222-4222-8222-222222222222", targetSha: "a".repeat(40) };

// Real shell/TS chain with relocated host paths and a fixture-only PATH. Brew's
// env -i strips the operation and test flags. Only the fixture Bun launcher
// reinstates host simulation/isolation keys, NEVER the stripped operation.
function fixture(fault = "") {
  const root = mkdtempSync(join(bundleFixtureRoot(), "cask-"));
  const bin = join(root, "bin"), home = join(root, "home"), app = join(root, "Applications/VoiceBar.app");
  const agents = join(home, "Library/LaunchAgents"), gate = join(root, "gate");
  for (const dir of [bin, app, agents, join(root, "src/cli"), join(root, "scripts/lib"), join(root, "launchd")]) mkdirSync(dir, { recursive: true });
  for (const tool of ["bash", "cat", "chmod", "cp", "dirname", "basename", "id", "mkdir", "readlink", "rm", "mv", "sleep", "env"])
    symlinkSync(Bun.which(tool)!, join(bin, tool));
  for (const file of ["src/update-gate-installer.ts", "src/update-gate-admission.ts", "src/update-gate-storage.ts", "src/paths.ts"])
    symlinkSync(join(process.cwd(), file), join(root, file));
  for (const file of ["src/cli/voicelayer.sh", "src/cli/setup.ts", "scripts/lib/update-gate.sh",
    "scripts/install-voicebar-autostart.sh", "scripts/install-voicebar-f5-hidutil.sh", "scripts/apply-voicebar-f5-hidutil.sh",
    "launchd/com.voicelayer.voicebar.plist", "launchd/com.voicelayer.f5-to-f18-hidutil.plist"])
    writeFileSync(join(root, file), readFileSync(file, "utf8").replaceAll("/Applications", join(root, "Applications")), { mode: 0o755 });
  const proof = join(root, "proof"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate; process.env.VOICELAYER_TEST_INSTALL_PROOF = proof;
  const simulation = { ROOT: root, APP: app, FAULT: fault, VOICEBAR_LEGACY_LOG_DIR: join(root, "legacy"),
    VOICELAYER_TEST_BUN_CANDIDATES: join(bin, "bun"), ...Object.fromEntries(Object.entries(process.env)
      .filter(([key]) => (key.startsWith("VOICELAYER_") && !["VOICELAYER_INSTALL_OPERATION", "VOICELAYER_SUPERVISED_BOOTSTRAP", "VOICELAYER_UPDATE_TARGET_SHA"].includes(key)) || key.startsWith("QA_VOICE_"))) };
  const quote = (s: string) => "'" + s.replaceAll("'", "'\\''") + "'";
  const preamble = Object.entries(simulation).map(([k, v]) => `export ${k}=${quote(v!)}`).join("\n");
  const stub = (name: string, body: string) => writeFileSync(join(bin, name), `#!/bin/bash\n${preamble}\n${body}\n`, { mode: 0o755 });
  stub("bun", `[[ "$*" != *setup.ts* ]] || echo $$ > "$ROOT/setup-pid"\nexec ${quote(process.execPath)} "$@"`);
  stub("which", "exit 1");
  stub("pgrep", '[[ "$FAULT" != inventory ]] || exit 2; [[ -s "$ROOT/running" ]] || exit 1; echo 101');
  stub("ps", 'if [[ "$*" == *comm=* ]]; then cat "$ROOT/running"; else exec /bin/ps "$@"; fi');
  stub("plutil", '[[ "$FAULT" != persistent ]] || exit 7; if [[ ( "$FAULT" == plist || ( "$FAULT" == relay && "$*" == *f5-to-f18* ) ) && ! -f "$ROOT/failed-once" ]]; then : > "$ROOT/failed-once"; exit 7; fi');
  stub("xattr", "exit 1"); stub("hidutil", "exit 0");
  stub("open", 'echo "open $*" >> "$ROOT/calls"; [[ "$FAULT" != nostart ]] || exit 1; echo "$1/Contents/MacOS/VoiceBar" > "$ROOT/running"; cp "$APP/version" "$ROOT/running-version"');
  stub("launchctl", `echo "$*" >> "$ROOT/calls"
if [[ -f "$ROOT/lease-active" && "$1" != remove && "$1" != print && "$1" != list ]]; then echo EARLY_START >&2; exit 98; fi
case "$1" in
  remove|bootout) rm -f "$ROOT/loaded-\${2##*/}";;
  print|list) [[ -f "$ROOT/loaded-\${2##*/}" ]] || exit 1; [[ ! -f "$ROOT/started" ]] || echo 'state = running';;
  bootstrap) label="\${3##*/}"; label="\${label%.plist}"; : > "$ROOT/loaded-$label"
    if [[ "$label" == com.voicelayer.voicebar && "$FAULT" != waiting && "$FAULT" != nostart && "$FAULT" != loaded-stopped ]]; then
      echo "$APP/Contents/MacOS/VoiceBar" > "$ROOT/running"; cp "$APP/version" "$ROOT/running-version"; : > "$ROOT/started"; fi;;
  kickstart) if [[ "$*" == *com.voicelayer.voicebar* && "$FAULT" != waiting && "$FAULT" != nostart ]]; then
    echo "$APP/Contents/MacOS/VoiceBar" > "$ROOT/running"; cp "$APP/version" "$ROOT/running-version"; : > "$ROOT/started"; fi;;
  enable) :;;
  *) exit 99;;
esac`);
  stub("brew", `labels=(com.voicelayer.voicebar com.voicelayer.f5-to-f18-hidutil com.voicelayer.mcp-daemon)
for label in "\${labels[@]}"; do launchctl remove "$label"; done
for label in "\${labels[@]}"; do echo "delete $label" >> "$ROOT/calls"; rm -f "$HOME/Library/LaunchAgents/$label.plist"; done
echo quit >> "$ROOT/calls"; : > "$ROOT/running"
mkdir -p "$ROOT/old.noindex" "$ROOT/deleted.noindex"
mv "$APP" "$ROOT/old.noindex/VoiceBar.app"; mkdir -p "$APP"; echo 2.2.60 > "$APP/version"
filtered=("HOME=$HOME" "PATH=$PATH" "SHELL=/bin/bash" "USER=fixture")
for key in \${!HOMEBREW_@}; do [[ -z "\${!key}" ]] || filtered+=("$key=\${!key}"); done
echo postflight >> "$ROOT/calls"
env -i "\${filtered[@]}" /bin/bash -c '
  [[ -z "\${VOICELAYER_INSTALL_OPERATION:-}" && -z "\${VOICELAYER_TEST_ISOLATED:-}" ]] || exit 97
  exec bash "$1/src/cli/voicelayer.sh" setup \${HOMEBREW_TEST_POSTFLIGHT_FLAG:-}
' _ "$ROOT"
status=$?
if [[ "$status" != 0 ]]; then
  echo revert >> "$ROOT/calls"; mv "$APP" "$ROOT/deleted.noindex/VoiceBar.app"; mv "$ROOT/old.noindex/VoiceBar.app" "$APP"; rm -rf "$ROOT/deleted.noindex/VoiceBar.app"
fi
exit "$status"`);
  for (const label of ["com.voicelayer.voicebar", "com.voicelayer.f5-to-f18-hidutil", "com.voicelayer.mcp-daemon"]) {
    writeFileSync(join(agents, label + ".plist"), "legacy"); writeFileSync(join(root, "loaded-" + label), "");
  }
  writeFileSync(join(app, "version"), "2.2.58"); writeFileSync(join(root, "running"), app + "/Contents/MacOS/VoiceBar\n");
  writeFileSync(join(root, "calls"), "");
  if (fault === "malformed") writeFileSync(gate, "broken gate");
  if (fault === "open" || fault === "locked-open") {
    writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
    mkdirSync(gate + ".admissions");
  }
  if (fault === "locked" || fault === "locked-open") mkdirSync(gate + ".lock");
  if (fault === "supervisor") mkdirSync(gate + ".bootstrap-lock");
  if (fault === "bootstrap") writeFileSync(gate + ".bootstrap", "retained bootstrap");
  if (fault === "diagnostic") writeFileSync(gate + ".voice-diag.json", "retained diagnostic");
  if (fault === "ledger") mkdirSync(gate + ".admissions");
  if (fault === "controller") writeFileSync(gate + ".controller", "retained controller");
  const env = { ...process.env, ...simulation, HOME: home, PATH: bin, VOICELAYER_INSTALL_OPERATION: "",
    VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_UPDATE_TARGET_SHA: "", HOMEBREW_VOICELAYER_INSTALL_OPERATION: "" };
  const command = [join(bin, "brew"), "upgrade", "--cask", "voicebar"];
  const run = (extra: Record<string, string> = {}) => Bun.spawnSync(command, { env: { ...process.env, ...env, ...extra }, stdout: "pipe", stderr: "pipe", timeout: 25000 });
  const setup = (extra: Record<string, string> = {}) => Bun.spawnSync([join(bin, "bun"), join(root, "src/cli/setup.ts"), root], { env: { ...process.env, ...env, ...extra }, stdout: "pipe", stderr: "pipe", timeout: 25000 });
  return { root, gate, app, agents, bin, home, env, command, run, setup };
}
function restored(f: ReturnType<typeof fixture>, agentsLoaded = true) {
  for (const label of ["com.voicelayer.voicebar", "com.voicelayer.f5-to-f18-hidutil"]) {
    expect(existsSync(join(f.agents, label + ".plist"))).toBe(true);
    if (agentsLoaded) expect(existsSync(join(f.root, "loaded-" + label))).toBe(true);
  }
  expect(readFileSync(join(f.root, "running"), "utf8").trim()).toBe(f.app + "/Contents/MacOS/VoiceBar");
  expect(readFileSync(join(f.root, "running-version"), "utf8")).toBe(readFileSync(join(f.app, "version"), "utf8"));
  expect(readFileSync(join(f.app, "version"), "utf8").trim()).toBe("2.2.60");
  expect(existsSync(join(f.agents, "com.voicelayer.mcp-daemon.plist"))).toBe(false);
}
for (const fault of ["", "open"]) for (const flag of ["", "--cask-postflight"]) caskTest(`cask ${fault || "absent"} gate upgrades with ${flag || "legacy no-flag"} after env -i`, () => {
  const f = fixture(fault), r = f.run({ HOMEBREW_TEST_POSTFLIGHT_FLAG: flag });
  expect({ exit: r.exitCode, err: r.stderr.toString() }).toMatchObject({ exit: 0 });
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN"); restored(f);
  const calls = readFileSync(join(f.root, "calls"), "utf8");
  expect(calls.lastIndexOf("remove ")).toBeLessThan(calls.indexOf("delete ")); expect(calls.lastIndexOf("delete ")).toBeLessThan(calls.indexOf("quit"));
});
for (const fault of ["malformed", "locked", "locked-open", "supervisor", "bootstrap", "diagnostic", "ledger", "controller", "closed", "plist", "relay", "persistent"])
  caskTest(`postflight ${fault} keeps the final bundle and preserves gate evidence`, () => {
    const f = fixture(fault); if (fault === "closed") writeFileSync(f.gate, JSON.stringify({ version: 1, kind: "DRAINING", lease }));
    const before = existsSync(f.gate) ? readFileSync(f.gate, "utf8") : null, r = f.run();
    expect({ exit: r.exitCode, err: r.stderr.toString() }).toMatchObject({ exit: 0 }); expect(r.stderr.toString()).toContain("RECOVERY_REQUIRED"); restored(f, fault !== "persistent");
    if (before !== null) expect(readFileSync(f.gate, "utf8")).toBe(before);
    else if (["locked", "supervisor", "bootstrap", "diagnostic", "ledger", "controller"].includes(fault)) expect(existsSync(f.gate)).toBe(false);
    if (fault === "supervisor") expect(r.stderr.toString()).toContain("another bootstrap or recovery owns this host");
  });
for (const kind of ["DRAINING", "PREPARED", "COMMITTED"]) caskTest(`${kind} live controller gets plists only; controller restores after brew`, () => {
  const f = fixture(), ack = { lease, activeOperations: 0, openArchives: 0 };
  writeFileSync(f.gate, JSON.stringify({ version: 1, kind, lease, ...(kind === "DRAINING" ? {} : { native: ack, daemon: ack }) }));
  const operation = { lease, pid: process.pid, identity: installerProcessIdentity(process.pid) };
  writeFileSync(f.gate + ".controller", JSON.stringify({ version: 1, lease: { generation: 1, operationId: lease.operationId }, pid: operation.pid, identity: operation.identity }));
  writeFileSync(join(f.root, "lease-active"), "");
  const r = f.run(kind === "COMMITTED" ? { HOMEBREW_VOICELAYER_INSTALL_OPERATION: JSON.stringify(operation) } : {});
  expect({ exit: r.exitCode, err: r.stderr.toString() }).toMatchObject({ exit: 0 }); expect(readFileSync(join(f.root, "running"), "utf8")).toBe("");
  for (const label of ["com.voicelayer.voicebar", "com.voicelayer.f5-to-f18-hidutil"]) {
    expect(readFileSync(join(f.agents, label + ".plist"), "utf8")).toContain("<plist"); expect(existsSync(join(f.root, "loaded-" + label))).toBe(false);
  }
  expect(readFileSync(join(f.root, "calls"), "utf8")).not.toMatch(/enable|bootstrap|kickstart|open /);
  const restore = Bun.spawnSync(["/bin/bash", "-c", 'source "$1/scripts/lib/update-gate.sh"; rm "$1/lease-active"', join(f.root, "owner.sh"), f.root], {
    env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: JSON.stringify(operation), VOICELAYER_GATE_RESTORE_CALLER: join(f.root, "owner.sh"), VOICELAYER_GATE_RESTORE_APP: f.app, VOICELAYER_GATE_RESTORE_LAUNCHD: "0" }, stdout: "pipe", stderr: "pipe",
  });
  expect(restore.exitCode).toBe(0); expect(readFileSync(join(f.root, "running-version"), "utf8").trim()).toBe("2.2.60");
});
for (const gate of ["open", ""]) caskTest(`unvalidated HOMEBREW operation on ${gate || "absent"} gate preserves evidence`, () => {
  const f = fixture(gate), before = existsSync(f.gate) ? readFileSync(f.gate, "utf8") : null;
  const r = f.run({ HOMEBREW_VOICELAYER_INSTALL_OPERATION: "forged" });
  expect(r.exitCode).toBe(0); expect(r.stderr.toString()).toContain("RECOVERY_REQUIRED"); restored(f);
  if (before === null) expect(existsSync(f.gate)).toBe(false);
  else expect(readFileSync(f.gate, "utf8")).toBe(before);
});
caskTest("nested validation failure never restores availability", () => {
  const f = fixture("open"), r = f.setup({ VOICELAYER_INSTALL_OPERATION: "invalid" });
  expect(r.exitCode).not.toBe(0); expect(readFileSync(join(f.root, "calls"), "utf8")).toBe("");
});
caskTest("public restore-availability without setup marker refuses before mutations", () => {
  const f = fixture(), r = Bun.spawnSync(["/bin/bash", join(f.root, "scripts/install-voicebar-autostart.sh"), "--restore-availability"], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(r.exitCode).not.toBe(0); expect(readFileSync(join(f.root, "calls"), "utf8")).toBe("");
});
for (const entry of ["src/cli/setup.ts", "scripts/install-voicebar-autostart.sh", "scripts/install-voicebar-f5-hidutil.sh"])
  for (const escape of ["HOME", "launchctl"]) caskTest(`${entry} isolation refuses outside-run ${escape} before actions`, () => {
    const f = fixture(), env = { ...process.env, ...f.env };
    // Both escape candidates are harmless. Even the failing-first run must not
    // write real HOME or execute a real launchctl before the guards exist.
    if (escape === "HOME") env.HOME = "/dev/null";
    else {
      const outside = mkdtempSync(join(process.cwd(), ".test-tmp/cask-trip-"));
      outsideFixtures.push(outside);
      writeFileSync(join(outside, "launchctl"), "#!/bin/bash\necho OUTSIDE_FIXTURE_COMMAND >&2\nexit 99\n", { mode: 0o755 });
      env.PATH = `${outside}:${f.bin}`;
    }
    const command = entry.endsWith(".ts") ? [process.execPath, join(f.root, entry), f.root] : ["/bin/bash", join(f.root, entry)];
    const r = Bun.spawnSync(command, { env: { ...process.env, ...env }, stdout: "pipe", stderr: "pipe" });
    expect(r.exitCode).not.toBe(0); expect(readFileSync(join(f.root, "calls"), "utf8")).toBe("");
    if (escape === "launchctl") expect(r.stderr.toString()).toContain("escaped isolated root");
  });
caskTest("SIGINT during start wait releases only its bootstrap mutex", async () => {
  const f = fixture("waiting"), child = Bun.spawn(f.command, { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  try {
    const deadline = Date.now() + 15000;
    while (!readFileSync(join(f.root, "calls"), "utf8").includes("kickstart") && Date.now() < deadline) await Bun.sleep(25);
    expect(existsSync(f.gate + ".bootstrap-lock")).toBe(true);
    process.kill(Number(readFileSync(join(f.root, "setup-pid"), "utf8")), "SIGINT");
    await child.exited; expect(existsSync(f.gate + ".bootstrap-lock")).toBe(false);
  } finally { if (child.exitCode === null) { child.kill(); await child.exited; } }
});
caskTest("real updater exports validated operation through filtered brew; EXIT trap restores last", () => {
  const f = fixture("open"), updater = join(process.cwd(), "scripts/voicelayer-update.sh");
  unlinkSync(join(f.bin, "bash"));
  writeFileSync(join(f.bin, "bash"), `#!/bin/bash
if [[ "$1" == ${JSON.stringify(updater)} ]]; then shift; exec /bin/bash "$ROOT/updater-runner.sh" "$@"; fi
exec /bin/bash "$@"
`, { mode: 0o755 });
  writeFileSync(join(f.root, "updater-runner.sh"), `#!/bin/bash
source ${JSON.stringify(updater)}
print_plan() { :; }; validate_args() { :; }; ensure_command() { :; }
detect_install_type() { echo global; }; voicebar_app_update_mode() { echo local; }
voicebar_cask_repair_needed() { return 0; }
update_package() {
  : > "$ROOT/lease-active"
  "$ROOT/bin/brew" upgrade --cask voicebar
  [[ ! -s "$ROOT/running" ]] || { echo EARLY_START >&2; return 98; }
}
update_voicebar_app() { :; }; update_formula() { :; }; run_qwen3_model_step() { :; }; sync_personal_data() { :; }
repair_and_verify_voicebar_hotkey_path() { :; }
verify_voicebar_stack() { echo mutations-done >> "$ROOT/calls"; rm "$ROOT/lease-active"; }
main "$@"
`, { mode: 0o755 });
  const r = Bun.spawnSync(["/bin/bash", join(f.root, "updater-runner.sh")], {
    env: { ...process.env, ...f.env, VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) }, stdout: "pipe", stderr: "pipe", timeout: 25000,
  });
  expect({ exit: r.exitCode, err: r.stderr.toString() }).toMatchObject({ exit: 0 });
  const calls = readFileSync(join(f.root, "calls"), "utf8");
  expect(calls.indexOf("mutations-done")).toBeGreaterThan(calls.indexOf("postflight"));
  expect(calls).not.toContain("EARLY_START");
  expect(readFileSync(join(f.root, "running-version"), "utf8").trim()).toBe("2.2.60");
});
caskTest("loaded stopped launchd job is kickstarted, without an open race", () => {
  const f = fixture("loaded-stopped");
  writeFileSync(join(f.root, "running"), "");
  const r = f.setup();
  expect({ exit: r.exitCode, err: r.stderr.toString() }).toMatchObject({ exit: 0 });
  expect(readFileSync(join(f.root, "calls"), "utf8")).toContain("kickstart");
  expect(readFileSync(join(f.root, "calls"), "utf8")).not.toContain("open ");
});
caskTest("failed startup retains plists and real brew revert swaps the bundle", () => {
  const f = fixture("nostart"), r = f.run();
  expect(r.exitCode).not.toBe(0);
  expect(r.stderr.toString()).toContain("RECOVERY_REQUIRED");
  expect(readFileSync(join(f.root, "calls"), "utf8")).toContain("revert");
  expect(readFileSync(join(f.app, "version"), "utf8").trim()).toBe("2.2.58");
  expect(readFileSync(join(f.root, "running"), "utf8")).toBe("");
  expect(existsSync(join(f.agents, "com.voicelayer.voicebar.plist"))).toBe(true);
});
caskTest("internal marker cannot restore while a live controller owns the host", () => {
  const f = fixture("open");
  writeFileSync(f.gate + ".controller", JSON.stringify({ version: 1, lease: { generation: 1, operationId: lease.operationId },
    pid: process.pid, identity: installerProcessIdentity(process.pid) }));
  const r = Bun.spawnSync(["/bin/bash", join(f.root, "scripts/install-voicebar-autostart.sh"), "--restore-availability"], {
    env: { ...process.env, ...f.env, VOICELAYER_SETUP_AVAILABILITY: "1" }, stdout: "pipe", stderr: "pipe",
  });
  expect(r.exitCode).not.toBe(0);
  expect(readFileSync(join(f.root, "calls"), "utf8")).toBe("");
});
