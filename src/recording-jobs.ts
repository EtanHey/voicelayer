import { hasActiveVoiceOperation } from "./voice-operation-reservation";
import { AsyncLocalStorage } from "node:async_hooks";
import { RecordingTakeQueue, type RecordingTake } from "./recording-take-queue";
import { broadcast } from "./socket-client";
import type { SocketEvent, TranscriptionEvent } from "./socket-protocol";
import { getEffectiveRecordingState, hasConversationCaptureFence, setRecordingState, type RecordingState } from "./recording-state";

const ownership = new AsyncLocalStorage<RecordingTake<string>>();
let newestCapture: RecordingTake<string> | undefined;
const pendingDeliveries = new Map<string, { event: TranscriptionEvent; resolve: () => void }>();
const queue = new RecordingTakeQueue<string>(publishRecordingJobs);

export function recordingJobsSnapshot() {
  const jobs = queue.jobs.map(({ take, phase }) => ({ take_id: take.id, kind: take.kind, phase }));
  const microphone = queue.jobs.find(({ phase }) => phase === "capturing" || phase === "draining");
  return { recording_jobs: jobs, processing_count: queue.snapshot.processingCount,
    mic_take_id: microphone?.take.id ?? null };
}

function projectedState(): RecordingState {
  return queue.snapshot.microphone !== "free" ? "recording"
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
export function ownsBarCapture(): boolean {
  const take = ownership.getStore();
  return take?.kind === "live" && recordingJobsSnapshot().mic_take_id === take.id;
}
export function mayUpdateRetainedCapture(): boolean {
  const take = ownership.getStore();
  return !take || take === newestCapture;
}
export function recordingJobCancelled(): boolean | undefined { return ownership.getStore()?.signal.aborted; }

export function runBarCapture(id: string, work: () => Promise<string | null>): Promise<string | null> {
  if (!canStartBarCapture()) return Promise.reject(new Error("Recording already in progress"));
  const take = queue.beginCapture(id, id);
  newestCapture = take;
  return ownership.run(take, work);
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
  if (!take) return process();
  let result: T | null = null;
  await queue.finishCapture(take, {
    recorderExited,
    archive: async () => archivePath,
    transcribe: async () => { result = await process(); },
    deliver: async () => {},
  });
  return result;
}

export function cancelRecordingJob(id?: string): "capture" | "job" | "delivery" | undefined {
  const entry = id ? queue.jobs.find(({ take }) => take.id === id)
    : queue.jobs.find(({ phase }) => phase === "capturing" || phase === "draining")
      ?? queue.jobs.find(({ phase }) => phase === "processing")
      ?? queue.jobs.find(({ phase }) => phase === "queued");
  if (!entry) return undefined;
  // Once delivery starts, cancellation cannot prove that an app did not insert text.
  if (pendingDeliveries.has(entry.take.id)) return "delivery";
  queue.cancel(entry.take);
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

export async function deliverInputTranscription(event: TranscriptionEvent): Promise<void> {
  const take = ownership.getStore();
  if (!take) { broadcast(event); return; }
  if (take.signal.aborted) return;
  if (take.kind === "history") { broadcastInputEvent(event); return; }
  await new Promise<void>(resolve => {
    const delivery = { ...event, take_id: take.id, job_kind: take.kind, delivery_id: take.id };
    pendingDeliveries.set(take.id, { event: delivery, resolve });
    broadcast(delivery);
  });
}

export function acknowledgeDictationDelivery(takeId: string, deliveryId: string): boolean {
  if (takeId !== deliveryId) return false;
  const delivery = pendingDeliveries.get(takeId);
  if (!delivery) return false;
  pendingDeliveries.delete(takeId);
  delivery.resolve();
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
