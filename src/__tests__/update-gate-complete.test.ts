import { afterEach, expect, test } from "bun:test";
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
  expect(await installer.completeGatedInstall(lease, fault === "exit" ? 7 : 0, fault === "caller-identity" ? "another birth" : f.identity, {
    participant: f.participant,
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
  else expect(error).toContain("voicelayer setup --cask-postflight");
});

test("G5 parses installed Info.plist bytes and detects replacement before COMPLETE", () => {
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
