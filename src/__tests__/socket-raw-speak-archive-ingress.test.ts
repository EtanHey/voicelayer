import { flushSpeechArchives } from "../speech-archive-live";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { createHash } from "crypto";
import * as fs from "fs";
import { basename, dirname, join, resolve } from "path";
import * as archive from "../speak-archive";
import * as tts from "../tts";
import * as runner from "../tts/long-read";
import * as input from "../input";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import * as reservation from "../voice-operation-reservation";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import { parseCommand, type SocketCommand, type SocketEvent } from "../socket-protocol";
import { createSpeechControl } from "../speech-control";
import { normalizedSpeechHash } from "../speech-identity";
import { PreparedReadStart } from "../tts/selection-read-preparation";
import { fixtureBarrier, deferredFixture } from "./long-read-fixture-barriers";
import { TTS_DISABLED_FILE } from "../paths";

const raw = " \t**שלום🙂**\n\nfu… no, full\r\n  ";
const realCreate = archive.createSpeakReceipt, realRun = runner.runLongRead;
let root: string, savedRoot: string, fixture: string;
let contexts: archive.SpeakArchiveContext[], events: SocketEvent[];
let spies: Array<{ mockRestore(): void }>;
let start: ReturnType<typeof spyOn<typeof tts, "speakText">>;
let state: ReturnType<typeof spyOn<typeof recording, "getEffectiveRecordingState">>;
let active: ReturnType<typeof spyOn<typeof reservation, "hasActiveVoiceOperation">>;
let log: ReturnType<typeof spyOn<typeof console, "error">>;
const syntheticHandle = (id: string): tts.LongReadHandle => ({ id, generation: 1,
  done: Promise.resolve(), playerExited: Promise.resolve(), started: Promise.resolve({}), completion: Promise.resolve({}) });
function incoming(fields: object, onSpeak?: (read: tts.LongReadHandle) => void) {
  const command = parseCommand(JSON.stringify({ cmd: "speak_text", text: raw, ...fields }));
  return command ? handleSocketCommand(command, onSpeak) : null;
}
function metadata(context: archive.SpeakArchiveContext) {
  return JSON.parse(fs.readFileSync(join(context.path, "metadata.json"), "utf8"));
}
function retained(context: archive.SpeakArchiveContext, status: string, text = raw) {
  expect(fs.readFileSync(join(context.path, "input.txt"))).toEqual(Buffer.from(text));
  expect(metadata(context)).toMatchObject({ source: "speak", status, generation_id: null,
    input: { bytes: Buffer.byteLength(text), sha256: createHash("sha256").update(text).digest("hex") } });
  expect(metadata(context).artifacts ?? []).toEqual([]);
  expect(metadata(context).lifecycle?.summary.generated_audio_ms ?? null).toBeNull();
  expect(metadata(context).lifecycle?.timing.first_player_start_ms ?? null).toBeNull();
  expect(metadata(context).lifecycle?.played_spans ?? []).toEqual([]);
  expect(fs.statSync(context.path).mode & 0o777).toBe(0o700);
  for (const name of ["input.txt", "metadata.json"]) expect(fs.statSync(join(context.path, name)).mode & 0o777).toBe(0o600);
  expect(fs.readdirSync(context.path).filter(name => !name.endsWith(".partial")).sort()).toEqual(["input.txt", "metadata.json"]);
}
const queueEvents = () => events.filter(event => event.type === "read_queue");

describe("socket raw speech ingress (real creator/store/queue; canonical isolated preload)", () => {
  beforeEach(() => {
    spies = []; contexts = []; events = []; fixture = "";
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, redirected = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !redirected ||
        dirname(run) !== resolve(import.meta.dir, "../../.test-tmp") ||
        !new RegExp(`^${process.pid}-[a-f0-9]{4}$`).test(basename(run)) || fs.realpathSync(run) !== run ||
        !resolve(TTS_DISABLED_FILE).startsWith(run + "/") ||
        !resolve(redirected).startsWith(run + "/") || fs.realpathSync(redirected) !== resolve(redirected)) {
      throw new Error("canonical isolated preload required");
    }
    savedRoot = redirected; fixture = fs.mkdtempSync(join(redirected, "socket-ingress-"));
    root = join(fixture, "recordings"); fs.mkdirSync(root, { mode: 0o700 }); process.env.QA_VOICE_RECORDINGS_DIR = root;
    resetSelectionReadQueueForTests();
    spies.push(spyOn(archive, "createSpeakReceipt").mockImplementation(request => {
      const receipt = realCreate(request); if (receipt.kind === "created") contexts.push(receipt.context); return receipt;
    }), spyOn(input, "getRecordingState").mockReturnValue("idle"),
    spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(0), spyOn(tts, "stopPlayback").mockReturnValue(true),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(socket, "broadcast").mockImplementation(event => { events.push(structuredClone(event)); }));
    state = spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"); spies.push(state);
    active = spyOn(reservation, "hasActiveVoiceOperation").mockReturnValue(false); spies.push(active);
    log = spyOn(console, "error").mockImplementation(() => {}); spies.push(log);
    start = spyOn(tts, "speakText").mockImplementation((_text, _kind, identity) => {
      expect(identity?.archiveContext).toBeDefined();
      expect(fs.existsSync(join(identity!.archiveContext!.path, "input.txt"))).toBe(true);
      return syntheticHandle(identity?.request_id ?? "synthetic-no-client-id");
    }); spies.push(start);
  });
  afterEach(async () => {
    if (!fixture) return;
    resetSelectionReadQueueForTests();
    await flushSpeechArchives();
    for (const spy of spies.reverse()) spy.mockRestore();
    process.env.QA_VOICE_RECORDINGS_DIR = savedRoot;
    fs.rmSync(fixture, { recursive: true, force: true });
  });

  for (const source of ["selection", "clipboard", "cli", undefined, "hostile source", "direct"] as const)
    it(`retains one raw direct invocation with source ${source}`, () => {
      const observed: tts.LongReadHandle[] = [];
      expect(incoming({ id: "direct", format: "markdown", profile: "long", source,
        archiveContext: { path: "/untrusted", id: "untrusted" }, text_hash: "a".repeat(64) }, read => observed.push(read)))
        .toMatchObject({ outcome: "accept", id: "direct" });
      expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(1);
      expect(contexts).toHaveLength(1); retained(contexts[0], "received");
      expect(metadata(contexts[0])).toMatchObject({ request_id: "direct",
        request_source: source === "selection" || source === "clipboard" || source === "cli" ? source : null,
        connection: null, format: "markdown", blocking: null,
        requested: { mode: null, profile: "long", engine: null, voice: null, rate: null },
        build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
      expect(start).toHaveBeenCalledTimes(1);
      expect(start.mock.calls[0]).toEqual(["שלום🙂 fu… no, full", "long",
        { request_id: "direct", text_hash: normalizedSpeechHash(raw), archiveContext: contexts[0],
          ...(source === "selection" ? { structuredDisplay: projectStructuredSpeech(raw) } : {}) }]);
      expect(observed).toEqual([start.mock.results[0].value]);
    });
  for (const format of [undefined, "plain"] as const) it(`keeps absent client ID and exact bytes with format=${format}`, () => {
    expect(incoming({ format })).toMatchObject({ outcome: "accept" });
    expect(contexts).toHaveLength(1); retained(contexts[0], "received");
    expect(metadata(contexts[0])).toMatchObject({ request_source: null, connection: null, format: format ?? null,
      blocking: null, requested: { profile: null } });
    expect(start.mock.calls[0]).toEqual([raw, "auto", { request_id: undefined,
      text_hash: normalizedSpeechHash(raw), archiveContext: contexts[0] }]);
  });
  for (const source of ["selection", "clipboard"] as const) it(`starts queued ${source} from idle without a direct lifecycle callback`, () => {
    let observed = false;
    expect(incoming({ id: "first", source, queue: true }, () => { observed = true; })).toMatchObject({ outcome: "accept" });
    expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(1); retained(contexts[0], "received");
    expect(start).toHaveBeenCalledTimes(1); expect(observed).toBe(false);
    expect(start.mock.calls[0][2]?.archiveContext).toBe(contexts[0]);
  });
  for (const source of ["selection", "clipboard"] as const) it(`carries queued ${source} through preparation and Next once`, async () => {
    incoming({ id: "A", source: "selection", text: raw + " owner" });
    const prepared = deferredFixture<PreparedReadStart>(), seen = fixtureBarrier<archive.SpeakArchiveContext | undefined>();
    const lease = new PreparedReadStart("synthetic", { chunk: { audioFile: "unused", durationMs: 1, wordBoundaries: [] },
      voice: "synthetic", engine: "synthetic" }, () => {});
    spies.push(spyOn(tts, "prepareSelectionReadStart").mockImplementation((_text, _profile, owner, _signal, context) => {
      expect(owner).toBe("A"); seen.push(context); return prepared.promise;
    }));
    let observed = false;
    expect(incoming({ id: "B", source, queue: true, format: "markdown" }, () => { observed = true; }))
      .toMatchObject({ outcome: "accept", reason: "queued" });
    expect(await seen.at(0)).toBe(contexts[1]);
    expect(tts.prepareSelectionReadStart).toHaveBeenCalledTimes(1);
    // The queue already awaits this exact preparation; it receives the lease before this observer.
    prepared.resolve(lease); await prepared.promise;
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" })).toMatchObject({ outcome: "accept" });
    expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(2);
    expect(contexts).toHaveLength(2); expect(start).toHaveBeenCalledTimes(2); expect(observed).toBe(false);
    retained(contexts[1], "received");
    expect(start.mock.calls[1][2]?.archiveContext).toBe(contexts[1]);
    expect(start.mock.calls[1][3]).toBe(lease);
    expect(start.mock.calls[1][2]?.structuredDisplay).toEqual(source === "selection" ? projectStructuredSpeech(raw) : undefined);
    expect(queueEvents()).toEqual([{ type: "read_queue", count: 1, current_request_id: "A" },
      { type: "read_queue", count: 0, current_request_id: "B" }]);
    for (const context of contexts) {
      expect(JSON.stringify(events)).not.toContain(context.path); expect(JSON.stringify(events)).not.toContain(context.id);
    }
    expect(JSON.stringify(events)).not.toContain("archiveContext"); expect(JSON.stringify(events)).not.toContain("שלום");
  });
  it("retains busy/reservation and queue-full refusals without audio or clearing the owner", async () => {
    state.mockReturnValue("recording"); expect(incoming({ id: "busy" })).toMatchObject({ outcome: "reject", reason: "busy" });
    state.mockReturnValue("idle"); active.mockReturnValue(true);
    expect(incoming({ id: "reserved" })).toMatchObject({ outcome: "reject", reason: "busy" }); active.mockReturnValue(false);
    expect(start).not.toHaveBeenCalled(); retained(contexts[0], "rejected"); retained(contexts[1], "rejected");
    incoming({ id: "A", source: "selection" });
    for (let i = 0; i < 10; i++) expect(incoming({ id: `Q${i}`, source: "selection", queue: true, text: raw + ` queued ${i}` })).toMatchObject({ reason: "queued" });
    expect(incoming({ id: "full", source: "clipboard", queue: true })).toMatchObject({ outcome: "reject", reason: "queue full" });
    retained(contexts.at(-1)!, "rejected"); expect(start).toHaveBeenCalledTimes(1);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 10, current_request_id: "A" });
  });
  it("clear/preemption retains waiting inputs without inventing completion or restarting them", async () => {
    incoming({ id: "A", source: "selection" }); incoming({ id: "B", source: "clipboard", queue: true });
    incoming({ id: "agent", source: "cli" });
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" })).toMatchObject({ outcome: "noop", reason: "stale" });
    expect(contexts).toHaveLength(3); await flushSpeechArchives(); retained(contexts[1], "stopped"); expect(start).toHaveBeenCalledTimes(2);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 0, current_request_id: null });
  });
  for (const queue of [false, true]) it(`keeps repeated-ID invocations distinct with queue=${queue}`, async () => {
    incoming({ id: "same", source: "cli" }); incoming({ id: "same", source: "cli", queue });
    expect(contexts).toHaveLength(2); expect(contexts[0].id).not.toBe(contexts[1].id);
    if (queue) expect(await handleSocketCommand({ cmd: "read_next", request_id: "same" })).toMatchObject({ outcome: "accept" });
    expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(2);
    expect(contexts).toHaveLength(2); expect(start).toHaveBeenCalledTimes(2);
    for (let i = 0; i < 2; i++) { retained(contexts[i], "received"); expect(start.mock.calls[i][2]?.archiveContext).toBe(contexts[i]); }
  });
  it("invalid, unauthenticated and nonspoken commands never create speech receipts", async () => {
    for (const fields of [{ text: " " }, { text: 3 }, { profile: "invalid" }, { format: "html" }, { text: "x".repeat(200001) }])
      expect(incoming(fields)).toBeNull();
    await expect(createSpeechControl("synthetic-auth", handleSocketCommand)({ cmd: "speak_text", text: raw, token: "wrong" })).rejects.toThrow("Unauthorized");
    spies.push(spyOn(tts, "getHistoryEntry").mockReturnValue(null));
    for (const command of [{ cmd: "replay" }, { cmd: "stop" }, { cmd: "cancel" }, { cmd: "read_next", request_id: "stale" }] satisfies SocketCommand[])
      handleSocketCommand(command);
    expect(archive.createSpeakReceipt).not.toHaveBeenCalled();
    expect(contexts).toHaveLength(0); expect(start).not.toHaveBeenCalled(); expect(fs.readdirSync(root)).toEqual([]);
  });
  for (const queue of [false, true]) it(`initial archive failure is bounded before direct/queued speech: ${queue}`, () => {
    spies.push(spyOn(fs, "writeFileSync").mockImplementation(() => { throw new Error(`private ${root} ${raw}`); }));
    expect(incoming({ id: "failed", queue })).toEqual({ type: "ack", command: "speak_text", id: "failed",
      outcome: "reject", reason: "Speech refused: input archive unavailable (IO_ERROR)" });
    expect(start).not.toHaveBeenCalled(); expect(contexts).toHaveLength(0);
    expect(log.mock.calls.flat().join(" ")).not.toContain(root); expect(log.mock.calls.flat().join(" ")).not.toContain("שלום");
  });
  for (const queue of [false, true]) for (const message of ["TTS is disabled", tts.SPEAKER_OUTPUT_REFUSED_MESSAGE, "synthesis failed"])
    it(`retains synchronous failure with queue=${queue}: ${message}`, () => {
    start.mockImplementation(() => { throw new Error(message); });
    expect(incoming({ id: "failed", queue })).toMatchObject({ outcome: "reject", reason: message });
    retained(contexts[0], message === "synthesis failed" ? "failed" : "rejected");
    expect(log.mock.calls.flat().join(" ")).not.toContain("FINALIZED");
  });
  it("queued start refusal retains its context and clears the existing chain", async () => {
    incoming({ id: "A", source: "selection", text: raw + " owner" }); incoming({ id: "B", source: "selection", queue: true });
    active.mockReturnValue(true);
    expect(await handleSocketCommand({ cmd: "read_next", request_id: "A" })).toMatchObject({ outcome: "accept" });
    retained(contexts[1], "rejected"); expect(start).toHaveBeenCalledTimes(1);
    expect(queueEvents().at(-1)).toEqual({ type: "read_queue", count: 0, current_request_id: null });
  });
  it("real disabled long-read refuses before runner synthesis", () => {
    const run = spyOn(runner, "runLongRead"); spies.push(run);
    start.mockImplementation((text, _kind, identity) => tts.speakLongRead(text,
      { engine: "edge", voice: "synthetic", rate: "+0%" }, Date.now(), identity));
    const previous = fs.existsSync(TTS_DISABLED_FILE) ? fs.readFileSync(TTS_DISABLED_FILE) : undefined;
    fs.writeFileSync(TTS_DISABLED_FILE, "1");
    try {
      expect(incoming({ id: "disabled" })).toMatchObject({ outcome: "reject", reason: "TTS is disabled" });
      retained(contexts[0], "rejected"); expect(run).not.toHaveBeenCalled();
    } finally {
      if (previous) fs.writeFileSync(TTS_DISABLED_FILE, previous); else fs.rmSync(TTS_DISABLED_FILE);
    }
  });
  it("explicit idle Stop clears waiting reads without another receipt or completion", async () => {
    incoming({ id: "A", source: "selection", text: raw + " owner" }); incoming({ id: "B", source: "selection", queue: true });
    expect(handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "noop", reason: "already idle" });
    expect(handleSocketCommand({ cmd: "read_next", request_id: "A" })).toMatchObject({ outcome: "noop", reason: "stale" });
    expect(contexts).toHaveLength(2); await flushSpeechArchives(); retained(contexts[1], "stopped"); expect(start).toHaveBeenCalledTimes(1);
  });
  it("late archive update fault keeps honest received evidence and fixed telemetry", () => {
    start.mockImplementation(() => { throw new Error("TTS is disabled"); });
    const rename = fs.renameSync;
    spies.push(spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(from).endsWith(".partial")) throw new Error(`private ${root} ${raw}`); rename(from, to);
    }));
    expect(incoming({ id: "late" })).toMatchObject({ outcome: "reject", reason: "TTS is disabled" }); retained(contexts[0], "received");
    expect(log.mock.calls.flat().join(" ")).toContain("speak archive update failed: WRITE_UNCERTAIN");
    expect(log.mock.calls.flat().join(" ")).not.toContain(root); expect(log.mock.calls.flat().join(" ")).not.toContain("שלום");
  });
  it("keeps received evidence if a direct lifecycle observer throws after speech admission", () => {
    expect(incoming({ id: "observer" }, () => { throw new Error("observer failure"); })).toMatchObject({ outcome: "reject" });
    retained(contexts[0], "received"); expect(start).toHaveBeenCalledTimes(1);
  });
  it("real long-read boundary receives the same private context and projects only public identity", async () => {
    const entered = fixtureBarrier<archive.SpeakArchiveContext | undefined>();
    const synthesized: string[] = [], played: string[] = [], disposed: string[] = [];
    spies.push(spyOn(runner, "runLongRead").mockImplementation((texts, id, signal, deps, lookahead) => {
      entered.push(deps.archiveContext);
      return realRun(texts, id, signal, { ...deps,
        synthesize: async (text, index) => { synthesized.push(text); return { audioFile: `synthetic-no-file-${index}`, durationMs: 1, wordBoundaries: [] }; },
        play: chunk => { played.push(chunk.audioFile); return { started: Promise.resolve(false),
          exited: Promise.resolve({ status: "failed", stopped_at_ms: 0 }) }; },
        saveHistory: async () => { throw new Error("Unstarted player must not save history"); },
        dispose: chunk => { disposed.push(chunk.audioFile); },
      }, lookahead);
    }));
    start.mockImplementation((text, _kind, identity) => tts.speakLongRead(text,
      { engine: "edge", voice: "synthetic", rate: "+0%" }, Date.now(), identity));
    let handle: tts.LongReadHandle | undefined;
    expect(incoming({ id: "runner" }, value => { handle = value; })).toMatchObject({ outcome: "accept" });
    expect(await entered.at(0)).toBe(contexts[0]); await handle!.done; await flushSpeechArchives();
    retained(contexts[0], "failed");
    // PROSODY v2 (b): the bold-only first line is planned as its own emphasized utterance, so this raw
    // fixture is two chunks and lookahead may synthesize chunk 1 before chunk 0's player fails. Every
    // synthesized chunk is still disposed exactly once, and only chunk 0 ever reached a player.
    expect(synthesized.length).toBeGreaterThanOrEqual(1); expect(played).toEqual(["synthetic-no-file-0"]);
    expect([...disposed].sort()).toEqual(synthesized.map((_, index) => `synthetic-no-file-${index}`));
    expect(events).toContainEqual(expect.objectContaining({ type: "state", request_id: "runner", text_hash: normalizedSpeechHash(raw) }));
    expect(JSON.stringify(events)).not.toContain(contexts[0].path); expect(JSON.stringify(events)).not.toContain("archiveContext");
  });
});
