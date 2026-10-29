import { afterEach, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { createVoiceSdkSessionManager } from "../voicesdk/session";
import type { SoundLayer, TextToSpeechOptions } from "../soundlayer";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const A = { id: "agent-a", name: "Agent A" };
const B = { id: "agent-b", name: "Agent B" };
type Phase = "FIRST_CONTACT" | "IMMEDIATE_FOLLOWUP" | "RETURN_AFTER_WORK";

async function fixture(reuseId = false) {
  const calls: { text: string; options?: TextToSpeechOptions }[] = [];
  let mode: "start" | "queued" | "fail" | "pending" = "start";
  let pending = Promise.withResolvers<void>();
  let physical = Promise.resolve();
  let captures = 0;
  const layer: SoundLayer = {
    micCapture: { async recordToBuffer() { throw Error("mic forbidden"); },
      async waitForInput() { captures++; throw Error("bare listen forbidden"); }, clear() {}, getState: () => "idle" },
    playback: { play() { throw Error("player forbidden"); }, async waitForIdle() {}, stop: () => false, getQueueDepth: () => 0 },
    vad: { async processChunk() { throw Error("VAD forbidden"); }, isSpeech: () => false,
      silenceChunksForMode: () => 1, async reset() {} },
    cancellation: { stopPlayback() { throw Error("global stop forbidden"); }, consumeRecordingCancel: () => false },
    transcriptEvents: { emitTranscript() {} },
    tts: { async speak(text, options) {
      calls.push({ text, options });
      const id = `fake-${calls.length}`;
      options?.onPlaybackQueued?.({ id, generation: calls.length, playerExited: physical,
        waitForPlayerExit: () => physical,
        exited: Promise.resolve({ type: "playback_outcome", playback_id: id, status: "completed", stopped_at_ms: 0, progress: 1 }) });
      if (mode === "fail") throw Error("synthesis failed before start");
      if (mode === "start") options?.onPlaybackStart?.(100);
      if (mode === "pending") await pending.promise;
      return {};
    } },
    stt: { async getBackend() { throw Error("STT forbidden"); } },
  };
  const root = mkdtempSync(join(process.env.VOICELAYER_TEST_RUN_ROOT!, "speaker-")); roots.push(root);
  let serial = 0;
  const manager = createVoiceSdkSessionManager({ soundLayer: layer, logDir: root,
    idFactory: () => reuseId ? "reused" : `session-${++serial}` });
  const session = await manager.startSession({ product: "fixture" });
  function say(agent = A, phase: Phase = "IMMEDIATE_FOLLOWUP", text = "Body.", sessionId = session.session_id, voice_id = "preset") {
    const input = { text, voice_id, conversation: { agent, phase } };
    return manager.speak(sessionId, input);
  }
  function ack(work: "work" | "lookup") {
    const input = { text: "Ignored ack body", conversation: { agent: A, phase: "ACK_AFTER_USER" as const, work } };
    return manager.speak(session.session_id, input);
  }
  return { manager, session, calls, say, ack, layer, get captures() { return captures; },
    mode(value: typeof mode) { mode = value; }, finish() { pending.resolve(); pending = Promise.withResolvers<void>(); },
    physical(value: Promise<void>) { physical = value; } };
}

it("actual manager introduces first contact, then exact unnamed ACKs and immediate follow-up", async () => {
  const f = await fixture();
  await f.say(A, "FIRST_CONTACT"); await f.ack("work"); await f.ack("lookup"); await f.say();
  expect(f.calls.map(call => call.text)).toEqual([
    "Agent A here. Body.", "OK, I'm on it.", "OK, I'm looking it up.", "Body.",
  ]);
  expect(f.captures).toBe(0);
});

for (const legacy of [false, true]) {
  it(`releases the reservation after pre-audio subscriber failure (${legacy ? "legacy" : "optional"})`, async () => {
    const f = await fixture();
    const unsubscribe = f.manager.subscribe(event => {
      if (event.type === "speak.started") throw Error("subscriber failed before audio");
    });
    try {
      const failed = legacy ? f.manager.speak(f.session.session_id, { text: "Legacy" }) : f.say();
      await expect(failed).rejects.toThrow("subscriber failed before audio");
      expect(f.calls).toHaveLength(0);
    } finally { unsubscribe(); }
    await f.say();
    expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body."]);
  });
}

it("a throwing monitor Stop retains ownership through monitor and player exit", async () => {
  const f = await fixture(), monitor = Promise.withResolvers<void>(), player = Promise.withResolvers<void>();
  const cause = Error("monitor Stop failed");
  f.physical(player.promise);
  f.layer.cancellation.cancelPlayback = () => true;
  f.layer.bargeIn = { monitorDuringPlayback: () => ({
    exited: monitor.promise, stop() { throw cause; },
    async pushAudioChunk() { return { speechStarted: false }; },
    getMetrics: () => ({ processed_chunks: 0, false_interrupts: 0, confirmed_interrupts: 0, false_interrupt_rate: 0 }),
  }) };
  let error: unknown, settled = false;
  const first = f.say().then(() => { settled = true; }, failure => { error = failure; settled = true; });
  try {
    await Bun.sleep(0);
    expect(settled).toBe(false);
    await expect(f.say(B)).rejects.toThrow("overlapping conversation");
    expect(f.calls).toHaveLength(1);
    monitor.resolve(); await Bun.sleep(0);
    expect(settled).toBe(false);
  } finally { monitor.resolve(); player.resolve(); await first; }
  expect(error).toBe(cause);
  f.layer.bargeIn = undefined;
  await f.say(B);
  expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "Agent B here. Body."]);
});

it("uses stable identity for A→B→A, independently of display/model/voice", async () => {
  const f = await fixture();
  await f.say();
  const changed = { id: A.id, name: "Different model label", model: "new-model" };
  await f.say(changed, "IMMEDIATE_FOLLOWUP", "Follow.", f.session.session_id, "another-voice");
  await f.say(B); await f.say(B); await f.say(A);
  expect(f.calls.map(call => call.text)).toEqual([
    "Agent A here. Body.", "Follow.", "Agent B here. Body.", "Body.", "Agent A here. Body.",
  ]);
});

it("isolates conversations and resets a fresh session", async () => {
  const f = await fixture(); await f.say();
  const next = await f.manager.startSession({ product: "fixture" });
  await f.say(A, "IMMEDIATE_FOLLOWUP", "New.", next.session_id); await f.say();
  expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "Agent A here. New.", "Body."]);
});

it("manager encodes response-required work-return copy and refuses before speech/events/capture", async () => {
  const f = await fixture(); await f.say(); await f.ack("work");
  for (const agent of [A, B]) {
    const before = f.manager.replay(f.session.session_id);
    try { await f.say(agent, "RETURN_AFTER_WORK", "Answer.\nKeep all words."); throw Error("accepted illegal return"); }
    catch (error) {
      expect(error).toMatchObject({ message: expect.stringContaining("ADMITTED_CONVERSATION_ASK"),
        plan: { kind: "admitted-ask-required", phase: "RETURN_AFTER_WORK", responseRequired: true,
          text: `${agent.name} here. Answer.\nKeep all words.` } });
    }
    expect(f.manager.replay(f.session.session_id)).toEqual(before);
  }
  await f.say();
  expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "OK, I'm on it.", "Body."]);
  expect(f.captures).toBe(0);
});

for (const mode of ["fail", "queued"] as const) {
  it(`${mode} before playback start does not consume introduction`, async () => {
    const f = await fixture(); f.mode(mode); await f.say();
    f.mode("start"); await f.say(); await f.say();
    expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "Agent A here. Body.", "Body."]);
    expect(f.manager.replay(f.session.session_id).filter(e => e.type === "speak.stopped").map(e => e.reason))
      .toEqual([mode === "fail" ? "error" : "completed", "completed", "completed"]);
  });
}

it("queue admission alone is not heard; overlapping optional intent fails before audio", async () => {
  const f = await fixture(); f.mode("pending"); const first = f.say();
  try {
    expect(f.calls).toHaveLength(1);
    await expect(f.say(B)).rejects.toThrow("overlapping conversation");
    expect(f.calls).toHaveLength(1);
  } finally { f.finish(); await first; }
  f.mode("start"); await f.say();
  expect(f.calls[1]?.text).toBe("Agent A here. Body.");
});

it("late completed/failed callbacks cannot replace the currently heard agent", async () => {
  const f = await fixture(); f.mode("fail"); await f.say(A);
  const stale = f.calls[0]?.options?.onPlaybackStart;
  f.mode("start"); await f.say(B); stale?.(200); await f.say(B);
  expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "Agent B here. Body.", "Body."]);
});

it("End and same-id replacement fence old playback and response-required intent", async () => {
  const f = await fixture(true); f.mode("pending"); const old = f.say();
  await f.manager.endSession(f.session.session_id, "fixture End");
  await expect(f.say(A, "RETURN_AFTER_WORK")).rejects.toThrow("has ended");
  await f.manager.startSession({ product: "successor" });
  f.mode("start"); await f.say(B);
  f.calls[0]?.options?.onPlaybackStart?.(300);
  f.finish(); await old; await f.say(B);
  expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "Agent B here. Body.", "Body."]);
  expect(f.captures).toBe(0);
});

it("legacy text/events stay verbatim and legacy overlap invalidates only opt-in continuity", async () => {
  const f = await fixture(); f.mode("pending");
  const old = f.say();
  const legacy = f.manager.speak(f.session.session_id, { text: "Legacy here.\nUntouched.", voice_id: "legacy" });
  f.calls[0]?.options?.onPlaybackStart?.(200);
  f.finish(); await Promise.all([old, legacy]);
  f.mode("start"); await f.say();
  expect(f.calls.map(call => call.text)).toEqual(["Agent A here. Body.", "Legacy here.\nUntouched.", "Agent A here. Body."]);
  expect(f.manager.replay(f.session.session_id).filter(e => e.type === "speak.chunk").map(e => e.text))
    .toEqual(f.calls.map(call => call.text));
});

it("keeps opt-in ownership pending through the unchanged physical-exit wait", async () => {
  const f = await fixture(); const exit = Promise.withResolvers<void>(); f.physical(exit.promise);
  const old = f.say();
  try { await expect(f.say(B)).rejects.toThrow("overlapping conversation"); }
  finally { exit.resolve(); await old; }
  await f.say(); expect(f.calls.at(-1)?.text).toBe("Body.");
});

it("a failed takeover and stale callbacks cannot consume the next introduction", async () => {
  const f = await fixture(); await f.say(A);
  f.mode("fail"); await f.say(B);
  f.mode("pending"); const current = f.say(A);
  try { f.calls[1]?.options?.onPlaybackStart?.(200); }
  finally { f.finish(); await current; }
  f.mode("start"); await f.say(B); await f.say(B);
  expect(f.calls.map(call => call.text)).toEqual([
    "Agent A here. Body.", "Agent B here. Body.", "Body.", "Agent B here. Body.", "Body.",
  ]);
});

it("copy preserves arbitrary body formatting and FIRST_CONTACT does not reintroduce once heard", async () => {
  const f = await fixture();
  const body = "  Supplied here.\n1. Keep words.\n2. Keep tails…  ";
  await f.say(A, "FIRST_CONTACT", body); await f.say(A, "FIRST_CONTACT", body);
  expect(f.calls.map(call => call.text)).toEqual([`Agent A here. ${body}`, body]);
  expect(Object.keys(f.session).sort()).toEqual([
    "created_at", "ended", "product", "sequence", "session_id", "startedAtMs",
  ]);
});

it("legacy in-flight speech refuses opt-in while preserving legacy concurrent calls", async () => {
  const f = await fixture(); f.mode("pending");
  const first = f.manager.speak(f.session.session_id, { text: "Legacy one" });
  const second = f.manager.speak(f.session.session_id, { text: "Legacy two" });
  try {
    await expect(f.say()).rejects.toThrow("overlapping conversation");
    expect(f.calls.map(call => call.text)).toEqual(["Legacy one", "Legacy two"]);
  } finally { f.finish(); await Promise.all([first, second]); }
  f.mode("start"); await f.say(); expect(f.calls.at(-1)?.text).toBe("Agent A here. Body.");
});
