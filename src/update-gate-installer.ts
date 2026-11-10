import { drainLedgerStatus, formatDrainStatus, type PendingParticipant } from "./update-gate-drain-status";
import { randomUUID } from "node:crypto";
import { assertInstallerSocketPath, installerProcessIdentity, retryInstallerContention as retryContention, retryInstallerAcquisition, createInstallerParticipant, UnsafeSuccessorError, type InstallerParticipant, type InstallerEvidence } from "./update-gate-installer-participant";
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
export function assertGatePath(): void {
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
/** Read-only identity fence shared by postflight and its internal startup helper. */
export function hasLiveInstallerController(): boolean {
  assertGatePath();
  const controller = readInstallerController(updateGateFilePath());
  return controller !== null && installerProcessIdentity(controller.pid) === controller.identity;
}
export function assertSetupAvailability(): void {
  if (process.env.VOICELAYER_SETUP_AVAILABILITY !== "1" || process.env.VOICELAYER_INSTALL_OPERATION)
    throw Error("UNKNOWN: availability restoration requires the internal setup marker");
  if (hasLiveInstallerController()) throw Error("UNKNOWN: live installer controller owns restoration");
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
type InstalledTarget = { sha: string; unchanged(): boolean };
type CompletionEvidence = { participant: InstallerParticipant; installed(): InstalledTarget;
  clock?: { now(): number; sleep(ms: number): Promise<void> } };
/** Parse the installed bytes outside G1; compare those exact bytes inside G1. */
export function readInstalledTarget(path = "/Applications/VoiceBar.app/Contents/Info.plist"): InstalledTarget {
  if (path !== "/Applications/VoiceBar.app/Contents/Info.plist" && process.env.VOICELAYER_TEST_ISOLATED !== "1")
    throw Error("UNKNOWN: noncanonical installed bundle");
  const bytes = readFileSync(path);
  const result = Bun.spawnSync(["/usr/bin/plutil", "-extract", "GitCommit", "raw", "-o", "-", "-"],
    { env: process.env, stdin: bytes, stdout: "pipe", stderr: "pipe", timeout: 1000 });
  const sha = result.stdout.toString().trim();
  if (result.exitCode !== 0 || !/^[0-9a-f]{40}$/.test(sha)) throw Error("UNKNOWN: installed GitCommit unavailable");
  return { sha, unchanged: () => { try { return readFileSync(path).equals(bytes); } catch { return false; } } };
}
function harnessCompletionEvidence(): CompletionEvidence {
  const read = () => {
    harnessParticipantEvidence();
    const value = JSON.parse(readFileSync(process.env.VOICELAYER_TEST_INSTALL_PROOF!, "utf8")).completion;
    if (!value || typeof value.ready !== "boolean" || !/^[0-9a-f]{40}$/.test(value.installedSha ?? ""))
      throw Error("UNKNOWN: missing qualified harness completion proof");
    return value as { ready: boolean; installedSha: string };
  };
  return {
    installed() { const sha = read().installedSha; return { sha, unchanged: () => read().installedSha === sha }; },
    participant: {
      async refresh(lease) { const p = read(), ack = { lease, activeOperations: 0 as const, openArchives: 0 as const };
        return { phase: "synthetic successor", ready: p.ready, native: ack, daemon: ack }; },
      verify: () => read().ready, quit: async () => {},
    },
  };
}
/** Refresh proofs after acquisition timeout; never stretch a receipt across the budget. */
async function finishWithSuccessor(lease: UpdateGateLease, evidence: CompletionEvidence,
  custody: ParticipantProof, beforeAcquisition: () => void = () => {}): Promise<void> {
  const installed = evidence.installed(), successor = evidence.participant;
  if (installed.sha !== lease.targetSha) throw Error("installed GitCommit does not match lease.targetSha");
  const clock = evidence.clock ?? { now: () => performance.now(), sleep: (ms: number) => Bun.sleep(ms) };
  const deadline = clock.now() + 60_000;
  for (let attempt = 1, backoff = 100; ; attempt++, backoff = Math.min(backoff * 2, 1000)) {
    let acquiring = false;
    try {
      const proof = await successor.refresh(lease);
      if (!proof.ready || !proof.native || !proof.daemon || !sameLease(proof.native.lease, lease) || !sameLease(proof.daemon.lease, lease))
        throw Error(`new participants not verified: ${proof.phase}`);
      if (clock.now() >= deadline) throw Error("successor readiness deadline passed");
      beforeAcquisition(); // Process sampling stays outside G1.
      const apply = () => updateVoiceGate({ kind: "COMPLETE", lease, installerExitCode: 0,
        installedSha: installed.sha, participantsVerified: true }, state => safeParticipantProof(() => ({
          ready: clock.now() < deadline && state.kind === "COMMITTED" && sameLease(state.lease, lease) &&
            custody(state) && installed.unchanged() && successor.verify(state),
        })), process.env, { throwOnContention: true });
      acquiring = true;
      const result = successor.withCompletionProof ? await successor.withCompletionProof(apply) : await retryInstallerAcquisition(apply);
      if (result.kind === "REFUSED") throw Error(`COMPLETE refused: ${result.reason}`);
      return;
    } catch (error) {
      if (error instanceof UnsafeSuccessorError || (acquiring && !(error instanceof Error &&
        error.message === "UNKNOWN: update-gate lock acquisition timed out"))) throw error;
      console.error(`[update-gate] Successor readiness attempt ${attempt} failed: ${error}`);
      const remaining = deadline - clock.now();
      if (remaining <= 0) throw Error(`successor readiness deadline passed: ${error}`);
      await clock.sleep(Math.min(backoff, remaining));
      if (clock.now() >= deadline) throw Error(`successor readiness deadline passed: ${error}`);
    }
  }
}
export async function completeGatedInstall(lease: UpdateGateLease, exitCode: number, identity: string,
  harness?: CompletionEvidence, previous?: InstallerParticipant, installerPid?: number): Promise<boolean> {
  try {
    assertGatePath();
    if (harness) harnessParticipantEvidence();
    if (exitCode !== 0) throw Error(`installer exited ${exitCode}; completion not verified`);
    if (installerProcessIdentity(process.pid) !== identity) throw Error("controller process identity changed");
    await finishWithSuccessor(lease, harness ?? (process.env.VOICELAYER_TEST_ISOLATED === "1" ? harnessCompletionEvidence() : {
      installed: readInstalledTarget,
      participant: previous?.successor ? previous.successor() : createInstallerParticipant(undefined, null),
    }), () => {
      const controller = readInstallerController(updateGateFilePath());
      return controller?.pid === process.pid && controller.identity === identity &&
        controller.lease.operationId === lease.operationId && controller.lease.generation === lease.generation;
    });
    console.error("[update-gate] COMPLETE: verified installed target and new participants; admission OPEN.");
    return true;
  } catch (error) {
    recoveryReceipt(lease, `completion failed: ${error}`, installerPid);
    console.error("[update-gate] The next matching VoiceBar launch will verify and recover an abandoned COMMITTED lease automatically; retain recovery evidence.");
    return false;
  }
}

/** Availability backstop, never installer authorization. No rollback or half-state repair.
 * A reaped controller cannot become live again; PID reuse/unknown identity refuses.
 * Observe death for five seconds, then recheck custody under G1. The verified
 * running target replaces the unavailable old controller's exit receipt. */
export async function recoverAbandonedUpdate(ownSha = process.env.VOICEBAR_GIT_COMMIT,
  harness?: CompletionEvidence & { controllerIdentity(pid: number): string | null }): Promise<boolean> {
  try {
    assertGatePath();
    if (harness) harnessParticipantEvidence();
    if (!ownSha || !/^[0-9a-f]{40}$/.test(ownSha)) return false;
    const evidence: CompletionEvidence = harness ?? { installed: readInstalledTarget, participant: createInstallerParticipant(undefined, null) };
    const clock = evidence.clock ?? { now: () => performance.now(), sleep: (ms: number) => Bun.sleep(ms) };
    const identity = harness?.controllerIdentity ?? installerProcessIdentity;
    const deadline = clock.now() + 60_000;
    let abandonedAt: number | undefined;
    let observedCustody: string | undefined;
    for (;;) {
      const state = await retryInstallerAcquisition(() => readInstallerGateState(), deadline, clock, 30_000);
      if (state.kind !== "COMMITTED" || state.lease.targetSha !== ownSha) return false;
      const lease = state.lease, controller = readInstallerController(updateGateFilePath());
      if (!controller || controller.lease.operationId !== lease.operationId || controller.lease.generation !== lease.generation) return false;
      const bytes = JSON.stringify(controller);
      const custody = JSON.stringify({ lease, controller });
      if (custody !== observedCustody) abandonedAt = undefined;
      observedCustody = custody;
      if (identity(controller.pid) !== null) abandonedAt = undefined;
      else abandonedAt ??= clock.now();
      if (abandonedAt !== undefined && clock.now() - abandonedAt >= 5000) {
        // The observed dead incarnation cannot revive. Sample again outside G1;
        // only unchanged custody is read inside the short publication section.
        await finishWithSuccessor(lease, evidence,
          () => JSON.stringify(readInstallerController(updateGateFilePath())) === bytes,
          () => { if (identity(controller.pid) !== null) throw new UnsafeSuccessorError("controller absence changed"); });
        console.error("[update-gate] Recovered abandoned COMMITTED lease: verified successor COMPLETE; admission OPEN.");
        return true;
      }
      if (clock.now() >= deadline) return false;
      await clock.sleep(Math.min(250, deadline - clock.now()));
    }
  } catch (error) {
    console.error(`[update-gate] Successor recovery deferred; gate and custody retained: ${error}`);
    return false;
  }
}
async function cancelLease(lease: UpdateGateLease): Promise<void> {
  let failure: unknown;
  try {
    // Retry the failed acquisition even if its holder releases before we decide.
    const result = await retryContention(() => updateVoiceGate({ kind: "CANCEL", lease }, undefined,
      process.env, { throwOnContention: true }), () => false);
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
export const DEFAULT_DRAIN_TIMEOUT_MS = 120_000;
const PREPARED_RECHECK_TIMEOUT_MS = 2000;
function drainTimeoutMs(): number {
  const value = process.env.VOICELAYER_UPDATE_DRAIN_TIMEOUT_MS;
  if (value === undefined) return DEFAULT_DRAIN_TIMEOUT_MS;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0 || parsed > DEFAULT_DRAIN_TIMEOUT_MS)
    throw Error("invalid VOICELAYER_UPDATE_DRAIN_TIMEOUT_MS (1..120000)");
  return parsed;
}
function writeDrainReceipt(lease: UpdateGateLease, reason: string, status: string): void {
  const path = `${updateGateFilePath()}.drain-${lease.operationId}.json`;
  const fd = openSync(path, "wx", 0o600);
  try { writeFileSync(fd, JSON.stringify({ lease, reason, status, at: new Date().toISOString() }) + "\n"); fsyncSync(fd); }
  finally { closeSync(fd); }
  const directory = openSync(dirname(path), "r");
  try { fsyncSync(directory); } finally { closeSync(directory); }
}
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
  const current = await retryContention(() => readInstallerGateState(), () => false);
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
  const drainBudget = drainTimeoutMs();
  let drainDeadline = Infinity, preparedDeadline = Infinity, timedOut = false, timeoutReason = "", lastStatus = "", lastProof: InstallerEvidence | undefined;
  let requested = false, committed = false, commitAttempted = false, commitUncertain = false, completed = false, cancelled = false, displayedPhase = "";
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
  const pending = (): PendingParticipant[] => lastProof?.pending ?? (lastProof?.ready ? [] :
    (["native", "daemon"] as const).map(participant => ({ participant, reply: lastProof?.phase ?? "no reply" })));
  const status = () => formatDrainStatus(pending(), drainLedgerStatus());
  const checkPrecommit = () => {
    if (cancelled || bootstrap?.cancelled()) { cancelled = true; throw Error("UPDATE_CANCELLED"); }
    if (performance.now() >= Math.min(drainDeadline, preparedDeadline)) {
      timedOut = true; lastStatus = status();
      timeoutReason = preparedDeadline < drainDeadline ? `prepared recheck timed out after ${PREPARED_RECHECK_TIMEOUT_MS} ms`
        : `drain timed out after ${drainBudget} ms`;
      throw Error(`${timeoutReason}: ${lastStatus}`);
    }
  };
  // Bound even a participant that never settles. A late read-only refresh cannot
  // authorize a transition: every locked mutation checks the deadline again.
  const waitPrecommit = <T>(work: Promise<T>): Promise<T> => new Promise((resolve, reject) => {
    const timer = setInterval(() => { try { checkPrecommit(); } catch (error) { clearInterval(timer); reject(error); } }, 10);
    work.then(value => { clearInterval(timer); try { checkPrecommit(); resolve(value); } catch (error) { reject(error); } },
      error => { clearInterval(timer); reject(error); });
  });
  const refreshPrecommit = async () => {
    checkPrecommit();
    const observed = lastProof?.participants ?? lastProof?.pending;
    lastProof = { ready: false, phase: "no reply", pending: observed?.map(p => ({ ...p, reply: "no reply" })) };
    try { lastProof = await waitPrecommit(participant.refresh(lease)); }
    catch (error) {
      if (!(error && typeof error === "object" && "replyLost" in error && error.replyLost === true)) throw error;
      lastProof = { ready: false, phase: "no reply" };
    }
    checkPrecommit();
    lastStatus = status();
    if (displayedPhase !== lastStatus) {
      console.error(`[update-gate] Update when idle: ${lastStatus}; Cancel: Ctrl-C (before commit)`);
      displayedPhase = lastStatus;
    }
    return lastProof;
  };
  const verify: ParticipantProof = state => safeParticipantProof(() => ({ ready: participant.verify(state) }));
  const acquire = <T>(read: () => T): Promise<T> => participant.withAcquisitionProof
    ? participant.withAcquisitionProof(read) : retryInstallerAcquisition(read);
  const transition = async (command: UpdateGateCommand) => {
    const apply = () => {
      checkPrecommit();
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
    drainDeadline = performance.now() + drainBudget;
    bootstrap?.onRequested(lease);
    while (!cancelled && !bootstrap?.cancelled()) {
      const proof = await refreshPrecommit();
      const ack = await acquire(() => {
        checkPrecommit();
        return acknowledgeVoiceDrain(lease, verify, { throwOnContention: true });
      });
      if (cancelled || bootstrap?.cancelled()) { cancelled = true; break; }
      if (!ack) {
        const drained = await retryContention(() => readInstallerGateState(), () => false);
        if (drained.kind === "UNKNOWN") throw Error("UNKNOWN: drain evidence unavailable");
      }
      if (ack && proof.ready && proof.native && proof.daemon) {
        const prepared = await transition({ kind: "PREPARE", lease, native: proof.native, daemon: proof.daemon });
        if (prepared.kind !== "APPLIED") {
          // A registration can land after the ACK and before PREPARE's lock.
          // Preserve the in-lock refusal and retry the entire proof round.
          const state = await retryContention(() => readInstallerGateState(), () => false);
          if (state.kind !== "DRAINING" || !sameLease(state.lease, lease)) throw Error("UNKNOWN: preparation refused");
          await waitPrecommit(Bun.sleep(20)); continue;
        }
        preparedDeadline = performance.now() + PREPARED_RECHECK_TIMEOUT_MS;
        if (cancelled || bootstrap?.cancelled()) { cancelled = true; break; } // PREPARE retries await backoff, allowing Cancel to arrive.
        // PREPARED bytes alone cannot authorize COMMIT; obtain another live round trip.
        const refreshed = await refreshPrecommit();
        if (!refreshed.ready || !refreshed.native || !refreshed.daemon) {
          // PREPARED no longer admits voice; do not park a failed recheck here.
          throw Error(`UNKNOWN: prepared participant recheck refused: ${lastStatus}`);
        }
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
        completed = await completeGatedInstall(lease, result, controllerIdentity, undefined, participant, child.pid);
        return completed ? 0 : result || 1;
      }
      await waitPrecommit(Bun.sleep(Math.min(200, drainDeadline - performance.now())));
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
    if (pastCommit() && !completed) console.error("[update-gate] COMMITTED or uncertain: admission retained closed pending verified completion/recovery");
    try {
      if (requested && !pastCommit()) {
        await cancelLease(lease);
        if (timedOut) {
          console.error(`[update-gate] ${timeoutReason}; CANCEL restored OPEN: ${lastStatus}`);
          writeDrainReceipt(lease, timeoutReason, lastStatus);
        }
      }
    }
    finally { for (const [name, handler] of handlers) process.off(name, handler); }
  }
}
if (import.meta.main) {
  const option = process.argv[2];
  if (option === "--help" || option === "-h") { console.log("Usage: update-gate-installer.ts COMMAND [ARGS...] | --validate"); process.exit(0); }
  if (!option || (option.startsWith("-") && option !== "--validate" && option !== "--setup-availability") ||
      ((option === "--validate" || option === "--setup-availability") && process.argv.length !== 3)) {
    console.error("Usage: update-gate-installer.ts COMMAND [ARGS...] | --validate"); process.exit(2);
  }
  try {
    if (process.argv[2] === "--setup-availability") { assertSetupAvailability(); }
    else if (process.argv[2] === "--validate") { await validateInstallerOperation(); }
    else process.exitCode = await runGatedInstall(process.argv.slice(2));
  } catch (error) { console.error(`[update-gate] REFUSED UNKNOWN: ${String(error instanceof Error ? error.message : error).replace(/^UNKNOWN: /, "")}`); process.exitCode = 1; }
}
