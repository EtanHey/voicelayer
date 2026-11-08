import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { acknowledgeVoiceDrain, captureVoiceAdmission, updateVoiceGate, withVoiceAdmission } from "../update-gate-admission";
import { runGatedInstall } from "../update-gate-installer";
import { createVoiceDrainControl } from "../update-gate-native-participant";
import { createInstallerParticipant, type InstallerParticipant } from "../update-gate-installer-participant";

const saved = { ...process.env };
afterEach(() => { process.env = { ...saved }; });
function fixture() {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "user-block-")), gate = join(root, "gate"), proof = join(root, "proof");
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  Object.assign(process.env, { VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof,
    VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40), VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "",
    VOICELAYER_UPDATE_DRAIN_TIMEOUT_MS: "80" });
  const lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  const ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
  return { root, gate, lease, ack };
}
test("DRAINING registers voice at the lease generation; PREPARE waits for its release", () => {
  const f = fixture();
  updateVoiceGate({ kind: "REQUEST", lease: f.lease });
  const admission = withVoiceAdmission(() => captureVoiceAdmission());
  const entries = readdirSync(f.gate + ".admissions");
  expect(entries).toHaveLength(1);
  expect(JSON.parse(readFileSync(join(f.gate + ".admissions", entries[0]!), "utf8"))).toMatchObject({ generation: 1, pid: process.pid });
  expect(acknowledgeVoiceDrain(f.lease, () => true)).toBeNull();
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: f.ack, daemon: f.ack }, () => true).kind).toBe("REFUSED");
  admission.release();
  expect(updateVoiceGate({ kind: "PREPARE", lease: f.lease, native: f.ack, daemon: f.ack }, () => true).kind).toBe("APPLIED");
  expect(() => withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY");
});
test.each(["unknown", "no-reply"])("%s participant times out, cancels, and records named ledger/participant evidence", async mode => {
  const f = fixture(); let attempts = 0;
  writeFileSync(join(f.gate + ".admissions", "synthetic-token"), JSON.stringify({ token: "synthetic-token", kind: "capture", pid: 123 }));
  const participant: InstallerParticipant = {
    refresh: async () => { attempts++; if (mode === "no-reply") return new Promise(() => {});
      return { ready: false, phase: "participant did not acknowledge (version 2.2.61)", pending: [
        { participant: "native", pid: 101, incarnation: "known-native", version: "2.2.61", reply: "UNKNOWN: unsupported drain" },
        { participant: "daemon", pid: 102, version: "2.2.61", reply: "UNKNOWN: unsupported drain" }] }; },
    verify: () => false, quit: async () => { throw Error("must never quit"); },
  };
  const started = performance.now();
  await expect(runGatedInstall([process.execPath, "-e", 'throw Error("must never install")'], participant)).rejects.toThrow("drain timed out");
  expect(performance.now() - started).toBeLessThan(2000);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toMatchObject({ kind: "OPEN", generation: 1 });
  const receipt = readdirSync(f.root).find(name => name.includes(".drain-"));
  expect(receipt).toBeDefined();
  const text = readFileSync(join(f.root, receipt!), "utf8");
  expect(text).toContain("native"); expect(text).toContain("daemon");
  expect(text).toContain("capture"); expect(text).toContain("123");
  if (mode === "unknown") { expect(text).toContain("2.2.61"); expect(text).toContain("101"); }
  expect(attempts).toBeGreaterThan(0);
});
test("UNKNOWN refresh retains diagnostic metadata and retries without authorizing", async () => {
  const f = fixture();
  const participant = createInstallerParticipant({ request: async () => ({ kind: "UNKNOWN", reason: "unsupported drain", version: "2.2.61" }),
    processIdentity: () => null, processParent: () => null, participantsExited: () => false, now: () => 0, sleep: async () => {} });
  const proof = await participant.refresh(f.lease);
  expect(proof.ready).toBe(false);
  expect(proof.pending).toHaveLength(2);
  expect(proof.phase).toContain("2.2.61");
});

test.each(["SIGINT", "SIGTERM"] as const)("%s cancels even an unsettled precommit refresh", async signal => {
  const f = fixture();
  const timer = setTimeout(() => process.emit(signal), 30);
  try {
    expect(await runGatedInstall(["must-never-run"], {
      refresh: () => new Promise(() => {}), verify: () => false, quit: async () => { throw Error("must never quit"); },
    })).toBe(130);
    expect(JSON.parse(readFileSync(f.gate, "utf8"))).toMatchObject({ kind: "OPEN", generation: 1 });
  } finally { clearTimeout(timer); }
});
test("UNKNOWN is retried and a registration racing PREPARE keeps the gate DRAINING", async () => {
  const f = fixture(); process.env.VOICELAYER_UPDATE_DRAIN_TIMEOUT_MS = "600";
  let rounds = 0, acquisitions = 0, release: (() => void) | undefined;
  const participant: InstallerParticipant = {
    async refresh(lease) {
      rounds++;
      const ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
      return { ready: rounds > 1, phase: rounds > 1 ? "idle" : "UNKNOWN", native: ack, daemon: ack };
    },
    verify: () => true,
    async withAcquisitionProof(read) {
      // First negative round checks ACK; the next positive round checks ACK,
      // then a fresh registration arrives immediately before PREPARE.
      if (++acquisitions === 3) {
        release = withVoiceAdmission(() => captureVoiceAdmission()).release;
      }
      const result = read();
      if (release) expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("DRAINING");
      return result;
    },
    quit: async () => { throw Error("must never quit"); },
  };
  try {
    await expect(runGatedInstall(["must-never-run"], participant)).rejects.toThrow("drain timed out");
    expect(rounds).toBeGreaterThan(1);
    expect(acquisitions).toBeGreaterThanOrEqual(3);
    expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  } finally { release?.(); }
});

test("native-only UNKNOWN names the native withholder without blaming an idle daemon", async () => {
  const f = fixture(); updateVoiceGate({ kind: "REQUEST", lease: f.lease });
  const control = createVoiceDrainControl({ request: async () => null, identity: () => ({ pid: 101 }) }, () => true);
  const participant = createInstallerParticipant({ request: async () => control(f.lease, "drain"),
    processIdentity: () => null, processParent: () => null, participantsExited: () => false, now: () => 0, sleep: async () => {} });
  const proof = await participant.refresh(f.lease);
  expect(proof.ready).toBe(false);
  expect(proof.pending).toEqual([{ participant: "native", pid: 101, incarnation: undefined, version: undefined,
    reply: "no reply: native did not acknowledge drain" }]);
});

test("an unsettled PREPARED recheck cancels within the short swap window", async () => {
  const f = fixture(); process.env.VOICELAYER_UPDATE_DRAIN_TIMEOUT_MS = "5000";
  let rounds = 0;
  const started = performance.now();
  await expect(runGatedInstall(["must-never-run"], {
    async refresh(lease) {
      if (++rounds > 1) return new Promise(() => {});
      const ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
      return { ready: true, phase: "idle", native: ack, daemon: ack,
        participants: [{ participant: "native" as const, pid: 101, reply: "ACKNOWLEDGED" },
          { participant: "daemon" as const, pid: 102, reply: "ACKNOWLEDGED" }] };
    }, verify: () => true, quit: async () => { throw Error("must never quit"); },
  })).rejects.toThrow("prepared recheck timed out");
  expect(performance.now() - started).toBeLessThan(4500);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("OPEN");
  expect(rounds).toBe(2);
});
