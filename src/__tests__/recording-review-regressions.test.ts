import { afterEach, expect, spyOn, test } from "bun:test";
import { randomUUID } from "node:crypto";
import * as socket from "../socket-client";
import * as input from "../input";
import * as booking from "../session-booking";
import * as tts from "../tts";
import { setRecordingState } from "../recording-state";
import { runBarCapture, finishBarCapture, deliverInputTranscription, recordingJobsSnapshot, registerBarRecorderExit,
  acknowledgeDictationDelivery } from "../recording-jobs";
import { handleSocketCommand } from "../socket-handlers";
import { fixtureBarrier } from "./long-read-fixture-barriers";
import { settleRecordingJobs } from "./setup/recording-jobs-fixture";
const mocks: Array<{ mockRestore(): void }> = [];
afterEach(async () => {
  try {
    await settleRecordingJobs(tts.hasF5Capture);
    expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
    expect(tts.hasF5Capture()).toBe(false);
  } finally {
    mocks.splice(0).reverse().forEach(m => m.mockRestore());
    setRecordingState("idle"); booking.clearStopSignal();
  }
});
test("F1 legacy record clients settle without sending delivery ACK and the next take decodes", async () => {
  const decoded: string[] = [];
  mocks.push(spyOn(socket, "broadcast").mockImplementation(() => {}));
  mocks.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
  mocks.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
  const entered = fixtureBarrier<Promise<string | null>>();
  mocks.push(spyOn(input, "waitForInput").mockImplementation(() => {
    const job = finishBarCapture(Promise.resolve(), "synthetic.wav", async () => {
      decoded.push("take"); await deliverInputTranscription({ type: "transcription", text: "kept words" }); return "kept words";
    }); entered.push(job); return job;
  }));
  for (let i = 0; i < 2; i++) {
    expect(await handleSocketCommand({ cmd: "record" })).toMatchObject({ outcome: "accept" });
    await entered.at(i);
    await settleRecordingJobs(tts.hasF5Capture);
    expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
    expect(tts.hasF5Capture()).toBe(false);
  }
  expect(decoded).toHaveLength(2);
});
test("F7 missing capable-client ACK is bounded, marks delivery unverified, keeps text and releases FIFO", async () => {
  const events: unknown[] = [];
  mocks.push(spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); }));
  const id = randomUUID();
  await runBarCapture(id, () => finishBarCapture(Promise.resolve(), "kept-a.wav", async () => {
    await deliverInputTranscription({ type: "transcription", text: "full words", recording_path: "kept-a.wav" }); return "full words";
  }), { expectsAck: true, ackTimeoutMs: 5 });
  expect(events).toContainEqual(expect.objectContaining({ type: "dictation_delivery_status", outcome: "unverified", take_id: id }));
  expect(events).toContainEqual(expect.objectContaining({ type: "transcription", text: "full words" }));
  expect(acknowledgeDictationDelivery(id, id)).toBe(false);
  await runBarCapture(randomUUID(), () => finishBarCapture(Promise.resolve(), "b.wav", async () => "second"));
});
test("F3 throw before capture handoff is terminal failed, never a phantom mic owner", async () => {
  const events: unknown[] = [];
  mocks.push(spyOn(socket, "broadcast").mockImplementation(e => { events.push(e); }));
  await expect(runBarCapture(randomUUID(), async () => { throw Error("archive/admission failed"); }))
    .rejects.toThrow("archive/admission failed");
  expect(events).toContainEqual(expect.objectContaining({ type: "error", message: expect.stringContaining("Audio recovery:") }));
  expect(recordingJobsSnapshot().mic_take_id).toBeNull();
  await runBarCapture(randomUUID(), () => finishBarCapture(Promise.resolve(), "next.wav", async () => null));
});
test("F3 unconfirmed exit has a bounded explicit failed state, then late proof releases only its owner", async () => {
  mocks.push(spyOn(socket, "broadcast").mockImplementation(() => {}));
  const exit = Promise.withResolvers<void>();
  const id = randomUUID();
  await expect(runBarCapture(id, async () => {
    registerBarRecorderExit(exit.promise); throw Error("capture failed");
  }, { failureSettlementMs: 5 })).rejects.toThrow("capture failed");
  expect(recordingJobsSnapshot()).toMatchObject({ mic_take_id: null, capture_error: expect.stringContaining("unconfirmed"),
    recording_jobs: [{ take_id: id, phase: "failed" }] });
  exit.resolve(); await Promise.resolve(); await Promise.resolve();
  expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
});
