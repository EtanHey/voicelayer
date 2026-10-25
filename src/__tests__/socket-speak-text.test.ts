import { afterEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "crypto";
import { lstatSync, readFileSync, realpathSync } from "fs";
import { basename, dirname, join, resolve } from "path";
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
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, root = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !root ||
        dirname(run) !== resolve(import.meta.dir, "../../.test-tmp") ||
        !new RegExp(`^${process.pid}-[a-f0-9]{4}$`).test(basename(run)) || realpathSync(run) !== run ||
        !root.startsWith(run + "/") || realpathSync(root) !== root) throw new Error("canonical isolated preload required");
    for (const directory of [run, root]) {
      const stat = lstatSync(directory);
      expect(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o7777) === 0o700).toBe(true);
    }
    spies.push(spyOn(input, "getRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(false));
    const start = spyOn(tts, "speakText").mockReturnValue({ id: "test", done: Promise.resolve() }); spies.push(start);
    expect(handleSocketCommand({ cmd: "speak_text", text: "**Hi**", format: "markdown", profile: "long", id: "s2" } as any)).toMatchObject({ outcome: "accept", id: "s2" });
    const context = start.mock.calls[0]?.[2]?.archiveContext;
    expect(context).toBeDefined();
    if (!context) throw new Error("Required raw speech receipt context is absent");
    expect(context.id).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/);
    const expectedPath = join(root, context.id.slice(0, 10), context.id);
    expect(context.path).toBe(expectedPath);
    for (const directory of [dirname(expectedPath), expectedPath]) {
      const stat = lstatSync(directory);
      expect(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o7777) === 0o700).toBe(true);
    }
    for (const name of ["input.txt", "metadata.json"]) {
      const stat = lstatSync(join(expectedPath, name));
      expect(stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1 && stat.uid === process.getuid?.() && (stat.mode & 0o7777) === 0o600).toBe(true);
    }
    expect(readFileSync(join(expectedPath, "input.txt"))).toEqual(Buffer.from("**Hi**", "utf8"));
    expect(context.metadata).toMatchObject({ schema_version: 1, id: context.id, source: "speak", status: "received",
      request_id: "s2", request_source: null, connection: null, format: "markdown", blocking: null,
      input: { bytes: 6, sha256: createHash("sha256").update(Buffer.from("**Hi**", "utf8")).digest("hex") } });
    expect(JSON.parse(readFileSync(join(expectedPath, "metadata.json"), "utf8"))).toEqual(context.metadata);
    expect(start).toHaveBeenCalledWith("Hi", "long", { request_id: "s2", text_hash: "46f3be07cae69b13f2cf62e764b4aa3f3aa67de0f952d0e37cd1d87f6fff63a4", archiveContext: context });
  });
});

describe("QUEUE1 Option+F5 read queue over the socket", () => {
  const hash = "b".repeat(64);
  // The real VoiceBar wire: the first selection from idle has no queue flag; later different ones do.
  const speak = (id: string, queue = id !== "A") => handleSocketCommand({ cmd: "speak_text", id, text: `selection ${id}`, text_hash: hash, source: "selection", ...(queue ? { queue: true } : {}) } as any);
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

  it("parses queue on speak_text, retain_read_queue on stop, and read_next only with a request id", () => {
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "a", queue: true }))).toEqual({ cmd: "speak_text", text: "a", queue: true });
    expect(parseCommand(JSON.stringify({ cmd: "speak_text", text: "a", queue: "yes" }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "stop", retain_read_queue: true }))).toEqual({ cmd: "stop", retain_read_queue: true });
    expect(parseCommand(JSON.stringify({ cmd: "stop", retain_read_queue: 1 }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "cancel", discard_read_queue: true }))).toEqual({ cmd: "cancel", discard_read_queue: true });
    expect(parseCommand(JSON.stringify({ cmd: "cancel", discard_read_queue: "yes" }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "read_next", request_id: "r1", id: "n1" }))).toEqual({ cmd: "read_next", request_id: "r1", id: "n1" });
    // SOL-3: an unscoped Next is not a command.
    expect(parseCommand(JSON.stringify({ cmd: "read_next" }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "read_next", request_id: "" }))).toBeNull();
    expect(parseCommand(JSON.stringify({ cmd: "read_next", request_id: 4 }))).toBeNull();
  });

  it("SOL-1: the real Swift sequence (A without queue, then B with queue) queues B behind A", () => {
    idle();
    const spoken: unknown[] = [];
    expect(handleSocketCommand({ cmd: "speak_text", id: "A", text: "selection A", text_hash: hash, source: "selection", profile: "auto", format: "markdown" } as any,
      (read) => spoken.push(read))).toMatchObject({ outcome: "accept", id: "A" });
    expect(spoken).toHaveLength(1);
    expect(handleSocketCommand({ cmd: "speak_text", id: "B", text: "selection B", text_hash: hash, source: "selection", profile: "auto", format: "markdown", queue: true } as any))
      .toMatchObject({ outcome: "accept", id: "B", reason: "queued" });
    expect(started).toEqual(["A"]);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 1, current_request_id: "A" });
  });

  it("P14b direct and queued selections carry their own exact source projection with the original hash", () => {
    idle();
    const done = new Promise<void>(() => {});
    const starts = spyOn(tts, "speakText").mockReturnValue({ id: "held", generation: 1, done,
      playerExited: done, started: Promise.resolve({}), completion: Promise.resolve({}) }); spies.push(starts);
    const a = "2. Alpha.\n3. Beta.", b = "# Heading\n\n4. Gamma.";
    handleSocketCommand({ cmd: "speak_text", id: "A", text: a, source: "selection", format: "markdown" });
    handleSocketCommand({ cmd: "speak_text", id: "B", text: b, source: "selection", format: "markdown", queue: true });
    expect(starts).toHaveBeenCalledTimes(1);
    expect(starts.mock.calls[0]?.[0]).toBe("Alpha. Beta.");
    expect(starts.mock.calls[0]?.[2]?.structuredDisplay?.displayText).toBe(a);
    expect(starts.mock.calls[0]?.[2]?.text_hash).toBe(normalizedSpeechHash(a));
    handleSocketCommand({ cmd: "read_next", request_id: "A" });
    expect(starts.mock.calls[1]?.[0]).toBe("Heading Gamma.");
    expect(starts.mock.calls[1]?.[2]?.structuredDisplay?.displayText).toBe(b);
    expect(starts.mock.calls[1]?.[2]?.text_hash).toBe(normalizedSpeechHash(b));
    expect(starts.mock.calls[1]?.[2]?.archiveContext).not.toBe(starts.mock.calls[0]?.[2]?.archiveContext);
  });

  it("speech-control speak_text (no selection source) keeps its lifecycle callback and does not own the queue", () => {
    idle();
    const spoken: unknown[] = [];
    handleSocketCommand({ cmd: "speak_text", id: "cli", text: "from the CLI" } as any, (read) => spoken.push(read));
    expect(spoken).toHaveLength(1);
    expect(speak("B")).toMatchObject({ outcome: "accept" });
    expect(started).toEqual(["cli", "B"]);
  });

  it("SOL-3: a Next missing its request id is a noop and starts nothing", () => {
    idle();
    speak("A"); speak("B");
    expect(handleSocketCommand({ cmd: "read_next" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
    expect(started).toEqual(["A"]);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 1, current_request_id: "A" });
  });

  it("D2: an F5 stop over the playing read keeps B and C for Next; explicit Stop later clears them even when idle", async () => {
    idle();
    const stop = spyOn(tts, "stopPlayback").mockReturnValue(true); spies.push(stop);
    const depth = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(1); spies.push(depth);
    speak("A"); speak("B"); speak("C");
    await handleSocketCommand({ cmd: "stop", retain_read_queue: true } as any);
    expect(stop).toHaveBeenCalledTimes(1);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 2, current_request_id: "A" });
    expect(started).toEqual(["A"]);
    depth.mockReturnValue(0);
    expect(handleSocketCommand({ cmd: "stop" } as any)).toMatchObject({ outcome: "noop" });
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 0, current_request_id: null });
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
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
