import { afterEach, expect, test } from "bun:test";
import { existsSync, mkdtempSync, writeFileSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { initializeVoiceGate, initializeSupervisedVoiceGate, updateVoiceGate } from "../update-gate-admission";
import { applyUpdateGateCommand, readUpdateGateFile } from "../update-gate-storage";
import { createVoiceDrainControl } from "../update-gate-native-participant";
const savedGate = process.env.VOICELAYER_UPDATE_GATE_PATH, savedProof = process.env.VOICELAYER_TEST_INSTALL_PROOF;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = savedGate; process.env.VOICELAYER_TEST_INSTALL_PROOF = savedProof; });
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
async function fixture(request = true) {
  const gate = join(mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "proof-")), "gate");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  await initializeVoiceGate();
  if (request) expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  return gate;
}
function cancellable(gate: string) {
  expect(existsSync(gate + ".lock")).toBe(false);
  expect(existsSync(gate + ".voice-diag.json")).toBe(false);
  expect(updateVoiceGate({ kind: "CANCEL", lease }).kind).toBe("APPLIED");
  expect(readUpdateGateFile().kind).toBe("OPEN");
}
test("R1 native readiness exception returns UNKNOWN without stranding drain", async () => {
  const gate = await fixture();
  const control = createVoiceDrainControl({ async request() { throw Error("must not send"); } }, () => { throw Error("expected evidence unavailable"); });
  expect(await control(lease, "drain")).toEqual({ kind: "UNKNOWN" });
  cancellable(gate);
});
test("R1 compatibility proof exception refuses PREPARE without stranding drain", async () => {
  const gate = await fixture(), ack = { lease, activeOperations: 0, openArchives: 0 };
  expect(applyUpdateGateCommand({ kind: "PREPARE", lease, native: ack, daemon: ack }, process.env,
    () => { throw Error("expected evidence unavailable"); })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  cancellable(gate);
});

test("R1 throwing installer proof leaves no lock and Cancel restores OPEN", async () => {
  const gate = await fixture(false), root = join(gate, ".."), bin = join(root, "bin"), log = join(root, "calls");
  mkdirSync(bin); writeFileSync(log, "");
  writeFileSync(join(bin, "brew"), '#!/bin/bash\necho forbidden >> "$CALL_LOG"\n', { mode: 0o755 });
  const proof = join(root, "proof.json"); writeFileSync(proof, JSON.stringify({ phase: "idle", ready: true }));
  process.env.VOICELAYER_TEST_INSTALL_PROOF = proof;
  const runner = join(root, "throw-proof.ts");
  writeFileSync(runner, `import { runGatedInstall } from ${JSON.stringify(join(process.cwd(), "src/update-gate-installer.ts"))};
    let calls = 0;
    const pending = runGatedInstall(["brew", "install"], {
      async refresh(lease) { const ack = { lease, activeOperations: 0, openArchives: 0 }; return { phase: "idle", ready: true, native: ack, daemon: ack }; },
      verify() { calls++; throw Error("expected evidence unavailable"); },
      async quit() { throw Error("must not quit"); },
    });
    setTimeout(() => process.kill(process.pid, "SIGINT"), 350);
    process.exitCode = await pending;
    console.error("PROOF_CALLS=" + calls);`);
  const child = Bun.spawn([process.execPath, runner], { env: { ...process.env, CALL_LOG: log, PATH: `${bin}:${process.env.PATH}`,
    VOICELAYER_INSTALL_OPERATION: "", VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_UPDATE_TARGET_SHA: "a".repeat(40) },
    stdout: "pipe", stderr: "pipe", timeout: 5000 });
  expect(await child.exited).toBe(130);
  expect(await new Response(child.stderr).text()).toMatch(/PROOF_CALLS=[1-9]/);
  expect(existsSync(gate + ".lock")).toBe(false);
  expect(existsSync(gate + ".voice-diag.json")).toBe(false);
  expect(readUpdateGateFile().kind).toBe("OPEN");
  expect(readFileSync(log, "utf8")).toBe("");
});

test("R1 supervised initialization refuses adoption of another initializer's OPEN gate", async () => {
  const gate = await fixture(false), before = readFileSync(gate, "utf8");
  expect(initializeSupervisedVoiceGate()).toBe(false);
  expect(readFileSync(gate, "utf8")).toBe(before);
  expect(existsSync(gate + ".lock")).toBe(false);
  expect(existsSync(gate + ".voice-diag.json")).toBe(false);
  process.env.VOICELAYER_UPDATE_GATE_PATH = join(gate, "..", "missing");
  expect(initializeSupervisedVoiceGate()).toBe(true);
  expect(readUpdateGateFile().kind).toBe("OPEN");
});
