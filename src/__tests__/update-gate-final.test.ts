import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import * as fs from "fs";
import { join } from "path";
import * as gate from "../update-gate-admission";
import { applyUpdateGateCommand, withUpdateGateLock } from "../update-gate-storage";
import { beginSpeechArchive, settleSpeechArchivesForUpdate } from "../speech-archive-live";
import { speechArchiveWriter } from "../speech-archive-writer";
import { withChildFixtureEnv } from "./setup/child-env";
import * as input from "../input";
import * as audio from "../audio-utils";
import * as tts from "../tts";
import { TTS_DISABLED_FILE, VOICE_DISABLED_FILE, MIC_DISABLED_FILE } from "../paths";
import * as launcher from "../voice-bar-launcher";
import { handleVoiceSpeak } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
const initial = { version: 1, kind: "OPEN", generation: 0, released: null };
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001", ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
let path: string;
let flags: Array<[string, Buffer | null]>;
const mocks: Array<{ mockRestore(): void }> = [];
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
beforeEach(() => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  flags = [TTS_DISABLED_FILE, VOICE_DISABLED_FILE, MIC_DISABLED_FILE].map(file => [file, fs.existsSync(file) ? fs.readFileSync(file) : null]);
  path = join(fs.mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "final-")), "gate.json");
  process.env.VOICELAYER_UPDATE_GATE_PATH = path;
  mocks.push(spyOn(console, "error").mockImplementation(() => {}));
});
afterEach(() => { for (const [file, data] of flags) { if (data) fs.writeFileSync(file, data); else if (fs.existsSync(file)) fs.unlinkSync(file); } mocks.splice(0).reverse().forEach(mock => mock.mockRestore()); process.env.VOICELAYER_UPDATE_GATE_PATH = original; });
function fixture() { fs.writeFileSync(path, JSON.stringify(initial)); fs.mkdirSync(path + ".admissions"); }
test("fresh host voice bootstraps OPEN gen 0 exclusively; updater alone never bootstraps", () => {
  expect(gate.updateVoiceGate({ kind: "COMMIT", lease }, () => true)).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  expect(fs.existsSync(path)).toBe(false);
  expect(gate.withVoiceAdmission(() => "speak/record admitted")).toBe("speak/record admitted");
  expect(JSON.parse(fs.readFileSync(path, "utf8"))).toEqual(initial);
  expect(fs.readdirSync(path + ".admissions")).toEqual([]);
  const closed = { version: 1, kind: "DRAINING", lease };
  fs.writeFileSync(path, JSON.stringify(closed));
  expect(() => gate.withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY");
  expect(JSON.parse(fs.readFileSync(path, "utf8"))).toEqual(closed);
});
for (const data of ["{broken", JSON.stringify({ ...initial, generation: 7 })]) test("bad existing gate admits voice with persisted diagnostic; updater refuses", () => {
  fs.writeFileSync(path, data);
  expect(gate.withVoiceAdmission(() => "words preserved")).toBe("words preserved");
  expect(fs.readFileSync(path, "utf8")).toBe(data);
  expect(fs.existsSync(path + ".voice-diag.json")).toBe(true);
  expect(console.error).toHaveBeenCalled();
  expect(gate.updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, () => true)).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
});
test("cross-process lock contention preserves voice without calling it a closed gate", async () => {
  fixture();
  const source = `import { withUpdateGateLock } from ${JSON.stringify(join(import.meta.dir, "..", "update-gate-storage.ts"))}; import {writeFileSync} from 'fs'; withUpdateGateLock(p=>{writeFileSync(p+'.ready','1');Bun.sleepSync(80);});`;
  const child = withChildFixtureEnv(process.env, () => Bun.spawn([process.execPath, "-e", source], { env: process.env, stdout: "pipe", stderr: "pipe" }));
  try {
    const deadline = Date.now() + 2000;
    while (!fs.existsSync(path + ".ready")) { if (Date.now() > deadline) throw Error("barrier"); await Bun.sleep(1); }
    expect(gate.withVoiceAdmission(() => 1)).toBe(1);
    expect(await child.exited).toBe(0);
  } finally { child.kill(); }
});
test("release survives more than 100 lock collisions and ownership mismatch never orphans the lock", () => {
  fixture();
  const retained = gate.withVoiceAdmission(() => gate.captureVoiceAdmission());
  const timers: Array<() => void> = [];
  mocks.push(spyOn(globalThis, "setTimeout").mockImplementation(((run: () => void) => { timers.push(run); return 1; }) as never));
  withUpdateGateLock(() => {
    retained.release();
    for (let n = 0; n < 130; n++) { expect(timers.length).toBeGreaterThan(0); timers.shift()!(); }
  });
  timers.shift()!();
  expect(fs.readdirSync(path + ".admissions")).toEqual([]);
  const changed = gate.withVoiceAdmission(() => gate.captureVoiceAdmission());
  const record = join(path + ".admissions", fs.readdirSync(path + ".admissions")[0]);
  fs.writeFileSync(record, "changed owner"); changed.release();
  expect(fs.existsSync(path + ".lock")).toBe(false);
  expect(fs.readFileSync(record, "utf8")).toBe("changed owner");
});
test("ledger writes avoid media sync and median admission-to-rec-spawn overhead is <=5ms", async () => {
  fixture();
  const elapsed: number[] = [];
  mocks.push(spyOn(audio, "detectNativeInputFormat").mockReturnValue({ sampleRate: 16000, channels: 1 }));
  let start = 0;
  mocks.push(spyOn(Bun, "spawn").mockImplementation(() => {
    elapsed.push(performance.now() - start);
    return { stdout: new ReadableStream({ start(c) { c.close(); } }), stderr: null, exited: Promise.resolve(0), kill() {} } as never;
  }));
  const sync = spyOn(fs, "fsyncSync"); mocks.push(sync);
  for (let n = 0; n < 21; n++) { start = performance.now(); await input.recordToBuffer(1, "standard", true); }
  const median = elapsed.sort((a,b) => a-b)[10];
  console.info(`admission-to-rec spawn median=${median.toFixed(3)}ms n=${elapsed.length}`);
  expect(median).toBeLessThanOrEqual(5);
  expect(sync).not.toHaveBeenCalled();
});
test("archive retry clears only its own uncertainty; deterministic drop does not taint a later archive", async () => {
  fixture();
  const first = beginSpeechArchive("first"); await first.settled();
  const write = spyOn(speechArchiveWriter, "write").mockRejectedValue(Error("IO_ERROR")); mocks.push(write);
  first.playerStarted(); await first.settled();
  write.mockRestore(); await first.retryFailed();
  await expect(settleSpeechArchivesForUpdate(first)).resolves.toBeUndefined();
  const dropped = beginSpeechArchive("dropped"); await dropped.settled();
  const bad = spyOn(speechArchiveWriter, "write").mockRejectedValue(Error("CONFLICT")); mocks.push(bad);
  dropped.playerStarted(); await dropped.settled(); await dropped.retryFailed(); bad.mockRestore();
  const later = beginSpeechArchive("later"); await later.settled();
  await expect(settleSpeechArchivesForUpdate(dropped)).rejects.toThrow("UNKNOWN");
  gate.withVoiceAdmission(() => gate.holdVoiceAdmission(settleSpeechArchivesForUpdate(dropped))); await tick();
  const ownUnresolved = fs.readdirSync(path + ".admissions"); expect(ownUnresolved).toHaveLength(1);
  await gate.withVoiceAdmission(async () => { gate.holdVoiceAdmission(settleSpeechArchivesForUpdate(later)); });
  await tick();
  expect(fs.readdirSync(path + ".admissions")).toEqual(ownUnresolved);
});
test("mute and think bypass drain admission, replay remains gated; paused replay is a control", async () => {
  fixture(); gate.updateVoiceGate({ kind: "REQUEST", lease });
  mocks.push(spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}));
  expect((await handleVoiceSpeak({ enabled: false })).isError).not.toBe(true);
  expect((await handleVoiceSpeak({ message: "silent synthetic note", mode: "think" })).isError).not.toBe(true);
  expect((await handleVoiceSpeak({ replay_index: 0 })).isError).toBe(true);
  mocks.push(spyOn(tts, "isPlaybackPaused").mockReturnValue(true), spyOn(tts, "restartPlayback").mockReturnValue(true));
  expect(await handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "accept" });
});
test("old storage command API cannot prepare/commit around active ledger", () => {
  fixture();
  gate.withVoiceAdmission(() => {
    expect(applyUpdateGateCommand({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
    expect(applyUpdateGateCommand({ kind: "PREPARE", lease, native: ack, daemon: ack }, process.env, () => true).kind).toBe("REFUSED");
  });
});
test("mic stream task errors surface after confirmed teardown without leaking admission", async () => {
  fixture();
  let end!: () => void, close!: ReadableStreamDefaultController<Uint8Array>;
  const exited = new Promise<number>(resolve => { end = () => resolve(0); });
  mocks.push(spyOn(audio, "detectNativeInputFormat").mockReturnValue({ sampleRate: 16000, channels: 1 }),
    spyOn(Bun, "spawn").mockImplementation(() => ({
      stdout: new ReadableStream({ start(c) { close = c; c.enqueue(new Uint8Array(1024)); } }), stderr: null, exited,
      kill() { try { close.close(); } catch {} end(); },
    }) as never));
  const stream = input.startMicChunkStream({ onChunk: async () => { throw Error("synthetic chunk failure"); } });
  await expect(stream.exited).rejects.toThrow("synthetic chunk failure"); await tick();
  expect(fs.readdirSync(path + ".admissions")).toEqual([]);
});
test("a pending archive retry releases the original admission when that retry succeeds", async () => {
  fixture();
  const archive = beginSpeechArchive("recoverable"); await archive.settled();
  const bad = spyOn(speechArchiveWriter, "write").mockRejectedValue(Error("IO_ERROR")); mocks.push(bad);
  archive.playerStarted(); await archive.settled();
  gate.withVoiceAdmission(() => gate.holdVoiceAdmission(settleSpeechArchivesForUpdate(archive)));
  await tick(); expect(fs.readdirSync(path + ".admissions")).toHaveLength(1);
  bad.mockRestore(); await archive.retryFailed(); await tick();
  expect(fs.readdirSync(path + ".admissions")).toEqual([]);
});
for (const entry of ["record", "speak"]) test(`fresh host actual ${entry} ingress creates OPEN gen 0`, async () => {
  mocks.push(spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}));
  if (entry === "record") {
    mocks.push(spyOn(audio, "detectNativeInputFormat").mockReturnValue({ sampleRate: 16000, channels: 1 }),
      spyOn(Bun, "spawn").mockReturnValue({ stdout: new ReadableStream({ start(c) { c.close(); } }), stderr: null, exited: Promise.resolve(0), kill() {} } as never));
    await input.recordToBuffer(1, "standard", true); expect(Bun.spawn).toHaveBeenCalledTimes(1);
  } else {
    mocks.push(spyOn(tts, "speak").mockResolvedValue({}));
    expect((await handleVoiceSpeak({ message: "synthetic fresh host", mode: "announce" })).isError).not.toBe(true);
    expect(tts.speak).toHaveBeenCalledTimes(1);
  }
  expect(JSON.parse(fs.readFileSync(path, "utf8"))).toEqual(initial);
});
test("readback seek refuses synchronously during drain rather than acknowledging a delayed start", () => {
  fixture(); gate.updateVoiceGate({ kind: "REQUEST", lease });
  expect(tts.seekPlayback(0, "readback")).toMatchObject({ outcome: "reject", reason: expect.stringContaining("UPDATE_BUSY") });
});
