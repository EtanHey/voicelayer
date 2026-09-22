import { describe, expect, test } from "bun:test";
import { WhisperLifecycleGate } from "../whisper-lifecycle-gate";

describe("whisper lifecycle gate", () => {
  test("rejects unload during a launch or inference reservation", async () => {
    const gate = new WhisperLifecycleGate();
    let finish!: () => void;
    const active = gate.use(() => new Promise<void>((resolve) => { finish = resolve; }));
    expect(await gate.unload(() => false, async () => "not_loaded"))
      .toEqual({ outcome: "reject", reason: "busy" });
    finish();
    await active;
    expect(await gate.unload(() => false, async () => "not_loaded"))
      .toEqual({ outcome: "accept", residency: "not_loaded" });
  });

  test("rejects external busy state before running unload", async () => {
    const gate = new WhisperLifecycleGate();
    let called = false;
    expect(await gate.unload(() => true, async () => { called = true; return "not_loaded"; }))
      .toEqual({ outcome: "reject", reason: "busy" });
    expect(called).toBe(false);
  });

  test("new use waits for accepted unload and then resumes", async () => {
    const gate = new WhisperLifecycleGate();
    let finish!: () => void;
    const unload = gate.unload(() => false, () => new Promise<"not_loaded">((resolve) => {
      finish = () => resolve("not_loaded");
    }));
    let ran = false;
    const next = gate.use(async () => { ran = true; });
    await Promise.resolve();
    expect(ran).toBe(false);
    finish();
    expect(await unload).toEqual({ outcome: "accept", residency: "not_loaded" });
    await next;
    expect(ran).toBe(true);
  });
});
