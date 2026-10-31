import { afterEach, test, expect } from "bun:test";
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync, unlinkSync, rmdirSync, existsSync, readdirSync, copyFileSync } from "node:fs";
import { join } from "node:path";
import { withVoiceAdmission } from "../update-gate-admission";
const repo = process.cwd();
// Bounds subprocess startup/teardown; this suite does not assert voice-onset latency.
const INSTALLER_PROCESS_TIMEOUT_MS = 30_000;
const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH, originalProof = process.env.VOICELAYER_TEST_INSTALL_PROOF;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate; process.env.VOICELAYER_TEST_INSTALL_PROOF = originalProof; });
export function fixture(phase: string | null) {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "installer-"));
  const bin = join(root, "bin"), gate = join(root, "gate"), proof = join(root, "proof");
  mkdirSync(bin); mkdirSync(join(root, "home")); mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  if (phase) writeFileSync(proof, JSON.stringify({ phase, ready: phase === "idle" }));
  const log = join(root, "calls"); writeFileSync(log, "");
  writeFileSync(join(root, "bash-env"), "enable -n kill\n");
  for (const name of ["brew", "launchctl", "osascript", "kill", "mv", "swift", "pkill", "open", "codesign", "hidutil", "plutil", "cp", "rm", "ditto"]) {
    writeFileSync(join(bin, name), `#!/bin/bash\nprintf '%s %s\\n' '${name}' "$*" >> "$CALL_LOG"\n`, { mode: 0o755 });
  }
  writeFileSync(join(bin, "pgrep"), "#!/bin/bash\nexit 1\n", { mode: 0o755 });
  // CLI still routes to the actual updater main; external mutations are PATH stubs.
  writeFileSync(join(bin, "bash"), `#!/bin/bash
if [[ "$1" == */scripts/voicelayer-update.sh ]]; then
  source "$1"
  print_plan() { :; }; validate_args() { :; }; ensure_command() { :; }
  detect_install_type() { echo global; }; voicebar_app_update_mode() { echo local; }
  update_package() { bcs_brew_run upgrade --formula fake; }
  update_voicebar_app() { run_cmd osascript quit; run_cmd launchctl bootout fake; run_cmd mv old.app new.app; }
  update_formula() { :; }; run_qwen3_model_step() { :; }; sync_personal_data() { :; }
  repair_and_verify_voicebar_hotkey_path() { :; }; verify_voicebar_stack() { :; }
  main "\u0024{@:2}"
else
  exec /bin/bash "$@"
fi
`, { mode: 0o755 });
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate; process.env.VOICELAYER_TEST_INSTALL_PROOF = proof;
  const env = { ...process.env, HOME: join(root, "home"), BASH_ENV: join(root, "bash-env"), VOICELAYER_INSTALL_OPERATION: "", PATH: `${bin}:${process.env.PATH}`, CALL_LOG: log,
    VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof,
    VOICEBAR_TEST_BREW_CASK_REGISTERED: "0", VOICEBAR_TEST_PROCESS_TABLE: "none", VOICEBAR_TEST_PS_PID_PPID: "none",
    BREW_CASK_SYNC_BREW_BIN: join(bin, "brew"), VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) };
  const start = () => Bun.spawn(["/bin/bash", "src/cli/voicelayer.sh", "update", "--no-stop", "--no-relaunch"],
    { cwd: repo, env, stdout: "pipe", stderr: "pipe" });
  return { root, gate, proof, log, env, start };
}
export async function waitFor(check: () => boolean, timeoutMs = 20_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) { if (check()) return; await Bun.sleep(25); }
  throw Error("fixture did not reach expected phase");
}
test("busy direct CLI waits without mutations; Ctrl-C restores admission", async () => {
  const f = fixture("transcription"), child = f.start();
  try {
    await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
    expect(readFileSync(f.log, "utf8")).toBe("");
    child.kill("SIGINT"); expect(await child.exited).toBe(130);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
    expect(withVoiceAdmission(() => "admitted")).toBe("admitted");
    expect(await new Response(child.stderr).text()).toContain("transcription");
  } finally { if (child.exitCode === null) { child.kill(); await child.exited; } }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("idle direct CLI commits once and nested helpers validate the same lease", async () => {
  const f = fixture("idle"), child = f.start();
  expect(await child.exited).toBe(0);
  const state = JSON.parse(readFileSync(f.gate, "utf8"));
  expect(state.kind).toBe("COMMITTED"); expect(state.lease.generation).toBe(1);
  expect(readFileSync(f.log, "utf8").trim().split("\n")).toEqual(["brew upgrade --formula fake", "osascript quit", "launchctl bootout fake", "mv old.app new.app"]);
  const retry = f.start(); expect(await retry.exited).not.toBe(0);
  expect(readFileSync(f.log, "utf8").trim().split("\n")).toHaveLength(4);
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("UNKNOWN proof refuses without mutation", async () => {
  const f = fixture(null), child = f.start();
  expect(await child.exited).not.toBe(0);
  expect(readFileSync(f.log, "utf8")).toBe("");
  expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("direct build opt-outs cannot bypass UNKNOWN", async () => {
  const f = fixture(null);
  const child = Bun.spawn(["/bin/bash", "src/cli/voicelayer.sh", "build-app", "--no-stop", "--no-relaunch"],
    { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
  expect(readFileSync(f.log, "utf8")).toBe("");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("busy fake daemon later becomes idle and commits the original generation", async () => {
  const f = fixture("Ask answer".toLowerCase()), child = f.start();
  try {
    await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
    expect(readFileSync(f.log, "utf8")).toBe("");
    writeFileSync(f.proof, JSON.stringify({ phase: "idle", ready: true }));
    expect(await child.exited).toBe(0);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).lease.generation).toBe(1);
  } finally { if (child.exitCode === null) { child.kill(); await child.exited; } }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("direct launchd and repair entry points refuse UNKNOWN before any mutation", async () => {
  for (const script of ["launchd/install.sh", "scripts/install-voicebar-autostart.sh",
    "scripts/voicelayer-dedupe-voicebar.sh"]) {
    const f = fixture(null);
    const child = Bun.spawn(["/bin/bash", script, ...(script.includes("dedupe") ? ["--apply"] : [])],
      { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
    expect(readFileSync(f.log, "utf8")).toBe("");
  }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("missing or corrupt authoritative gate is UNKNOWN even with idle participants", async () => {
  for (const missing of [true, false]) {
    const f = fixture("idle");
    if (missing) unlinkSync(f.gate); else writeFileSync(f.gate, "{}");
    const child = f.start(); expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
    expect(readFileSync(f.log, "utf8")).toBe("");
  }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("direct cask helpers refuse without an owning operation", async () => {
  const f = fixture("idle");
  for (const call of ["bcs_brew_run upgrade --formula fake", "bcs_sync_cask fake fake.app backup", "bcs_reregister_cask fake backup", "bcs_tap_update fake"]) {
    const child = Bun.spawn(["/bin/bash", "-c", 'source scripts/lib/brew-cask-sync.sh; ' + call],
      { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
  }
  expect(readFileSync(f.log, "utf8")).toBe("");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("direct setup refuses UNKNOWN before starting its command plan", async () => {
  const f = fixture(null);
  const child = Bun.spawn([process.execPath, "src/cli/setup.ts", repo], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
  expect(readFileSync(f.log, "utf8")).toBe("");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("admitted work drains through G2 even when the fake participant reports idle", async () => {
  const f = fixture("idle"); let finish!: () => void;
  const work = withVoiceAdmission(() => new Promise<void>(resolve => { finish = resolve; }));
  const child = f.start();
  try {
    await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
    expect(readFileSync(f.log, "utf8")).toBe("");
    finish(); await work;
    expect(await child.exited).toBe(0);
  } finally { finish(); await work; if (child.exitCode === null) { child.kill(); await child.exited; } }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("release artifacts and promotion do not take a resident gate", async () => {
  for (const promotion of [false, true]) {
    const f = fixture(null);
    const args = promotion ? ["scripts/promote-voicebar-release.sh", "--version", "0.0.0", "--app", "fake.app", "--zip", "fake.zip",
      "--tap-root", f.root, "--formula-sha256", "a".repeat(64), "--t3-proof", "fake.json"] :
      ["scripts/release-voicebar.sh", "--skip-tap-check", "--output-dir", join(f.root, "out.noindex")];
    const child = Bun.spawn(["/bin/bash", ...args], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).not.toContain("[update-gate]");
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R1 Cancel retries a transient lock and restores admission", async () => {
  const f = fixture("transcription"), child = f.start(); let locked = false;
  try {
    await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
    await waitFor(() => { try { mkdirSync(f.gate + ".lock"); return locked = true; } catch { return false; } });
    child.kill("SIGINT"); await Bun.sleep(400);
    rmdirSync(f.gate + ".lock"); locked = false;
    expect(await child.exited).toBe(130);
    expect(withVoiceAdmission(() => "admitted")).toBe("admitted");
    expect(readFileSync(f.log, "utf8")).toBe("");
  } finally { if (locked) rmdirSync(f.gate + ".lock"); if (child.exitCode === null) { child.kill(); await child.exited; } }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R1 exhausted Cancel leaves a visible recovery receipt and retains the lease", async () => {
  const f = fixture("transcription"), child = f.start(); let locked = false;
  try {
    await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
    await waitFor(() => { try { mkdirSync(f.gate + ".lock"); return locked = true; } catch { return false; } });
    child.kill("SIGINT"); expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("RECOVERY_REQUIRED");
    const receipt = readdirSync(f.root).find(name => name.includes(".recovery-"));
    expect(receipt).toBeDefined();
    expect(JSON.parse(readFileSync(join(f.root, receipt!), "utf8")).lease).toEqual(JSON.parse(readFileSync(f.gate, "utf8")).lease);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("DRAINING");
  } finally { if (locked) rmdirSync(f.gate + ".lock"); if (child.exitCode === null) { child.kill(); await child.exited; } }
});
test.each(["scripts/install-voicebar-autostart.sh", "scripts/install-voicebar-f5-hidutil.sh", "launchd/install.sh",
  "flow-bar/build-app.sh", "scripts/voicelayer-update.sh", "scripts/voicelayer-dedupe-voicebar.sh",
  "scripts/release-voicebar.sh", "scripts/promote-voicebar-release.sh", "scripts/auto-f5-verify.sh"])("R2 help/invalid arguments never acquire a lease: %s", async script => {
  for (const help of [true, false]) {
    const f = fixture("idle");
    const child = Bun.spawn(["/bin/bash", script, help ? "--help" : "--invalid-g4-option"],
      { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).toBe(help ? 0 : 2);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
    expect(readFileSync(f.log, "utf8")).toBe("");
  }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R2 CLI setup handles help and invalid arguments before the gate", async () => {
  for (const help of [true, false]) {
    const f = fixture(null);
    const child = Bun.spawn(["/bin/bash", "src/cli/voicelayer.sh", "setup", help ? "--help" : "--invalid-g4-option"],
      { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).toBe(help ? 0 : 2);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  }
});
test.each(["SIGINT", "SIGTERM"] as const)("R3 postcommit %s preserves the controller until installer completion", async signal => {
  const f = fixture("idle"), started = join(f.root, "started"), finish = join(f.root, "finish"), done = join(f.root, "done");
  const code = `import{writeFileSync,existsSync}from'node:fs';writeFileSync(${JSON.stringify(started)},String(process.pid));while(!existsSync(${JSON.stringify(finish)}))await Bun.sleep(20);writeFileSync(${JSON.stringify(done)},'done');`;
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", process.execPath, "-e", code],
    { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  try {
    await waitFor(() => existsSync(started)); child.kill(signal);
    await Bun.sleep(150);
    expect(child.exitCode).toBeNull();
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
    writeFileSync(finish, "finish"); await waitFor(() => existsSync(done));
    expect(await child.exited).toBe(0);
    expect(await new Response(child.stderr).text()).toContain("Cancel unavailable after COMMIT");
  } finally { writeFileSync(finish, "finish"); if (child.exitCode === null) await child.exited; }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R4 command simulation leaves the gate OPEN and performs no mutations", async () => {
  const f = fixture("idle");
  const child = Bun.spawn(["/bin/bash", "src/cli/voicelayer.sh", "update", "--no-stop", "--no-relaunch"],
    { env: { ...process.env, ...f.env, VOICELAYER_UPDATE_DRY_RUN_COMMANDS: "1" }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(0);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  expect(readFileSync(f.log, "utf8")).toBe("");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R5 a no-command helper returns refusal to its caller instead of exec", async () => {
  const f = fixture(null);
  const child = Bun.spawn(["/bin/bash", "-c", 'source scripts/lib/update-gate.sh; if vl_update_gate "$1"; then exit 9; else echo caller-survived; fi', "_", repo],
    { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(0);
  expect(await new Response(child.stdout).text()).toContain("caller-survived");
  expect(readFileSync(f.log, "utf8")).toBe("");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R2 controller help and invalid options never acquire a lease", async () => {
  for (const help of [true, false]) {
    const f = fixture("idle");
    const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", help ? "--help" : "--invalid-g4-option"],
      { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).toBe(help ? 0 : 2);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  }
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R6 bundled relay setup needs neither src nor Bun and never acquires a lease", async () => {
  const f = fixture(null), resources = join(f.root, "bundle.noindex/VoiceBar.app/Contents/Resources"), bin = join(f.root, "bin");
  mkdirSync(join(resources, "scripts"), { recursive: true }); mkdirSync(join(resources, "launchd"));
  for (const name of ["install-voicebar-f5-hidutil.sh", "apply-voicebar-f5-hidutil.sh"]) {
    copyFileSync(join(repo, "scripts", name), join(resources, "scripts", name));
  }
  copyFileSync(join(repo, "launchd/com.voicelayer.f5-to-f18-hidutil.plist"), join(resources, "launchd/com.voicelayer.f5-to-f18-hidutil.plist"));
  for (const name of ["mkdir", "cp", "chmod", "launchctl", "plutil", "hidutil"]) {
    writeFileSync(join(bin, name), `#!/bin/bash\nprintf '%s %s\\n' '${name}' "$*" >> "$CALL_LOG"\n`, { mode: 0o755 });
  }
  writeFileSync(join(bin, "dirname"), '#!/bin/bash\nprintf "%s\\n" "${1%/*}"\n', { mode: 0o755 });
  writeFileSync(join(bin, "id"), '#!/bin/bash\necho 501\n', { mode: 0o755 });
  const child = Bun.spawn(["/bin/bash", join(resources, "scripts/install-voicebar-f5-hidutil.sh")],
    { env: { ...process.env, ...f.env, PATH: bin }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(0);
  expect(await new Response(child.stderr).text()).toBe("");
  expect(readFileSync(f.log, "utf8")).toContain("kickstart -k gui/501/com.voicelayer.f5-to-f18-hidutil");
  expect(readFileSync(f.log, "utf8")).not.toContain("com.voicelayer.voicebar");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
}, INSTALLER_PROCESS_TIMEOUT_MS);
test("R2 CLI helper-install help reaches parsing before relay or app mutation", async () => {
  for (const command of ["hotkey", "autostart"]) {
    const f = fixture(null);
    const child = Bun.spawn(["/bin/bash", "src/cli/voicelayer.sh", command, "install", "--help"],
      { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).toBe(0);
    expect(readFileSync(f.log, "utf8")).toBe("");
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  }
}, INSTALLER_PROCESS_TIMEOUT_MS);
