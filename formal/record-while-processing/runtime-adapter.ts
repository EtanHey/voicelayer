/** Lane I's only fixture seam: seed owned take IDs here when its controller lands.
 * Decision code is always the production handleSocketCommand. Mic/playback edges remain silent.
 */
import { spyOn } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { z } from "zod";
import * as input from "../../src/input";
import * as booking from "../../src/session-booking";
import * as socket from "../../src/socket-client";
import * as tts from "../../src/tts";
import { STOP_FILE } from "../../src/paths";
import { setRecordingState } from "../../src/recording-state";
import { handleSocketCommand } from "../../src/socket-handlers";
import { runBarCapture, runHistoryTranscription, finishBarCapture, cancelRecordingJob, recordingJobCancellationState, recordingJobsSnapshot } from "../../src/recording-jobs";
import { randomUUID } from "node:crypto";
import type { SocketCommand } from "../../src/socket-protocol";

export const wireCase = z.object({ policy: z.enum(["Current", "Fixed"]), command: z.enum(["record", "cancel"]),
  origin: z.string(), phase: z.enum(["idle", "recording", "transcribing"]), before: z.record(z.string(), z.string()),
  target: z.enum(["A", "B"]), requestId: z.enum(["none", "A", "B", "stale"]), outcome: z.enum(["accept", "reject", "noop"]),
  token: z.enum(["none", "global", "A", "B"]) });
export const contractSchema = z.object({ pipelinePolicy: z.enum(["current", "fixed"]), cancelIdField: z.string(), captureIds: z.record(z.string(), z.number()) });
export type WireCase = z.infer<typeof wireCase>;
export function fixture() {
  if (process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("Run with bunfig.toml's normal isolation preload");
  const isolatedRoot = z.string().min(1).parse(process.env.VOICELAYER_TEST_RUN_ROOT);
  const oldGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
  const gate = join(mkdtempSync(join(isolatedRoot, "formal-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
  writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  mkdirSync(gate + ".admissions");
  const signal = spyOn(booking, "setCancelSignal").mockImplementation(() => {});
  const mocks = [signal, spyOn(input, "waitForInput").mockImplementation(() => finishBarCapture(Promise.resolve(), "fixture.wav", async () => null)),
    spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
    spyOn(socket, "broadcast").mockImplementation(() => {}), spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0),
    spyOn(tts, "stopPlayback").mockImplementation(() => {}), spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(tts, "isPlaybackPaused").mockReturnValue(false)];
  return {
    async dispatch(row: WireCase, contract: z.infer<typeof contractSchema>) {
      booking.clearStopSignal(); booking.clearCancelSignal(); signal.mockClear();
      const tasks: Promise<unknown>[] = [], release: Array<() => void> = [];
      const ids = Object.fromEntries(["A","B"].map(t => [t, String(contract.captureIds[t]) + "-" + randomUUID()]));
      const seedWorker = async (take: string, history = false) => {
        const entered = Promise.withResolvers<void>(), done = Promise.withResolvers<void>(); release.push(done.resolve);
        const work = async () => { entered.resolve(); await done.promise; return null; };
        tasks.push(history ? runHistoryTranscription(take, work) : runBarCapture(take, () => finishBarCapture(Promise.resolve(), "fixture.wav", work)));
        await entered.promise;
      };
      const settle = async () => {
        release.forEach(done => done()); await Promise.allSettled(tasks);
        const deadline = performance.now()+2000;
        while (recordingJobsSnapshot().recording_jobs.length) {
          if (performance.now()>deadline) throw Error("TLC owned fixture did not settle");
          await Bun.sleep(1);
        }
      };
      try {
        const worker = ["A","B"].find(t => ["transcribing","cancelling","ready"].includes(row.before[t] ?? ""));
        if (worker) await seedWorker(ids[worker]!);
        const captured = ["A","B"].filter(t => row.before[t] === "captured");
        if (captured.length && !worker) await seedWorker("fixture-" + randomUUID(), true);
        for (const t of captured) {
          const done = Promise.withResolvers<void>(); release.push(done.resolve);
          tasks.push(runBarCapture(ids[t]!, () => finishBarCapture(Promise.resolve(), "fixture.wav", async () => { await done.promise; return null; })));
          while (recordingJobsSnapshot().mic_take_id) await Bun.sleep(1);
        }
        for (const t of ["A","B"].filter(t => row.before[t] === "recording")) {
          const done = Promise.withResolvers<void>(); release.push(done.resolve);
          tasks.push(runBarCapture(ids[t]!, async () => { await done.promise; return finishBarCapture(Promise.resolve(), "fixture.wav", async () => null); }));
        }
        for (const t of ["A","B"]) if (row.before[t] === "cancelling") cancelRecordingJob(ids[t]);
        const before = Object.fromEntries(["A","B"].map(t => [t, recordingJobCancellationState(ids[t]!) === true]));
        const command: SocketCommand = row.command === "record"
          ? { cmd: "record", take_id: ids[row.target], press_to_talk: true, timeout_seconds: 3600 }
          : { cmd: "cancel", take_id: ids[row.requestId] ?? "stale" };
        const reply = await handleSocketCommand(command);
        const accepted = reply && "outcome" in reply && reply.outcome === "accept";
        const signals = row.command === "cancel" ? ["A","B"].filter(t =>
          recordingJobCancellationState(ids[t]!) === true && (!before[t] || (accepted && ids[t] === command.take_id)))
          .map(t => [contract.captureIds[t]]) : [];
        return { reply, signals, stop: existsSync(STOP_FILE) ? readFileSync(STOP_FILE, "utf8") : "" };
      } finally { await settle(); }

    },
    close() {
      setRecordingState("idle"); booking.clearStopSignal(); booking.clearCancelSignal();
      mocks.reverse().forEach(mock => mock.mockRestore());
      if (oldGate === undefined) delete process.env.VOICELAYER_UPDATE_GATE_PATH;
      else process.env.VOICELAYER_UPDATE_GATE_PATH = oldGate;
    },
  };
}
