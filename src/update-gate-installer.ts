import { randomUUID } from "node:crypto";
import { lstatSync, readFileSync, realpathSync } from "node:fs";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { acknowledgeVoiceDrain, updateVoiceGate, type ParticipantProof } from "./update-gate-admission";
import { readUpdateGateFile } from "./update-gate-storage";
import { updateGateLeaseSchema, type UpdateGateLease } from "./update-gate";

// G2 deliberately has no live participant/target probe. Until that adapter is
// qualified, production installation refuses UNKNOWN (including first install).
function participantEvidence(): { phase: string; ready: boolean } {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  const file = process.env.VOICELAYER_TEST_INSTALL_PROOF;
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !root || !file) {
    throw Error("UNKNOWN: live native/daemon/target proof unavailable; bootstrap/recovery qualification required");
  }
  const resolvedRoot = realpathSync(root), resolvedFile = realpathSync(file);
  const tail = relative(resolvedRoot, resolvedFile);
  if (!resolvedRoot.startsWith(resolve(import.meta.dir, "../.test-tmp") + sep) ||
    !tail || tail.startsWith("..") || isAbsolute(tail) || lstatSync(file).isSymbolicLink()) {
    throw Error("UNKNOWN: harness evidence escaped isolated run");
  }
  const proof = JSON.parse(readFileSync(resolvedFile, "utf8"));
  if (typeof proof.phase !== "string" || !/^[a-z -]{1,60}$/.test(proof.phase) ||
    typeof proof.ready !== "boolean") throw Error("UNKNOWN: malformed harness proof");
  return proof;
}
export function validateInstallerOperation(): void {
  participantEvidence();
  const owner = JSON.parse(process.env.VOICELAYER_INSTALL_OPERATION!);
  const lease = updateGateLeaseSchema.parse(owner.lease);
  const current = readUpdateGateFile();
  if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0 || current.kind !== "COMMITTED" ||
    JSON.stringify(current.lease) !== JSON.stringify(lease)) throw Error("UNKNOWN: installer lease mismatch");
  process.kill(owner.pid, 0); // Controller must still own the child operation.
}
export async function runGatedInstall(command: string[]): Promise<number> {
  if (!command.length) throw Error("UNKNOWN: missing installer command");
  if (process.env.VOICELAYER_INSTALL_OPERATION) {
    validateInstallerOperation();
    return await Bun.spawn(command, { env: process.env, stdin: "inherit", stdout: "inherit", stderr: "inherit" }).exited;
  }
  participantEvidence(); // No synthetic production acknowledgement or idle fallback.
  const current = readUpdateGateFile();
  if (current.kind !== "OPEN") throw Error("UNKNOWN: gate unavailable or another update owns it");
  const lease: UpdateGateLease = { generation: current.generation + 1, operationId: randomUUID(),
    ownerId: randomUUID(), targetSha: process.env.VOICELAYER_UPDATE_TARGET_SHA ?? "" };
  if (!updateGateLeaseSchema.safeParse(lease).success) throw Error("UNKNOWN: verified target SHA required");
  let requested = false, committed = false, cancelled = false, displayedPhase = "";
  const cancel = () => { if (!committed) cancelled = true; };
  process.on("SIGINT", cancel); process.on("SIGTERM", cancel);
  const verify: ParticipantProof = () => participantEvidence().ready === true;
  try {
    const request = updateVoiceGate({ kind: "REQUEST", lease });
    if (request.kind !== "APPLIED") throw Error("UNKNOWN: drain request refused");
    requested = true;
    while (!cancelled) {
      const proof = participantEvidence();
      if (displayedPhase !== proof.phase) {
        console.error(`[update-gate] Update when idle: ${proof.phase}; Cancel: Ctrl-C (before commit)`);
        displayedPhase = proof.phase;
      }
      const ack = acknowledgeVoiceDrain(lease, verify);
      if (ack) {
        const prepared = updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, verify);
        if (prepared.kind !== "APPLIED") throw Error("UNKNOWN: preparation refused");
        if (cancelled) break;
        const commit = updateVoiceGate({ kind: "COMMIT", lease }, verify);
        if (commit.kind !== "APPLIED") throw Error("UNKNOWN: commit refused; mutation not authorized");
        committed = true;
        const env = { ...process.env, VOICELAYER_INSTALL_OPERATION: JSON.stringify({ lease, pid: process.pid }) };
        const child = Bun.spawn(command, { env, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
        const result = await child.exited;
        return result;
      }
      await Bun.sleep(200);
    }
    return 130;
  } finally {
    if (committed) console.error("[update-gate] COMMITTED: admission retained closed pending verified completion/recovery");
    if (requested && !committed) {
      const result = updateVoiceGate({ kind: "CANCEL", lease });
      if (result.kind === "REFUSED") throw Error("UNKNOWN: Cancel requires recovery; admission retained closed");
    }
    process.off("SIGINT", cancel); process.off("SIGTERM", cancel);
  }
}
if (import.meta.main) {
  try {
    if (process.argv[2] === "--validate") { validateInstallerOperation(); }
    else process.exitCode = await runGatedInstall(process.argv.slice(2));
  } catch (error) { console.error(`[update-gate] REFUSED UNKNOWN: ${error instanceof Error ? error.message : error}`); process.exitCode = 1; }
}
