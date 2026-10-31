import { createConnection } from "node:net";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { getMcpSocketPath } from "./paths";
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
  quit(lease: UpdateGateLease): Promise<void>;
}
export interface InstallerParticipantDependencies {
  request(action: "drain" | "quit", lease: UpdateGateLease): Promise<unknown>;
  processIdentity(pid: number): string | null;
  participantsExited(proof: ProcessProof): boolean | "UNKNOWN";
  now(): number;
  sleep(): Promise<void>;
}

/** No retries: a written quit may already have executed when the socket closes. */
export function requestInstallerControl(action: "drain" | "quit", lease: UpdateGateLease,
  options: { socketPath?: string; token?: string } = {}): Promise<unknown> {
  return new Promise((resolve, reject) => {
    let issued = false, settled = false, buffer = "";
    const id = randomUUID();
    const socket = createConnection(options.socketPath ?? getMcpSocketPath());
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
function processIdentity(pid: number): string | null {
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
function readProcessTable(): string {
  const result = Bun.spawnSync(["/bin/ps", "-axo", "pid=,comm="], { env: process.env, stdout: "pipe", stderr: "pipe", timeout: 1000 });
  if (result.exitCode !== 0) throw Error("UNKNOWN: process table unavailable");
  return result.stdout.toString();
}
export function observeInstallerExit(proof: ProcessProof, probes = { identity: processIdentity, table: readProcessTable }): boolean | "UNKNOWN" {
  try {
    const native = probes.identity(proof.identities.native.pid), daemon = probes.identity(proof.identities.daemon.pid);
    if ((native !== null && native !== proof.native) || (daemon !== null && daemon !== proof.daemon)) return "UNKNOWN";
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
  request: requestInstallerControl, processIdentity, participantsExited: observeInstallerExit,
  now: () => performance.now(), sleep: () => Bun.sleep(100),
}): InstallerParticipant {
  let evidence: Receipt | undefined, observedAt = 0, pinned: ProcessProof | undefined;
  const parse = (input: unknown, lease: UpdateGateLease): Receipt => {
    const parsed = receiptSchema.safeParse(input);
    if (!parsed.success || !sameLease(parsed.data.native.lease, lease) || !sameLease(parsed.data.daemon.lease, lease) ||
      parsed.data.identities.native.pid === parsed.data.identities.daemon.pid) throw Error("UNKNOWN: malformed or mismatched participant acknowledgements");
    const value = parsed.data;
    const native = deps.processIdentity(value.identities.native.pid), daemon = deps.processIdentity(value.identities.daemon.pid);
    if (!native || !daemon) throw Error("UNKNOWN: participant identity disappeared");
    const proof = { identities: value.identities, native, daemon };
    if (pinned && JSON.stringify(proof) !== JSON.stringify(pinned)) throw Error("UNKNOWN: participant identity changed during drain");
    pinned = proof;
    return value;
  };
  const verify: ParticipantProof = state => {
    try {
      return !!evidence && !!pinned && state.kind !== "OPEN" && sameLease(state.lease, evidence.native.lease) &&
        deps.now() - observedAt >= 0 && deps.now() - observedAt <= 1000 &&
        deps.processIdentity(pinned.identities.native.pid) === pinned.native &&
        deps.processIdentity(pinned.identities.daemon.pid) === pinned.daemon;
    } catch { return false; }
  };
  return {
    verify,
    async refresh(lease) {
      evidence = undefined; // A failed/new request invalidates the preceding receipt.
      const requestedAt = deps.now();
      const reply = await deps.request("drain", lease);
      if (unknownSchema.safeParse(reply).success)
        return { phase: "waiting for live participants", ready: false };
      const receipt = parse(reply, lease);
      if (deps.now() - requestedAt < 0 || deps.now() - requestedAt > 1000) throw Error("UNKNOWN: stale participant round trip");
      evidence = receipt; observedAt = requestedAt;
      return { phase: "idle", ready: true, native: evidence.native, daemon: evidence.daemon };
    },
    async quit(lease) {
      // Under G1's lock, recheck lease, diagnostics, ledger and last live identities.
      const authorized = acknowledgeVoiceDrain(lease, state => state.kind === "COMMITTED" && verify(state));
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
        let exited: boolean | "UNKNOWN" = "UNKNOWN";
        const held = acknowledgeVoiceDrain(lease, state => {
          if (state.kind !== "COMMITTED") return false;
          exited = deps.participantsExited(pinned!);
          return exited !== "UNKNOWN";
        });
        if (!held || exited === "UNKNOWN") throw Error("UNKNOWN: quit outcome or held lease unverifiable; gate retained closed for recovery");
        if (exited === true) return;
        if (deps.now() >= deadline) throw Error("UNKNOWN: participants did not exit; gate retained closed for recovery");
        await deps.sleep();
      }
    },
  };
}
