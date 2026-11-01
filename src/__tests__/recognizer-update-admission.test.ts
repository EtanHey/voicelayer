import { afterEach, beforeEach, describe, expect, spyOn, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import * as controller from "../recognizer-controller";
import * as admission from "../update-gate-admission";
import { readRecognizerStatus } from "../recognizer-state";
import { handleSocketCommand } from "../socket-handlers";
import { acknowledgeVoiceDrain, updateVoiceGate } from "../update-gate-admission";

const lease = { generation: 1, operationId: "10000000-0000-4000-8000-000000000001",
  ownerId: "20000000-0000-4000-8000-000000000001", targetSha: "a".repeat(40) };
const proof = () => true;
const tick = () => new Promise<void>(resolve => setImmediate(resolve));
const originalGate = process.env.VOICELAYER_UPDATE_GATE_PATH;
const spies: Array<{ mockRestore(): void }> = [];
const drain = () => expect(updateVoiceGate({ kind: "REQUEST", lease }).kind).toBe("APPLIED");

describe("picker mutation participates in update drain", () => {
  beforeEach(() => {
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1") throw Error("isolated tests required");
    const dir = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "recognizer-gate-"));
    const gate = join(dir, "gate.json");
    process.env.VOICELAYER_UPDATE_GATE_PATH = gate;
    writeFileSync(gate, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
    mkdirSync(gate + ".admissions");
  });
  afterEach(() => {
    for (const spy of spies.splice(0).reverse()) spy.mockRestore();
    if (originalGate === undefined) delete process.env.VOICELAYER_UPDATE_GATE_PATH;
    else process.env.VOICELAYER_UPDATE_GATE_PATH = originalGate;
  });
  test("closed gate refuses a selection before controller persistence or provider work", async () => {
    const select = spyOn(controller, "selectRecognizer").mockImplementation(async () => {
      throw Error("selection must not reach the controller");
    }); spies.push(select);
    drain();
    expect(await handleSocketCommand({ cmd: "set_recognizer", recognizer: "parakeet", id: "blocked-picker" }))
      .toMatchObject({ type: "ack", command: "set_recognizer", id: "blocked-picker", outcome: "reject",
        reason: expect.stringContaining("UPDATE_BUSY"), recognizer_status: readRecognizerStatus() });
    expect(select).not.toHaveBeenCalled();
  });
  test("cancelled admission is a picker rejection with a fresh snapshot", async () => {
    const select = spyOn(controller, "selectRecognizer").mockImplementation(async () => {
      throw Error("cancelled admission must not reach the controller");
    }); spies.push(select);
    spies.push(spyOn(admission, "withFreshDeferredVoiceAdmission").mockImplementation(() => {
      throw new admission.VoiceAdmissionCancelledError();
    }));
    expect(await handleSocketCommand({ cmd: "set_recognizer", recognizer: "parakeet", id: "cancelled-picker" }))
      .toMatchObject({ type: "ack", command: "set_recognizer", id: "cancelled-picker", outcome: "reject",
        recognizer_status: readRecognizerStatus() });
    expect(select).not.toHaveBeenCalled();
  });
  test("an awaited selection holds drain admission until it settles", async () => {
    const selected = { outcome: "accept" as const, recognizer_status: readRecognizerStatus() };
    let finish!: (result: typeof selected) => void;
    const pending = new Promise<typeof selected>(resolve => { finish = resolve; });
    const select = spyOn(controller, "selectRecognizer").mockReturnValue(pending); spies.push(select);
    const work = handleSocketCommand({ cmd: "set_recognizer", recognizer: "parakeet", id: "held-picker" });
    try {
      await tick(); expect(select).toHaveBeenCalledTimes(1);
      drain(); expect(acknowledgeVoiceDrain(lease, proof)).toBeNull();
      finish(selected);
      expect(await work).toMatchObject({ outcome: "accept", id: "held-picker" });
      await tick();
      expect(acknowledgeVoiceDrain(lease, proof)).toEqual({ lease, activeOperations: 0, openArchives: 0 });
    } finally { finish(selected); await work; await tick(); }
  });
  test("status is readable during drain without selecting or loading a provider", async () => {
    const select = spyOn(controller, "selectRecognizer").mockImplementation(async () => {
      throw Error("status read must not select a provider");
    }); spies.push(select);
    drain();
    expect(await handleSocketCommand({ cmd: "get_recognizer_status", id: "read-during-drain" }))
      .toMatchObject({ type: "recognizer_status", id: "read-during-drain" });
    expect(select).not.toHaveBeenCalled();
    expect(acknowledgeVoiceDrain(lease, proof)).toEqual({ lease, activeOperations: 0, openArchives: 0 });
  });
});
