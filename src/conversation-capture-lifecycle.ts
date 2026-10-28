import type { NativeInputFormat } from "./audio-utils";
import type { RecorderStderrWatcher } from "./input";

type RecorderChild = Pick<Bun.Subprocess<"ignore", "pipe", "pipe">, "exited" | "kill" | "stdout" | "stderr">;
interface NormalizedCaptureExtent {
  readonly nativeBytes: number;
  readonly pcm: Uint8Array;
  readonly nativeTail: Uint8Array;
  readonly format: NativeInputFormat;
}
interface CaptureFormatEvidence {
  readonly format: NativeInputFormat | "invalidated" | null;
  readonly stderr: ReturnType<RecorderStderrWatcher["finish"]>;
}
type CaptureSafetyReport = { readonly generation: number } & (
  { readonly kind: "not-started" } |
  { readonly kind: "complete"; readonly exitCode: number; readonly nativeBytes: number; readonly normalizedBytes: number }
);
type ExitObservation = { readonly kind: "unattached" | "pending" } |
  { readonly kind: "fulfilled"; readonly exitCode: number } | { readonly kind: "rejected"; readonly cause: unknown };

interface CaptureRecord {
  readonly generation: number;
  readonly safety: Promise<Readonly<CaptureSafetyReport>>;
  readonly complete: (report: Readonly<CaptureSafetyReport>) => void;
  readonly cleanups: Array<() => Promise<void>>;
  phase: "fresh" | "setup" | "closed" | "failed" | "safe";
  spawnAllowed: boolean;
  stopRequested: boolean;
  child?: RecorderChild;
  childJoin?: Promise<Readonly<CaptureSafetyReport> | undefined>;
  exit: ExitObservation;
  stop: "none" | "term" | "kill" | "unconfirmed";
  stopTimer?: ReturnType<typeof setTimeout>;
  errors: unknown[];
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
      exit: { kind: "unattached" }, stop: "none", errors: [], stopRequested: false,
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
  const record = recordFor(policy);
  record.spawnAllowed = false;
  record.stopRequested = true;
  stopChild(record);
}

/** A snapshot is evidence only; stop expiry never fulfills the private safety record. */
export function getConversationCaptureObservation(policy: ConversationCapturePolicy) {
  const record = recordFor(policy);
  return Object.freeze({ generation: record.generation, exit: Object.freeze({ ...record.exit }),
    stop: record.stop, errors: Object.freeze([...record.errors]) });
}

function stopChild(record: CaptureRecord): void {
  const child = record.child;
  if (!child || record.stop !== "none" || record.exit.kind === "fulfilled") return;
  const signal = (value: "SIGTERM" | "SIGKILL") => {
    try { child.kill(value); } catch (error) { record.errors.push(error); }
  };
  record.stop = "term";
  signal("SIGTERM");
  record.stopTimer = setTimeout(() => {
    if (record.exit.kind === "fulfilled") return;
    record.stop = "kill";
    signal("SIGKILL");
    record.stopTimer = setTimeout(() => {
      if (record.exit.kind !== "fulfilled") record.stop = "unconfirmed";
    }, 300);
  }, 300);
}

async function own<T>(record: CaptureRecord, work: () => Promise<T>): Promise<PromiseSettledResult<T>> {
  try { return { status: "fulfilled", value: await work() }; }
  catch (reason) {
    record.errors.push(reason);
    stopChild(record);
    return { status: "rejected", reason };
  }
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

  startChild(input: {
    spawn: () => RecorderChild;
    readStdout: (child: RecorderChild) => Promise<NormalizedCaptureExtent>;
    readStderr: (child: RecorderChild) => Promise<CaptureFormatEvidence>;
    fenceProcessing: () => Promise<void>;
  }): void {
    const record = this.#record;
    if (record.phase !== "setup" || !record.spawnAllowed || record.child) throw new Error("Capture child start revoked");
    record.spawnAllowed = false;
    const child = input.spawn();
    record.child = child;
    record.exit = { kind: "pending" };
    const before = record.errors.length;
    const exited = own(record, () => child.exited.then(exitCode => {
      record.exit = { kind: "fulfilled", exitCode };
      clearTimeout(record.stopTimer);
      return exitCode;
    }, cause => { record.exit = { kind: "rejected", cause }; throw cause; }));
    if (record.stopRequested) stopChild(record);
    const stdout = own(record, () => input.readStdout(child));
    const stderr = own(record, () => input.readStderr(child));
    const fence = own(record, () => input.fenceProcessing());
    record.childJoin = own(record, async () => {
      const [exit, out, err, effect] = await Promise.all([exited, stdout, stderr, fence]);
      if (exit.status !== "fulfilled" || out.status !== "fulfilled" || err.status !== "fulfilled" || effect.status !== "fulfilled") return undefined;
      const extent = out.value, format = err.value.format;
      const { sampleRate, channels } = extent.format;
      if (
        !Number.isInteger(sampleRate) || sampleRate <= 0 || sampleRate > 192000 ||
        !Number.isInteger(channels) || channels <= 0 || channels > 16 ||
        !format || format === "invalidated" ||
        format.sampleRate !== sampleRate || format.channels !== channels ||
        !Number.isSafeInteger(extent.nativeBytes) || extent.nativeBytes < 0 ||
        extent.nativeBytes % (channels * 2) || extent.nativeTail.byteLength ||
        extent.pcm.byteLength !== Math.floor(extent.nativeBytes / (channels * 2) / (sampleRate / 16000)) * 2 ||
        !(child.stdout instanceof ReadableStream) || child.stdout.locked ||
        !(child.stderr instanceof ReadableStream) || child.stderr.locked
      ) {
        throw new Error("Incomplete capture extent, format or reader closure");
      }
      if (exit.value !== 0) record.errors.push(new Error(`Recorder exited with code ${exit.value}`));
      return Object.freeze({ kind: "complete" as const, generation: record.generation,
        exitCode: exit.value, nativeBytes: extent.nativeBytes, normalizedBytes: extent.pcm.byteLength });
    }).then(result => result.status === "fulfilled" ? result.value : undefined);
    if (record.errors.length > before) throw new AggregateError(record.errors.slice(before), "Capture child startup failed");
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
  if (outcome.kind === "threw") stopChild(record);
  const childReport = await record.childJoin;
  const cleanups = await Promise.allSettled(record.cleanups.map(async (cleanup) => cleanup()));
  const failures = cleanups.filter((cleanup) => cleanup.status === "rejected");
  if (failures.length || (record.child && !childReport)) {
    record.phase = "failed";
  } else {
    record.phase = "safe";
    record.complete(childReport ?? Object.freeze({ kind: "not-started", generation: record.generation }));
  }
  const errors = [...record.errors, ...failures.map((failure) => failure.reason)];
  if (outcome.kind === "threw") errors.unshift(outcome.error);
  if (errors.length > 1) throw new AggregateError(errors, "Capture setup/cleanup failed");
  if (errors.length) throw errors[0];
  if (outcome.kind === "threw") throw outcome.error;
  return outcome.value;
}
