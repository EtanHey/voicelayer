import { expect, spyOn, test } from "bun:test";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { admissionOwnerProbe, reconcileDeadAdmissions } from "../update-gate-owner";
function fixture(startTime?: string) {
  const gate = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "reap-r2-")), "gate");
  mkdirSync(gate + ".admissions");
  writeFileSync(gate + ".admissions/owner", JSON.stringify({ token: "owner", pid: 1234, incarnation: "r2", generation: 0, ...(startTime === undefined ? {} : { startTime }) }));
  utimesSync(gate + ".admissions/owner", 200, 200);
  return gate;
}
test("sysctl reads another user's process start time (pid 1)", () => {
  if (process.platform !== "darwin") return;
  expect(admissionOwnerProbe.startTime(1)).toMatch(/^\d+:\d+$/);
  expect(admissionOwnerProbe.startTime(99999999)).toBeNull();
});
for (const legacy of [false, true]) test(`reuse is proved despite EPERM: legacy=${legacy}`, () => {
  const gate = fixture(legacy ? undefined : "100:0");
  const exists = spyOn(admissionOwnerProbe, "exists").mockImplementation(() => { throw Object.assign(Error("permission"), { code: "EPERM" }); });
  const birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue("201:0");
  try { expect(reconcileDeadAdmissions(gate, ["owner"])).toEqual([]); expect(readdirSync(gate + ".admissions")).toEqual([]); }
  finally { exists.mockRestore(); birth.mockRestore(); }
});
for (const birthTime of ["199:999999", "200:0", null]) test(`legacy mtime retains non-positive reuse evidence ${birthTime}`, () => {
  const gate = fixture();
  const exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(true);
  const birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue(birthTime);
  try { expect(reconcileDeadAdmissions(gate, ["owner"])).toEqual(["owner"]); }
  finally { exists.mockRestore(); birth.mockRestore(); }
});
test("withholder log is once per name per minute", () => {
  const gate = fixture("100:0"), exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(true);
  const birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue(null);
  const log = spyOn(console, "error").mockImplementation(() => {}), clock = spyOn(Date, "now").mockReturnValue(100000);
  try {
    reconcileDeadAdmissions(gate, ["owner"]); reconcileDeadAdmissions(gate, ["owner"]);
    expect(log).toHaveBeenCalledTimes(1);
    clock.mockReturnValue(160000); reconcileDeadAdmissions(gate, ["owner"]);
    expect(log).toHaveBeenCalledTimes(2); expect(log.mock.calls[0]!.join(" ")).toContain('withholder "owner"');
  } finally { exists.mockRestore(); birth.mockRestore(); log.mockRestore(); clock.mockRestore(); }
});
test("failed reap reports its reason and preserves the registration", () => {
  const gate = fixture(), exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(false);
  writeFileSync(gate + ".admissions.retired", "unsafe");
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(() => reconcileDeadAdmissions(gate, ["owner"])).toThrow();
    expect(readFileSync(gate + ".admissions/owner", "utf8")).toContain("owner");
    expect(log.mock.calls.flat().join(" ")).toContain("UPDATE_GATE_UNSAFE_RETIRED_LEDGER");
  } finally { exists.mockRestore(); log.mockRestore(); }
});
test("retention keeps newest 50 retired proofs and never follows symlinks or touches live ledger", () => {
  const gate = fixture("100:0"), retired = gate + ".admissions.retired";
  mkdirSync(retired);
  const ids: string[] = [];
  for (let i = 0; i < 52; i++) {
    const id = `00000000-0000-4000-8000-${String(i).padStart(12, "0")}`; ids.push(id);
    mkdirSync(join(retired, id));
    writeFileSync(join(retired, id, "record.json"), "preserved");
    writeFileSync(join(retired, id, "reason.json"), JSON.stringify({ reason: "PID_ABSENT" }));
    utimesSync(join(retired, id, "reason.json"), 100 + i, 100 + i);
  }
  symlinkSync(gate + ".admissions", join(retired, "linked"));
  const exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(true), birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue("100:0");
  try {
    expect(reconcileDeadAdmissions(gate, ["owner"])).toEqual(["owner"]);
    expect(readdirSync(retired).filter(n => ids.includes(n)).sort()).toEqual(ids.slice(2));
    expect(lstatSync(join(retired, "linked")).isSymbolicLink()).toBe(true);
    expect(readdirSync(gate + ".admissions")).toEqual(["owner"]);
  } finally { exists.mockRestore(); birth.mockRestore(); }
});
test("legacy same-user birth after file mtime is positive PID reuse proof", () => {
  const gate = fixture(), exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(true);
  const birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue("200:1");
  try { expect(reconcileDeadAdmissions(gate, ["owner"])).toEqual([]); }
  finally { exists.mockRestore(); birth.mockRestore(); }
});
test("a positively observed zombie is retired", () => {
  const gate = fixture("100:0"), exists = spyOn(admissionOwnerProbe, "exists").mockReturnValue(true);
  const birth = spyOn(admissionOwnerProbe, "startTime").mockReturnValue("100:0");
  const zombie = spyOn(admissionOwnerProbe, "zombie").mockReturnValue(true);
  try {
    expect(reconcileDeadAdmissions(gate, ["owner"])).toEqual([]);
    const dir = readdirSync(gate + ".admissions.retired")[0]!;
    expect(JSON.parse(readFileSync(join(gate + ".admissions.retired", dir, "reason.json"), "utf8")).reason).toBe("PID_ZOMBIE");
  } finally { exists.mockRestore(); birth.mockRestore(); zombie.mockRestore(); }
});
