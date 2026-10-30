import { randomUUID } from "node:crypto";
import { existsSync, lstatSync, readFileSync, realpathSync, openSync, writeFileSync, fsyncSync, closeSync } from "node:fs";
import { userInfo } from "node:os";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { acknowledgeVoiceDrain, updateVoiceGate, type ParticipantProof } from "./update-gate-admission";
import { readUpdateGateFile } from "./update-gate-storage";
import { updateGateFilePath } from "./paths";
import { sameLease, updateGateLeaseSchema, type UpdateGateLease } from "./update-gate";

// Only the live preload owns this harness capability; environment flags alone do not qualify it.
function harnessRoot(): string {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT ?? "";
  const resolvedRoot = realpathSync(root);
  const markerPath = resolve(resolvedRoot, ".installer-harness.json");
  const marker = JSON.parse(readFileSync(markerPath, "utf8"));
  if (!resolvedRoot.startsWith(resolve(import.meta.dir, "../.test-tmp") + sep) ||
    lstatSync(root).isSymbolicLink() || lstatSync(markerPath).isSymbolicLink() ||
    !Number.isSafeInteger(marker.pid) || marker.pid <= 0 ||
    !/^[a-f0-9]{32}$/.test(marker.token) || marker.token !== process.env.VOICELAYER_TEST_INSTALL_TOKEN ||
    !resolvedRoot.split(sep).at(-1)?.startsWith(`${marker.pid}-`)) throw Error("unqualified harness capability");
  process.kill(marker.pid, 0);
  return resolvedRoot;
}
function assertGatePath(): void {
  const gate = resolve(updateGateFilePath());
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") {
    const tail = relative(harnessRoot(), gate);
    if (!tail || tail.startsWith("..") || isAbsolute(tail)) throw Error("gate escaped harness run");
  } else if (gate !== resolve(userInfo().homedir, ".local/state/voicelayer/update-gate.json")) {
    throw Error("noncanonical gate path; nothing was changed");
  }
}
const contended = () => existsSync(updateGateFilePath() + ".lock");
const backoff = (attempt: number) => Bun.sleep(Math.min(25 * 2 ** attempt, 250));
// G2 reports contention as REFUSED/UNKNOWN (ack: null), not necessarily a throw.
async function retryContention<T>(read: () => T, retry: (result: T) => boolean): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      const result = read();
      if (!retry(result) || !contended() || attempt === 7) return result;
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED" || attempt === 7) throw error;
    }
    console.error("[update-gate] Waiting for update-gate lock (bounded retry)");
    await backoff(attempt);
  }
}
export function safeParticipantProof(read: () => { ready: boolean }): boolean {
  try { return read().ready === true; } catch { return false; }
}
// G2 deliberately has no live participant/target probe. Until that adapter is
// qualified, production installation refuses UNKNOWN (including first install).
function participantEvidence(): { phase: string; ready: boolean } {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  const file = process.env.VOICELAYER_TEST_INSTALL_PROOF;
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !root || !file) {
    throw Error("UNKNOWN: nothing was changed; installer updates are disabled until live participant proof lands");
  }
  const resolvedRoot = harnessRoot(), resolvedFile = realpathSync(file);
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
export async function validateInstallerOperation(): Promise<void> {
  assertGatePath();
  participantEvidence();
  const owner = JSON.parse(process.env.VOICELAYER_INSTALL_OPERATION!);
  const lease = updateGateLeaseSchema.parse(owner.lease);
  const current = await retryContention(() => readUpdateGateFile(), state => state.kind === "UNKNOWN");
  if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0 || current.kind !== "COMMITTED" ||
    !sameLease(current.lease, lease)) throw Error("UNKNOWN: installer lease mismatch");
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
  try {
    const result = await retryContention(() => updateVoiceGate({ kind: "CANCEL", lease }), result => result.kind === "REFUSED" && result.reason === "UNKNOWN");
    if (result.kind !== "REFUSED") return;
    failure = Error(`Cancel refused: ${result.reason}`);
  } catch (error) { failure = error; }
  recoveryReceipt(lease, `precommit Cancel failed: ${failure}`);
  throw Error("RECOVERY_REQUIRED: Cancel could not restore admission; inspect the preserved lease and receipt");
}
export async function runGatedInstall(command: string[]): Promise<number> {
  assertGatePath();
  if (!command.length) throw Error("UNKNOWN: missing installer command");
  if (process.env.VOICELAYER_INSTALL_OPERATION) {
    await validateInstallerOperation();
    return await Bun.spawn(command, { env: process.env, stdin: "inherit", stdout: "inherit", stderr: "inherit" }).exited;
  }
  participantEvidence(); // No synthetic production acknowledgement or idle fallback.
  const current = await retryContention(() => readUpdateGateFile(), state => state.kind === "UNKNOWN");
  if (current.kind !== "OPEN") throw Error("UNKNOWN: gate unavailable or another update owns it");
  const lease: UpdateGateLease = { generation: current.generation + 1, operationId: randomUUID(),
    ownerId: randomUUID(), targetSha: process.env.VOICELAYER_UPDATE_TARGET_SHA ?? "" };
  if (!updateGateLeaseSchema.safeParse(lease).success) throw Error("UNKNOWN: verified target SHA required");
  let requested = false, committed = false, cancelled = false, displayedPhase = "";
  const signals = ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"] as const;
  const handlers = signals.map(name => {
    const handler = () => {
      if (!committed) { cancelled = true; return; }
      console.error(`[update-gate] ${name}: Cancel unavailable after COMMIT. Ctrl-C will not stop the installer; waiting for completion.`);
    };
    process.on(name, handler);
    return [name, handler] as const;
  });
  const verify: ParticipantProof = () => safeParticipantProof(participantEvidence);
  const transition = (command: unknown) => retryContention(() => {
    if (cancelled) throw Error("UPDATE_CANCELLED"); // Never commit after Cancel during backoff.
    return updateVoiceGate(command, verify);
  }, result => result.kind === "REFUSED" && result.reason === "UNKNOWN");
  try {
    const request = await transition({ kind: "REQUEST", lease });
    if (request.kind !== "APPLIED") throw Error("UNKNOWN: drain request refused");
    requested = true;
    while (!cancelled) {
      const proof = participantEvidence();
      if (displayedPhase !== proof.phase) {
        console.error(`[update-gate] Update when idle: ${proof.phase}; Cancel: Ctrl-C (before commit)`);
        displayedPhase = proof.phase;
      }
      const ack = await retryContention(() => acknowledgeVoiceDrain(lease, verify), result => result === null);
      if (cancelled) break;
      if (!ack && !contended() && readUpdateGateFile().kind === "UNKNOWN") throw Error("UNKNOWN: drain evidence unavailable");
      if (ack) {
        const prepared = await transition({ kind: "PREPARE", lease, native: ack, daemon: ack });
        if (prepared.kind !== "APPLIED") throw Error("UNKNOWN: preparation refused");
        if (cancelled) break; // PREPARE retries await backoff, allowing Cancel to arrive.
        const commit = await transition({ kind: "COMMIT", lease });
        if (commit.kind !== "APPLIED") throw Error("UNKNOWN: commit refused; mutation not authorized");
        committed = true;
        const env = { ...process.env, VOICELAYER_INSTALL_OPERATION: JSON.stringify({ lease, pid: process.pid }) };
        console.error("[update-gate] COMMITTED: Ctrl-C will not stop the installer; waiting for completion.");
        const child = Bun.spawn(command, { env, detached: true, stdin: "inherit", stdout: "inherit", stderr: "inherit" });
        const result = await child.exited;
        if (result !== 0) recoveryReceipt(lease, `installer exited ${result}; completion not verified`, child.pid);
        return result;
      }
      await Bun.sleep(200);
    }
    return 130;
  } catch (error) {
    if (cancelled && !committed && error instanceof Error && error.message === "UPDATE_CANCELLED") return 130;
    if (committed) recoveryReceipt(lease, `installer failed: ${error}`);
    throw error;
  } finally {
    if (committed) console.error("[update-gate] COMMITTED: admission retained closed pending verified completion/recovery");
    try { if (requested && !committed) await cancelLease(lease); }
    finally { for (const [name, handler] of handlers) process.off(name, handler); }
  }
}
if (import.meta.main) {
  const option = process.argv[2];
  if (option === "--help" || option === "-h") { console.log("Usage: update-gate-installer.ts COMMAND [ARGS...] | --validate"); process.exit(0); }
  if (!option || (option.startsWith("-") && option !== "--validate") || (option === "--validate" && process.argv.length !== 3)) {
    console.error("Usage: update-gate-installer.ts COMMAND [ARGS...] | --validate"); process.exit(2);
  }
  try {
    if (process.argv[2] === "--validate") { await validateInstallerOperation(); }
    else process.exitCode = await runGatedInstall(process.argv.slice(2));
  } catch (error) { console.error(`[update-gate] REFUSED UNKNOWN: ${String(error instanceof Error ? error.message : error).replace(/^UNKNOWN: /, "")}`); process.exitCode = 1; }
}
