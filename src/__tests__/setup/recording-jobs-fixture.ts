import { finishBarCapture, recordingJobsSnapshot } from "../../recording-jobs";

/** Input spies replace recorder/archive IO, but must retain the real take-completion boundary. */
export function finishSyntheticCapture<T>(work: () => Promise<T>): Promise<T | null> {
  return finishBarCapture(Promise.resolve(), "synthetic-fixture/audio.wav", work);
}
export async function settleRecordingJobs(): Promise<void> {
  const deadline = performance.now() + 2000;
  while (recordingJobsSnapshot().recording_jobs.length > 0) {
    if (performance.now() >= deadline) throw Error("Synthetic recording jobs did not settle before spies were restored");
    await Bun.sleep(1);
  }
}
