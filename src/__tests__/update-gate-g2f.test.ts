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

test("G2f concurrent durability waiters share one backoff driver and retain failure evidence", async () => {
  const archive = beginSpeechArchive("shared retry driver"); await archive.settled();
  const real = speechArchiveWriter.write.bind(speechArchiveWriter);
  let recovering = false;
  const write = spyOn(speechArchiveWriter, "write").mockImplementation((...args) =>
    recovering || args[0] !== archive.key ? real(...args) : Promise.reject(Error("IO_ERROR"))); mocks.push(write);
  archive.playerStarted(); await archive.settled();
  const log = console.error as ReturnType<typeof spyOn>; log.mockClear(); write.mockClear();
  const waiters = Array.from({ length: 16 }, () => settleSpeechArchivesForUpdate(archive));
  try {
    await Bun.sleep(80);
    // Other full-suite archives may still be retrying; measure only this owner.
    expect(write.mock.calls.filter(args => args[0] === archive.key).length).toBeLessThanOrEqual(5);
    expect(archive.failures).toHaveLength(1);
    expect(log).not.toHaveBeenCalled(); // The original failure is already reported and retained.
  } finally { recovering = true; await archive.retryFailed(); await Promise.all(waiters); }
});

for (const kind of ["DRAINING", "PREPARED", "COMMITTED"]) test(`G2g ${kind} unreadable ledger admits unregistered voice`, () => {
  fs.writeFileSync(path, JSON.stringify({ version: 1, kind, lease, ...(kind === "DRAINING" ? {} : { native: ack, daemon: ack }) }));
  fs.chmodSync(path + ".admissions", 0o000);
  try {
    expect(() => fs.readdirSync(path + ".admissions")).toThrow();
    expect(gate.updateVoiceGate({ kind: "CANCEL", lease })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
    expect(gate.withVoiceAdmission(() => "voice")).toBe("voice");
    expect(fs.existsSync(path + ".voice-diag.json")).toBe(true);
    expect(console.error).toHaveBeenCalled();
  } finally { fs.chmodSync(path + ".admissions", 0o700); }
  expect(fs.readdirSync(path + ".admissions")).toEqual([]);
  expect(gate.updateVoiceGate({ kind: "CANCEL", lease })).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
});
test("G2g OPEN admission never reads the ledger", () => {
  const read = spyOn(fs, "readdirSync"); mocks.push(read);
  expect(gate.withVoiceAdmission(() => "voice")).toBe("voice");
  expect(read).not.toHaveBeenCalled();
});
test("G2g duplicate playing selection has a truthful noop reason", async () => {
  fakeReads(); fs.mkdirSync(path + ".lock");
  const first = selection("one", "same playing selection");
  const second = selection("two", "same playing selection");
  fs.rmdirSync(path + ".lock");
  expect(await first).toMatchObject({ outcome: "accept" });
  expect(await second).toMatchObject({ outcome: "noop", reason: "Already playing" });
});
for (const cmd of ["stop", "cancel"] as const) test(`G2g idle ${cmd} acknowledges cancelled admissions`, async () => {
  tts.stopPlayback(); fs.mkdirSync(path + ".lock");
  const speech = gate.withAsyncVoiceAdmission(() => "must not start"); void speech.catch(() => {});
  try {
    expect(await handleSocketCommand({ cmd })).toMatchObject({ outcome: "accept", reason: "pending admissions cancelled" });
  } finally { fs.rmdirSync(path + ".lock"); await expect(speech).rejects.toThrow("cancelled before start"); }
});
test("G2g daemon startup has no double blank line", () => {
  const source = fs.readFileSync(join(import.meta.dir, "..", "mcp-server-daemon.ts"), "utf8");
  expect(source).not.toContain("\n\n\n");
});
