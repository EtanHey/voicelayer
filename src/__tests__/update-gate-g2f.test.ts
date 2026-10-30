import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as fs from "node:fs";
import { join } from "node:path";
import * as gate from "../update-gate-admission";
import * as tts from "../tts";
import * as recording from "../recording-state";
import * as launcher from "../voice-bar-launcher";
import { handleVoiceSpeak } from "../handlers";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import { beginSpeechArchive, flushSpeechArchives, settleSpeechArchivesForUpdate } from "../speech-archive-live";
import { speechArchiveWriter } from "../speech-archive-writer";
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
let path: string;
const mocks: Array<{ mockRestore(): void }> = [];
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  path = join(fs.mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "g2f-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  fs.writeFileSync(path, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  fs.mkdirSync(path + ".admissions");
  recording.setRecordingState("idle");
  mocks.push(spyOn(console, "error").mockImplementation(() => {}));
});
afterEach(async () => {
  resetSelectionReadQueueForTests();
  await flushSpeechArchives();
  mocks.splice(0).reverse().forEach(m => m.mockRestore());
  process.env.VOICELAYER_UPDATE_GATE_PATH = original;
});
const selection = (id: string, text: string, queue = false) => handleSocketCommand({ cmd: "speak_text", source: "selection", id, text, queue });
function fakeReads() {
  const starts: string[] = [];
  mocks.push(spyOn(tts, "speakText").mockImplementation((_text, _profile, identity) => {
    starts.push(identity?.request_id!);
    return { id: identity?.request_id!, generation: 1, done: Promise.resolve(), playerExited: Promise.resolve(),
      started: Promise.resolve({}), completion: Promise.resolve({}) };
  }), spyOn(tts, "isPlaybackPaused").mockReturnValue(false),
  spyOn(tts, "prepareSelectionReadStart").mockRejectedValue(Error("synthetic prefetch disabled")));
  return starts;
}
test("G2f concurrent identical queued selections under contention enqueue exactly one read", async () => {
  const starts = fakeReads();
  await selection("owner", "current selection");
  fs.mkdirSync(path + ".lock");
  const first = selection("one", "same queued selection", true);
  const second = selection("two", "same queued selection", true);
  fs.rmdirSync(path + ".lock");
  expect(await first).toMatchObject({ outcome: "accept" });
  expect(await second).toMatchObject({ outcome: "noop" });
  await handleSocketCommand({ cmd: "read_next", request_id: "owner" });
  await handleSocketCommand({ cmd: "read_next", request_id: "one" });
  expect(starts).toEqual(["owner", "one"]);
});
for (const kind of ["DRAINING", "PREPARED", "COMMITTED"]) for (const ledger of ["missing", "file", "symlink", "directory"]) {
  test(`G2f ${kind} ledger=${ledger}: faults admit voice unregistered and refuse updates`, () => {
    fs.writeFileSync(path, JSON.stringify({ version: 1, kind, lease, ...(kind === "DRAINING" ? {} : { native: ack, daemon: ack }) }));
    if (ledger !== "directory") fs.rmdirSync(path + ".admissions");
    if (ledger === "file") fs.writeFileSync(path + ".admissions", "unsafe");
    if (ledger === "symlink") fs.symlinkSync(join(path, "absent"), path + ".admissions");
    if (ledger === "directory") {
      expect(() => gate.withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY");
      expect(fs.existsSync(path + ".voice-diag.json")).toBe(false);
    } else {
      expect(gate.withVoiceAdmission(() => "voice")).toBe("voice");
      expect(fs.existsSync(path + ".voice-diag.json")).toBe(true);
      expect(console.error).toHaveBeenCalled();
      expect(gate.updateVoiceGate({ kind: "REQUEST", lease })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
    }
  });
}
for (const drop of [false, true]) test(`G2f durability re-drives repeated failures, dropped=${drop}`, async () => {
  const archive = beginSpeechArchive("synthetic retry"); await archive.settled();
  const real = speechArchiveWriter.write.bind(speechArchiveWriter);
  let calls = 0;
  const write = spyOn(speechArchiveWriter, "write").mockImplementation((...args) => {
    calls++;
    if (calls <= 2) return Promise.reject(Error("IO_ERROR"));
    return drop ? Promise.reject(Error("CONFLICT")) : real(...args);
  }); mocks.push(write);
  archive.playerStarted(); await archive.settled();
  const result = settleSpeechArchivesForUpdate(archive).then(() => "durable", () => "dropped");
  gate.withVoiceAdmission(() => gate.holdVoiceAdmission(result.then(value => { if (value === "dropped") throw Error("UNKNOWN"); })));
  let timeout: ReturnType<typeof setTimeout>;
  try {
    expect(await Promise.race([result, new Promise(resolve => { timeout = setTimeout(() => resolve("parked"), 500); })])).toBe(drop ? "dropped" : "durable");
    await Bun.sleep(0);
    expect(fs.readdirSync(path + ".admissions")).toHaveLength(drop ? 1 : 0);
    expect(calls).toBeGreaterThanOrEqual(3);
  } finally { clearTimeout(timeout!); write.mockRestore(); await archive.retryFailed(); }
});
test("G2f replay launches VoiceBar only after admission", async () => {
  const launch = spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}); mocks.push(launch);
  fs.mkdirSync(path + ".lock");
  const replay = handleVoiceSpeak({ replay_index: 999999 });
  expect(launch).not.toHaveBeenCalled();
  fs.rmdirSync(path + ".lock"); await replay;
  expect(launch).toHaveBeenCalledTimes(1);
  gate.updateVoiceGate({ kind: "REQUEST", lease });
  await handleVoiceSpeak({ replay_index: 999999 });
  expect(launch).toHaveBeenCalledTimes(1);
});
test("G2f selection Next on last leaves pending capture alive", async () => {
  fakeReads(); await selection("owner", "last selection");
  fs.mkdirSync(path + ".lock");
  const capture = gate.withCaptureVoiceAdmission(() => "captured");
  expect(await handleSocketCommand({ cmd: "read_next", request_id: "owner" })).toMatchObject({ outcome: "accept" });
  fs.rmdirSync(path + ".lock");
  expect(await capture).toBe("captured");
});
for (const cmd of ["stop", "cancel"] as const) test(`G2f socket ${cmd} still cancels pending capture`, async () => {
  fs.mkdirSync(path + ".lock"); let started = false;
  const capture = gate.withCaptureVoiceAdmission(() => { started = true; });
  void capture.catch(() => {});
  await handleSocketCommand({ cmd });
  fs.rmdirSync(path + ".lock");
  await expect(capture).rejects.toThrow("cancelled before start");
  expect(started).toBe(false);
});
test("G2f stopPlayback cancels pending speech but returns whether playback was stopped", async () => {
  tts.stopPlayback(); fs.mkdirSync(path + ".lock");
  const speech = gate.withAsyncVoiceAdmission(() => "must not start"); void speech.catch(() => {});
  expect(tts.stopPlayback()).toBe(false);
  fs.rmdirSync(path + ".lock");
  await expect(speech).rejects.toThrow("cancelled before start");
});

for (const cmd of ["stop", "cancel"] as const) test(`G2f idle socket ${cmd} still cancels pending speech`, async () => {
  fs.mkdirSync(path + ".lock"); let started = false;
  const speech = gate.withAsyncVoiceAdmission(() => { started = true; }); void speech.catch(() => {});
  await handleSocketCommand({ cmd });
  fs.rmdirSync(path + ".lock");
  await expect(speech).rejects.toThrow("cancelled before start");
  expect(started).toBe(false);
});
