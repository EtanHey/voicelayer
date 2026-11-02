import { afterEach, expect, spyOn, test } from "bun:test";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import * as input from "../../src/input";
import * as booking from "../../src/session-booking";
import * as socket from "../../src/socket-client";
import * as tts from "../../src/tts";
import { setRecordingState } from "../../src/recording-state";
import { handleSocketCommand } from "../../src/socket-handlers";
import { runBarCapture, runHistoryTranscription, finishBarCapture, recordingJobCancelled,
  recordingJobsSnapshot } from "../../src/recording-jobs";

const path = process.env.VOICELAYER_RECORD_TLC_CASES;
const isolated = process.env.VOICELAYER_TEST_ISOLATED === "1";
function deferred() { return Promise.withResolvers<void>(); }
async function until(predicate: () => boolean) {
  const deadline = performance.now() + 2000;
  while (!predicate()) {
    if (performance.now() >= deadline) throw Error("Owned replay did not settle");
    await Bun.sleep(1);
  }
}
afterEach(() => {
  if (!isolated) return;
  expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
  setRecordingState("idle");
  booking.clearCancelSignal(); booking.clearStopSignal();
});
test.skipIf(!path || !isolated)("TLC fixed socket admission and scoped capture cancel agree with the real handler", async () => {
  const cases = z.object({ admissions: z.array(z.object({ state: z.enum(["idle", "transcribing"]),
    outcome: z.literal("accept") })).min(2) }).parse(JSON.parse(readFileSync(z.string().parse(path), "utf8")));
  const owned = spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true });
  const broadcast = spyOn(socket, "broadcast").mockImplementation(() => {});
  const depth = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0);
  try {
    for (const kind of ["live", "history"] as const) for (const row of cases.admissions) {
      const a = randomUUID(), b = randomUUID();
      const decoding = deferred(), decoded = deferred(), captured = deferred();
      let aCancelled: boolean | undefined;
      const work = async () => { decoding.resolve(); await decoded.promise; aCancelled = recordingJobCancelled(); return null; };
      const first = row.state === "transcribing" ? (kind === "live"
        ? runBarCapture(a, () => finishBarCapture(Promise.resolve(), "a.wav", work))
        : runHistoryTranscription(a, work)) : Promise.resolve(null);
      if (row.state === "transcribing") await decoding.promise;
      const wait = spyOn(input, "waitForInput").mockImplementation(async () => {
        await captured.promise;
        expect(input.consumeCancelSignalForRecording()).toBe(true);
        return finishBarCapture(Promise.resolve(), "b-kept.wav", async () => null);
      });
      try {
        // Missing take_id is supported too: trusted socket ingress assigns a new identity.
        const reply = await handleSocketCommand({ cmd: "record", ...(kind === "live" ? { take_id: b } : {}), press_to_talk: true });
        expect(reply).toMatchObject({ outcome: row.outcome });
        expect(wait).toHaveBeenCalledTimes(1);
        const mic = recordingJobsSnapshot().mic_take_id;
        expect(mic).not.toBeNull();
        expect(await handleSocketCommand({ cmd: "cancel", take_id: mic ?? "missing" })).toMatchObject({ outcome: "accept" });
        expect(booking.hasCancelSignal()).toBe(false);
      } finally {
        captured.resolve(); decoded.resolve();
        await first;
        await until(() => recordingJobsSnapshot().recording_jobs.length === 0);
        wait.mockRestore();
      }
      if (row.state === "transcribing") expect(aCancelled).toBe(false);
      booking.clearStopSignal();
    }
    console.info(`Replayed ${cases.admissions.length} fixed socket classes for live/History, with scoped B cancellation`);
  } finally { [owned, broadcast, depth].forEach(mock => mock.mockRestore()); }
});

test.skipIf(!path || !isolated)("stale processing cancellation cannot target a later take and never consumes the global signal", async () => {
  const broadcast = spyOn(socket, "broadcast").mockImplementation(() => {});
  const a = randomUUID(), b = randomUUID(), enteredA = deferred(), finishA = deferred(), enteredB = deferred(), finishB = deferred();
  let bCancelled: boolean | undefined;
  try {
    const first = runHistoryTranscription(a, async () => { enteredA.resolve(); await finishA.promise; return null; });
    await enteredA.promise;
    expect(await handleSocketCommand({ cmd: "cancel", take_id: a })).toMatchObject({ outcome: "accept" });
    finishA.resolve(); await first;
    const second = runHistoryTranscription(b, async () => {
      enteredB.resolve(); await finishB.promise;
      bCancelled = recordingJobCancelled();
      expect(input.consumeCancelSignalForRecording()).toBe(false); return null;
    });
    await enteredB.promise;
    try {
      expect(await handleSocketCommand({ cmd: "cancel", take_id: a })).toMatchObject({ outcome: "noop" });
      booking.setCancelSignal();
    } finally { finishB.resolve(); await second; }
    expect(bCancelled).toBe(false);
    expect(input.consumeCancelSignalForRecording()).toBe(true); // legacy signal remains owned by the legacy path
    expect(input.consumeCancelSignalForRecording()).toBe(false);
  } finally { broadcast.mockRestore(); }
});
