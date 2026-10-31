import { afterEach, test, expect } from "bun:test";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmdirSync, cpSync } from "node:fs";
import { join } from "node:path";
import { fixture, waitFor } from "./update-gate-installer.test";
import * as installer from "../update-gate-installer";
import { installerProcessIdentity } from "../update-gate-installer-participant";
import { updateVoiceGate, acknowledgeVoiceDrain } from "../update-gate-admission";
const repo = process.cwd();
const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH, originalProof = process.env.VOICELAYER_TEST_INSTALL_PROOF;
// fixture() points the process gate at its own gate; restore it here too (see the last test in this file).
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate; process.env.VOICELAYER_TEST_INSTALL_PROOF = originalProof; });
const timeout = 30_000;
test("proof exceptions are false without orphan locks or diagnostic poisoning", () => {
  const f = fixture("idle");
  const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  expect(acknowledgeVoiceDrain(lease, () => installer.safeParticipantProof(() => { throw Error("probe failed"); }))).toBeNull();
  expect(existsSync(f.gate + ".lock")).toBe(false);
  expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
  expect(updateVoiceGate({ kind: "CANCEL", lease }).kind).toBe("APPLIED");
});
test.each(["SIGHUP", "SIGQUIT"] as const)("precommit %s restores admission", async signal => {
  const f = fixture("transcription"), child = f.start();
  await waitFor(() => JSON.parse(readFileSync(f.gate, "utf8")).kind === "DRAINING");
  child.kill(signal);
  expect(await child.exited).toBe(130);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  expect(readFileSync(f.log, "utf8")).toBe("");
}, timeout);
test("nested helper resolves refreshed package after original keg vanishes", async () => {
  const f = fixture("idle"), old = join(f.root, "old-keg"), fresh = join(f.root, "new-keg");
  mkdirSync(join(old, "scripts/lib"), { recursive: true }); mkdirSync(join(fresh, "scripts/lib"), { recursive: true });
  cpSync("scripts/lib/brew-cask-sync.sh", join(old, "scripts/lib/brew-cask-sync.sh"));
  writeFileSync(join(fresh, "scripts/lib/update-gate.sh"), 'vl_update_gate() { echo "fresh:$1"; }\n');
  const script = 'source "$1/scripts/lib/brew-cask-sync.sh"; /bin/rm -rf "$1"; PACKAGE_ROOT="$2"; bcs_update_gate';
  const child = Bun.spawn(["/bin/bash", "-c", script, "_", old, fresh], { env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: "fixture" }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(0);
  expect(await new Response(child.stdout).text()).toContain("fresh:" + fresh);
}, timeout);
test("nonresident QA build reaches stub compiler without taking a lease", async () => {
  const f = fixture(null);
  writeFileSync(join(f.root, "bin/swift"), '#!/bin/bash\necho compiler-stub >&2\nexit 42\n', { mode: 0o755 });
  const child = Bun.spawn(["/bin/bash", "flow-bar/build-app.sh", "--install-path", join(f.root, "qa.noindex/VoiceBarQA.app"), "--no-stop", "--no-relaunch"], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(42);
  expect(await new Response(child.stderr).text()).toContain("compiler-stub");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
}, timeout);
test("terminal group interrupt cannot reach committed installer; nested owner remains live", async () => {
  const f = fixture("idle"), started = join(f.root, "started"), finish = join(f.root, "finish"), done = join(f.root, "done");
  const code = `import{writeFileSync,existsSync}from'node:fs';writeFileSync(${JSON.stringify(started)},'ready');while(!existsSync(${JSON.stringify(finish)}))await Bun.sleep(20);await (await import(${JSON.stringify(join(repo, "src/update-gate-installer.ts"))})).validateInstallerOperation();writeFileSync(${JSON.stringify(done)},'done');`;
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", process.execPath, "-e", code], { env: { ...process.env, ...f.env }, detached: true, stdout: "pipe", stderr: "pipe" });
  try {
    await waitFor(() => existsSync(started)); process.kill(-child.pid, "SIGINT"); await Bun.sleep(150);
    expect(child.exitCode).toBeNull(); writeFileSync(finish, "finish");
    expect(await child.exited).toBe(0); expect(existsSync(done)).toBe(true);
    expect(await new Response(child.stderr).text()).toContain("Ctrl-C will not stop the installer");
  } finally { writeFileSync(finish, "finish"); if (child.exitCode === null) await child.exited; }
}, timeout);
test("nested validation waits through transient lock presence", async () => {
  const f = fixture("idle"), child = f.start(); expect(await child.exited).toBe(0);
  const lease = JSON.parse(readFileSync(f.gate, "utf8")).lease;
  mkdirSync(f.gate + ".lock");
  const nested = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "--validate"], { env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: JSON.stringify({ lease, pid: process.pid, identity: installerProcessIdentity(process.pid) }) }, stdout: "pipe", stderr: "pipe" });
  try { await Bun.sleep(300); rmdirSync(f.gate + ".lock"); expect(await nested.exited).toBe(0); }
  finally { if (existsSync(f.gate + ".lock")) rmdirSync(f.gate + ".lock"); }
}, timeout);
test("simulation assertion without a simulated run_cmd cannot skip the guard", async () => {
  const f = fixture(null);
  const child = Bun.spawn(["/bin/bash", "-c", 'source scripts/lib/brew-cask-sync.sh; bcs_caller_simulates_commands() { return 0; }; bcs_brew_run upgrade fake'], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0); expect(readFileSync(f.log, "utf8")).toBe("");
});
test("missing Bun runtime refuses clearly without mutation", async () => {
  const f = fixture(null);
  const child = Bun.spawn(["/bin/bash", "-c", 'source scripts/lib/update-gate.sh; vl_update_gate "$1" true', "_", repo], { env: { ...process.env, ...f.env, PATH: f.root + "/bin", VOICELAYER_TEST_BUN_CANDIDATES: f.root + "/absent" }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(1);
  expect(await new Response(child.stderr).text()).toContain("REFUSED UNKNOWN: bun runtime not found; nothing was changed");
});
test("forged harness token refuses before any lease", async () => {
  const f = fixture("idle");
  const code = `process.env.VOICELAYER_TEST_INSTALL_TOKEN='forged';await (await import('./src/update-gate-installer.ts')).runGatedInstall(['true']);`;
  const child = Bun.spawn([process.execPath, "-e", code], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0); expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
});
test("noncanonical production gate refuses without reading or mutating it", async () => {
  const f = fixture("idle");
  const code = `delete process.env.VOICELAYER_TEST_ISOLATED;await (await import('./src/update-gate-installer.ts')).runGatedInstall(['true']);`;
  const child = Bun.spawn([process.execPath, "-e", code], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(await new Response(child.stderr).text()).toContain("noncanonical gate path");
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
});

test("verify asks before admission and inherited re-exec does not prompt twice", () => {
  const source = readFileSync("scripts/voicelayer-verify.sh", "utf8");
  expect(source.indexOf("Rebuild, stop the running VoiceBar")).toBeLessThan(source.indexOf('vl_update_gate "$REPO_ROOT"'));
  expect(source).toContain('[ -z "${VOICELAYER_INSTALL_OPERATION:-}" ] && [ -n "$running_pids" ]');
});
test("Bun resolver prefers a candidate then falls back to PATH", async () => {
  const f = fixture(null), candidate = join(f.root, "candidate-bun");
  writeFileSync(candidate, "#!/bin/bash\nexit 0\n", { mode: 0o755 });
  for (const available of [true, false]) {
    const pathBun = join(f.root, "bin/bun"); writeFileSync(pathBun, "#!/bin/bash\nexit 0\n", { mode: 0o755 });
    const child = Bun.spawn(["/bin/bash", "-c", 'source scripts/lib/update-gate.sh; vl_gate_bun'], { env: { ...process.env, ...f.env, VOICELAYER_TEST_BUN_CANDIDATES: available ? candidate : candidate + "-missing" }, stdout: "pipe", stderr: "pipe" });
    expect(await child.exited).toBe(0);
    expect((await new Response(child.stdout).text()).trim()).toBe(available ? candidate : pathBun);
  }
  expect(readFileSync("scripts/lib/update-gate.sh", "utf8")).toContain('candidates=(/opt/homebrew/bin/bun "$HOME/.bun/bin/bun")');
});
test("fixture polling tolerates readiness later than two seconds", async () => {
  const started = Date.now();
  await waitFor(() => Date.now() - started >= 2200);
  expect(Date.now() - started).toBeGreaterThanOrEqual(2200);
}, timeout);
test.each(["invalid", "absent"])("setup awaits %s operation validation before any mutation", async kind => {
  const f = fixture(kind === "invalid" ? "idle" : null);
  writeFileSync(join(f.root, "bin/bash"), '#!/bin/bash\necho setup-mutator >> "$CALL_LOG"\n', { mode: 0o755 });
  const operation = kind === "absent" ? "" : JSON.stringify({ lease: { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) }, pid: process.pid });
  const child = Bun.spawn([process.execPath, "src/cli/setup.ts", repo], { env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: operation }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(existsSync(join(f.env.HOME, ".voicelayer"))).toBe(false);
  expect(readFileSync(f.log, "utf8")).toBe("");
}, timeout);
test("shell validator failure stops nested mutations with nonzero status", async () => {
  const f = fixture("idle");
  const child = Bun.spawn(["/bin/bash", "-ec", 'source scripts/lib/update-gate.sh; vl_update_gate "$1"; brew forbidden-mutation', "_", repo], { env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: "invalid" }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).not.toBe(0);
  expect(readFileSync(f.log, "utf8")).toBe("");
}, timeout);

test("copied committed operation with an arbitrary live PID cannot validate", async () => {
  const f = fixture("idle"), record = join(f.root, "operation.json");
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", process.execPath, "-e",
    `await Bun.write(${JSON.stringify(record)}, process.env.VOICELAYER_INSTALL_OPERATION!)`], {
    env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe",
  });
  expect(await child.exited).toBe(0);
  const owner = JSON.parse(readFileSync(record, "utf8")), identity = installerProcessIdentity(process.pid)!;
  expect(owner.identity).toBeString();
  const forgeries = [
    { ...owner, pid: process.pid }, // Copied real record with a different live PID.
    { ...owner, pid: process.pid, identity: undefined },
    { ...owner, pid: process.pid, identity: "Fri Oct 30 09:10:11 2000" + identity.slice(24) },
    { ...owner, pid: process.pid, identity: identity.slice(0, 24) + " /foreign/controller" },
  ];
  for (const forged of forgeries) {
    const nested = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "--validate"], {
      env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: JSON.stringify(forged) }, stdout: "pipe", stderr: "pipe",
    });
    expect(await nested.exited).not.toBe(0);
    expect(await new Response(nested.stderr).text()).toContain("UNKNOWN");
  }
}, timeout);

// Runs last in this file. When update-gate-installer.test.ts was already loaded as its own file, its module-level
// afterEach does not cover these tests, and a leaked fixture gate (possibly left closed) became the gate of every
// later voice suite in the same Bun process: all their admissions were refused.
test("installer fixtures leave the process gate environment as it was", () => {
  expect(process.env.VOICELAYER_UPDATE_GATE_PATH).toBe(originalGate);
  expect(process.env.VOICELAYER_TEST_INSTALL_PROOF).toBe(originalProof);
});
