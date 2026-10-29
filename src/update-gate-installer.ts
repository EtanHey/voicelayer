import { randomUUID } from "node:crypto";
import { lstatSync, readFileSync, realpathSync, openSync, writeFileSync, fsyncSync, closeSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { acknowledgeVoiceDrain, updateVoiceGate, type ParticipantProof } from "./update-gate-admission";
import { readUpdateGateFile } from "./update-gate-storage";
import { updateGateLeaseSchema, type UpdateGateLease } from "./update-gate";
import { updateGateFilePath } from "./paths";

// G2 deliberately has no live participant/target probe. Until that adapter is
// qualified, automatic production installation refuses UNKNOWN. G4b is opt-in.
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
  const owner = JSON.parse(process.env.VOICELAYER_INSTALL_OPERATION!);
  if (owner.source === "supervised-bootstrap") {
    const file = updateGateFilePath() + ".bootstrap";
    if (lstatSync(file).isSymbolicLink() || readFileSync(file, "utf8") !== JSON.stringify(owner)) throw Error("UNKNOWN: bootstrap receipt mismatch");
  } else participantEvidence();
  const lease = updateGateLeaseSchema.parse(owner.lease);
  const current = readUpdateGateFile();
  if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0 || current.kind !== "COMMITTED" ||
    JSON.stringify(current.lease) !== JSON.stringify(lease)) throw Error("UNKNOWN: installer lease mismatch");
  process.kill(owner.pid, 0); // Controller must still own the child operation.
}
function recoveryReceipt(lease: UpdateGateLease, reason: string, installerPid?: number): void {
  const gate = updateGateFilePath(), receipt = `${gate}.recovery-${lease.operationId}.json`;
  console.error(`[update-gate] RECOVERY_REQUIRED: ${reason}; admission remains closed; gate=${gate}; receipt=${receipt}`);
  try {
    const fd = openSync(receipt, "wx", 0o600);
    try { writeFileSync(fd, JSON.stringify({ lease, reason, installerPid, at: new Date().toISOString() }) + "\n"); fsyncSync(fd); }
    finally { closeSync(fd); }
    const directory = openSync(dirname(receipt), "r");
    try { fsyncSync(directory); } finally { closeSync(directory); }
  } catch (error) { console.error(`[update-gate] RECOVERY_RECEIPT_WRITE_FAILED: ${error}; durable lease remains at ${gate}`); }
}
async function cancelLease(lease: UpdateGateLease): Promise<void> {
  let failure: unknown;
  for (let attempt = 0; attempt < 8; attempt++) {
    try {
      const result = updateVoiceGate({ kind: "CANCEL", lease });
      if (result.kind !== "REFUSED") return;
      failure = Error(`Cancel refused: ${result.reason}`); break;
    } catch (error) {
      failure = error;
      if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED") break;
      if (attempt < 7) {
        console.error("[update-gate] Cancel waiting for update-gate lock (bounded retry)");
        await Bun.sleep(Math.min(25 * 2 ** attempt, 250));
      }
    }
  }
  recoveryReceipt(lease, `precommit Cancel failed: ${failure}`);
  throw Error("RECOVERY_REQUIRED: Cancel could not restore admission; inspect the preserved lease and receipt");
}
export async function runGatedInstall(command: string[], bootstrap?: { evidence: typeof participantEvidence; onCommitted: () => void }): Promise<number> {
  if (!command.length) throw Error("UNKNOWN: missing installer command");
  if (process.env.VOICELAYER_INSTALL_OPERATION) {
    validateInstallerOperation();
    return await Bun.spawn(command, { env: process.env, stdin: "inherit", stdout: "inherit", stderr: "inherit" }).exited;
  }
  if (!bootstrap && process.env.VOICELAYER_SUPERVISED_BOOTSTRAP === "1") {
    return await (await import("./update-gate-bootstrap")).runSupervisedBootstrap(command);
  }
  const evidence = bootstrap?.evidence ?? participantEvidence;
  evidence(); // No synthetic production acknowledgement or idle fallback.
  const current = readUpdateGateFile();
  if (current.kind !== "OPEN") throw Error("UNKNOWN: gate unavailable or another update owns it");
  const lease: UpdateGateLease = { generation: current.generation + 1, operationId: randomUUID(),
    ownerId: randomUUID(), targetSha: process.env.VOICELAYER_UPDATE_TARGET_SHA ?? "" };
  if (!updateGateLeaseSchema.safeParse(lease).success) throw Error("UNKNOWN: verified target SHA required");
  let requested = false, committed = false, cancelled = false, displayedPhase = "";
  let installerPid: number | undefined;
  const signal = (name: "SIGINT" | "SIGTERM") => {
    if (!committed) { cancelled = true; return; }
    recoveryReceipt(lease, `${name}: Cancel unavailable after COMMIT; installer not signalled, outcome requires recovery`, installerPid);
    process.exit(name === "SIGINT" ? 130 : 143); // Never signal/cancel the committed installer.
  };
  const interrupt = () => signal("SIGINT"), terminate = () => signal("SIGTERM");
  process.on("SIGINT", interrupt); process.on("SIGTERM", terminate);
  const verify: ParticipantProof = () => evidence().ready === true;
  try {
    const request = updateVoiceGate({ kind: "REQUEST", lease });
    if (request.kind !== "APPLIED") throw Error("UNKNOWN: drain request refused");
    requested = true;
    while (!cancelled) {
      const proof = evidence();
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
        bootstrap?.onCommitted();
        const owner = { lease, pid: process.pid, ...(bootstrap ? { source: "supervised-bootstrap" } : {}) };
        if (bootstrap) {
          const fd = openSync(updateGateFilePath() + ".bootstrap", "wx", 0o600);
          try { writeFileSync(fd, JSON.stringify(owner)); fsyncSync(fd); } finally { closeSync(fd); }
          const directory = openSync(dirname(updateGateFilePath()), "r");
          try { fsyncSync(directory); } finally { closeSync(directory); }
        }
        const env = { ...process.env, VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_INSTALL_OPERATION: JSON.stringify(owner) };
        const child = Bun.spawn(command, { env, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
        installerPid = child.pid;
        const result = await child.exited;
        return result;
      }
      await Bun.sleep(200);
    }
    return 130;
  } finally {
    if (committed) console.error("[update-gate] COMMITTED: admission retained closed pending verified completion/recovery");
    try { if (requested && !committed) await cancelLease(lease); }
    finally { process.off("SIGINT", interrupt); process.off("SIGTERM", terminate); }
  }
}
if (import.meta.main) {
  const option = process.argv[2];
  if (option === "--help" || option === "-h") { console.log("Usage: update-gate-installer.ts COMMAND [ARGS...] | --validate"); process.exit(0); }
  if (!option || (option.startsWith("-") && option !== "--validate") || (option === "--validate" && process.argv.length !== 3)) {
    console.error("Usage: update-gate-installer.ts COMMAND [ARGS...] | --validate"); process.exit(2);
  }
  try {
    if (process.argv[2] === "--validate") { validateInstallerOperation(); }
    else process.exitCode = await runGatedInstall(process.argv.slice(2));
  } catch (error) { console.error(`[update-gate] REFUSED UNKNOWN: ${error instanceof Error ? error.message : error}`); process.exitCode = 1; }
}
