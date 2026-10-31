import { afterEach, expect, test } from "bun:test";
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { installerProcessIdentity } from "../update-gate-installer-participant";
const savedGate = process.env.VOICELAYER_UPDATE_GATE_PATH, savedProof = process.env.VOICELAYER_TEST_INSTALL_PROOF;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = savedGate; process.env.VOICELAYER_TEST_INSTALL_PROOF = savedProof; });
function fixture() {
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "owner-")), gate = join(root, "g"), proof = join(root, "proof");
  mkdirSync(gate + ".admissions");
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate; process.env.VOICELAYER_TEST_INSTALL_PROOF = proof;
  return { root, gate, env: { ...process.env, VOICELAYER_UPDATE_GATE_PATH: gate, VOICELAYER_TEST_INSTALL_PROOF: proof,
    VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40), VOICELAYER_INSTALL_OPERATION: "" } };
}

test("durable controller passes; copied env with another live PID and matching identity refuses", async () => {
  const f = fixture(), record = join(f.root, "operation"), validated = join(f.root, "validated");
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", process.execPath, "-e", `
    const installer=await import('./src/update-gate-installer.ts');
    await installer.validateInstallerOperation();
    await Bun.write(${JSON.stringify(validated)},'yes');
    await Bun.write(${JSON.stringify(record)},process.env.VOICELAYER_INSTALL_OPERATION);
  `], { env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect({ exit: await child.exited, error: await new Response(child.stderr).text() }).toMatchObject({ exit: 0 });
  expect(existsSync(validated)).toBe(true);
  const owner = JSON.parse(readFileSync(record, "utf8"));
  expect(JSON.parse(readFileSync(f.gate + ".controller", "utf8"))).toEqual({ version: 1,
    lease: { operationId: owner.lease.operationId, generation: owner.lease.generation }, pid: owner.pid, identity: owner.identity });
  expect(lstatSync(f.gate + ".controller").mode & 0o777).toBe(0o600);
  expect(Object.keys(JSON.parse(readFileSync(f.gate, "utf8"))).sort()).toEqual(["daemon", "kind", "lease", "native", "version"]);
  const forged = { ...owner, pid: process.pid, identity: installerProcessIdentity(process.pid) };
  const copied = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "--validate"],
    { env: { ...process.env, ...f.env, VOICELAYER_INSTALL_OPERATION: JSON.stringify(forged) }, stdout: "pipe", stderr: "pipe" });
  expect(await copied.exited).toBe(1);
  expect(await new Response(copied.stderr).text()).toContain("controller");
});

test("legacy committed gate without durable controller metadata refuses safely", async () => {
  const f = fixture(), lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  const ack = { lease, activeOperations: 0, openArchives: 0 };
  writeFileSync(f.gate, JSON.stringify({ version: 1, kind: "COMMITTED", lease, native: ack, daemon: ack }));
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "--validate"], { env: { ...process.env, ...f.env,
    VOICELAYER_INSTALL_OPERATION: JSON.stringify({ lease, pid: process.pid, identity: installerProcessIdentity(process.pid) }) }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(1);
  expect(JSON.parse(readFileSync(f.gate, "utf8")).kind).toBe("COMMITTED");
});
for (const fault of ["missing", "garbled", "foreign-lease", "stale-identity"]) test(`controller receipt ${fault} refuses nested validation`, async () => {
  const f = fixture(), lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  const ack = { lease, activeOperations: 0, openArchives: 0 }, identity = installerProcessIdentity(process.pid);
  writeFileSync(f.gate, JSON.stringify({ version: 1, kind: "COMMITTED", lease, native: ack, daemon: ack }));
  if (fault !== "missing") writeFileSync(f.gate + ".controller", fault === "garbled" ? "{" : JSON.stringify({ version: 1,
    lease: { generation: lease.generation, operationId: fault === "foreign-lease" ? crypto.randomUUID() : lease.operationId },
    pid: process.pid, identity: fault === "stale-identity" ? "old birth /foreign" : identity }));
  const before = existsSync(f.gate + ".controller") ? readFileSync(f.gate + ".controller", "utf8") : null;
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "--validate"], { env: { ...process.env, ...f.env,
    VOICELAYER_INSTALL_OPERATION: JSON.stringify({ lease, pid: process.pid, identity }) }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(1);
  expect(existsSync(f.gate + ".controller") ? readFileSync(f.gate + ".controller", "utf8") : null).toBe(before);
});
test("release and Cancel remove only the matching controller receipt", async () => {
  const { persistUpdateGateState, withUpdateGateLock } = await import("../update-gate-storage");
  const { updateVoiceGate } = await import("../update-gate-admission");
  const f = fixture(), lease = { generation: 1, operationId: crypto.randomUUID(), ownerId: crypto.randomUUID(), targetSha: "a".repeat(40) };
  for (const cancel of [false, true]) for (const own of [false, true]) {
    writeFileSync(f.gate, JSON.stringify({ version: 1, kind: "DRAINING", lease }));
    writeFileSync(f.gate + ".controller", JSON.stringify({ version: 1, lease: { generation: own ? 1 : 2, operationId: lease.operationId }, pid: process.pid, identity: "birth /bun" }));
    if (cancel) expect(updateVoiceGate({ kind: "CANCEL", lease }).kind).toBe("APPLIED");
    else withUpdateGateLock(path => persistUpdateGateState(path, { version: 1, kind: "OPEN", generation: 1, released: lease }));
    expect(existsSync(f.gate + ".controller")).toBe(!own);
  }
});

test("OPEN with an earlier lease's controller refuses before REQUEST and retains its bytes", async () => {
  const f = fixture(), stale = JSON.stringify({ version: 1,
    lease: { generation: 7, operationId: crypto.randomUUID() }, pid: process.pid, identity: "old birth /bun" });
  writeFileSync(f.gate + ".controller", stale);
  const child = Bun.spawn([process.execPath, "src/update-gate-installer.ts", "/usr/bin/true"], {
    env: { ...process.env, ...f.env }, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(1);
  expect(JSON.parse(readFileSync(f.gate, "utf8"))).toEqual({ version: 1, kind: "OPEN", generation: 0, released: null });
  expect(readFileSync(f.gate + ".controller", "utf8")).toBe(stale);
  expect(existsSync(f.gate + ".lock")).toBe(false);
  expect(existsSync(f.gate + ".voice-diag.json")).toBe(false);
});
