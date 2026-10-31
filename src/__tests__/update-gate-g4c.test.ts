import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { runGatedInstall } from "../update-gate-installer";
import { createInstallerParticipant, type InstallerParticipantDependencies } from "../update-gate-installer-participant";

const saved = { ...process.env };
afterEach(() => { for (const key of ["VOICELAYER_UPDATE_GATE_PATH", "VOICELAYER_TEST_INSTALL_PROOF", "VOICELAYER_UPDATE_TARGET_SHA"]) {
  if (saved[key] === undefined) delete process.env[key]; else process.env[key] = saved[key];
} });
function fixture() {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "g4c-")), gate = join(root, "g");
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  const proof = join(root, "proof"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  Object.assign(process.env, { VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof, VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) });
  let now = 0;
  const deps: InstallerParticipantDependencies = {
    request: async (_action, lease) => { const ack = { lease, activeOperations: 0, openArchives: 0 };
      return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities: {
        native: { pid: 101, incarnation: "11111111-1111-4111-8111-111111111111" },
        daemon: { pid: 102, incarnation: "22222222-2222-4222-8222-222222222222" } } }; },
    processIdentity: pid => { Bun.sleepSync(3); return pid === 101 ? "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "birth /bun"; },
    processParent: () => 101, participantsExited: () => true, now: () => now,
    sleep: async (ms = 100) => { now += ms; await Bun.sleep(ms); },
  };
  const participant = createInstallerParticipant(deps); participant.quit = async () => {};
  return { root, gate, deps, participant, advance: (ms: number) => { now += ms; } };
}
for (const phase of ["OPEN", "DRAINING", "PREPARED"]) test(`G4c real 1.5 ms contender: 0/20 refusals at ${phase}`, async () => {
  let refused = 0;
  for (let i = 0; i < 20; i++) {
    const f = fixture(), trigger = join(f.root, "trigger"), held = join(f.root, "held");
    const holder = Bun.spawn([process.execPath, "-e", `
      const fs=require('node:fs'), [gate,trigger,held]=${JSON.stringify([f.gate, trigger, held])};
      const deadline=performance.now()+5000;
      while(!fs.existsSync(trigger)&&performance.now()<deadline) Bun.sleepSync(0.1);
      if(!fs.existsSync(trigger)) process.exit(2);
      const end=performance.now()+120;
      while(performance.now()<end){try{fs.mkdirSync(gate+'.lock');fs.writeFileSync(held,'held');Bun.sleepSync(1.5);fs.rmdirSync(gate+'.lock');}catch{}Bun.sleepSync(2.5);}
    `], { env: process.env, stdout: "ignore", stderr: "pipe" });
    // REQUEST runs with the contender already active; later phases trigger
    // precisely inside their proof bracket, after the before-sample.
    let triggered = false;
    const start = () => {
      if (triggered || JSON.parse(readFileSync(f.gate, "utf8")).kind !== phase) return;
      triggered = true; writeFileSync(trigger, "go");
      const end = performance.now() + 2000;
      while (!existsSync(held) && performance.now() < end) Bun.sleepSync(0.1);
      expect(existsSync(held)).toBe(true);
    };
    if (phase === "OPEN") { start(); }
    else {
      let calls = 0;
      const intercept = <T>(read: () => T) => () => {
        calls++; if (calls === (phase === "DRAINING" ? 2 : 3)) start(); return read();
      };
      const sync = f.participant.withProcessProof!, asyncProof = f.participant.withAcquisitionProof;
      f.participant.withProcessProof = read => sync(intercept(read));
      if (asyncProof) f.participant.withAcquisitionProof = read => asyncProof(intercept(read));
    }
    try { await runGatedInstall(["/usr/bin/true"], f.participant); } catch { refused++; }
    if (!triggered) writeFileSync(trigger, "finish");
    expect(await holder.exited).toBe(0);
  }
  console.log(`${phase}: ${refused}/20 refusals`); expect(refused).toBe(0);
}, 60000);

test("G4c precommit contention stays within receipt lifetime without identity resampling", async () => {
  const f = fixture(); let reads = 0, sleeps = 0;
  const parent = f.deps.processParent;
  f.deps.processParent = pid => { reads++; return parent(pid); };
  const request = f.deps.request;
  f.deps.request = async (action, lease) => {
    const result = await request(action, lease); f.advance(600); return result;
  };
  f.deps.sleep = async ms => { expect(ms).toBe(2); sleeps++; f.advance(ms ?? 0); };
  // Hold the first precommit acknowledgement; its receipt is already 600 ms old.
  // An independent timer releases the lock for Cancel.
  const holder = join(f.root, "held");
  const child = Bun.spawn([process.execPath, "-e", `const fs=require('node:fs'),g=${JSON.stringify(f.gate)},h=${JSON.stringify(holder)};
    const end=performance.now()+5000;while(performance.now()<end){if(JSON.parse(fs.readFileSync(g,'utf8')).kind==='DRAINING'){try{fs.mkdirSync(g+'.lock');fs.writeFileSync(h,'held');Bun.sleepSync(100);fs.rmdirSync(g+'.lock');break;}catch{}}Bun.sleepSync(0.1);}`],
    { env: process.env, stdout: "ignore", stderr: "pipe" });
  const refresh = f.participant.refresh;
  f.participant.refresh = async lease => { const result = await refresh(lease); const end = performance.now() + 2000;
    while (!existsSync(holder) && performance.now() < end) Bun.sleepSync(0.1); return result; };
  await expect(runGatedInstall(["/usr/bin/true"], f.participant)).rejects.toThrow("lock acquisition timed out");
  expect(await child.exited).toBe(0);
  expect(sleeps).toBeGreaterThan(0); expect(sleeps).toBeLessThanOrEqual(99);
  expect(reads).toBeLessThanOrEqual(4);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
});

for (const managed of [false, true]) test(`G4c verify re-exec relaunches initially running VoiceBar, launchd=${managed}`, async () => {
  const f = fixture(), source = readFileSync("scripts/voicelayer-verify.sh", "utf8");
  const functions = source.slice(source.indexOf("is_voicebar_launchd_managed()"), source.indexOf("needs_verification=0"));
  const tail = source.slice(source.indexOf('# Preserve pre-quit intent'), source.indexOf('printf "Press F5'));
  const harness = join(f.root, "verify-harness.sh"), state = join(f.root, "running"); writeFileSync(state, "101");
  const gateLib = join(f.root, "scripts/lib"); mkdirSync(gateLib, { recursive: true });
  writeFileSync(join(gateLib, "update-gate.sh"), `vl_update_gate() { if [[ -z "\u0024{VOICELAYER_INSTALL_OPERATION:-}" ]]; then : > "$STATE"; export VOICELAYER_INSTALL_OPERATION=fixture; exec /bin/bash "$HARNESS"; fi; }\n`);
  writeFileSync(harness, `#!/bin/bash\nset -euo pipefail\n${functions}\nREPO_ROOT="$ROOT"; UPDATE_GATE_ARGS=(); VOICEBAR_LAUNCHD_LABEL=fake\npgrep() { cat "$STATE"; test -s "$STATE"; }; pkill() { echo forbidden-stop >&2; exit 91; }; lsof() { :; }; sleep() { :; }; kill() { return 1; }\nlaunchctl() { if [[ "$1" == list ]]; then ${managed ? "return 0" : "return 1"}; else echo 202 > "$STATE"; fi; }\nopen() { echo 202 > "$STATE"; }\n${tail}\ntest -s "$STATE"\n`);
  const child = Bun.spawn(["/bin/bash", harness], { env: { ...process.env, VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_VERIFY_SKIP_BUILD: "1", ROOT: f.root, STATE: state, HARNESS: harness }, stdin: new TextEncoder().encode("y\n"), stdout: "pipe", stderr: "pipe" });
  const stderr = await new Response(child.stderr).text();
  expect({ exit: await child.exited, stderr }).toEqual({ exit: 0, stderr: "" });
  expect(readFileSync(state, "utf8").trim()).toBe("202");
});

test("G4c build guard retains no-relaunch decision after the original owner exits", async () => {
  const f = fixture(), app = join(f.root, "candidate.noindex/VoiceBar.app");
  const script = `VOICEBAR_BUILD_APP_SOURCE_ONLY=1 source flow-bar/build-app.sh
    APP_DIR="$1"; STOP_RUNNING=1; RELAUNCH_APP=1
    VOICEBAR_TEST_RUNNING_APP_PATHS=/Applications/VoiceBar.app
    guard_build_lifecycle_for_running_instances
    export VOICEBAR_PRE_GATE_APP_DIR="$APP_DIR" VOICEBAR_PRE_GATE_STOP="$STOP_RUNNING"
    export VOICEBAR_PRE_GATE_RELAUNCH="$RELAUNCH_APP" VOICEBAR_PRE_GATE_LEAVE="$LEAVE_RUNNING_INSTANCE_ALONE"
    export VOICELAYER_INSTALL_OPERATION=fixture
    unset VOICEBAR_TEST_RUNNING_APP_PATHS
    voicebar_running_app_paths() { :; }
    STOP_RUNNING=1; RELAUNCH_APP=1
    guard_build_lifecycle_for_running_instances
    test "$STOP_RUNNING:$RELAUNCH_APP:$LEAVE_RUNNING_INSTANCE_ALONE" = 0:0:1`;
  const child = Bun.spawn(["/bin/bash", "-c", script, "_", app], { env: process.env, stdout: "pipe", stderr: "pipe" });
  expect({ exit: await child.exited, stderr: await new Response(child.stderr).text() }).toEqual({ exit: 0, stderr: "" });
});
