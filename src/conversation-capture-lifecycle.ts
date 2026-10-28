/** Inert setup ownership; child/task observation is added before capture integration. */
interface CaptureSafetyReport {
  readonly kind: "not-started";
  readonly generation: number;
}

interface CaptureRecord {
  readonly generation: number;
  readonly safety: Promise<Readonly<CaptureSafetyReport>>;
  readonly complete: (report: Readonly<CaptureSafetyReport>) => void;
  readonly cleanups: Array<() => Promise<void>>;
  phase: "fresh" | "setup" | "closed" | "failed" | "safe";
  spawnAllowed: boolean;
}

const records = new WeakMap<IssuedCapturePolicy, CaptureRecord>();
let generation = 0;

class IssuedCapturePolicy {
  readonly #identity = Symbol();
  private constructor() {}

  static issue(): IssuedCapturePolicy {
    const policy = new IssuedCapturePolicy();
    const { promise, resolve } = Promise.withResolvers<Readonly<CaptureSafetyReport>>();
    Object.freeze(promise);
    records.set(policy, {
      generation: ++generation, safety: promise, complete: resolve,
      cleanups: [], phase: "fresh", spawnAllowed: true,
    });
    Object.freeze(policy);
    return policy;
  }
}

export type ConversationCapturePolicy = IssuedCapturePolicy;

function recordFor(policy: ConversationCapturePolicy): CaptureRecord {
  const record = records.get(policy);
  if (!record) throw new Error("Unissued conversation capture policy");
  return record;
}

export function createConversationCapturePolicy(): ConversationCapturePolicy {
  return IssuedCapturePolicy.issue();
}

/** Revokes future spawn permission; never certifies setup or cleanup completion. */
export function requestConversationCaptureStop(policy: ConversationCapturePolicy): void {
  recordFor(policy).spawnAllowed = false;
}

export function waitForConversationCaptureSafety(
  policy: ConversationCapturePolicy,
): Promise<Readonly<CaptureSafetyReport>> {
  return recordFor(policy).safety;
}

class CaptureSetupOwner {
  readonly #record: CaptureRecord;
  private constructor(record: CaptureRecord) { this.#record = record; }

  static create(record: CaptureRecord): CaptureSetupOwner {
    const owner = new CaptureSetupOwner(record);
    Object.freeze(owner);
    return owner;
  }

  ownSetupCleanup(cleanup: () => Promise<void>): void {
    if (this.#record.phase !== "setup") throw new Error("Capture setup owner closed");
    this.#record.cleanups.push(cleanup);
  }
}

/** One registration owns setup settlement and every cleanup, including on failure. */
export async function runRegisteredConversationCapture<T>(
  policy: ConversationCapturePolicy,
  setup: (owner: CaptureSetupOwner) => Promise<T>,
): Promise<T> {
  const record = recordFor(policy);
  if (record.phase !== "fresh") throw new Error("Capture setup already registered");
  record.phase = "setup";
  let outcome: { kind: "returned"; value: T } | { kind: "threw"; error: unknown };
  try {
    outcome = { kind: "returned", value: await setup(CaptureSetupOwner.create(record)) };
  } catch (error) {
    outcome = { kind: "threw", error };
  }
  record.phase = "closed";
  record.spawnAllowed = false;
  const cleanups = await Promise.allSettled(record.cleanups.map(async (cleanup) => cleanup()));
  const failures = cleanups.filter((cleanup) => cleanup.status === "rejected");
  if (failures.length) {
    record.phase = "failed";
  } else {
    record.phase = "safe";
    record.complete(Object.freeze({ kind: "not-started", generation: record.generation }));
  }
  const errors = failures.map((failure) => failure.reason);
  if (outcome.kind === "threw") errors.unshift(outcome.error);
  if (errors.length > 1) throw new AggregateError(errors, "Capture setup/cleanup failed");
  if (errors.length) throw errors[0];
  if (outcome.kind === "threw") throw outcome.error;
  return outcome.value;
}
