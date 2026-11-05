import { afterEach, expect, test, spyOn } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { transitionUpdateGate } from "../update-gate";
import { initializeVoiceGate, updateVoiceGate, withVoiceAdmission } from "../update-gate-admission";
import { installerProcessIdentity, type InstallerParticipant } from "../update-gate-installer-participant";
import * as installer from "../update-gate-installer";
const saved = { ...process.env };
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = saved.VOICELAYER_UPDATE_GATE_PATH; process.env.VOICELAYER_TEST_INSTALL_PROOF = saved.VOICELAYER_TEST_INSTALL_PROOF; });
const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
const committed = { version: 1, kind: "COMMITTED", lease, native: ack, daemon: ack };
const command = { kind: "COMPLETE", lease, installerExitCode: 0, installedSha: lease.targetSha, participantsVerified: true };
const released = { version: 1, kind: "OPEN", generation: 1, released: lease };
test("G5 COMPLETE releases exactly the committed generation and is idempotent", () => {
  expect(transitionUpdateGate(committed, command)).toEqual({ kind: "APPLIED", state: released });
  expect(transitionUpdateGate(released, command)).toEqual({ kind: "UNCHANGED", state: released });
});
test.each(["ownerId", "generation", "targetSha", "operationId"])("G5 COMPLETE fences %s", key => {
  const other = { ...lease, [key]: key === "generation" ? 2 : key === "targetSha" ? "b".repeat(40) : crypto.randomUUID() };
  expect(transitionUpdateGate(committed, { ...command, lease: other })).toEqual({ kind: "REFUSED", reason: "OWNERSHIP" });
});
test.each(["DRAINING", "PREPARED"])("G5 COMPLETE never releases %s", kind => {
  const state = kind === "DRAINING" ? { version: 1, kind, lease } : { ...committed, kind };
  expect(transitionUpdateGate(state, command)).toEqual({ kind: "REFUSED", reason: "PHASE" });
});
test.each([{ installerExitCode: 7 }, { installedSha: "b".repeat(40) }, { participantsVerified: false }])("G5 COMPLETE refuses unverified evidence %j", fault => {
  expect(transitionUpdateGate(committed, { ...command, ...fault }).kind).toBe("REFUSED");
});
function fixture() {
  const gate = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "complete-")), "g");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  process.env.VOICELAYER_TEST_INSTALL_PROOF = gate + ".proof";
  writeFileSync(gate + ".proof", JSON.stringify({ phase: "idle", ready: true }));
  mkdirSync(gate + ".admissions"); writeFileSync(gate, JSON.stringify(committed));
  const identity = installerProcessIdentity(process.pid)!;
  const controller = { version: 1, lease: { generation: 1, operationId: lease.operationId }, pid: process.pid, identity };
  writeFileSync(gate + ".controller", JSON.stringify(controller));
  const participant: InstallerParticipant = {
    refresh: async () => ({ phase: "idle", ready: true, native: ack, daemon: ack }),
    verify: () => true, quit: async () => {}, withAcquisitionProof: async read => read(),
  };
  const receipt = gate + `.recovery-${lease.operationId}.json`;
  return { gate, identity, controller, participant, receipt };
}
test("G5 locked COMPLETE needs a trusted proof even with well-formed fields", () => {
  const f = fixture();
  expect(updateVoiceGate(command).kind).toBe("REFUSED");
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(committed);
});
test("G5 verified controller reopens and the same admission instance admits without restart", async () => {
  const f = fixture();
  await initializeVoiceGate();
  expect(() => withVoiceAdmission(() => "early")).toThrow("UPDATE_BUSY");
  expect(await installer.completeGatedInstall(lease, 0, f.identity, {
    participant: f.participant, installed: () => ({ sha: lease.targetSha, unchanged: () => true }),
  })).toBe(true);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(released);
  expect(existsSync(f.gate + ".controller")).toBe(false);
  expect(withVoiceAdmission(() => readdirSync(f.gate + ".admissions").length)).toBe(1);
  expect(readdirSync(f.gate + ".admissions")).toEqual([]);
});
test.each(["exit", "sha", "dead", "changed-plist", "foreign-controller", "foreign-pid", "foreign-identity", "caller-identity"])("G5 controller %s retains COMMITTED, controller and recovery receipt", async fault => {
  const f = fixture();
  if (fault === "dead") f.participant.refresh = async () => { throw Error("dead successor"); };
  if (fault === "foreign-controller") f.controller.lease.operationId = crypto.randomUUID();
  if (fault === "foreign-pid") f.controller.pid += 100000;
  if (fault === "foreign-identity" || fault === "caller-identity") f.controller.identity = "another birth";
  writeFileSync(f.gate + ".controller", JSON.stringify(f.controller));
  const before = readFileSync(f.gate + ".controller", "utf8");
  let virtualNow = 0;
  expect(await installer.completeGatedInstall(lease, fault === "exit" ? 7 : 0, fault === "caller-identity" ? "another birth" : f.identity, {
    participant: f.participant,
    clock: { now: () => virtualNow, sleep: async ms => { virtualNow += ms; } },
    installed: () => ({ sha: fault === "sha" ? "b".repeat(40) : lease.targetSha, unchanged: () => fault !== "changed-plist" }),
  })).toBe(false);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(committed);
  expect(readFileSync(f.gate + ".controller", "utf8")).toBe(before);
  expect(JSON.parse(readFileSync(f.receipt, "utf8")).lease).toEqual(lease);
  expect(existsSync(f.gate + ".lock")).toBe(false);
});

test.each(["verified", "exit", "sha", "dead"])("G5 controller child lifecycle: %s", async fault => {
  const f = fixture();
  // This is an isolated controller process; it owns a new lease from OPEN.
  writeFileSync(f.gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  const { unlinkSync } = await import("node:fs"); unlinkSync(f.gate + ".controller");
  const completion = { ready: fault !== "dead", installedSha: (fault === "sha" ? "b" : "a").repeat(40) };
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", process.execPath, "-e",
    `await Bun.write(process.env.VOICELAYER_TEST_INSTALL_PROOF!,JSON.stringify({phase:'idle',ready:true,completion:${JSON.stringify(completion)}}));process.exit(${fault === "exit" ? 7 : 0});`], {
    env: { ...process.env, VOICELAYER_UPDATE_TARGET_SHA: lease.targetSha, VOICELAYER_INSTALL_OPERATION: "" }, stdout: "pipe", stderr: "pipe",
  });
  const code = await child.exited, error = await new Response(child.stderr).text();
  const state = JSON.parse(readFileSync(f.gate, "utf8"));
  expect(code).toBe(fault === "verified" ? 0 : fault === "exit" ? 7 : 1);
  expect(state.kind).toBe(fault === "verified" ? "OPEN" : "COMMITTED");
  expect(existsSync(f.gate + ".controller")).toBe(fault !== "verified");
  const releasedLease = state.released ?? state.lease;
  expect(releasedLease.targetSha).toBe(lease.targetSha);
  expect(existsSync(f.gate + `.recovery-${releasedLease.operationId}.json`)).toBe(fault !== "verified");
  if (fault === "verified") expect(error).toContain("admission OPEN");
  else expect(error).toContain("recover an abandoned COMMITTED lease automatically");
}, 70_000);

// readInstalledTarget shells out to /usr/bin/plutil (macOS-only); the installer itself only runs on macOS.
test.skipIf(process.platform !== "darwin")("G5 parses installed Info.plist bytes and detects replacement before COMPLETE", () => {
  const f = fixture(), plist = f.gate + ".plist";
  writeFileSync(plist, `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>GitCommit</key><string>${lease.targetSha}</string></dict></plist>`);
  const installed = installer.readInstalledTarget(plist);
  expect(installed.sha).toBe(lease.targetSha); expect(installed.unchanged()).toBe(true);
  writeFileSync(plist, "changed"); expect(installed.unchanged()).toBe(false);
  expect(() => installer.readInstalledTarget(plist)).toThrow("GitCommit unavailable");
});

test.each(["active", "diagnostic", "stale-proof"])("G5 locked COMPLETE refuses %s", async fault => {
  const f = fixture();
  if (fault === "active") writeFileSync(f.gate + ".admissions/active", "retained");
  if (fault === "diagnostic") writeFileSync(f.gate + ".voice-diag.json", "retained");
  if (fault === "stale-proof") f.participant.verify = () => false;
  expect(await installer.completeGatedInstall(lease, 0, f.identity, {
    participant: f.participant, installed: () => ({ sha: lease.targetSha, unchanged: () => true }),
  })).toBe(false);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(committed);
  expect(existsSync(f.gate + ".controller")).toBe(true);
});

test("G5 COMPLETE cannot mistake the next owner's REQUEST for its own failed completion", async () => {
  const f = fixture(), next = { ...lease, generation: 2, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID() };
  f.participant.withCompletionProof = async read => {
    const result = read();
    expect(updateVoiceGate({ kind: "REQUEST", lease: next }).kind).toBe("APPLIED");
    return result;
  };
  expect(await installer.completeGatedInstall(lease, 0, f.identity, {
    participant: f.participant, installed: () => ({ sha: lease.targetSha, unchanged: () => true }),
  })).toBe(true);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual({ version: 1, kind: "DRAINING", lease: next });
  expect(existsSync(f.receipt)).toBe(false);
});

// A real participant verifier with a synthetic RPC/process table and virtual time.
async function readinessFixture(outcome: string) {
  const f = fixture();
  const { createInstallerParticipant } = await import("../update-gate-installer-participant");
  let now = 0, attempts = 0, successorStarted = false;
  const sleeps: number[] = [];
  const old = { native: { pid: 101, incarnation: crypto.randomUUID() }, daemon: { pid: 102, incarnation: crypto.randomUUID() } };
  const fresh = { native: { pid: 201, incarnation: crypto.randomUUID() }, daemon: { pid: 202, incarnation: crypto.randomUUID() } };
  let identities = old;
  const clock = { now: () => now, sleep: async (ms: number) => { sleeps.push(ms); now += ms; } };
  const previous = createInstallerParticipant({
    ...clock,
    request: async () => {
      if (successorStarted) {
        attempts++;
        if (outcome === "never" || attempts < (outcome === "late" ? 22 : outcome === "ready" ? 3 : 2)) return { kind: "UNKNOWN" };
        identities = structuredClone(fresh);
        if (outcome === "old-native") identities.native.incarnation = old.native.incarnation;
        if (outcome === "old-daemon") identities.daemon.incarnation = old.daemon.incarnation;
        if (outcome === "old-birth") identities.native.pid = old.native.pid;
        if (outcome === "stale" && attempts < 3) now += 1100;
        if (outcome === "disconnected" && attempts < 3) throw Error("connection refused");
      }
      return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities };
    },
    processIdentity: pid => "Tue Nov  3 15:54:30 2026 " + (pid === identities.native.pid
      ? outcome === "wrong-bundle" && successorStarted ? "/tmp/Other.app/Contents/MacOS/Other" : "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar"
      : "/opt/homebrew/bin/bun"),
    processParent: () => identities.native.pid, participantsExited: () => true,
  });
  await previous.refresh(lease);
  const participant = previous.successor!(); successorStarted = true;
  const run = () => installer.completeGatedInstall(lease, 0, f.identity, {
    participant, installed: () => ({ sha: lease.targetSha, unchanged: () => true }), clock,
  });
  return { ...f, run, sleeps, attempts: () => attempts, now: () => now };
}

test.each(["ready", "stale", "disconnected"])("G5 readiness retries fresh authenticated attempts: %s", async outcome => {
  const f = await readinessFixture(outcome);
  expect(await f.run()).toBe(true);
  expect(f.attempts()).toBe(3);
  expect(f.sleeps).toEqual([100, 200]);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(released);
  expect(existsSync(f.gate + ".controller")).toBe(false);
  expect(existsSync(f.receipt)).toBe(false);
});

test("G5 readiness deadline retains COMMITTED and writes recovery without real sleeps", async () => {
  const f = await readinessFixture("never");
  const log = spyOn(console, "error");
  try {
    expect(await f.run()).toBe(false);
    const failures = log.mock.calls.map(args => String(args[0])).filter(line => line.includes("readiness attempt"));
    expect(failures).toHaveLength(63);
    expect(failures.every((line, index) => line.includes(`attempt ${index + 1} failed:`) && line.includes("not verified"))).toBe(true);
  } finally { log.mockRestore(); }
  expect(f.now()).toBe(60_000);
  expect(f.attempts()).toBe(63);
  expect(f.sleeps.slice(0, 5)).toEqual([100, 200, 400, 800, 1000]);
  expect(f.sleeps.at(-1)).toBe(500);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(committed);
  expect(existsSync(f.gate + ".controller")).toBe(true);
  expect(JSON.parse(readFileSync(f.receipt, "utf8")).reason).toContain("deadline");
});

test.each(["old-native", "old-daemon", "old-birth", "wrong-bundle"])("G5 readiness immediately refuses unsafe second attempt: %s", async outcome => {
  const f = await readinessFixture(outcome);
  expect(await f.run()).toBe(false);
  expect(f.attempts()).toBe(2);
  expect(f.sleeps).toEqual([100]);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(committed);
  expect(existsSync(f.gate + ".controller")).toBe(true);
  expect(existsSync(f.receipt)).toBe(true);
});

// R6: filesystem/G1 are real; the clock and external process/RPC observations are controlled.
test.each(["dead", "real-dead", "late-death", "live", "unknown", "wrong-sha", "foreign", "active", "diagnostic", "changed-custody"])(
  "R6 successor recovery: %s", async fault => {
    const f = fixture();
    let now = 0;
    const recovers = ["dead", "real-dead", "late-death"].includes(fault);
    if (fault === "real-dead") {
      const child = Bun.spawn(["/usr/bin/true"], { env: process.env });
      await child.exited;
      f.controller.pid = child.pid;
    }
    if (fault === "foreign") f.controller.lease.operationId = crypto.randomUUID();
    writeFileSync(f.gate + ".controller", JSON.stringify(f.controller));
    const custody = readFileSync(f.gate + ".controller", "utf8");
    if (fault === "active") writeFileSync(f.gate + ".admissions/active", "retained");
    if (fault === "diagnostic") writeFileSync(f.gate + ".voice-diag.json", "retained");
    f.participant.refresh = async () => {
      expect(now).toBeGreaterThanOrEqual(5000);
      if (fault === "changed-custody") writeFileSync(f.gate + ".controller", custody.replace(f.identity, "foreign"));
      return { phase: "idle", ready: true, native: ack, daemon: ack };
    };
    expect(await installer.recoverAbandonedUpdate(fault === "wrong-sha" ? "b".repeat(40) : lease.targetSha, {
      participant: f.participant, installed: () => ({ sha: lease.targetSha, unchanged: () => true }),
      clock: { now: () => now, sleep: async ms => { now += ms; } },
      controllerIdentity: () => {
        if (fault === "unknown") throw Error("process evidence unavailable");
        if (fault === "real-dead") return installerProcessIdentity(f.controller.pid);
        return fault === "live" || (fault === "late-death" && now < 1000) ? f.identity : null;
      },
    })).toBe(recovers);
    expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(recovers ? released : committed);
    expect(existsSync(f.gate + ".controller")).toBe(!recovers);
    expect(existsSync(f.gate + ".lock")).toBe(false);
    if (recovers) {
      expect(now).toBe(fault === "late-death" ? 6000 : 5000);
      expect(withVoiceAdmission(() => "available")).toBe("available");
      expect(await installer.recoverAbandonedUpdate(lease.targetSha)).toBe(false); // Already OPEN.
    }
  });

test("R6 COMPLETE survives G1 held beyond 250 ms and renews expired receipts", async () => {
  const f = fixture();
  const { createInstallerParticipant } = await import("../update-gate-installer-participant");
  const { rmdirSync } = await import("node:fs");
  let now = 0, requests = 0;
  const identities = { native: { pid: 201, incarnation: crypto.randomUUID() }, daemon: { pid: 202, incarnation: crypto.randomUUID() } };
  const clock = { now: () => now, sleep: async (ms = 100) => {
    now += ms;
    if (now >= 1600 && existsSync(f.gate + ".lock")) rmdirSync(f.gate + ".lock");
  } };
  const participant = createInstallerParticipant({ ...clock,
    request: async () => { requests++; return { kind: "ACKNOWLEDGED", native: ack, daemon: ack, identities }; },
    processIdentity: pid => "Tue Nov  3 15:54:30 2026 " + (pid === 201 ? "/Applications/VoiceBar.app/Contents/MacOS/VoiceBar" : "/opt/homebrew/bin/bun"),
    processParent: () => 201, participantsExited: () => false,
  }, null);
  mkdirSync(f.gate + ".lock");
  expect(await installer.completeGatedInstall(lease, 0, f.identity, {
    participant, clock, installed: () => ({ sha: lease.targetSha, unchanged: () => true }),
  })).toBe(true);
  expect(now).toBeGreaterThanOrEqual(1600);
  expect(requests).toBeGreaterThan(1);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual(released);
});

test("R6 successor ready after the old 15-second budget can COMPLETE", async () => {
  const f = await readinessFixture("late");
  expect(await f.run()).toBe(true);
  expect(f.now()).toBeGreaterThan(15_000);
  expect(f.attempts()).toBe(22);
});
