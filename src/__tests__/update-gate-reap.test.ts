import { afterEach, expect, spyOn, test } from "bun:test";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { updateVoiceGate, acknowledgeVoiceDrain, withVoiceAdmission } from "../update-gate-admission";
import { admissionOwnerProbe } from "../update-gate-owner";
const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = original; });
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001", ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
for (const scenario of ["dead", "reused", "live", "unverifiable", "legacy", "malformed"] as const) {
  test(`reconciliation retains or moves ${scenario} owner with named evidence`, () => {
    const path = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "reap-")), "gate.json");
    process.env.VOICELAYER_UPDATE_GATE_PATH = path;
    writeFileSync(path, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
    mkdirSync(path + ".admissions");
    const owner = { token: "owner", pid: 1234, incarnation: "synthetic", generation: 0, startTime: "100:200" };
    if (scenario === "legacy") delete (owner as Partial<typeof owner>).startTime;
    const bytes = JSON.stringify(scenario === "malformed" ? {} : owner);
    writeFileSync(path + ".admissions/owner", bytes);
    const exists = spyOn(admissionOwnerProbe, "exists").mockImplementation(() => {
      if (scenario === "unverifiable") throw Error("EPERM");
      return scenario !== "dead";
    });
    const birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue(scenario === "reused" ? "101:200" : "100:200");
    const log = spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
      const retired = scenario === "dead" || scenario === "reused";
      expect(readdirSync(path + ".admissions")).toHaveLength(retired ? 0 : 1);
      expect(updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, () => true).kind).toBe(retired ? "APPLIED" : "REFUSED");
      if (retired) {
        const dir = join(path + ".admissions.retired", readdirSync(path + ".admissions.retired")[0]!);
        expect(readFileSync(join(dir, "record.json"), "utf8")).toBe(bytes);
        expect(JSON.parse(readFileSync(join(dir, "reason.json"), "utf8")).reason).toBe(scenario === "dead" ? "PID_ABSENT" : "PID_REUSED");
      } else expect(log.mock.calls.flat().join(" ")).toContain('withholder "owner"');
    } finally { exists.mockRestore(); birth.mockRestore(); log.mockRestore(); }
  });
}
test("waiting drain reconciles a death after REQUEST; real live registration stores OS birth", () => {
  const path = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "reap-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  withVoiceAdmission(() => {
    const names = readdirSync(path + ".admissions");
    const record = JSON.parse(readFileSync(join(path + ".admissions", names[0]!), "utf8"));
    expect(record.startTime ?? null).toBe(admissionOwnerProbe.startTime(process.pid));
    expect(typeof record.startTime).toBe(process.platform === "darwin" ? "string" : "undefined");
  });
  writeFileSync(path + ".admissions/dead-later", JSON.stringify({ pid: 1234, token: "dead-later", incarnation: "old", generation: 0 }));
  const exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(true);
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    updateVoiceGate({ kind: "REQUEST", lease });
    expect(acknowledgeVoiceDrain(lease, () => true)).toBeNull();
    exists.mockReturnValue(false);
    expect(acknowledgeVoiceDrain(lease, () => true)).toEqual(ack);
    expect(readdirSync(path + ".admissions")).toEqual([]);
  } finally { exists.mockRestore(); log.mockRestore(); }
});
test("real exited Bun owner leaves a ledger that REQUEST retires without age", () => {
  const path = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "reap-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  const module = new URL("../update-gate-admission.ts", import.meta.url).pathname;
  const child = Bun.spawnSync([process.execPath, "-e", `import { withVoiceAdmission } from ${JSON.stringify(module)}; withVoiceAdmission(() => process.exit(0));`],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  expect(child.exitCode).toBe(0);
  expect(readdirSync(path + ".admissions")).toHaveLength(1);
  expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  expect(readdirSync(path + ".admissions")).toEqual([]);
  expect(updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, () => true).kind).toBe("APPLIED");
});
