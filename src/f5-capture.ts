import { STOP_FILE, safeWriteFileSync } from "./paths";
import { canStartBarCapture, runBarCapture, cancelRecordingJob } from "./recording-jobs";
import { pauseForF5Capture } from "./tts";

/** Lane I owns mic, transcription, delivery and cancellation. This adapter only lends it the read. */
const opening = new Map<string, { control?: "stop" | "cancel" }>();
/** Preserve a physical up-edge that arrives while the old speech player is still exiting. */
export function bufferOpeningCaptureControl(id: string | undefined, control: "stop" | "cancel"): boolean {
  if (!id) return false;
  const pending = opening.get(id);
  if (!pending) return false;
  if (pending.control !== "cancel") pending.control = control;
  return true;
}

let loan: { pause: ReturnType<typeof pauseForF5Capture>; takes: Set<string>; settled(): void } | undefined;

export function runBarCaptureWithPausedRead(id: string, record: (opened: () => void) => Promise<string | null>,
  held: () => void, settled: () => void, playbackElapsedMs?: number): Promise<string | null> {
  if (!canStartBarCapture() || loan?.takes.has(id)) return Promise.reject(new Error("Recording already in progress"));
  if (!loan) {
    const pause = pauseForF5Capture(playbackElapsedMs);
    loan = { pause, takes: new Set(), settled };
    held();
  }
  const current = loan;
  current.takes.add(id);
  const pending: { control?: "stop" | "cancel" } = {};
  opening.set(id, pending);
  return current.pause.ready.then(() => runBarCapture(id, () => record(() => {
    if (opening.get(id) !== pending) return;
    opening.delete(id);
    if (pending.control === "cancel") cancelRecordingJob(id);
    if (pending.control) safeWriteFileSync(STOP_FILE, JSON.stringify({ physical_press: pending.control === "stop" }));
  }))).finally(() => {
    opening.delete(id);
    if (!current.takes.delete(id) || current.takes.size !== 0 || loan !== current) return;
    loan = undefined;
    current.pause.settle();
    current.settled();
  });
}
