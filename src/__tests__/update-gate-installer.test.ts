import { afterEach, test, expect } from "bun:test";
import { mkdirSync, writeFileSync, readFileSync, mkdtempSync, unlinkSync } from "node:fs";
import { join } from "node:path";
import { withVoiceAdmission } from "../update-gate-admission";
const repo = process.cwd();
const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH, originalProof = process.env.VOICELAYER_TEST_INSTALL_PROOF;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate; process.env.VOICELAYER_TEST_INSTALL_PROOF = originalProof; });
function fixture(phase: string | null) {
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
  // CLI still routes to the actual updater main; external mutations are PATH stubs.
  writeFileSync(join(bin, "bash"), `#!/bin/bash
if [[ "$1" == */scripts/voicelayer-update.sh ]]; then
  source "$1"
  print_plan() { :; }; validate_args() { :; }; ensure_command() { :; }
  detect_install_type() { echo global; }; voicebar_app_update_mode() { echo local; }
  update_package() { bcs_brew_run upgrade --formula fake; }
  update_voicebar_app() { osascript quit; launchctl bootout fake; mv old.app new.app; }
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
async function waitFor(check: () => boolean) {
  for (let i = 0; i < 100; i++) { if (check()) return; await Bun.sleep(20); }
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
});
test("idle direct CLI commits once and nested helpers validate the same lease", async () => {
  const f = fixture("idle"), child = f.start();
  expect(await child.exited).toBe(0);
  const state = JSON.parse(readFileSync(f.gate, "utf8"));
  expect(state.kind).toBe("COMMITTED"); expect(state.lease.generation).toBe(1);
  expect(readFileSync(f.log, "utf8").trim().split("\n")).toEqual(["brew upgrade --formula fake", "osascript quit", "launchctl bootout fake", "mv old.app new.app"]);
  const retry = f.start(); expect(await retry.exited).not.toBe(0);
  expect(readFileSync(f.log, "utf8").trim().split("\n")).toHaveLength(4);
});
test("UNKNOWN proof refuses without mutation", async () => {
  const f = fixture(null), child = f.start();
  expect(await child.exited).not.toBe(0);
  expect(readFileSync(f.log, "utf8")).toBe("");
  expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
});
test("direct build opt-outs cannot bypass UNKNOWN", async () => {
  const f = fixture(null);
  const child = Bun.spawn(["/bin/bash", "src/cli/voicelayer.sh", "build-app", "--no-stop", "--no-relaunch"],
    { env: f.env, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
  expect(readFileSync(f.log, "utf8")).toBe("");
});
test("busy fake daemon later becomes idle and commits the original generation", async () => {
  const f = fixture("Ask answer".toLowerCase()), child = f.start();
  try {
    await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
    expect(readFileSync(f.log, "utf8")).toBe("");
    writeFileSync(f.proof, JSON.stringify({ phase: "idle", ready: true }));
    expect(await child.exited).toBe(0);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).lease.generation).toBe(1);
  } finally { if (child.exitCode === null) { child.kill(); await child.exited; } }
});
test("direct launchd and repair entry points refuse UNKNOWN before any mutation", async () => {
  for (const script of ["launchd/install.sh", "scripts/install-voicebar-autostart.sh", "scripts/install-voicebar-f5-hidutil.sh",
    "scripts/voicelayer-dedupe-voicebar.sh"]) {
    const f = fixture(null);
    const child = Bun.spawn(["/bin/bash", script, ...(script.includes("dedupe") ? ["--apply"] : [])],
      { env: f.env, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
    expect(readFileSync(f.log, "utf8")).toBe("");
  }
});
test("missing or corrupt authoritative gate is UNKNOWN even with idle participants", async () => {
  for (const missing of [true, false]) {
    const f = fixture("idle");
    if (missing) unlinkSync(f.gate); else writeFileSync(f.gate, "{}");
    const child = f.start(); expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
    expect(readFileSync(f.log, "utf8")).toBe("");
  }
});
test("direct cask helpers refuse without an owning operation", async () => {
  const f = fixture("idle");
  for (const call of ["bcs_brew_run upgrade --formula fake", "bcs_sync_cask fake fake.app backup", "bcs_reregister_cask fake backup", "bcs_tap_update fake"]) {
    const child = Bun.spawn(["/bin/bash", "-c", 'source scripts/lib/brew-cask-sync.sh; ' + call],
      { env: f.env, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
  }
  expect(readFileSync(f.log, "utf8")).toBe("");
});
test("direct setup refuses UNKNOWN before starting its command plan", async () => {
  const f = fixture(null);
  const child = Bun.spawn([process.execPath, "src/cli/setup.ts", repo], { env: f.env, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
  expect(readFileSync(f.log, "utf8")).toBe("");
});
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
});
test("release cleanup and promotion refuse UNKNOWN before artifact or recipe writes", async () => {
  for (const promotion of [false, true]) {
    const f = fixture(null);
    const args = promotion ? ["scripts/promote-voicebar-release.sh", "--version", "0.0.0", "--app", "fake.app", "--zip", "fake.zip",
      "--tap-root", f.root, "--formula-sha256", "a".repeat(64), "--t3-proof", "fake.json"] :
      ["scripts/release-voicebar.sh", "--skip-tap-check", "--output-dir", join(f.root, "out.noindex")];
    const child = Bun.spawn(["/bin/bash", ...args], { env: f.env, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).not.toBe(0);
    expect(await new Response(child.stderr).text()).toContain("UNKNOWN");
    expect(readFileSync(f.log, "utf8")).toBe("");
  }
});
