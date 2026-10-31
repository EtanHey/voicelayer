// Regression probe adapted from the PR #631 other-vendor fix verifier.
// Run from the worktree root so bunfig's isolation preload applies.
import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmdirSync } from "node:fs";
import { join } from "node:path";
import { createInstallerParticipant, type InstallerParticipantDependencies } from "../update-gate-installer-participant";
import { acknowledgeVoiceDrain, updateVoiceGate } from "../update-gate-admission";

const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate; });
const NATIVE = "birth /Applications/VoiceBar.app/Contents/MacOS/VoiceBar", DAEMON = "birth /opt/homebrew/bin/bun";
const PS_MS = 3; // Verifier measured on M1: one `ps -p` spawn costs 3.3-5.2 ms.

function fixture() {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "fv-")), gate = join(root, "g");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  const identities = { native: { pid: 101, incarnation: crypto.randomUUID() }, daemon: { pid: 102, incarnation: crypto.randomUUID() } };
  const ack = { lease, activeOperations: 0, openArchives: 0 };
  const s = { exited: false, calls: [] as string[], hooks: {} as Record<string, () => void> };
  const deps: InstallerParticipantDependencies = {
    request: async (action: string) => { s.calls.push(action); if (action === "quit") { s.hooks.onQuit?.(); return { kind: "UNKNOWN" }; } return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities }; },
    processIdentity: (pid: number) => { s.hooks.onIdentity?.(); Bun.sleepSync(PS_MS); return s.exited ? null : pid === 101 ? NATIVE : DAEMON; },
    processParent: () => { Bun.sleepSync(PS_MS); s.hooks.onParent?.(); return 101; },
    participantsExited: () => false,
    now: () => performance.now(),
    sleep: (ms = 100) => Bun.sleep(ms),
  };
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  const participant = createInstallerParticipant(deps);
  const commit = async () => {
    const proof = await participant.refresh(lease);
    expect(participant.withProcessProof!(() => updateVoiceGate({ kind: "PREPARE", lease, native: proof.native, daemon: proof.daemon }, participant.verify)).kind).toBe("APPLIED");
    await participant.refresh(lease);
    expect(participant.withProcessProof!(() => updateVoiceGate({ kind: "COMMIT", lease }, participant.verify)).kind).toBe("APPLIED");
    await participant.refresh(lease); // the controller's post-commit drain refresh
  };
  return { gate, lease, s, deps, participant, commit };
}

// The holder releases on its own process clock, even while this process is
// blocked in a sample or retry. The installer never removes its lock.
async function shortHolder(gate: string) {
  const ready = gate + ".holder-ready", trigger = gate + ".holder-trigger", held = gate + ".holder-held";
  const child = Bun.spawn([process.execPath, "-e", `
    const fs = require("node:fs");
    const [lock, ready, trigger, held] = ${JSON.stringify([gate + ".lock", ready, trigger, held])};
    fs.writeFileSync(ready, "ready");
    const deadline = performance.now() + 2000;
    while (!fs.existsSync(trigger) && performance.now() < deadline) Bun.sleepSync(0.1);
    if (!fs.existsSync(trigger)) process.exit(2);
    fs.mkdirSync(lock); fs.writeFileSync(held, "held");
    Bun.sleepSync(1.5); fs.rmdirSync(lock);
  `], { env: process.env, stdout: "ignore", stderr: "pipe" });
  const deadline = performance.now() + 2000;
  while (!existsSync(ready) && performance.now() < deadline) await Bun.sleep(1);
  expect(existsSync(ready)).toBe(true);
  return {
    hold() {
      writeFileSync(trigger, "hold");
      const deadline = performance.now() + 2000;
      while (!existsSync(held) && performance.now() < deadline) Bun.sleepSync(0.1);
      expect(existsSync(held)).toBe(true);
      expect(existsSync(gate + ".lock")).toBe(true);
    },
    async exited() { expect(await child.exited).toBe(0); },
  };
}

// Scenario A: a voice_speak acquire() holds G1 for ~1 ms exactly when the quit authorization's
// acknowledgeVoiceDrain runs, and releases it long before the ~10 ms after-sample finishes.
test("A: short holder at quit authorization", async () => {
  const f = fixture(); await f.commit();
  const holder = await shortHolder(f.gate);
  f.s.hooks.onQuit = () => { f.deps.participantsExited = () => true; };
  let held = false;
  f.s.hooks.onParent = () => { if (!held && f.s.calls.filter(c => c === "drain").length === 3 && !f.s.calls.includes("quit")) { holder.hold(); held = true; } };
  let error: unknown;
  try { await f.participant.quit(f.lease); } catch (e) { error = e; }
  console.log("A result:", error ? String(error) : "quit authorized", "| quit RPCs:", f.s.calls.filter(c => c === "quit").length,
    "| gate:", JSON.parse(readFileSync(f.gate, "utf8")).kind);
  await holder.exited();
  expect(error).toBeUndefined();
});

// Scenario B: VoiceBar's permitsTermination takes G1 (<=2 ms) during the first exit verification.
test("B: short holder during first exit verification", async () => {
  const f = fixture(); await f.commit();
  const holder = await shortHolder(f.gate);
  let poll = 0;
  f.s.hooks.onQuit = () => {
    f.deps.participantsExited = () => {
      poll++;
      Bun.sleepSync(PS_MS * 2);
      if (poll === 1) { holder.hold(); return false; } // `before` sample ends as Swift takes the lock
      return poll >= 4; // VoiceBar then exits normally
    };
  };
  let error: unknown;
  try { await f.participant.quit(f.lease); } catch (e) { error = e; }
  console.log("B result:", error ? String(error) : "exit verified", "| polls:", poll, "| quit RPCs:", f.s.calls.filter(c => c === "quit").length);
  await holder.exited();
  expect(error).toBeUndefined();
});

// Control: the fix-round's own model (holder persists until the installer's next sleep) passes.
test("control: persistent holder at quit authorization", async () => {
  const f = fixture(); await f.commit();
  f.s.hooks.onQuit = () => { f.deps.participantsExited = () => true; };
  mkdirSync(f.gate + ".lock");
  const sleep = f.deps.sleep;
  f.deps.sleep = async (ms?: number) => { if (existsSync(f.gate + ".lock")) rmdirSync(f.gate + ".lock"); return sleep(ms); };
  await f.participant.quit(f.lease);
}, 20000);

// Statistical: a separate process takes G1 for 1.5 ms every ~4 ms (a busy voice_speak/F5 stream).
test("statistical: real concurrent short holder at quit authorization", async () => {
  let failures = 0, ok = 0; const reasons: Record<string, number> = {};
  for (let i = 0; i < 20; i++) {
    const f = fixture(); await f.commit();
    f.s.hooks.onQuit = () => { f.deps.participantsExited = () => true; };
    const contender = Bun.spawn([process.execPath, "-e", `
      const fs=require("node:fs"); const l=${JSON.stringify(f.gate + ".lock")}; const end=performance.now()+400;
      while(performance.now()<end){ try{ fs.mkdirSync(l); Bun.sleepSync(1.5); fs.rmdirSync(l);}catch{} Bun.sleepSync(2.5); }`],
      { env: process.env, stdout: "ignore", stderr: "ignore" });
    await Bun.sleep(30);
    try { await f.participant.quit(f.lease); ok++; } catch (e) { failures++; const k = String(e) + " quitRPCs=" + f.s.calls.filter(c => c === "quit").length; reasons[k] = (reasons[k] ?? 0) + 1; }
    expect(await contender.exited).toBe(0);
    expect(existsSync(f.gate + ".lock")).toBe(false);
  }
  console.log(`statistical: ${ok} succeeded, ${failures} refused`, JSON.stringify(reasons));
  expect(failures).toBe(0);
}, 60000);

// Lock-hold measurement with slow readers (SHOULD-FIX 1).
test("lock hold time with 15 ms process readers", async () => {
  const f = fixture(); await f.commit();
  f.deps.processIdentity = (pid: number) => { Bun.sleepSync(15); return pid === 101 ? NATIVE : DAEMON; };
  const times: number[] = [], base: number[] = [];
  for (let i = 0; i < 50; i++) {
    f.participant.withProcessProof!(() => {
      const t = performance.now();
      const r = acknowledgeVoiceDrain(f.lease, f.participant.verify);
      times.push(performance.now() - t);
      expect(r).not.toBeNull();
    });
    { const t = performance.now(); acknowledgeVoiceDrain(f.lease, () => true); base.push(performance.now() - t); }
    await f.participant.refresh(f.lease);
  }
  times.sort((a, b) => a - b); base.sort((a, b) => a - b);
  console.log(`baseline (trivial verifier) ms: median ${base[25].toFixed(3)} p95 ${base[47].toFixed(3)} max ${base[49].toFixed(3)}`);
  console.log(`ack window ms: median ${times[25].toFixed(3)} p95 ${times[47].toFixed(3)} max ${times[49].toFixed(3)}`);
  expect(times[25]).toBeLessThan(2);
}, 60000);

// A held acquisition may consume only a small part of the original one-second
// receipt lifetime. Exhaustion refuses without issuing quit or refreshing trust.
test("quit authorization contention stays within receipt freshness", async () => {
  const f = fixture(); await f.commit();
  let now = 0, waited = 0, reads = 0;
  const identity = f.deps.processIdentity;
  f.deps.processIdentity = pid => { reads++; return identity(pid); };
  f.deps.now = () => now;
  await f.participant.refresh(f.lease);
  mkdirSync(f.gate + ".lock");
  reads = 0;
  f.deps.sleep = async (ms = 100) => {
    expect(reads).toBe(2); // No identity work between failed acquisition attempts.
    expect(ms).toBe(2); waited += ms; now += ms;
  };
  try {
    await expect(f.participant.quit(f.lease)).rejects.toThrow("UNKNOWN");
    console.log(`quit authorization contention sleep budget: ${waited} ms`);
    expect(waited).toBe(198);
    expect(reads).toBe(2);
    expect(f.s.calls.filter(c => c === "quit")).toHaveLength(0);
    expect(existsSync(f.gate + ".lock")).toBe(true);
    expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
  } finally { rmdirSync(f.gate + ".lock"); }
});

test("clean exit observed across the deadline is accepted", async () => {
  const f = fixture(); await f.commit();
  let now = 0;
  f.deps.now = () => now;
  await f.participant.refresh(f.lease);
  f.s.hooks.onQuit = () => {
    f.deps.participantsExited = () => { now += 2501; return true; };
  };
  await f.participant.quit(f.lease);
  expect(f.s.calls.filter(c => c === "quit")).toHaveLength(1);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});
