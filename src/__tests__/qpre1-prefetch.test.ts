import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as input from "../input";
import * as recording from "../recording-state";
import * as reservation from "../voice-operation-reservation";
import { fixtureCheckpoint } from "./long-read-fixture-barriers";

/** QPRE1 at the socket-handler boundary: the queue head's preparation is owned, transferred or discarded
 * by the real handlers. Synthesis and playback are seams here; tts-long-read-runtime covers the real runner. */
describe("QPRE1 handler-level preparation of the next queued read", () => {
  const hash = "d".repeat(64);
  const spies: ReturnType<typeof spyOn>[] = [];
  type Prep = { text: string; owner: string; signal: AbortSignal; disposed: number; lease: any; settle(fail?: boolean): void };
  let preps: Prep[];
  let starts: { id: string; prepared: unknown; args: number }[];
  let deferPrep: boolean;
  afterEach(() => { resetSelectionReadQueueForTests(); for (const spy of spies.splice(0)) spy.mockRestore(); });
  const settle = async () => { for (let i = 0; i < 4; i++) await fixtureCheckpoint(); };
  const select = (id: string, queue = id !== "A") => handleSocketCommand({ cmd: "speak_text", id, text: `selection ${id}`, text_hash: hash, source: "selection", ...(queue ? { queue: true } : {}) } as any);

  function idle(failPrep = false) {
    preps = []; starts = []; deferPrep = false;
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(false));
    spies.push(spyOn(socketClient, "broadcast").mockImplementation(() => {}));
    spies.push(spyOn(tts, "stopPlayback").mockReturnValue(true));
    spies.push(spyOn(tts, "speakText").mockImplementation(((...args: any[]) => {
      starts.push({ id: args[2].request_id, prepared: args[3], args: args.length });
      return { id: args[2].request_id, done: new Promise(() => {}) };
    }) as any));
    spies.push(spyOn(tts, "prepareSelectionReadStart").mockImplementation(((text: string, _kind: string, owner: string, signal: AbortSignal) =>
      new Promise((resolve, reject) => {
        const prep: Prep = { text, owner, signal, disposed: 0, lease: undefined, settle: (fail = failPrep) => {
          if (fail) { reject(new Error("synthetic prefetch failure")); return; }
          prep.lease = { dispose: () => { prep.disposed++; } }; resolve(prep.lease);
        } };
        preps.push(prep);
        if (!deferPrep) prep.settle();
      })) as any));
  }
  const started = () => starts.map((s) => s.id);

  it("prepares only the queue head (B), never C, owned by the playing read A", async () => {
    idle();
    select("A"); select("B"); select("C");
    await settle();
    expect(preps.map((p) => [p.text, p.owner])).toEqual([["selection B", "A"]]);
    expect(started()).toEqual(["A"]);
  });

  const routes: [string, () => unknown][] = [
    ["Stop", () => { spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1)); return handleSocketCommand({ cmd: "stop" } as any); }],
    ["Hide (discard_read_queue) during a capture", () => {
      spies.push(spyOn(input, "getRecordingState").mockReturnValue("recording"));
      return handleSocketCommand({ cmd: "cancel", discard_read_queue: true } as any);
    }],
    ["agent speech or Ask preemption", () => tts.preemptLongRead("external")],
    ["idle Cancel", () => handleSocketCommand({ cmd: "cancel" } as any)],
    ["a replacing non-queue speak_text", () => handleSocketCommand({ cmd: "speak_text", id: "cli", text: "from the CLI" } as any)],
    ["a fresh direct selection", () => select("Z", false)],
  ];
  for (const [route, clear] of routes) it(`${route} aborts and disposes prepared B exactly once; B never starts`, async () => {
    idle();
    select("A"); select("B"); select("C");
    await settle();
    expect(preps).toHaveLength(1);
    await clear();
    await settle();
    expect(preps[0].signal.aborted).toBe(true);
    expect(preps[0].disposed).toBe(1);
    expect(started()).not.toContain("B");
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
    expect(preps).toHaveLength(1);
  });

  it("a late prefetch result after Stop is disposed, never transferred, even when the provider ignores abort", async () => {
    idle(); deferPrep = true;
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1));
    select("A"); select("B");
    await settle();
    await handleSocketCommand({ cmd: "stop" } as any);
    preps[0].settle(false);
    await settle();
    expect(preps[0].disposed).toBe(1);
    expect(started()).toEqual(["A"]);
  });

  it("Next transfers the ready lease into B's start exactly once, then prepares C behind B", async () => {
    idle();
    select("A"); select("B"); select("C");
    await settle();
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
    expect(starts.at(-1)).toMatchObject({ id: "B", prepared: preps[0].lease });
    expect(preps[0].disposed).toBe(0);
    await settle();
    expect(preps.map((p) => [p.text, p.owner])).toEqual([["selection B", "A"], ["selection C", "B"]]);
  });

  it("advance never waits on preparation in flight: B starts with ordinary synthesis and the late lease is disposed", async () => {
    idle(); deferPrep = true;
    select("A"); select("B");
    await settle();
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
    expect(starts.at(-1)).toMatchObject({ id: "B", prepared: undefined, args: 3 });
    expect(preps[0].signal.aborted).toBe(true);
    preps[0].settle(false);
    await settle();
    expect(preps[0].disposed).toBe(1);
  });

  it("a failed prefetch falls back to ordinary synthesis at B's start", async () => {
    idle(true);
    select("A"); select("B");
    await settle();
    expect(preps.map((p) => p.text)).toEqual(["selection B"]);
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
    expect(starts.at(-1)).toMatchObject({ id: "B", prepared: undefined, args: 3 });
  });

  it("a start that cannot run (busy) disposes the transferred lease", async () => {
    idle();
    select("A"); select("B");
    await settle();
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("recording"));
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0));
    await handleSocketCommand({ cmd: "read_next", request_id: "A" } as any);
    expect(preps[0].disposed).toBe(1);
    expect(started()).toEqual(["A"]);
  });

  it("F5 suspend aborts the prefetch but keeps the text; it re-prepares only when a user read resumes", async () => {
    idle();
    spies.push(spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1));
    select("A"); select("B"); select("C");
    await settle();
    await handleSocketCommand({ cmd: "stop", retain_read_queue: true } as any);
    await settle();
    expect(preps[0].signal.aborted).toBe(true);
    expect(preps[0].disposed).toBe(1);
    expect(preps).toHaveLength(1);
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
    expect(starts.at(-1)).toMatchObject({ id: "B", prepared: undefined, args: 3 });
    await settle();
    expect(preps.map((p) => [p.text, p.owner])).toEqual([["selection B", "A"], ["selection C", "B"]]);
  });

  it("the capture-Cancel retention is unchanged: the prepared head survives a Cancel aimed at the capture", async () => {
    idle();
    select("A"); select("B");
    await settle();
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("recording"));
    spies.push(spyOn(tts, "isPlaybackPaused").mockReturnValue(true));
    expect(await handleSocketCommand({ cmd: "cancel" } as any)).toMatchObject({ outcome: "accept" });
    expect(preps[0].signal.aborted).toBe(false);
    expect(preps[0].disposed).toBe(0);
  });
});
