import { z } from "zod";

const generationSchema = z.number().int().nonnegative();
export const updateGateLeaseSchema = z.strictObject({
  generation: generationSchema.positive(),
  operationId: z.uuid(),
  ownerId: z.uuid(),
  targetSha: z.string().regex(/^[0-9a-f]{40}$/),
});
export type UpdateGateLease = z.infer<typeof updateGateLeaseSchema>;

export const updateGateAckSchema = z.strictObject({
  lease: updateGateLeaseSchema,
  activeOperations: z.literal(0),
  openArchives: z.literal(0),
});

function sameLease(a: UpdateGateLease, b: UpdateGateLease): boolean {
  return a.generation === b.generation && a.operationId === b.operationId
    && a.ownerId === b.ownerId && a.targetSha === b.targetSha;
}

const openSchema = z.strictObject({
  version: z.literal(1),
  kind: z.literal("OPEN"),
  generation: generationSchema,
  released: updateGateLeaseSchema.nullable(),
}).refine(state => state.released === null
  ? state.generation === 0 : state.generation === state.released.generation);
const drainingSchema = z.strictObject({
  version: z.literal(1),
  kind: z.literal("DRAINING"),
  lease: updateGateLeaseSchema,
});
const acknowledgedShape = {
  version: z.literal(1),
  lease: updateGateLeaseSchema,
  native: updateGateAckSchema,
  daemon: updateGateAckSchema,
};
function matchingAcks(state: {
  lease: UpdateGateLease;
  native: z.infer<typeof updateGateAckSchema>;
  daemon: z.infer<typeof updateGateAckSchema>;
}): boolean {
  return sameLease(state.lease, state.native.lease) && sameLease(state.lease, state.daemon.lease);
}
export const updateGateStateSchema = z.union([
  openSchema,
  drainingSchema,
  z.strictObject({ ...acknowledgedShape, kind: z.literal("PREPARED") }).refine(matchingAcks),
  z.strictObject({ ...acknowledgedShape, kind: z.literal("COMMITTED") }).refine(matchingAcks),
]);
export type UpdateGateState = z.infer<typeof updateGateStateSchema>;

export const updateGateCommandSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("REQUEST"), lease: updateGateLeaseSchema }),
  z.strictObject({ kind: z.literal("PREPARE"), lease: updateGateLeaseSchema,
    native: updateGateAckSchema, daemon: updateGateAckSchema }),
  z.strictObject({ kind: z.literal("COMMIT"), lease: updateGateLeaseSchema }),
  z.strictObject({ kind: z.literal("CANCEL"), lease: updateGateLeaseSchema }),
]);
export type UpdateGateCommand = z.infer<typeof updateGateCommandSchema>;
export type UpdateGateTransition =
  | { kind: "APPLIED" | "UNCHANGED"; state: UpdateGateState }
  | { kind: "REFUSED"; reason: "UNKNOWN" | "INVALID_COMMAND" | "OWNERSHIP" | "PHASE" | "GENERATION" | "ACKNOWLEDGEMENTS" };

export function readUpdateGate(value: unknown): UpdateGateState | { kind: "UNKNOWN" } {
  const parsed = updateGateStateSchema.safeParse(value);
  return parsed.success ? parsed.data : { kind: "UNKNOWN" };
}

export function transitionUpdateGate(value: unknown, input: unknown): UpdateGateTransition {
  const state = readUpdateGate(value);
  if (state.kind === "UNKNOWN") return { kind: "REFUSED", reason: "UNKNOWN" };
  const parsed = updateGateCommandSchema.safeParse(input);
  if (!parsed.success) return { kind: "REFUSED", reason: "INVALID_COMMAND" };
  const command = parsed.data;
  if (state.kind === "OPEN") {
    if (command.kind === "CANCEL" && state.released && sameLease(state.released, command.lease)) {
      return { kind: "UNCHANGED", state };
    }
    if (command.kind !== "REQUEST") return { kind: "REFUSED", reason: "PHASE" };
    if (command.lease.generation !== state.generation + 1) return { kind: "REFUSED", reason: "GENERATION" };
    return { kind: "APPLIED", state: { version: 1, kind: "DRAINING", lease: command.lease } };
  }
  if (!sameLease(state.lease, command.lease)) return { kind: "REFUSED", reason: "OWNERSHIP" };
  switch (command.kind) {
    case "REQUEST":
      return { kind: "UNCHANGED", state };
    case "PREPARE":
      if (state.kind === "COMMITTED") return { kind: "REFUSED", reason: "PHASE" };
      if (!matchingAcks(command)) return { kind: "REFUSED", reason: "ACKNOWLEDGEMENTS" };
      if (state.kind === "PREPARED") return { kind: "UNCHANGED", state };
      return { kind: "APPLIED", state: { version: 1, kind: "PREPARED", lease: state.lease,
        native: command.native, daemon: command.daemon } };
    case "COMMIT":
      if (state.kind === "COMMITTED") return { kind: "UNCHANGED", state };
      if (state.kind !== "PREPARED") return { kind: "REFUSED", reason: "PHASE" };
      return { kind: "APPLIED", state: { ...state, kind: "COMMITTED" } };
    case "CANCEL":
      if (state.kind === "COMMITTED") return { kind: "REFUSED", reason: "PHASE" };
      return { kind: "APPLIED", state: { version: 1, kind: "OPEN", generation: state.lease.generation,
        released: state.lease } };
    default: {
      const exhaustive: never = command;
      return exhaustive;
    }
  }
}
