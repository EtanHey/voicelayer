import { reserveStandardVoiceOperation } from "../voice-operation-reservation";
import { afterEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { STOP_FILE, CANCEL_FILE, getRecordingsArchiveRoot } from "../paths";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { readdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import * as input from "../input";
import * as tts from "../tts";
import * as stt from "../stt";
import * as socket from "../socket-client";
import { handleSocketCommand } from "../socket-handlers";
import { getEffectiveRecordingState, setRecordingState } from "../recording-state";
import { runBarCapture, runHistoryTranscription, finishBarCapture, deliverInputTranscription,
  acknowledgeDictationDelivery, cancelRecordingJob, recordingJobsSnapshot, recordingJobCancelled,
  replayRecordingJobs, mayUpdateRetainedCapture } from "../recording-jobs";
import { clearStopSignal, clearCancelSignal, hasCancelSignal } from "../session-booking";
import { parseCommand, type SocketEvent } from "../socket-protocol";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>(accept => { resolve = accept; });
  return { promise, resolve };
}
async function until(predicate: () => boolean) {
  for (let i = 0; i < 300; i++) { if (predicate()) return; await Bun.sleep(10); }
  throw new Error("isolated runtime did not settle");
}
const spies: Array<{ mockRestore(): void }> = [];
afterEach(() => {
  for (const spy of spies.splice(0).reverse()) spy.mockRestore();
  clearStopSignal(); clearCancelSignal();
  expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
  setRecordingState("idle");
});

describe("recording job runtime (isolated fake recorder, never real mic)", () => {
  it("review817 VAD stop signals have consumption provenance and an explicit stop label", async () => {
    const logs: string[] = [];
    spies.push(spyOn(console, "error").mockImplementation((...args) => { logs.push(args.join(" ")); }));
    const capture = input.recordToBuffer(2000, "quick", false);
    await until(() => logs.some(line => line.includes('"event":"first-pcm"')));
    writeFileSync(STOP_FILE, JSON.stringify({ physical_press: true, cancelled: true }));
    await capture;
    await until(() => logs.some(line => line.includes('"event":"exit"')));
    const trace = logs.filter(line => line.startsWith("[voicelayer][capture-lifecycle] ")).map(line => JSON.parse(line.slice(line.indexOf("{"))));
    expect(trace.find(row => row.event === "consume-stop")).toMatchObject({ control_cancelled: true, physical_press: true });
    expect(trace.find(row => row.event === "finish")).toMatchObject({ stop_reason: "stop-signal", control_cancelled: true });
    expect(trace.filter(row => row.event === "first-pcm")).toHaveLength(1);
    expect(trace.find(row => row.event === "finish").first_pcm_ms).toBeGreaterThanOrEqual(0);
    expect(trace.find(row => row.event === "exit")).toHaveProperty("signal_code");
  });

  for (const scenario of ["capturing-bare", "opening-bare", "opening-scoped", "opening-cancel"]) {
    // BARE-STOP: the bare scenarios now pin the fix. The bare stop is traced as ignored, writes no stop and the take
    // keeps recording; only its own scoped stop ends it. The scoped scenarios are unchanged.
    it(`review817 characterizes ${scenario} control provenance${scenario.endsWith("bare") ? " and the bare stop leaves the take recording" : " without changing routing"}`, async () => {
      const events: SocketEvent[] = [], logs: string[] = [];
      spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
      spies.push(spyOn(console, "error").mockImplementation((...args) => { logs.push(args.join(" ")); }));
      const open = deferred<void>();
      if (scenario.startsWith("opening")) {
        const pause = tts.pauseForF5Capture;
        spies.push(spyOn(tts, "pauseForF5Capture").mockImplementation(ms => {
          const loan = pause(ms);
          return { ...loan, ready: loan.ready.then(() => open.promise) };
        }));
        const spawn = Bun.spawn;
        spies.push(spyOn(Bun, "spawn").mockImplementation((...args: Parameters<typeof Bun.spawn>) => {
          const command = args[0];
          if (Array.isArray(command) && command.includes("signed")) {
            return spawn([process.execPath, "-e", "await Bun.sleep(600); process.stdout.write(new Uint8Array(32000)); await Bun.sleep(60000)"],
              { stdout: "pipe", stderr: "pipe", env: process.env });
          }
          if (Array.isArray(command)) {
            return spawn(command, { ...args[1], env: { ...process.env, ...args[1]?.env } });
          }
          return spawn({ ...command, env: { ...process.env, ...command.env } });
        }));
      }
      const root = getRecordingsArchiveRoot();
      const before = new Set(existsSync(root) ? readdirSync(root, { recursive: true }) : []);
      const id = randomUUID(), controlID = randomUUID();
      expect(await handleSocketCommand({ cmd: "record", id: randomUUID(), take_id: id, press_to_talk: true })).toMatchObject({ outcome: "accept" });
      if (scenario === "capturing-bare") await until(() => events.some(e => e.type === "state" && e.capture_id !== undefined));
      const scoped = scenario === "opening-scoped" || scenario === "opening-cancel";
      const bare = !scoped;
      const rows = () => logs.filter(line => line.startsWith("[voicelayer][capture-lifecycle] ")).map(line => JSON.parse(line.slice(line.indexOf("{"))));
      expect(await handleSocketCommand({ cmd: scenario === "opening-cancel" ? "cancel" : "stop", id: controlID,
        ...(scoped ? { take_id: id, physical_press: true } : {}) })).toMatchObject({ outcome: "accept" });
      open.resolve();
      if (bare) {
        expect(rows().find(row => row.event === "ignore-unscoped-stop")).toMatchObject({ route: "unscoped-speech-only",
          command_id: controlID, command_take_id: null, take_id: id });
        // The take is still live 600 ms on (and past the opening fixture's first PCM); nothing wrote a stop.
        await until(() => recordingJobsSnapshot().mic_take_id === id);
        if (scenario === "opening-bare") await until(() => rows().some(row => row.event === "first-pcm"));
        await Bun.sleep(600);
        expect(recordingJobsSnapshot().mic_take_id).toBe(id);
        expect(rows().filter(row => row.event === "write-stop" || row.event === "buffer-control")).toEqual([]);
        expect(await handleSocketCommand({ cmd: "stop", take_id: id, physical_press: true })).toMatchObject({ outcome: "accept" });
      }
      await until(() => recordingJobsSnapshot().recording_jobs.length === 0 && logs.some(line => line.includes('"event":"finish"')));
      const trace = rows();
      const writer = trace.find(row => row.event === "write-stop");
      if (bare) {
        // The only writer is the take's own scoped stop.
        expect(writer).toMatchObject({ route: "scoped", command_take_id: id, stamped_take_id: id });
        expect(trace.find(row => row.event === "finish")).toMatchObject({ take_id: id, control_cancelled: false, job_cancelled: false });
        expect(trace.every(row => Number.isFinite(row.t_ms) && Number.isFinite(row.monotonic_ms) && Number.isFinite(row.since_accept_ms) && row.since_accept_ms >= 0)).toBe(true);
        if (scenario === "opening-bare") {
          const audio = readdirSync(root, { recursive: true }).filter(name => typeof name === "string" && name.endsWith("audio.wav") && !before.has(name));
          expect(audio).toHaveLength(1);
          expect(readFileSync(join(root, String(audio[0]))).byteLength).toBeGreaterThan(44); // no header-only take
        }
        return;
      }
      expect(writer).toMatchObject({ route: "buffered-in-opening", command_id: controlID, command_take_id: id, stamped_take_id: id });
      const finish = trace.find(row => row.event === "finish");
      expect(finish).toMatchObject({ take_id: id, control_cancelled: scenario === "opening-cancel", job_cancelled: scenario === "opening-cancel" });
      expect(trace.every(row => Number.isFinite(row.t_ms) && Number.isFinite(row.monotonic_ms) && Number.isFinite(row.since_accept_ms) && row.since_accept_ms >= 0)).toBe(true);
      if (scenario.startsWith("opening")) {
        expect(finish).toMatchObject({ first_pcm_ms: null, frames_written: 0 });
        expect(trace.filter(row => row.event === "first-pcm")).toHaveLength(0);
        const audio = readdirSync(root, { recursive: true }).filter(name => typeof name === "string" && name.endsWith("audio.wav") && !before.has(name));
        expect(audio).toHaveLength(1);
        expect(readFileSync(join(root, String(audio[0]))).byteLength).toBe(44);
      }
      expect(recordingJobsSnapshot().mic_take_id).toBeNull();
    });
  }

  for (const gapMs of [0, 1000, 3000]) {
    it(`back-to-back socket captures retain frames after ${gapMs}ms and reject old controls`, async () => {
      const events: SocketEvent[] = [];
      const logs: string[] = [];
      spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
      spies.push(spyOn(console, "error").mockImplementation((...args) => { logs.push(args.join(" ")); }));
      const first = randomUUID(), second = randomUUID();
      for (const id of [first, second]) {
        if (id === second) await Bun.sleep(gapMs);
        writeFileSync(STOP_FILE, "stale previous stop");
        writeFileSync(CANCEL_FILE, "stale previous cancel");
        expect(await handleSocketCommand({ cmd: "record", id: randomUUID(), take_id: id, press_to_talk: true }))
          .toMatchObject({ outcome: "accept" });
        await until(() => events.some(e => e.type === "state" && e.take_id === id && e.capture_id !== undefined));
        if (id === second) {
          expect(await handleSocketCommand({ cmd: "stop", take_id: first })).toMatchObject({ outcome: "noop" });
          expect(await handleSocketCommand({ cmd: "cancel", take_id: first })).toMatchObject({ outcome: "noop" });
        }
        await Bun.sleep(200);
        expect(recordingJobsSnapshot().mic_take_id).toBe(id);
        expect(await handleSocketCommand({ cmd: "stop", take_id: id })).toMatchObject({ outcome: "accept" });
        await until(() => recordingJobsSnapshot().recording_jobs.length === 0);
      }
      const finished = logs.filter(line => line.startsWith("[voicelayer][capture-lifecycle] "))
        .map(line => JSON.parse(line.slice(line.indexOf("{") ))).filter(row => row.event === "finish");
      expect(finished).toHaveLength(2);
      expect(finished.every(row => row.frames_written > 0 && row.stop_reason === "stop-signal")).toBe(true);
      expect(finished[0].capture_id).not.toBe(finished[1].capture_id);
      expect(finished.map(row => row.take_id)).toEqual([first, second]);
      expect(finished.map(row => row.stop_take_id)).toEqual([first, second]);
      expect(finished.every(row => typeof row.recorder_pid === "number")).toBe(true);
    });
  }

  it("keeps a running 3:03 History retranscription alive through socket F5 capture and its cancellation", async () => {
    const events: SocketEvent[] = [];
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
    const decode = deferred<stt.STTResult>();
    const entered = deferred<void>();
    spies.push(spyOn(stt, "getBackend").mockResolvedValue({ name: "synthetic", isAvailable: async () => true,
      transcribe: async () => { entered.resolve(); return decode.promise; } }));
    const archive = input.archiveVoiceBarUntranscribedRecording({
      audioBytes: input.createWavBuffer(new Uint8Array(183 * 16000 * 2)), source: "voicebar",
      silenceMode: "standard", pushToEnd: true, durationMs: 183000, backend: "synthetic", reason: "captured",
    });
    if (!archive) throw new Error("synthetic History fixture was not archived");
    const historyID = randomUUID(), takeID = randomUUID();
    const ack = await handleSocketCommand({ cmd: "retranscribe_recording", id: historyID, audio_path: join(archive, "audio.wav") });
    expect(ack).toMatchObject({ outcome: "accept" });
    await entered.promise;
    const recordAck = await handleSocketCommand({ cmd: "record", id: randomUUID(), take_id: takeID, press_to_talk: true });
    expect(recordAck).toMatchObject({ outcome: "accept" });
    try {
      await until(() => events.some(e => e.type === "state" && e.take_id === takeID && e.state === "recording" && e.capture_id !== undefined));
      expect(hasCancelSignal()).toBe(false);
      decode.resolve({ text: "History recovered", backend: "synthetic", durationMs: 183000 });
      await until(() => !recordingJobsSnapshot().recording_jobs.some(job => job.take_id === historyID));
      expect(getEffectiveRecordingState()).toBe("recording");
      expect(events.some(e => e.type === "transcription" && e.take_id === historyID && e.job_kind === "history" && e.text.startsWith("History recovered"))).toBe(true);
      expect(readFileSync(join(archive, "voicelayer-transcript.txt"), "utf8")).toMatch(/^History recovered/);
      expect(existsSync(join(archive, "audio.wav"))).toBe(true);
      expect(await handleSocketCommand({ cmd: "cancel", take_id: takeID })).toMatchObject({ outcome: "accept" });
      await until(() => recordingJobsSnapshot().recording_jobs.length === 0);
      expect(events.filter(e => e.type === "transcription" && e.take_id === takeID)).toEqual([]);
    } finally {
      decode.resolve({ text: "History recovered", backend: "synthetic", durationMs: 183000 });
      await handleSocketCommand({ cmd: "cancel", take_id: takeID });
      await until(() => recordingJobsSnapshot().recording_jobs.length === 0);
    }
  });

  it("holds FIFO through paste ack/reconnect and never clears or cancels a newer capture", async () => {
    const events: SocketEvent[] = [];
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
    const a = randomUUID(), b = randomUUID(), c = randomUUID();
    const entered = deferred<void>(), decode = deferred<void>(), finishC = deferred<void>();
    let oldMayWriteRecovery: boolean | undefined;
    const first = runBarCapture(a, () => finishBarCapture(Promise.resolve(), "a.wav", async () => {
      entered.resolve(); await decode.promise;
      oldMayWriteRecovery = mayUpdateRetainedCapture();
      expect(recordingJobCancelled()).toBe(false);
      await deliverInputTranscription({ type: "transcription", text: "first\r\nשלום fu…" });
      return "first";
    }));
    await entered.promise;
    let decodedB = false;
    const second = runBarCapture(b, () => finishBarCapture(Promise.resolve(), "b.wav", async () => {
      decodedB = true;
      await deliverInputTranscription({ type: "transcription", text: "second" });
      return "second";
    }));
    await until(() => recordingJobsSnapshot().mic_take_id === null);
    const third = runBarCapture(c, async () => {
      await finishC.promise;
      return finishBarCapture(Promise.resolve(), "c.wav", async () => null);
    });
    decode.resolve();
    await until(() => events.some(e => e.type === "transcription" && e.take_id === a));
    expect(oldMayWriteRecovery).toBe(false);
    expect(decodedB).toBe(false);
    expect(acknowledgeDictationDelivery(b, a)).toBe(false);
    replayRecordingJobs();
    expect(events.filter(e => e.type === "transcription" && e.take_id === a)).toHaveLength(2);
    expect(cancelRecordingJob(a)).toBe("delivery");
    expect(acknowledgeDictationDelivery(a, a)).toBe(true);
    await first;
    await until(() => decodedB);
    expect(getEffectiveRecordingState()).toBe("recording");
    expect(recordingJobsSnapshot().mic_take_id).toBe(c);
    expect(cancelRecordingJob(c)).toBe("capture");
    expect(acknowledgeDictationDelivery(b, b)).toBe(true);
    finishC.resolve();
    await Promise.all([second, third]);
    expect(events.filter(e => e.type === "transcription" && e.take_id === a)[0]).toMatchObject({
      text: "first\r\nשלום fu…", take_id: a, job_kind: "live", delivery_id: a,
    });
  });

  it("cancel ownership stays disjoint for History jobs and new live captures", async () => {
    spies.push(spyOn(socket, "broadcast").mockImplementation(() => {}));
    const history = randomUUID(), capture = randomUUID();
    const entered = deferred<void>(), finishHistory = deferred<void>(), finishCapture = deferred<void>();
    const old = runHistoryTranscription(history, async () => {
      entered.resolve(); await finishHistory.promise;
      expect(recordingJobCancelled()).toBe(false);
      return "history";
    });
    await entered.promise;
    const current = runBarCapture(capture, async () => {
      await finishCapture.promise;
      expect(recordingJobCancelled()).toBe(true);
      return finishBarCapture(Promise.resolve(), "kept-cancelled.wav", async () => null);
    });
    expect(cancelRecordingJob(capture)).toBe("capture");
    finishHistory.resolve(); await old;
    expect(getEffectiveRecordingState()).toBe("recording");
    finishCapture.resolve(); await current;
  });

  it("reconnect publishes empty ownership after work settled while the app was disconnected", () => {
    const events: SocketEvent[] = [];
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
    replayRecordingJobs();
    expect(events).toEqual([{ type: "state", state: "idle", source: "recording",
      recording_jobs: [], processing_count: 0, mic_take_id: null }]);
  });

  it("preserves an existing Ask reservation before History or a new bar capture claims state", async () => {
    spies.push(spyOn(socket, "broadcast").mockImplementation(() => {}));
    const reservation = reserveStandardVoiceOperation();
    expect(reservation).not.toBeNull();
    try {
      expect(await handleSocketCommand({ cmd: "retranscribe_recording", audio_path: "/synthetic/old/audio.wav" }))
        .toMatchObject({ outcome: "reject", reason: "busy" });
      expect(await handleSocketCommand({ cmd: "retranscribe_last" })).toMatchObject({ outcome: "reject", reason: "busy" });
      await expect(runBarCapture(randomUUID(), async () => "must not run")).rejects.toThrow("Recording already");
      expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
    } finally { reservation?.release(); }
  });

  it("archives an owned take even when recording fails before producing PCM", async () => {
    spies.push(spyOn(socket, "broadcast").mockImplementation(() => {}));
    spies.push(spyOn(input, "recordToBuffer").mockRejectedValue(new Error("Synthetic recorder launch failed")));
    let archive: string | undefined;
    await expect(runBarCapture(randomUUID(), () => input.waitForInput(30, "standard", true, {
      archiveSource: "voicebar", onArchiveCreated: path => { archive = path; },
    }))).rejects.toThrow("Synthetic recorder launch failed");
    expect(archive).toBeDefined();
    const bytes = readFileSync(join(archive!, "audio.wav"));
    expect(bytes.subarray(0, 4).toString()).toBe("RIFF");
    expect(bytes.byteLength).toBe(44);
    expect(JSON.parse(readFileSync(join(archive!, "metadata.json"), "utf8"))).toMatchObject({
      transcription_status: "recording-failed", not_transcribed_reason: "recording-failed",
    });
  });

  it("validates scoped controls and delivery receipts before dispatch", () => {
    expect(parseCommand(JSON.stringify({ cmd: "cancel", take_id: "" }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "record", take_id: 42 }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "stop", take_id: "b", physical_press: true }))).toMatchObject({ take_id: "b" });
    expect(parseCommand(JSON.stringify({ cmd: "dictation_delivered", take_id: "a", delivery_id: "a" }))).toMatchObject({ cmd: "dictation_delivered" });
    expect(parseCommand(JSON.stringify({ cmd: "dictation_delivered", take_id: "a" }))).toBeNull();
  });
});

it("R2 waits for unowned recorder exit before processing", async () => {
  const exit = deferred<void>();
  let processing = false;
  const result = finishBarCapture(exit.promise, null, async () => { processing = true; return "answer"; });
  await Promise.resolve();
  const startedEarly = processing;
  exit.resolve();
  expect(await result).toBe("answer");
  expect(startedEarly).toBe(false);
});
