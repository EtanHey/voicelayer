import { retainedRecordingFilePath } from "./paths";
import { hasActiveVoiceOperation } from "./voice-operation-reservation";
import { AsyncLocalStorage } from "node:async_hooks";
import { RecordingTakeQueue, boundedSettlement, type RecordingTake } from "./recording-take-queue";
import { broadcast } from "./socket-client";
import type { SocketEvent, TranscriptionEvent } from "./socket-protocol";
import { getEffectiveRecordingState, hasConversationCaptureFence, setRecordingState, type RecordingState } from "./recording-state";

const ownership = new AsyncLocalStorage<RecordingTake<string>>();
const exitProofs = new WeakMap<RecordingTake<string>, Promise<void>>();
const deliveryOptions = new WeakMap<RecordingTake<string>, { expectsAck: boolean; timeoutMs: number }>();
/** BARE-STOP: live takes whose client named them (VoiceBar). Their mic admission is scoped, so an id-less stop spares it. */
const clientNamedTakes = new WeakSet<RecordingTake<string>>();
let newestCapture: RecordingTake<string> | undefined;
const pendingDeliveries = new Map<string, { event: TranscriptionEvent; resolve: () => void; mark: (outcome: "unverified" | "not_inserted") => void }>();
const queue = new RecordingTakeQueue<string>(publishRecordingJobs);

export function recordingJobsSnapshot() {
  const jobs = queue.jobs.map(({ take, phase }) => ({ take_id: take.id, kind: take.kind, phase }));
  const microphone = queue.jobs.find(({ phase }) => phase === "capturing" || phase === "draining");
  return { recording_jobs: jobs, processing_count: queue.snapshot.processingCount,
    mic_take_id: microphone?.take.id ?? null,
    ...(queue.snapshot.microphone === "blocked" ? { capture_error: "Recording failed. Recorder exit unconfirmed. Audio recovery: " + retainedRecordingFilePath() } : {}) };
}

function projectedState(): RecordingState {
  return ["capturing", "draining"].includes(queue.snapshot.microphone) ? "recording"
    : queue.snapshot.processingCount > 0 ? "transcribing" : "idle";
}

function publishRecordingJobs(): void {
  setRecordingState(projectedState());
  broadcast({ type: "state", state: projectedState(), source: "recording", ...recordingJobsSnapshot() });
}

export function canStartBarCapture(): boolean {
  if (queue.snapshot.microphone !== "free" || hasConversationCaptureFence() || hasActiveVoiceOperation()) return false;
  const state = getEffectiveRecordingState();
  return state === "idle" || (state === "transcribing" && queue.jobs.length > 0);
}

export function ownsRecordingJob(): boolean { return ownership.getStore() !== undefined; }
export function ownsHistoryJob(): boolean { return ownership.getStore()?.kind === "history"; }
export function ownsClientNamedCapture(): boolean {
  const take = ownership.getStore();
  return take !== undefined && clientNamedTakes.has(take);
}
export function ownsBarCapture(): boolean {
  const take = ownership.getStore();
  return take?.kind === "live" && recordingJobsSnapshot().mic_take_id === take.id;
}
export function mayUpdateRetainedCapture(): boolean {
  const take = ownership.getStore();
  return !take || take === newestCapture;
}
/** Read-only cancellation observation for health/conformance; decisions remain in the owned handler. */
export function recordingJobCancellationState(id: string): boolean | undefined {
  return queue.jobs.find(entry => entry.take.id === id)?.take.signal.aborted;
}
export function recordingJobCancelled(): boolean | undefined { return ownership.getStore()?.signal.aborted; }

export function registerBarRecorderExit(proof: Promise<void>): void {
  // Direct/legacy capture also supplies a rejecting proof. Observe it without
  // replacing it: admission and the owned queue still require proven exit.
  void proof.catch(() => {});
  const take = ownership.getStore();
  if (take?.kind !== "live") return;
  exitProofs.set(take, proof);
}

export async function runBarCapture(id: string, work: () => Promise<string | null>,
  options: { expectsAck?: boolean; ackTimeoutMs?: number; failureSettlementMs?: number; clientNamed?: boolean } = {}): Promise<string | null> {
  if (!canStartBarCapture()) throw new Error("Recording already in progress");
  const take = queue.beginCapture(id, id);
  newestCapture = take;
  deliveryOptions.set(take, { expectsAck: options.expectsAck ?? true, timeoutMs: options.ackTimeoutMs ?? 30_000 });
  if (options.clientNamed === true) clientNamedTakes.add(take);
  try { return await ownership.run(take, work); }
  finally {
    if (queue.ownsCapture(take)) {
      const settling = queue.failCapture(take, exitProofs.get(take) ?? Promise.resolve(), options.failureSettlementMs ?? 5000);
      broadcast({ type: "error", message: "Recording failed. Audio recovery: " + retainedRecordingFilePath(),
        recoverable: true, take_id: take.id, job_kind: "live" });
      await settling;
    }
  }
}

export function runHistoryTranscription(id: string, work: () => Promise<string | null>): Promise<string | null> {
  let result: string | null = null;
  const done = queue.runHistory(id, id, null, {
    transcribe: async () => {
      const take = queue.jobs.find(entry => entry.take.id === id)?.take;
      if (!take) throw new Error("History job lost its owner");
      result = await ownership.run(take, work);
    },
    deliver: async () => {},
  });
  return done.then(() => result);
}

/** Requires a complete archive; recorder and VAD settlement fence the next mic owner. */
export async function finishBarCapture<T>(recorderExited: Promise<void>, archivePath: string | null,
  process: () => Promise<T>): Promise<T | null> {
  const take = ownership.getStore();
  if (!take) {
    try { await boundedSettlement(recorderExited, 5000); }
    catch (error) { console.warn("Recorder exit unconfirmed before Ask processing", error); }
    return process();
  }
  registerBarRecorderExit(recorderExited);
  let result: T | null = null;
  await queue.finishCapture(take, {
    recorderExited,
    archive: async () => archivePath,
    transcribe: async () => { result = await process(); },
    deliver: async () => {},
  });
  return result;
}

export function markBarCaptureDraining(id: string): void {
  const take = queue.jobs.find(entry => entry.take.id === id)?.take;
  if (take) queue.beginDrain(take);
}
export function isBarCaptureDraining(): boolean { return queue.snapshot.microphone === "draining"; }

export function cancelRecordingJob(id?: string): "capture" | "job" | "delivery" | undefined {
  const entry = id ? queue.jobs.find(({ take }) => take.id === id)
    : queue.jobs.find(({ phase }) => phase === "capturing" || phase === "draining")
      ?? queue.jobs.toReversed().find(({ phase }) => phase === "processing" || phase === "queued");
  if (!entry) return undefined;
  // Once delivery starts, cancellation cannot prove that an app did not insert text.
  if (pendingDeliveries.has(entry.take.id)) return "delivery";
  queue.cancel(entry.take);
  if (entry.phase === "capturing") queue.beginDrain(entry.take);
  return entry.phase === "capturing" || entry.phase === "draining" ? "capture" : "job";
}

export function setInputRecordingState(state: RecordingState): void {
  if (!ownership.getStore()) { setRecordingState(state); return; }
  // Completion is published by queue removal, after delivery acknowledgment, never by an old owner.
  if (state !== "idle") setRecordingState(projectedState());
}

export function broadcastInputEvent(event: SocketEvent): void {
  const take = ownership.getStore();
  if (!take) { broadcast(event); return; }
  if (event.type === "state") {
    broadcast({ ...event, state: projectedState(), take_id: take.id, job_kind: take.kind, ...recordingJobsSnapshot() });
  } else {
    broadcast({ ...event, take_id: take.id, job_kind: take.kind });
  }
}

export async function deliverInputTranscription(event: TranscriptionEvent, markOutcome: (outcome: "unverified" | "not_inserted") => void = () => {}): Promise<void> {
  const take = ownership.getStore();
  if (!take) { broadcast(event); return; }
  if (take.signal.aborted) return;
  if (take.kind === "history") { broadcastInputEvent(event); return; }
  const delivery = { ...event, take_id: take.id, job_kind: take.kind, delivery_id: take.id };
  const options = deliveryOptions.get(take);
  if (!options?.expectsAck) { broadcast(delivery); return; }
  queue.beginDelivery(take);
  await new Promise<void>(resolve => {
    const timer = setTimeout(() => {
      const pending = pendingDeliveries.get(take.id);
      if (!pending) return;
      pendingDeliveries.delete(take.id);
      try {
        markOutcome("unverified");
        broadcast({ type: "dictation_delivery_status", take_id: take.id, job_kind: take.kind,
          delivery_id: take.id, outcome: "unverified", recording_path: event.recording_path });
      } catch { console.error("[voicelayer] Delivery outcome persistence failed; text remains retained"); }
      finally { resolve(); }
    }, options.timeoutMs);
    pendingDeliveries.set(take.id, { event: delivery, mark: markOutcome, resolve: () => { clearTimeout(timer); resolve(); } });
    broadcast(delivery);
  });
}

export function acknowledgeDictationDelivery(takeId: string, deliveryId: string, outcome?: "unverified" | "not_inserted"): boolean {
  if (takeId !== deliveryId) return false;
  const delivery = pendingDeliveries.get(takeId);
  if (!delivery) return false;
  pendingDeliveries.delete(takeId);
  try { if (outcome) delivery.mark(outcome); }
  finally { delivery.resolve(); }
  return true;
}

export function replayRecordingJobs(): void {
  if (!queue.jobs.length) {
    if (getEffectiveRecordingState() === "idle") {
      broadcast({ type: "state", state: "idle", source: "recording", ...recordingJobsSnapshot() });
    }
    return;
  }
  publishRecordingJobs();
  for (const delivery of pendingDeliveries.values()) broadcast(delivery.event);
}
