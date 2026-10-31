import { createConnection } from "node:net";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { getMcpSocketPath, updateGateFilePath } from "./paths";
import { readSpeechSecret } from "./speech-control";
import { acknowledgeVoiceDrain, type ParticipantProof } from "./update-gate-admission";
import { sameLease, updateGateAckSchema, type UpdateGateLease } from "./update-gate";

const unknownSchema = z.strictObject({ kind: z.literal("UNKNOWN") });
const identitySchema = z.strictObject({ pid: z.number().int().positive().safe(), incarnation: z.uuid() });
const receiptSchema = z.strictObject({ kind: z.literal("ACKNOWLEDGED"), native: updateGateAckSchema,
  daemon: updateGateAckSchema, identities: z.strictObject({ native: identitySchema, daemon: identitySchema }) });
type Receipt = z.infer<typeof receiptSchema>;
type Identities = Receipt["identities"];
type ProcessProof = { identities: Identities; native: string; daemon: string };
export type InstallerEvidence = { phase: string; ready: boolean; native?: Receipt["native"]; daemon?: Receipt["daemon"] };
export interface InstallerParticipant {
  refresh(lease: UpdateGateLease): Promise<InstallerEvidence>;
  verify: ParticipantProof;
  /** Process-table reads bracket a locked operation; verify itself is memory-only. */
  withProcessProof?<T>(read: () => T): T;
  quit(lease: UpdateGateLease): Promise<void>;
}
export interface InstallerParticipantDependencies {
  request(action: "drain" | "quit", lease: UpdateGateLease): Promise<unknown>;
  processIdentity(pid: number): string | null;
  processParent(pid: number): number | null;
  participantsExited(proof: ProcessProof): boolean | "UNKNOWN";
  now(): number;
  sleep(ms?: number): Promise<void>;
}

/** Production installer transport is pinned; isolated tests keep their private sockets. */
export function assertInstallerSocketPath(env: NodeJS.ProcessEnv = process.env, path = getMcpSocketPath(env)): void {
  if (env.VOICELAYER_TEST_ISOLATED !== "1" && resolve(path) !== "/tmp/voicelayer-mcp.sock")
    throw Error("UNKNOWN: noncanonical MCP socket path; nothing was changed");
}
export const installerGateContended = () => existsSync(updateGateFilePath() + ".lock");
/** Retry only a failed non-blocking mkdir acquisition, never an RPC or a gate fault. */
export async function retryInstallerContention<T>(read: () => T, retry: (result: T) => boolean,
  sleep = (attempt: number) => Bun.sleep(Math.min(25 * 2 ** attempt, 250))): Promise<T> {
  for (let attempt = 0; ; attempt++) {
    try {
      const result = read();
      if (!retry(result) || !installerGateContended() || attempt === 7) return result;
    } catch (error) {
      if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED" || attempt === 7) throw error;
    }
    console.error("[update-gate] Waiting for update-gate lock (bounded retry)");
    await sleep(attempt);
  }
}

/** No retries: a written quit may already have executed when the socket closes. */
export function requestInstallerControl(action: "drain" | "quit", lease: UpdateGateLease,
  options: { socketPath?: string; token?: string } = {}): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let issued = false, settled = false, buffer = "";
    const id = randomUUID();
    const path = options.socketPath ?? getMcpSocketPath();
    assertInstallerSocketPath(process.env, path);
    const socket = createConnection(path);
    const finish = (error?: string, value?: unknown, replyLost = false) => {
      if (settled) return;
      settled = true; clearTimeout(timer); socket.destroy();
      if (error) reject(Object.assign(Error(`UNKNOWN: ${error}`), { issued, replyLost })); else resolve(value);
    };
    const timer = setTimeout(() => finish("participant reply timed out", undefined, true), 2000);
    socket.setEncoding("utf8");
    socket.on("connect", () => {
      try {
        const token = options.token ?? readSpeechSecret();
        socket.write(JSON.stringify({ jsonrpc: "2.0", id, method: "voicelayer/speech",
          params: { cmd: `update_gate_${action}`, lease, token } }) + "\n");
        issued = true;
      } catch { finish("participant request unavailable"); }
    });
    socket.on("data", data => {
      buffer += data;
      if (buffer.length > 64 * 1024) { finish("oversized participant reply"); return; }
      let newline: number;
      while ((newline = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
        try {
          const reply = JSON.parse(line);
          if (reply.id !== id) continue;
          if (reply.jsonrpc !== "2.0" || reply.error || !("result" in reply)) finish("invalid participant RPC reply");
          else finish(undefined, reply.result);
        } catch { finish("malformed participant RPC reply"); }
      }
    });
    socket.on("error", () => finish("participant disconnected", undefined, true));
    socket.on("close", () => finish("participant closed before reply", undefined, true));
  });
}

/** Birth plus executable name fence PID reuse. Unknown process-table reads refuse. */
export function installerProcessIdentity(pid: number): string | null {
  const result = Bun.spawnSync(["/bin/ps", "-p", String(pid), "-o", "lstart=", "-o", "comm="], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 1000 });
  const identity = result.stdout.toString().trim();
  if (result.exitCode === 0 && identity) return identity;
  if (result.exitCode === 1 && !identity) {
    try { process.kill(pid, 0); } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ESRCH") return null;
    }
  }
  throw Error("UNKNOWN: participant process identity unavailable");
}
function processParent(pid: number): number | null {
  const result = Bun.spawnSync(["/bin/ps", "-p", String(pid), "-o", "ppid="], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 1000 });
  const value = result.stdout.toString().trim();
  if (result.exitCode === 0 && /^[1-9]\d*$/.test(value) && Number.isSafeInteger(Number(value))) return Number(value);
  return null;
}
function readProcessTable(): string {
  const result = Bun.spawnSync(["/bin/ps", "-axo", "pid=,comm="], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 1000 });
  if (result.exitCode !== 0) throw Error("UNKNOWN: process table unavailable");
  return result.stdout.toString();
}
export function observeInstallerExit(proof: ProcessProof, probes = { identity: installerProcessIdentity, table: readProcessTable }): boolean | "UNKNOWN" {
  try {
    const native = probes.identity(proof.identities.native.pid), daemon = probes.identity(proof.identities.daemon.pid);
    const stillExiting = (current: string | null, pinned: string) => {
      // macOS preserves lstart but replaces comm with <defunct> until reaping.
      const zombie = current?.match(/^(.{24})\s+<defunct>$/);
      return !!zombie && pinned.slice(0, 24) === zombie[1];
    };
    if ((native !== null && native !== proof.native && !stillExiting(native, proof.native)) ||
      (daemon !== null && daemon !== proof.daemon && !stillExiting(daemon, proof.daemon))) return "UNKNOWN";
    if (native !== null || daemon !== null) return false;
    // A new/competing native owner is never evidence that replacement is safe.
    const rows = probes.table().split("\n").map(line => line.trim()).filter(Boolean);
    if (!rows.length) return "UNKNOWN";
    for (const row of rows) {
      const parsed = /^([1-9]\d*)\s+(.+)$/.exec(row);
      if (!parsed || !Number.isSafeInteger(Number(parsed[1]))) return "UNKNOWN";
      if (/(?:^|\/)VoiceBar$/.test(parsed[2]!)) return "UNKNOWN";
    }
    return true;
  } catch { return "UNKNOWN"; }
}

/** Each refresh obtains a fresh authenticated G3 round trip, never persisted ACKs. */
export function createInstallerParticipant(deps: InstallerParticipantDependencies = {
  request: requestInstallerControl, processIdentity: installerProcessIdentity, processParent, participantsExited: observeInstallerExit,
  now: () => performance.now(), sleep: (ms = 100) => Bun.sleep(ms),
}): InstallerParticipant {
  let evidence: Receipt | undefined, observedAt = 0, pinned: ProcessProof | undefined;
  const fresh = () => deps.now() - observedAt >= 0 && deps.now() - observedAt <= 1000;
  const processProof = (identities: Identities): ProcessProof => {
    const native = deps.processIdentity(identities.native.pid), daemon = deps.processIdentity(identities.daemon.pid);
    const nativeExecutable = native?.replace(/^.{24}\s+/, ""); // Strip ps lstart, retaining the full comm.
    if (!native || !daemon || !/(?:^|\/)VoiceBar$/.test(nativeExecutable ?? "") || /\s<defunct>$/.test(daemon) ||
      deps.processParent(identities.daemon.pid) !== identities.native.pid)
      throw Error("UNKNOWN: participant process identity or role unavailable");
    return { identities, native, daemon };
  };
  const verify: ParticipantProof = state => !!evidence && !!pinned && state.kind !== "OPEN" &&
    sameLease(state.lease, evidence.native.lease) && fresh();
  const sampleProcessProof = () => {
    if (!evidence || !pinned) throw Error("UNKNOWN: participant identity unavailable");
    const current = processProof(pinned.identities);
    if (!fresh() || JSON.stringify(current) !== JSON.stringify(pinned))
      throw Error("UNKNOWN: participant identity changed or receipt expired");
  };
  const withProcessProof = <T>(read: () => T): T => {
    if (!evidence || !pinned) return read(); // The in-lock verifier will refuse absent evidence.
    try { sampleProcessProof(); const result = read(); sampleProcessProof(); return result; }
    catch (error) { evidence = undefined; throw error; }
  };
  // EEXIST is reported by mkdir itself. Retry acquisition before any after-sample,
  // without observing whether the other owner's lock is still present. At most
  // 99 short sleeps (198 ms), also fenced by elapsed time and receipt/exit expiry.
  const retryAcquire = async <T>(read: () => T, deadline: number): Promise<T> => {
    for (let attempt = 0; attempt < 100; attempt++) {
      try { return read(); }
      catch (error) {
        if (!(error instanceof Error) || error.message !== "UPDATE_GATE_LOCKED") throw error;
        if (attempt === 99 || deps.now() + 2 >= deadline)
          throw Error("UNKNOWN: update-gate lock acquisition timed out");
      }
      await deps.sleep(2); // Failed acquisition owns no lock.
      if (deps.now() >= deadline) throw Error("UNKNOWN: update-gate lock acquisition timed out");
    }
    throw Error("UNKNOWN: update-gate lock acquisition exhausted");
  };
  return {
    verify, withProcessProof,
    async refresh(lease) {
      evidence = undefined; // A failed/new request invalidates the preceding receipt.
      const requestedAt = deps.now();
      const reply = await deps.request("drain", lease);
      if (unknownSchema.safeParse(reply).success)
        return { phase: "waiting for live participants", ready: false };
      const parsed = receiptSchema.safeParse(reply);
      if (!parsed.success || !sameLease(parsed.data.native.lease, lease) || !sameLease(parsed.data.daemon.lease, lease) ||
        parsed.data.identities.native.pid === parsed.data.identities.daemon.pid)
        throw Error("UNKNOWN: malformed or mismatched participant acknowledgements");
      if (deps.now() - requestedAt < 0 || deps.now() - requestedAt > 1000) throw Error("UNKNOWN: stale participant round trip");
      const proof = processProof(parsed.data.identities);
      if (deps.now() - requestedAt < 0 || deps.now() - requestedAt > 1000) throw Error("UNKNOWN: stale participant round trip");
      if (pinned && JSON.stringify(proof) !== JSON.stringify(pinned)) throw Error("UNKNOWN: participant identity changed during drain");
      pinned = proof; // Only a fresh, role-checked round trip may pin identities.
      evidence = parsed.data; observedAt = requestedAt;
      return { phase: "idle", ready: true, native: evidence.native, daemon: evidence.daemon };
    },
    async quit(lease) {
      // Under G1's lock, recheck lease, diagnostics, ledger and last live identities.
      let authorized: ReturnType<typeof acknowledgeVoiceDrain>;
      try {
        sampleProcessProof();
        authorized = await retryAcquire(() => acknowledgeVoiceDrain(lease,
          state => state.kind === "COMMITTED" && verify(state), { throwOnContention: true }),
          Math.min(deps.now() + 250, observedAt + 1000));
        sampleProcessProof();
      } catch (error) { evidence = undefined; throw error; }
      if (!authorized || !pinned) throw Error("UNKNOWN: controlled quit not authorized");
      evidence = undefined;
      let reply: unknown;
      try { reply = await deps.request("quit", lease); }
      catch (error) {
        if (!(error && typeof error === "object" && "issued" in error && error.issued === true && "replyLost" in error && error.replyLost === true))
          throw Error("UNKNOWN: controlled quit delivery or reply invalid; gate retained closed");
        console.error("[update-gate] Controlled-quit reply lost; verifying participant exit and held lease.");
      }
      if (unknownSchema.safeParse(reply).success) {
        // G3 also returns UNKNOWN when its native waiter disconnects after quit.
        // This response proves no idle state; only the exit observation below can.
        console.error("[update-gate] Controlled-quit acknowledgement unavailable; verifying participant exit and held lease.");
      } else if (reply !== undefined) {
        // Quit receipts may arrive after the native process exits; validate the
        // envelope and pinned identities without requiring that process alive.
        const parsed = receiptSchema.safeParse(reply);
        if (!parsed.success || !sameLease(parsed.data.native.lease, lease) || !sameLease(parsed.data.daemon.lease, lease) ||
          JSON.stringify(parsed.data.identities) !== JSON.stringify(pinned.identities))
          throw Error("UNKNOWN: controlled quit refused or mismatched; gate retained closed");
      }
      const deadline = deps.now() + 5000;
      for (;;) {
        // Both expensive process samples run outside the mkdir lock. Only the
        // lease/diagnostic/ledger snapshot is taken inside it.
        const before = deps.participantsExited(pinned);
        const held = await retryAcquire(() => acknowledgeVoiceDrain(lease,
          state => state.kind === "COMMITTED", { throwOnContention: true }), Math.min(deps.now() + 250, deadline));
        const after = deps.participantsExited(pinned);
        if (!held || before === "UNKNOWN" || after === "UNKNOWN")
          throw Error("UNKNOWN: quit outcome or held lease unverifiable; gate retained closed for recovery");
        if (before === true && after === true) return;
        if (deps.now() >= deadline) throw Error("UNKNOWN: participants did not exit; gate retained closed for recovery");
        await deps.sleep();
      }
    },
  };
}
