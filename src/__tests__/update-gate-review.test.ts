import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import { join } from "path";
import * as tts from "../tts";
import * as input from "../input";
import * as audio from "../audio-utils";
import * as booking from "../session-booking";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import { handleVoiceAsk } from "../handlers";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import { settleSpeechArchivesForUpdate } from "../speech-archive-live";
import { acknowledgeVoiceDrain, holdVoiceAdmission, updateVoiceGate } from "../update-gate-admission";
import { TTS_DISABLED_FILE } from "../paths";

const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const ack = { lease, activeOperations: 0, openArchives: 0 };
const proof = () => true;
const prepare = () => updateVoiceGate({ kind: "PREPARE", lease, native: ack, daemon: ack }, proof);
const drain = () => expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (error: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  void promise.catch(() => {});
  return { promise, resolve, reject };
}
const spies: Array<{ mockRestore(): void }> = [];
const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
let disabled: Buffer | null;

describe("G2 review regressions (synthetic media, isolated gate)", () => {
  beforeEach(() => {
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || process.env.VOICELAYER_TEST_REAL_MIC === "1") throw Error("isolated synthetic tests required");
    const dir = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "gate-review-"));
    const gate = join(dir, "gate.json");
    process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
    writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
    mkdirSync(gate + ".admissions");
    disabled = existsSync(TTS_DISABLED_FILE) ? readFileSync(TTS_DISABLED_FILE) : null;
    recording.setRecordingState("idle");
    spies.push(spyOn(console, "error").mockImplementation(() => {}));
  });
  afterEach(async () => {
    resetSelectionReadQueueForTests();
    await settleSpeechArchivesForUpdate(); await tick();
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    if (disabled) writeFileSync(TTS_DISABLED_FILE, disabled);
    else if (existsSync(TTS_DISABLED_FILE)) unlinkSync(TTS_DISABLED_FILE);
    process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate;
  });
  function askSetup() {
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
      spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0),
      spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined));
  }
  for (const failure of ["TTS disabled", "backend rejects", "user stops preparation"] as const) {
    test(`Ask ${failure} with no player/capture releases admission after proven teardown`, async () => {
      askSetup();
      if (failure === "TTS disabled") writeFileSync(TTS_DISABLED_FILE, "disabled");
      else spies.push(spyOn(tts, "speak").mockRejectedValue(failure === "backend rejects" ? Error("synthetic synthesis failure") : new tts.SpeechPreparationStoppedError()));
      const capture = spyOn(input, "waitForInput").mockRejectedValue(Error("MUST NOT CAPTURE")); spies.push(capture);
      const result = await handleVoiceAsk({ message: "synthetic question" });
      expect(result.content[0].text.toLowerCase()).toContain(failure === "TTS disabled" ? "recording was not started" : failure === "backend rejects" ? "synthetic synthesis failure" : "stopped");
      expect(capture).not.toHaveBeenCalled();
      await settleSpeechArchivesForUpdate(); await tick();
      drain();
      expect(acknowledgeVoiceDrain(lease, proof)).toEqual(ack);
      expect(prepare().kind).toBe("APPLIED");
    });
  }
  for (const confirmed of [true, false]) test(`Ask failure after a queued player requires confirmed exit: ${confirmed}`, async () => {
    askSetup();
    const exit = deferred<void>();
    spies.push(spyOn(tts, "speak").mockImplementation(async (_text, options) => {
      options?.onPlaybackQueued?.({ id: "synthetic-player", generation: 1, playerExited: exit.promise,
        exited: new Promise(() => {}), waitForPlayerExit: () => exit.promise });
      throw Error("synthetic error after queuing");
    }));
    expect((await handleVoiceAsk({ message: "synthetic question" })).isError).toBe(true);
    drain();
    expect(acknowledgeVoiceDrain(lease, proof)).toBeNull();
    if (confirmed) exit.resolve(); else exit.reject(Error("physical exit unconfirmed"));
    await settleSpeechArchivesForUpdate(); await tick();
    if (confirmed) {
      expect(acknowledgeVoiceDrain(lease, proof)).toEqual(ack);
      expect(prepare().kind).toBe("APPLIED");
    } else expect(prepare()).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
  });
  for (const exitOutcome of ["confirmed", "rejected"] as const) {
    test(`direct capture keeps admission until recorder exit is ${exitOutcome}`, async () => {
      const exit = deferred<number>();
      let stream!: ReadableStreamDefaultController<Uint8Array>;
      const kills: string[] = [];
      const recorder = { stdout: new ReadableStream<Uint8Array>({ start(controller) { stream = controller; } }),
        stderr: null, exited: exit.promise, kill(signal?: string) { kills.push(signal ?? "SIGTERM"); try { stream.close(); } catch {} } };
      spies.push(spyOn(audio, "detectNativeInputFormat").mockReturnValue({ sampleRate: 16000, channels: 1 }),
        spyOn(Bun, "spawn").mockImplementation((command) => {
          expect((command as string[])[0]).toBe(process.env.VOICELAYER_TEST_FAKE_REC_BIN!);
          return recorder as never;
        }));
      try {
        expect(await input.recordToBuffer(5, "standard", true)).toBeNull();
        await input.terminateRecorderProcess(recorder, 1); // Bounded termination returning is not exit proof.
        expect(kills).toContain("SIGKILL");
        if (exitOutcome === "rejected") { exit.reject(Error("recorder exit unconfirmed")); await tick(); }
        drain();
        expect(acknowledgeVoiceDrain(lease, proof)).toBeNull();
        expect(prepare()).toEqual({ kind: "REFUSED", reason: "UNKNOWN" });
        if (exitOutcome === "confirmed") {
          exit.resolve(0); await tick();
          expect(acknowledgeVoiceDrain(lease, proof)).toEqual(ack);
          expect(prepare().kind).toBe("APPLIED");
        }
      } finally { exit.resolve(0); await tick(); }
    });
  }
  test("same-selection re-press advances and stops admitted reads during drain; new text refuses", async () => {
    const starts: string[] = [], exits: ReturnType<typeof deferred<void>>[] = [];
    const stop = spyOn(tts, "stopPlayback").mockImplementation(() => { exits.forEach(exit => exit.resolve()); return true; }); spies.push(stop);
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1),
      spyOn(tts, "isPlaybackPaused").mockReturnValue(false),
      spyOn(tts, "prepareSelectionReadStart").mockRejectedValue(Error("synthetic prefetch disabled")),
      spyOn(tts, "speakText").mockImplementation((_text, _profile, identity) => {
        exits.forEach(exit => exit.resolve());
        const exit = deferred<void>(); exits.push(exit); holdVoiceAdmission(exit.promise);
        starts.push(identity?.request_id!);
        return { id: identity?.request_id!, generation: 1, done: exit.promise, playerExited: exit.promise,
          started: Promise.resolve({}), completion: exit.promise.then(() => ({})) };
      }));
    const command = (id: string, text: string, queue = false) => handleSocketCommand({ cmd: "speak_text", source: "selection", id, text, queue });
    try {
      expect(await command("A", "selection A")).toMatchObject({ outcome: "accept" });
      expect(await command("B", "selection B", true)).toMatchObject({ outcome: "accept", reason: "queued" });
      drain();
      expect(await command("A-next", "selection A")).toMatchObject({ outcome: "accept", reason: "selection advanced" });
      expect(starts).toEqual(["A", "B"]);
      expect(await command("C", "unadmitted selection")).toMatchObject({ outcome: "reject", reason: expect.stringContaining("UPDATE_BUSY") });
      expect(await command("B-stop", "selection B")).toMatchObject({ outcome: "accept", reason: "selection advanced" });
      expect(stop).toHaveBeenCalledTimes(1);
      await settleSpeechArchivesForUpdate(); await tick();
      expect(prepare().kind).toBe("APPLIED");
    } finally { exits.forEach(exit => exit.resolve()); resetSelectionReadQueueForTests(); }
  });
});
