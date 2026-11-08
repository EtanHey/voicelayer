import { STOP_FILE, safeWriteFileSync } from "./paths";
import { canStartBarCapture, runBarCapture, cancelRecordingJob, markBarCaptureDraining, recordingJobsSnapshot } from "./recording-jobs";
import { onRecordingStateChange } from "./recording-state";
import { pauseForF5Capture } from "./tts";

/** Lane I owns mic, transcription, delivery and cancellation. This adapter only lends it the read. */
const opening = new Map<string, { control?: "stop" | "cancel"; physicalPress?: boolean }>();
/** Takes whose client named them (VoiceBar always does). Only a stop carrying that id may end one. */
const scopedTakes = new Set<string>();
/** A client-named take is opening or holds the mic. An unscoped stop must leave it recording. */
export function hasScopedCapture(micTakeID: string | null): boolean {
  return (micTakeID !== null && scopedTakes.has(micTakeID)) || [...opening.keys()].some(id => scopedTakes.has(id));
}
/** Preserve a physical up-edge that arrives while the old speech player is still exiting.
 *  An id-less stop falls back only to an anonymous (daemon-named) opening take; a cancel keeps its fallback. */
export function bufferOpeningCaptureControl(id: string | undefined, control: "stop" | "cancel", physicalPress = false): boolean {
  if (id === undefined) {
    id = opening.keys().next().value;
    if (id !== undefined && control === "stop" && scopedTakes.has(id)) return false;
  }
  if (!id) return false;
  const pending = opening.get(id);
  if (!pending) return false;
  if (pending.control !== "cancel") {
    pending.control = control;
    pending.physicalPress = pending.physicalPress === true || physicalPress;
  }
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
  options?: Parameters<typeof runBarCapture>[2], scoped = false): Promise<string | null> {
  if (!canStartBarCapture() || loan?.takes.has(id)) return Promise.reject(new Error("Recording already in progress"));
  if (!loan) {
    const pause = pauseForF5Capture(playbackElapsedMs);
    loan = { pause, takes: new Set(), finished: new Set(), settled };
    held();
  }
  const current = loan;
  current.takes.add(id);
  if (scoped) scopedTakes.add(id);
  const pending: { control?: "stop" | "cancel"; physicalPress?: boolean } = {};
  opening.set(id, pending);
  return current.pause.ready.then(() => runBarCapture(id, () => record(() => {
    if (opening.get(id) !== pending) return;
    opening.delete(id);
    if (pending.control === "cancel") cancelRecordingJob(id);
    else if (pending.control === "stop") markBarCaptureDraining(id);
    if (pending.control) safeWriteFileSync(STOP_FILE, JSON.stringify({ take_id: id,
      ...(pending.control === "cancel" ? { cancelled: true } : { physical_press: pending.physicalPress === true }) }));
  }), options)).finally(() => {
    opening.delete(id);
    scopedTakes.delete(id);
    current.finished.add(id);
    settleLoan(current);
  });
}
