import { afterEach, expect, test, spyOn } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { withVoiceAdmission, holdVoiceAdmission, updateVoiceGate, acknowledgeVoiceDrain, captureVoiceAdmission } from "../update-gate-admission";
import { withUpdateGateLock } from "../update-gate-storage";
import { updateGateFilePath, STOP_FILE, CANCEL_FILE } from "../paths";
const original = process.env.VOICELAYER_UPDATE_GATE_PATH;
afterEach(() => { process.env.VOICELAYER_UPDATE_GATE_PATH = original; });
const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
const proof = () => true;
function fixture() {
  const dir = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "admission-"));
  process.env.VOICELAYER_UPDATE_GATE_PATH = join(dir, "gate.json");
  writeFileSync(updateGateFilePath(), JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  mkdirSync(updateGateFilePath() + ".admissions");
}
function prepare() { return updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, proof); }
test("admission wins race, drain waits; closure wins, start refuses", async () => {
    fixture();
    let finish!: () => void;
    const done = new Promise<void>(resolve => { finish = resolve; });
    const operation = withVoiceAdmission(async () => { await done; });
    expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
    expect(prepare().kind).toBe("REFUSED");
    expect(() => withVoiceAdmission(() => { throw Error("MUST NOT START"); })).toThrow("UPDATE_BUSY");
    finish(); await operation;
    expect(prepare().kind).toBe("APPLIED");
    expect(updateVoiceGate({ kind: "COMMIT", lease }, proof).kind).toBe("APPLIED");
    expect(updateVoiceGate({ kind: "COMMIT", lease }, proof).kind).toBe("UNCHANGED");
});
test("queued selections keep their own admission and playback holds it through physical exit", async () => {
  fixture();
  const { SelectionReadQueue } = await import("../selection-read-queue");
  let finish!: () => void;
  const playback = new Promise<void>(resolve => { finish = resolve; }), started: string[] = [];
  const queue = new SelectionReadQueue(read => read.admission!.run(() => {
    started.push(read.requestId);
    if (read.requestId === "first") holdVoiceAdmission(playback);
    read.admission!.release();
  }), () => {});
  for (const requestId of ["first", "second"]) withVoiceAdmission(() => {
    queue.submit({ requestId, text: requestId, textHash: requestId, profile: "short", admission: captureVoiceAdmission() }, true);
  });
  updateVoiceGate({ kind: "REQUEST", lease });
  expect(prepare().kind).toBe("REFUSED");
  expect(queue.next("first")).toBe("advanced");
  expect(started).toEqual(["first", "second"]);
  expect(prepare().kind).toBe("REFUSED");
  finish(); await playback; await Promise.resolve();
  expect(prepare().kind).toBe("APPLIED");
});
test("missing state, missing ledger and stale registrations refuse; uses G1 lock", () => {
  fixture();
  withUpdateGateLock(() => expect(() => withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY"));
  process.env.VOICELAYER_UPDATE_GATE_PATH += "-missing";
  expect(() => withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY");
  fixture();
  writeFileSync(join(updateGateFilePath() + ".admissions", "stale"), "{}");
  updateVoiceGate({ kind: "REQUEST", lease });
  expect(prepare().kind).toBe("REFUSED");
  fixture();
  process.env.VOICELAYER_UPDATE_GATE_PATH += "-no-ledger";
  writeFileSync(updateGateFilePath(), JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
  expect(() => withVoiceAdmission(() => {})).toThrow("UPDATE_BUSY");
});
test("drain/cancel never write Stop or Cancel; preparation and commit require fresh participant proof", () => {
  fixture();
  const signals = [existsSync(STOP_FILE), existsSync(CANCEL_FILE)];
  updateVoiceGate({ kind: "REQUEST", lease });
  expect(updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }).kind).toBe("REFUSED");
  expect(acknowledgeVoiceDrain({ ...lease, generation: 2 }, proof)).toBeNull();
  expect(acknowledgeVoiceDrain(lease, () => false)).toBeNull();
  expect(acknowledgeVoiceDrain(lease, proof)).toEqual(ack);
  expect(prepare().kind).toBe("APPLIED");
  expect(updateVoiceGate({ kind: "COMMIT", lease }, () => false).kind).toBe("REFUSED");
  expect(updateVoiceGate({ kind: "CANCEL", lease }).kind).toBe("APPLIED");
  expect([existsSync(STOP_FILE), existsSync(CANCEL_FILE)]).toEqual(signals);
});
test("real ingress refuses before any media starts; Stop and Cancel remain available", async () => {
  fixture();
  const { handleSocketCommand } = await import("../socket-handlers");
  const { handleVoiceAsk, handleVoiceSpeak, handleConverse } = await import("../handlers");
  const { speakLocally } = await import("../cli/speak");
  const tts = await import("../tts"), input = await import("../input");
  updateVoiceGate({ kind: "REQUEST", lease });
  for (const command of [{ cmd: "speak_text", text: "hello" }, { cmd: "record" },
    { cmd: "retranscribe_last" }, { cmd: "retranscribe_recording", audio_path: "absent.wav" },
    { cmd: "preview_tts_profile", profile: "short" }, { cmd: "replay" }]) {
    expect(await handleSocketCommand(command as never)).toMatchObject({ outcome: "reject", reason: expect.stringContaining("UPDATE_BUSY") });
  }
  for (const handler of [handleVoiceAsk, handleVoiceSpeak, handleConverse]) {
    expect(await handler({ message: "hello" })).toMatchObject({ isError: true,
      content: [{ type: "text", text: expect.stringContaining("UPDATE_BUSY") }] });
  }
  for (const work of [() => tts.speak("hello"), () => tts.speakText("hello"),
    () => tts.playAudioNonBlocking("absent.wav"), () => input.waitForInput(10),
    () => input.recordToBuffer(10), () => input.startMicChunkStream({ onChunk: async () => false }),
    () => input.retranscribeLastCapture(), () => input.retranscribeRecordingCapture("absent.wav"),
    () => input.retranscribeVoiceAskArchive("absent"), () => speakLocally({ cmd: "speak_text", text: "hello", profile: "short", format: "plain", wait: true })]) {
    try { await work(); throw Error("STARTED"); } catch (error) { expect(String(error)).toContain("UPDATE_BUSY"); }
  }
  expect(await handleSocketCommand({ cmd: "read_next", request_id: "stale" })).toMatchObject({ outcome: "noop" });
  for (const cmd of ["stop", "cancel"]) expect(await handleSocketCommand({ cmd } as never)).toMatchObject({ outcome: "noop" });
});
test("real admitted Ask speaks, survives drain, captures answer; Stop still reaches playback", async () => {
  fixture();
  const tts = await import("../tts"), input = await import("../input");
  const socket = await import("../socket-client"), booking = await import("../session-booking");
  const { handleVoiceAsk, handleVoiceSpeak } = await import("../handlers");
  const { handleSocketCommand } = await import("../socket-handlers");
  let captured = false;
  const spies = [spyOn(socket, "isConnected").mockReturnValue(true),
    spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(),
    spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0),
    spyOn(tts, "stopPlayback").mockReturnValue(true),
    spyOn(tts, "speak").mockImplementation(async () => {
      expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
      expect(prepare().kind).toBe("REFUSED");
      expect(await handleVoiceSpeak({ message: "unrelated start" })).toMatchObject({ isError: true });
      expect(await handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "accept" });
      return { engine: "edge-tts", voice: "synthetic", displayText: "question",
        audioArtifact: { bytes: new Uint8Array([1]), format: "mp3" } };
    }), spyOn(input, "waitForInput").mockImplementation(async () => withVoiceAdmission(() => {
      captured = true; expect(prepare().kind).toBe("REFUSED"); return "synthetic answer";
    })), spyOn(tts, "hasPendingSpeechPreparation").mockReturnValue(true)];
  try {
    expect((await handleVoiceAsk({ message: "question" })).content[0].text).toContain("synthetic answer");
    expect(captured).toBe(true); expect(spies[4]).toHaveBeenCalledTimes(1);
    expect(prepare().kind).toBe("APPLIED");
  } finally { for (const spy of spies.reverse()) spy.mockRestore(); }
});
test("unconfirmed physical completion never acknowledges idle", async () => {
  fixture();
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    withVoiceAdmission(() => holdVoiceAdmission(Promise.reject(Error("exit unconfirmed"))));
    await Promise.resolve(); await Promise.resolve();
    updateVoiceGate({ kind: "REQUEST", lease });
    expect(prepare().kind).toBe("REFUSED");
  } finally { log.mockRestore(); }
});
test("operation release racing a drain lock retries only its own registration", async () => {
  fixture();
  const admission = withVoiceAdmission(() => captureVoiceAdmission());
  withUpdateGateLock(() => admission.release());
  expect(readdirSync(updateGateFilePath() + ".admissions")).toHaveLength(1);
  await new Promise(resolve => setTimeout(resolve, 30));
  expect(readdirSync(updateGateFilePath() + ".admissions")).toHaveLength(0);
});
test("failed archive writes retain admission instead of acknowledging durable completion", async () => {
  fixture();
  const { beginSpeechArchive, settleSpeechArchivesForUpdate } = await import("../speech-archive-live");
  const { speechArchiveWriter } = await import("../speech-archive-writer");
  const writer = spyOn(speechArchiveWriter, "write").mockRejectedValue(Error("IO_ERROR"));
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    await withVoiceAdmission(async () => { await beginSpeechArchive("synthetic").settled(); holdVoiceAdmission(settleSpeechArchivesForUpdate()); });
    updateVoiceGate({ kind: "REQUEST", lease }); expect(prepare().kind).toBe("REFUSED");
  } finally { writer.mockRestore(); log.mockRestore(); }
});
