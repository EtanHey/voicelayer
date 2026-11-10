import { finishSyntheticCapture, settleRecordingJobs } from "./setup/recording-jobs-fixture";
import { deferredFixture as deferred } from "./long-read-fixture-barriers";
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as fs from "fs";
import { join } from "path";
import * as gate from "../update-gate-admission";
import { readUpdateGateFile, withUpdateGateLock } from "../update-gate-storage";
import { handleSocketCommand } from "../socket-handlers";
import * as input from "../input";
import * as tts from "../tts";
import * as booking from "../session-booking";
import * as socket from "../socket-client";
import * as stt from "../stt";
import { recordingJobsSnapshot } from "../recording-jobs";
import { setRecordingState } from "../recording-state";
import { VOICE_DISABLED_FILE, MIC_DISABLED_FILE } from "../paths";
const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001", ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
let path: string, flags: Array<[string, Buffer | null]>;
const mocks: Array<{ mockRestore(): void }> = [];
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  path = join(fs.mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "round1-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  fs.writeFileSync(path, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  fs.mkdirSync(path + ".admissions"); setRecordingState("idle");
  flags = [VOICE_DISABLED_FILE, MIC_DISABLED_FILE].map(file => [file, fs.existsSync(file) ? fs.readFileSync(file) : null]);
  for (const [file] of flags) if (fs.existsSync(file)) fs.unlinkSync(file);
  mocks.push(spyOn(console, "error").mockImplementation(() => {}));
});
afterEach(async () => {
  try { await settleRecordingJobs(tts.hasF5Capture); } finally {
    mocks.splice(0).reverse().forEach(m => m.mockRestore());
    for (const [file, data] of flags) { if (data) fs.writeFileSync(file, data); else if (fs.existsSync(file)) fs.unlinkSync(file); }
    process.env.VOICELAYER_UPDATE_GATE_PATH = original;
  }
});
function capture() {
  mocks.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }), spyOn(socket, "broadcast").mockImplementation(() => {}), spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
  const wait = spyOn(input, "waitForInput").mockImplementation(() => finishSyntheticCapture(async () => "synthetic words")); mocks.push(wait); return wait;
}
test("MF1 second async admission bypasses a known stale lock in under 50ms", async () => {
  fs.mkdirSync(path + ".lock");
  await gate.withAsyncVoiceAdmission(() => "first");
  const start = performance.now();
  expect(await gate.withAsyncVoiceAdmission(() => "second")).toBe("second");
  const ms = performance.now() - start; console.info(`MF1 second-admission=${ms.toFixed(3)}ms`);
  expect(ms).toBeLessThan(50); expect(fs.existsSync(path + ".lock")).toBe(true);
});
test("MF1 first record reaches waitForInput within 50ms under a held lock", async () => {
  const wait = capture(), started = deferred<void>(); let elapsed = Infinity; const start = performance.now();
  wait.mockImplementation(async () => { elapsed = performance.now() - start; started.resolve(); return finishSyntheticCapture(async () => "words"); });
  fs.mkdirSync(path + ".lock");
  expect(await handleSocketCommand({ cmd: "record", press_to_talk: true, timeout_seconds: 3600 })).toMatchObject({ outcome: "accept" });
  await started.promise;
  console.info(`MF1 first-capture=${elapsed.toFixed(3)}ms`); expect(elapsed).toBeLessThanOrEqual(50);
  expect(wait).toHaveBeenCalledTimes(1);
});
test("MF2 post-rename persistence plus both diagnostic failures retains the lock", async () => {
  gate.updateVoiceGate({ kind: "REQUEST", lease });
  const sync = fs.fsyncSync, write = fs.writeFileSync, mkdir = fs.mkdirSync; let syncs = 0;
  mocks.push(spyOn(fs, "fsyncSync").mockImplementation(fd => { if (++syncs === 2) throw Error("synthetic post-rename sync failure"); sync(fd); }));
  mocks.push(spyOn(fs, "writeFileSync").mockImplementation(((file: unknown, ...args: unknown[]) => { if (file === path + ".voice-diag.json") throw Error("synthetic diagnostic failure"); return (write as Function)(file, ...args); }) as never));
  mocks.push(spyOn(fs, "mkdirSync").mockImplementation(((file: unknown, ...args: unknown[]) => { if (file === path + ".voice-diag.json") throw Error("synthetic marker failure"); return (mkdir as Function)(file, ...args); }) as never));
  expect(gate.updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, () => true)).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  expect(JSON.parse(fs.readFileSync(path, "utf8")).kind).toBe("PREPARED");
  expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
  expect(fs.existsSync(path + ".lock")).toBe(true);
  expect(await gate.withAsyncVoiceAdmission(() => "words")).toBe("words");
  expect(readUpdateGateFile()).toEqual({ kind: "UNKNOWN" });
  expect(gate.updateVoiceGate({ kind: "COMMIT", lease }, () => true).kind).toBe("REFUSED");
});
test("MF2 G1 observation treats diagnostic-fenced published bytes as UNKNOWN", () => {
  fs.writeFileSync(path + ".voice-diag.json", "{}");
  expect(readUpdateGateFile()).toEqual({ kind: "UNKNOWN" });
});
for (const cmd of ["stop", "cancel"] as const) test(`SF1 ${cmd} prevents a pending record from ever starting`, async () => {
  const wait = capture(); fs.mkdirSync(path + ".lock");
  const pending = Promise.resolve(handleSocketCommand({ cmd: "record", press_to_talk: true, timeout_seconds: 3600 }));
  const stopped = setTimeout(() => { void handleSocketCommand({ cmd }); }, 3);
  const unlock = setTimeout(() => fs.rmdirSync(path + ".lock"), 10);
  try {
    expect(await pending).toMatchObject({ outcome: "noop", reason: expect.stringContaining("cancelled") });
    expect(wait).not.toHaveBeenCalled();
  } finally { clearTimeout(stopped); clearTimeout(unlock); if (fs.existsSync(path + ".lock")) fs.rmdirSync(path + ".lock"); }
});
// BARE-STOP counterpart of SF1: a pending VoiceBar take that carries its own take id survives an id-less stop,
// while the same stop still cancels the anonymous record above. A cancel (Hide) still ends it.
for (const cmd of ["stop", "cancel"] as const) test(`BARE-STOP id-less ${cmd} and a pending VoiceBar take with a take id`, async () => {
  const wait = capture(); fs.mkdirSync(path + ".lock");
  const pending = Promise.resolve(handleSocketCommand({ cmd: "record", take_id: `pending-${cmd}`, press_to_talk: true, timeout_seconds: 3600 }));
  const stopped = setTimeout(() => { void handleSocketCommand({ cmd }); }, 3);
  const unlock = setTimeout(() => fs.rmdirSync(path + ".lock"), 10);
  try {
    if (cmd === "stop") {
      expect(await pending).toMatchObject({ outcome: "accept" });
      expect(wait).toHaveBeenCalledTimes(1);
    } else {
      expect(await pending).toMatchObject({ outcome: "noop", reason: expect.stringContaining("cancelled") });
      expect(wait).not.toHaveBeenCalled();
    }
  } finally { clearTimeout(stopped); clearTimeout(unlock); if (fs.existsSync(path + ".lock")) fs.rmdirSync(path + ".lock"); }
});
// BARE-STOP (Bugbot on #831): the MIC admission inside waitForInput, not just the socket record admission. The
// record's own admission is released at its synchronous ack; the lock then appears (as the previous take's admission
// release holds it in record-after-record) before waitForInput admits the mic. Real waitForInput, stub recorder.
for (const named of [true, false]) test(`BARE-STOP id-less stop vs a ${named ? "client-named" : "anonymous"} take's pending MIC admission`, async () => {
  mocks.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }), spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
  const events: Array<Record<string, unknown>> = [];
  mocks.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event as never); }));
  mocks.push(spyOn(stt, "getBackend").mockResolvedValue({ name: "synthetic", isAvailable: async () => true,
    transcribe: async () => ({ text: "", backend: "synthetic", durationMs: 0 }) }));
  const original = gate.withCaptureVoiceAdmission;
  const pendingMic = deferred<boolean>();
  mocks.push(spyOn(gate, "withCaptureVoiceAdmission").mockImplementation(((work: () => unknown, options?: { scoped?: boolean }) => {
    let started = false;
    const result = original(() => { started = true; return work(); }, options);
    pendingMic.resolve(!started); // true only if acquire(true) hit the held lock and the admission is pending
    return result;
  }) as never));
  const take = `mic-pending-${named}`;
  expect(handleSocketCommand({ cmd: "record", ...(named ? { take_id: take } : {}), press_to_talk: true, timeout_seconds: 3600 }))
    .toMatchObject({ outcome: "accept" });
  fs.mkdirSync(path + ".lock");
  let unlock: ReturnType<typeof setTimeout> | undefined;
  try {
    expect(await pendingMic.promise).toBe(true);
    await handleSocketCommand({ cmd: "stop" });
    unlock = setTimeout(() => fs.rmdirSync(path + ".lock"), 5);
    const captured = () => events.some(e => e.type === "state" && e.capture_id !== undefined);
    const deadline = performance.now() + 3000;
    while (performance.now() < deadline && !captured() && recordingJobsSnapshot().recording_jobs.length > 0) await Bun.sleep(5);
    if (named) {
      expect(captured()).toBe(true); // the take reached its recorder
      expect(recordingJobsSnapshot().mic_take_id).toBe(take);
      expect(await handleSocketCommand({ cmd: "stop", take_id: take })).toMatchObject({ outcome: "accept" });
    } else {
      expect(captured()).toBe(false); // SF1 semantics: the anonymous record is cancelled before its mic opens
    }
    const settle = performance.now() + 10_000;
    while (performance.now() < settle && recordingJobsSnapshot().recording_jobs.length > 0) await Bun.sleep(10);
    expect(recordingJobsSnapshot().recording_jobs).toEqual([]);
  } finally { if (unlock) clearTimeout(unlock); if (fs.existsSync(path + ".lock")) fs.rmdirSync(path + ".lock"); }
});
test("SF1 direct playback Stop invalidates pending async voice work", async () => {
  fs.mkdirSync(path + ".lock"); let starts = 0;
  const pending = gate.withAsyncVoiceAdmission(() => { starts++; });
  const result = pending.then(() => "started", error => String(error));
  tts.stopPlayback(); fs.rmdirSync(path + ".lock");
  expect(await result).toContain("cancelled"); expect(starts).toBe(0);
});
test("SF2 updater collisions refuse without sticky diagnostic evidence", () => {
  withUpdateGateLock(() => {
    expect(gate.updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("REFUSED");
    expect(gate.acknowledgeVoiceDrain(lease, () => true)).toBeNull();
  });
  expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
  expect(gate.updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
});
test("SF2 startup asynchronously waits through a harmless collision", async () => {
  fs.mkdirSync(path + ".lock"); const unlock = setTimeout(() => fs.rmdirSync(path + ".lock"), 10);
  try {
    await gate.initializeVoiceGate();
    expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
    expect(gate.updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
  } finally { clearTimeout(unlock); if (fs.existsSync(path + ".lock")) fs.rmdirSync(path + ".lock"); }
});
test("SF2 sync media retries brief collisions without sleeping or marking UNKNOWN", () => {
  const mkdir = fs.mkdirSync; let collisions = 0;
  mocks.push(spyOn(fs, "mkdirSync").mockImplementation(((file: unknown, ...args: unknown[]) => {
    if (file === path + ".lock" && collisions++ < 2) throw Object.assign(Error("busy"), { code: "EEXIST" });
    return (mkdir as Function)(file, ...args);
  }) as never));
  expect(gate.withVoiceAdmission(() => fs.readdirSync(path + ".admissions").length)).toBe(1);
  expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
});
test("N1 diagnostic logging never throws or strands an otherwise releasable lock", async () => {
  fs.rmdirSync(path + ".admissions"); fs.writeFileSync(path + ".admissions", "unsafe ledger");
  mocks.push(spyOn(console, "error").mockImplementation(() => { throw Error("synthetic logger failure"); }));
  expect(await gate.withAsyncVoiceAdmission(() => "words")).toBe("words");
  expect(fs.existsSync(path + ".voice-diag.json")).toBe(true);
  expect(fs.existsSync(path + ".lock")).toBe(false);
});
test("MF1 direct capture boundary also has a first-fault wait below 50ms", async () => {
  fs.mkdirSync(path + ".lock"); const start = performance.now();
  expect(await gate.withCaptureVoiceAdmission(() => "capture starts")).toBe("capture starts");
  const ms = performance.now() - start; console.info(`MF1 direct-capture=${ms.toFixed(3)}ms`);
  expect(ms).toBeLessThanOrEqual(50); expect(fs.readdirSync(path + ".admissions")).toEqual([]);
});
