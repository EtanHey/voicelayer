import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { normalizedSpeechHash } from "../speech-identity";
import { parseCommand } from "../socket-protocol";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as input from "../input";
import * as recording from "../recording-state";
import * as reservation from "../voice-operation-reservation";

const spies: ReturnType<typeof spyOn>[] = [];
afterEach(() => { for (const spy of spies.splice(0)) spy.mockRestore(); });
describe("speak_text socket command", () => {
  it("accepts more than MCP's cap and preserves all text and optional fields", () => {
    const command = { cmd: "speak_text", text: "word ".repeat(10000), profile: "long", format: "markdown", source: "selection", id: "s1", text_hash: "a".repeat(64) };
    expect(parseCommand(JSON.stringify(command))).toEqual(command);
  });
  it("hashes normalized Unicode whitespace without projecting or changing the input", () => {
    expect(normalizedSpeechHash(" hello\nworld ")).toBe("b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");
    expect(normalizedSpeechHash("hello\u0085\u00a0\u2003world")).toBe(normalizedSpeechHash("hello world"));
    expect(normalizedSpeechHash("**hello** world")).not.toBe(normalizedSpeechHash("hello world"));
    for (const text_hash of ["invalid", 4, "A".repeat(64)]) {
      expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "hello", text_hash }))).toBeNull();
    }
  });
  it("enforces the 200,000-character sanity maximum", () => {
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "x".repeat(200000) }))).not.toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "x".repeat(200001) }))).toBeNull();
  });
  it("rejects empty text and invalid options", () => {
    for (const fields of [{ text: " " }, { text: 3 }, { text: "a", profile: "invalid" }, { text: "a", format: "html" }, { text: "a", source: 4 }]) {
      expect(parseCommand(JSON.stringify({ cmd: "speak_text", ...fields }))).toBeNull();
    }
  });
  it("refuses while local or cross-process recording is busy", () => {
    const local = spyOn(input, "getRecordingState").mockReturnValue("idle"); spies.push(local);
    const effective = spyOn(recording, "getEffectiveRecordingState"); spies.push(effective);
    for (const state of ["recording", "transcribing"] as const) {
      effective.mockReturnValue(state);
      expect(handleSocketCommand({ cmd: "speak_text", text: "hello" } as any)).toMatchObject({ command: "speak_text", outcome: "reject", reason: "busy" });
    }
  });
  it("refuses during voice_ask's reserved prompt-to-recording transition", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(true));
    expect(handleSocketCommand({ cmd: "speak_text", text: "hello" } as any)).toMatchObject({ outcome: "reject", reason: "busy" });
  });
  it("normalizes markdown before starting through the profile seam", () => {
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(false));
    const start = spyOn(tts, "speakText").mockReturnValue({ id: "test", done: Promise.resolve() }); spies.push(start);
    expect(handleSocketCommand({ cmd: "speak_text", text: "**Hi**", format: "markdown", profile: "long", id: "s2" } as any)).toMatchObject({ outcome: "accept", id: "s2" });
    expect(start).toHaveBeenCalledWith("Hi", "long", { request_id: "s2", text_hash: "46f3be07cae69b13f2cf62e764b4aa3f3aa67de0f952d0e37cd1d87f6fff63a4" });
  });
});

describe("QUEUE1 Option+F5 read queue over the socket", () => {
  const hash = "b".repeat(64);
  const speak = (id: string, queue = true) => handleSocketCommand({ cmd: "speak_text", id, text: `selection ${id}`, text_hash: hash, source: "selection", ...(queue ? { queue: true } : {}) } as any);
  let events: any[];
  let started: string[];
  function idle() {
    events = []; started = [];
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(false));
    spies.push(spyOn(socketClient, "broadcast").mockImplementation((event: any) => { events.push(event); }));
    spies.push(spyOn(tts, "speakText").mockImplementation(((_text: string, _kind: string, identity: any) => {
      started.push(identity.request_id); return { id: identity.request_id, done: new Promise(() => {}) };
    }) as any));
  }
  afterEach(() => { resetSelectionReadQueueForTests(); });
  const queueEvents = () => events.filter(e => e.type === "read_queue");

  it("parses queue on speak_text and read_next with an optional request id", () => {
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "a", queue: true }))).toEqual({ cmd: "speak_text", text: "a", queue: true });
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "a", queue: "yes" }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "read_next", request_id: "r1", id: "n1" }))).toEqual({ cmd: "read_next", request_id: "r1", id: "n1" });
    expect(parseCommand(JSON.stringify({ cmd: "read_next" }))).toEqual({ cmd: "read_next" });
    expect(parseCommand(JSON.stringify({ cmd: "read_next", request_id: 4 }))).toBeNull();
  });

  it("a different selection while reading is queued (count 1), not started", () => {
    idle();
    expect(speak("A")).toMatchObject({ outcome: "accept", id: "A" });
    expect(speak("B")).toMatchObject({ outcome: "accept", id: "B", reason: "queued" });
    expect(started).toEqual(["A"]);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 1, current_request_id: "A" });
    expect(JSON.stringify(events)).not.toContain("selection B");
  });

  it("read_next starts the following item at count-1; a stale request id is a noop", () => {
    idle();
    speak("A"); speak("B"); speak("C");
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A", id: "n1" } as any)).toMatchObject({ command: "read_next", outcome: "accept" });
    expect(started).toEqual(["A", "B"]);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 1, current_request_id: "B" });
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
    expect(started).toEqual(["A", "B"]);
  });

  it("Stop clears the whole queue", async () => {
    idle();
    const stop = spyOn(tts, "stopPlayback").mockReturnValue(true); spies.push(stop);
    spies.push(spyOn(tts, "hasPendingSpeechPreparation").mockReturnValue(true));
    speak("A"); speak("B"); speak("C");
    await handleSocketCommand({ cmd: "stop" } as any);
    expect(stop).toHaveBeenCalled();
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 0, current_request_id: null });
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
  });

  it("read_next on the last item stops playback", async () => {
    idle();
    const stop = spyOn(tts, "stopPlayback").mockReturnValue(true); spies.push(stop);
    speak("A"); speak("B");
    handleSocketCommand({ cmd: "read_next", request_id: "A" } as any);
    expect(await handleSocketCommand({ cmd: "read_next", request_id: "B" } as any)).toMatchObject({ outcome: "accept" });
    expect(stop).toHaveBeenCalledTimes(1);
    expect(started).toEqual(["A", "B"]);
  });

  it("recording rejects Option+F5 as busy and queues nothing", () => {
    idle();
    speak("A");
    (recording.getEffectiveRecordingState as any).mockReturnValue("recording");
    expect(speak("B")).toMatchObject({ outcome: "reject", reason: "busy" });
    expect(queueEvents()).toEqual([]);
  });

  it("a full queue refuses the eleventh read", () => {
    idle();
    speak("A");
    for (let i = 0; i < 10; i++) expect(speak(`q${i}`)).toMatchObject({ outcome: "accept", reason: "queued" });
    expect(speak("overflow")).toMatchObject({ outcome: "reject", reason: "queue full" });
  });
});
