import { randomUUID } from "node:crypto";
import { assertInstallerSocketPath, installerProcessIdentity, installerGateContended as contended,
  retryInstallerContention as retryContention, retryInstallerAcquisition, createInstallerParticipant, type InstallerParticipant } from "./update-gate-installer-participant";
import { lstatSync, readFileSync, realpathSync, openSync, writeFileSync, fsyncSync, closeSync } from "node:fs";
import { userInfo } from "node:os";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import { acknowledgeVoiceDrain, updateVoiceGate, type ParticipantProof } from "./update-gate-admission";
import { persistInstallerController, readInstallerController, readInstallerGateState, readUpdateGateFile } from "./update-gate-storage";
import { updateGateFilePath } from "./paths";
import { sameLease, updateGateLeaseSchema, type UpdateGateLease, type UpdateGateCommand } from "./update-gate";

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
  assertInstallerSocketPath();
}
export function safeParticipantProof(read: () => { ready: boolean }): boolean {
  try { return read().ready === true; } catch { return false; }
}
// Preserve the qualified preload-only synthetic proof contract unchanged.
function harnessParticipantEvidence(): { phase: string; ready: boolean } {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  const file = process.env.VOICELAYER_TEST_INSTALL_PROOF;
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !root || !file) {
    throw Error("UNKNOWN: missing qualified harness participant proof");
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
function participantEvidence(): InstallerParticipant {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") return createInstallerParticipant();
  harnessParticipantEvidence(); // Never fall through to live sockets on a harness fault.
  return {
    async refresh(lease) {
      const proof = harnessParticipantEvidence();
      const ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
      return { ...proof, native: ack, daemon: ack };
    },
    verify: () => safeParticipantProof(harnessParticipantEvidence),
    async quit() { harnessParticipantEvidence(); },
  };
}
export async function validateInstallerOperation(): Promise<void> {
  assertGatePath();
  if (process.env.VOICELAYER_TEST_ISOLATED === "1") harnessParticipantEvidence();
  // Native/daemon are already gone. Nested helpers validate the closed lease and
  // live owning controller, never fabricate a new participant ACK after quit.
  const owner = JSON.parse(process.env.VOICELAYER_INSTALL_OPERATION!);
  const lease = updateGateLeaseSchema.parse(owner.lease);
  if (!Number.isSafeInteger(owner.pid) || owner.pid <= 0 || typeof owner.identity !== "string" || !owner.identity ||
    installerProcessIdentity(owner.pid) !== owner.identity) throw Error("UNKNOWN: installer controller identity mismatch");
  const current = await retryContention(() => readUpdateGateFile(), state => state.kind === "UNKNOWN");
  if (current.kind !== "COMMITTED" || !sameLease(current.lease, lease)) throw Error("UNKNOWN: installer lease mismatch");
  const controller = readInstallerController(updateGateFilePath());
  if (!controller || controller.lease.operationId !== lease.operationId || controller.lease.generation !== lease.generation ||
    controller.pid !== owner.pid || controller.identity !== owner.identity || controller.source !== owner.source ||
    (owner.source !== undefined && owner.source !== "supervised-bootstrap"))
    throw Error("UNKNOWN: installer controller receipt mismatch");
  if (installerProcessIdentity(controller.pid) !== controller.identity) throw Error("UNKNOWN: installer controller identity changed");
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
export type BootstrapInstall = {
  participant: InstallerParticipant;
  cancelled(): boolean;
  onRequested(lease: UpdateGateLease): void;
  onCommitted(): void;
};
export async function runGatedInstall(command: string[], harnessParticipant?: InstallerParticipant, bootstrap?: BootstrapInstall): Promise<number> {
  assertGatePath();
  if (!command.length) throw Error("UNKNOWN: missing installer command");
  if (process.env.VOICELAYER_INSTALL_OPERATION) {
    await validateInstallerOperation();
    return await Bun.spawn(command, { env: process.env, stdin: "inherit", stdout: "inherit", stderr: "inherit" }).exited;
  }
  if (!bootstrap && process.env.VOICELAYER_SUPERVISED_BOOTSTRAP === "1") {
    return await (await import("./update-gate-bootstrap")).runSupervisedBootstrap(command);
  }
  let participant = bootstrap?.participant ?? participantEvidence(); // Ordinary updates always use live participants.
  if (harnessParticipant) {
    harnessParticipantEvidence(); // Dependency injection has no unqualified production path.
    participant = harnessParticipant;
  }
  const controllerIdentity = installerProcessIdentity(process.pid);
  if (!controllerIdentity) throw Error("UNKNOWN: controller identity unavailable");
  const current = await retryContention(() => readUpdateGateFile(), state => state.kind === "UNKNOWN");
  if (current.kind !== "OPEN") throw Error("UNKNOWN: gate unavailable or another update owns it");
  // A foreign receipt is not evidence for this lease. Refuse before REQUEST;
  // recovery/finalization must remove only their own matching controller.
  try {
    lstatSync(updateGateFilePath() + ".controller");
    throw Error("UNKNOWN: existing controller receipt retained; verified recovery required");
  } catch (error) { if (!(error instanceof Error) || !("code" in error) || error.code !== "ENOENT") throw error; }
  const lease: UpdateGateLease = { generation: current.generation + 1, operationId: randomUUID(),
    ownerId: randomUUID(), targetSha: process.env.VOICELAYER_UPDATE_TARGET_SHA ?? "" };
  if (!updateGateLeaseSchema.safeParse(lease).success) throw Error("UNKNOWN: verified target SHA required");
  let requested = false, committed = false, commitAttempted = false, commitUncertain = false, cancelled = false, displayedPhase = "";
  const pastCommit = () => committed || commitUncertain;
  const signals = ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"] as const;
  const handlers = signals.map(name => {
    const handler = () => {
      if (!pastCommit()) { cancelled = true; return; }
      console.error(`[update-gate] ${name}: Cancel unavailable after COMMIT. Ctrl-C will not stop the installer; waiting for completion.`);
    };
    process.on(name, handler);
    return [name, handler] as const;
  });
  const verify: ParticipantProof = state => safeParticipantProof(() => ({ ready: participant.verify(state) }));
  const acquire = <T>(read: () => T): Promise<T> => participant.withAcquisitionProof
    ? participant.withAcquisitionProof(read) : retryInstallerAcquisition(read);
  const transition = async (command: UpdateGateCommand) => {
    const apply = () => {
      if (cancelled || bootstrap?.cancelled()) { cancelled = true; throw Error("UPDATE_CANCELLED"); }
      const confirm: ParticipantProof = state => {
        if (!verify(state)) return false;
        if (command.kind === "COMMIT") return persistInstallerController(updateGateFilePath(), {
          version: 1, lease: { generation: lease.generation, operationId: lease.operationId },
          pid: process.pid, identity: controllerIdentity,
          ...(bootstrap ? { source: "supervised-bootstrap" as const } : {}),
        });
        return true;
      };
      if (command.kind === "COMMIT") commitAttempted = true;
      const result = updateVoiceGate(command, confirm, process.env, { throwOnContention: true });
      // Publish durable COMMIT custody before an acquisition wrapper's post-check
      // can throw. No evidence check may turn this outcome back into precommit.
      if (command.kind === "COMMIT" && result.kind === "APPLIED" && result.state.kind === "COMMITTED") {
        commitUncertain = true; // Durability acknowledged; never roll back while readback waits.
        bootstrap?.onCommitted();
      }
      return result;
    };
    const result = await (requested ? acquire(apply) : retryInstallerAcquisition(apply));
    if (command.kind === "COMMIT" && result.kind === "APPLIED") {
      const persisted = await retryContention(() => readInstallerGateState(), () => false);
      committed = persisted.kind === "COMMITTED" && sameLease(persisted.lease, lease);
      commitUncertain = !committed;
      if (commitUncertain) throw Error("UNKNOWN: durable COMMIT readback unavailable; recovery required");
    }
    return result;
  };
  try {
    const request = await transition({ kind: "REQUEST", lease });
    if (request.kind !== "APPLIED") throw Error("UNKNOWN: drain request refused");
    requested = true;
    bootstrap?.onRequested(lease);
    while (!cancelled && !bootstrap?.cancelled()) {
      const proof = await participant.refresh(lease);
      if (displayedPhase !== proof.phase) {
        console.error(`[update-gate] Update when idle: ${proof.phase}; Cancel: Ctrl-C (before commit)`);
        displayedPhase = proof.phase;
      }
      const ack = await acquire(() => {
        if (cancelled || bootstrap?.cancelled()) { cancelled = true; throw Error("UPDATE_CANCELLED"); }
        return acknowledgeVoiceDrain(lease, verify, { throwOnContention: true });
      });
      if (cancelled || bootstrap?.cancelled()) { cancelled = true; break; }
      if (!ack && !contended() && readUpdateGateFile().kind === "UNKNOWN") throw Error("UNKNOWN: drain evidence unavailable");
      if (ack && proof.ready && proof.native && proof.daemon) {
        const prepared = await transition({ kind: "PREPARE", lease, native: proof.native, daemon: proof.daemon });
        if (prepared.kind !== "APPLIED") throw Error("UNKNOWN: preparation refused");
        if (cancelled || bootstrap?.cancelled()) { cancelled = true; break; } // PREPARE retries await backoff, allowing Cancel to arrive.
        // PREPARED bytes alone cannot authorize COMMIT; obtain another live round trip.
        await participant.refresh(lease);
        if (cancelled || bootstrap?.cancelled()) { cancelled = true; break; }
        const commit = await transition({ kind: "COMMIT", lease });
        if (commit.kind !== "APPLIED") throw Error("UNKNOWN: commit refused; mutation not authorized");
        // Give late fail-open admissions a chance to publish fault/ledger evidence,
        // then revalidate through G3 and G2 before issuing the final controlled quit.
        await Bun.sleep(100);
        for (let attempt = 0; ; attempt++) {
          const proof = await participant.refresh(lease);
          if (proof.ready && proof.native && proof.daemon) break;
          if (attempt === 3) throw Error("UNKNOWN: postcommit drain evidence unavailable");
          await Bun.sleep(Math.min(25 * 2 ** attempt, 250));
        }
        await participant.quit(lease); // Never retry: a written quit may already have executed.
        const env = { ...process.env, VOICELAYER_SUPERVISED_BOOTSTRAP: "", VOICELAYER_INSTALL_OPERATION: JSON.stringify({ lease, pid: process.pid, identity: controllerIdentity,
          ...(bootstrap ? { source: "supervised-bootstrap" } : {}) }) };
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
    if (commitAttempted && !pastCommit()) {
      let persisted: ReturnType<typeof readInstallerGateState>;
      try { persisted = await retryContention(() => readInstallerGateState(), () => false); }
      catch { persisted = { kind: "UNKNOWN" }; }
      committed = persisted.kind === "COMMITTED" && sameLease(persisted.lease, lease);
      commitUncertain = persisted.kind === "UNKNOWN" || (persisted.kind !== "OPEN" && !sameLease(persisted.lease, lease));
      if (pastCommit()) bootstrap?.onCommitted();
    }
    if (cancelled && !pastCommit() && error instanceof Error && error.message === "UPDATE_CANCELLED") return 130;
    if (pastCommit()) recoveryReceipt(lease, `installer failed: ${error}`);
    throw error;
  } finally {
    if (pastCommit()) console.error("[update-gate] COMMITTED or uncertain: admission retained closed pending verified completion/recovery");
    try { if (requested && !pastCommit()) await cancelLease(lease); }
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
