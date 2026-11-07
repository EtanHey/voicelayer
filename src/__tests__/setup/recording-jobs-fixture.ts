import { finishBarCapture, recordingJobsSnapshot } from "../../recording-jobs";

/** Input spies replace recorder/archive IO, but must retain the real take-completion boundary. */
export function finishSyntheticCapture<T>(work: () => Promise<T>): Promise<T | null> {
  return finishBarCapture(Promise.resolve(), "synthetic-fixture/audio.wav", work);
}
/** A deferred F5 start can own the read before its first Lane I job exists. */
export async function settleRecordingJobs(capturePending: () => boolean = () => false): Promise<void> {
  const deadline = performance.now() + 2000;
  while (capturePending() || recordingJobsSnapshot().recording_jobs.length > 0) {
    if (performance.now() >= deadline) throw Error("Synthetic recording jobs did not settle before spies were restored");
    await Bun.sleep(1);
  }
}
