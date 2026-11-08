import { beginCaptureTrace, captureLifecycle, writeCaptureStop } from "./capture-lifecycle";
import { canStartBarCapture, runBarCapture, cancelRecordingJob, markBarCaptureDraining, recordingJobsSnapshot } from "./recording-jobs";
import { onRecordingStateChange } from "./recording-state";
import { pauseForF5Capture } from "./tts";

/** Lane I owns mic, transcription, delivery and cancellation. This adapter only lends it the read. */
const opening = new Map<string, { control?: "stop" | "cancel"; physicalPress?: boolean; origin?: Record<string, unknown> }>();
/** Preserve a physical up-edge that arrives while the old speech player is still exiting. */
export function bufferOpeningCaptureControl(id: string | undefined, control: "stop" | "cancel", physicalPress = false, origin: Record<string, unknown> = {}): boolean {
  const commandTakeID = id;
  id ??= opening.keys().next().value;
  if (!id) return false;
  const pending = opening.get(id);
  if (!pending) return false;
  if (pending.control !== "cancel") {
    pending.control = control;
    pending.origin = { ...origin, command_take_id: commandTakeID ?? null };
    pending.physicalPress = pending.physicalPress === true || physicalPress;
  }
  captureLifecycle("buffer-control", { ...origin, take_id: id, command_take_id: commandTakeID ?? null, route: "buffered-in-opening", cancelled: control === "cancel" });
  return true;
}

type ReadLoan = { pause: ReturnType<typeof pauseForF5Capture>; takes: Set<string>; finished: Set<string>; settled(): void };
let loan: ReadLoan | undefined;

function settleLoan(current: ReadLoan): void {
  if (loan !== current) return;
  const active = new Set(recordingJobsSnapshot().recording_jobs.map(job => job.take_id));
  for (const id of current.finished) {
    // A bounded failed promise can settle while Lane I still lacks recorder-exit proof.
    if (!active.has(id)) { current.takes.delete(id); current.finished.delete(id); }
  }
  if (current.takes.size !== 0) return;
  loan = undefined;
  current.pause.settle();
  current.settled();
}

onRecordingStateChange(() => {
  const current = loan;
  // Lane I persists its projected idle after notifying observers. Resume checks that persisted state too.
  if (current) queueMicrotask(() => settleLoan(current));
});

export function runBarCaptureWithPausedRead(id: string, record: (opened: () => void) => Promise<string | null>,
  held: () => void, settled: () => void, playbackElapsedMs?: number,
  options?: Parameters<typeof runBarCapture>[2]): Promise<string | null> {
  if (!canStartBarCapture() || loan?.takes.has(id)) return Promise.reject(new Error("Recording already in progress"));
  beginCaptureTrace(id);
  if (!loan) {
    const pause = pauseForF5Capture(playbackElapsedMs);
    loan = { pause, takes: new Set(), finished: new Set(), settled };
    held();
  }
  const current = loan;
  current.takes.add(id);
  const pending: { control?: "stop" | "cancel"; physicalPress?: boolean; origin?: Record<string, unknown> } = {};
  opening.set(id, pending);
  return current.pause.ready.then(() => runBarCapture(id, () => record(() => {
    if (opening.get(id) !== pending) return;
    opening.delete(id);
    if (pending.control === "cancel") cancelRecordingJob(id);
    else if (pending.control === "stop") markBarCaptureDraining(id);
    if (pending.control) writeCaptureStop(JSON.stringify({ take_id: id,
      ...(pending.control === "cancel" ? { cancelled: true } : { physical_press: pending.physicalPress === true }) }), "buffered-in-opening", pending.origin ?? {}, id);
  }), options)).finally(() => {
    opening.delete(id);
    current.finished.add(id);
    settleLoan(current);
  });
}
