import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { z } from "zod";
import { acknowledgeVoiceDrain } from "./update-gate-admission";
import { updateGateLeaseSchema, type UpdateGateLease } from "./update-gate";

type Envelope = { action: "drain" | "quit"; id: string; pid: number; incarnation: string; lease: UpdateGateLease };
const replySchema = z.object({ cmd: z.literal("update_gate_drain_ack"), action: z.enum(["drain", "quit"]),
  id: z.uuid(), pid: z.number().int().positive(), incarnation: z.uuid(), lease: updateGateLeaseSchema,
  mac: z.string().regex(/^[0-9a-f]{64}$/) });
/** Fixed field order shared with NativeDrainParticipant.swift; never signs user text. */
export function drainMessage(kind: string, value: Envelope): string {
  const l = value.lease;
  return [kind, value.id, value.pid, value.incarnation, l.generation, l.operationId, l.ownerId, l.targetSha].join("|");
}
export function createNativeDrainParticipant(options: {
  secret?: string; nativePid?: number; send: (request: Envelope & { type: "update_gate_drain"; mac: string }) => void;
}) {
  const incarnation = randomUUID();
  const pending = new Map<string, { lease: UpdateGateLease; action: "drain" | "quit"; finish: (value: Envelope | null) => void }>();
  const sign = (kind: string, value: Envelope) => createHmac("sha256", options.secret!).update(drainMessage(kind, value)).digest("hex");
  return {
    request(lease: UpdateGateLease, action: "drain" | "quit" = "drain"): Promise<Envelope | null> {
      if (!options.secret || !options.nativePid || !updateGateLeaseSchema.safeParse(lease).success) return Promise.resolve(null);
      const value = { action, id: randomUUID(), pid: process.pid, incarnation, lease };
      return new Promise(resolve => {
        const timer = setTimeout(() => finish(null), 1000);
        const finish = (reply: Envelope | null) => { clearTimeout(timer); pending.delete(value.id); resolve(reply); };
        pending.set(value.id, { lease, action, finish });
        try { options.send({ ...value, type: "update_gate_drain", mac: sign(action, value) }); }
        catch { finish(null); }
      });
    },
    receive(input: unknown): void {
      const parsed = replySchema.safeParse(input);
      if (!parsed.success || !options.secret) return;
      const v = parsed.data;
      const waiter = pending.get(v.id);
      if (!waiter || v.action !== waiter.action || v.pid !== options.nativePid ||
        drainMessage("lease", { ...v, id: "", pid: 0, incarnation: "" }) !==
        drainMessage("lease", { ...v, id: "", pid: 0, incarnation: "", lease: waiter.lease })) return;
      if (timingSafeEqual(Buffer.from(v.mac, "hex"), Buffer.from(sign("ack-" + v.action, v), "hex"))) waiter.finish(v);
    },
    disconnect(): void { for (const waiter of [...pending.values()]) waiter.finish(null); },
  };
}

/** Live round trip bracketed by G2's exact in-lock snapshot; no saved ACK cache. */
export function createVoiceDrainControl(participant: Pick<ReturnType<typeof createNativeDrainParticipant>, "request">,
  ready: () => boolean) {
  const incarnation = randomUUID();
  return async (input: unknown, action: "drain" | "quit"): Promise<Record<string, unknown>> => {
    const parsed = updateGateLeaseSchema.safeParse(input);
    if (!parsed.success) return { kind: "UNKNOWN" };
    const lease = parsed.data;
    const proof = (state: import("./update-gate").UpdateGateState) => ready() && (action !== "quit" || state.kind === "COMMITTED");
    if (!acknowledgeVoiceDrain(lease, proof)) return { kind: "UNKNOWN" };
    const native = await participant.request(lease, action);
    const daemon = native && acknowledgeVoiceDrain(lease, proof);
    return native && daemon ? { kind: "ACKNOWLEDGED", native: { lease, activeOperations: 0, openArchives: 0 },
      daemon, identities: { native: { pid: native.pid, incarnation: native.incarnation },
        daemon: { pid: process.pid, incarnation } } } : { kind: "UNKNOWN" };
  };
}
