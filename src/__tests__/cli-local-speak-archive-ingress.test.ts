import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { createHash, randomUUID } from "node:crypto";
import * as fs from "fs";
import * as net from "node:net";
import { basename, dirname, join, resolve } from "node:path";
import * as archive from "../speak-archive";
import * as tts from "../tts";
import * as markdown from "../tts/markdown-to-speech";
import * as secret from "../speech-control";
import * as runner from "../tts/long-read";
import * as recording from "../recording-state";
import * as socketClient from "../socket-client";
import { requestSpeech, runSpeakCli, speakLocally, type SpeechRequest } from "../cli/speak";
import { deferredFixture, fixtureBarrier } from "./long-read-fixture-barriers";

const raw = " \t**שלום🙂**\n\nfu… no, full\r\n  ";
const realCreate = archive.createSpeakReceipt, realRun = runner.runLongRead;
const handle = (): tts.LongReadHandle => ({ id: "synthetic-local", generation: 1, done: Promise.resolve(),
  playerExited: Promise.resolve(), started: Promise.resolve({}), completion: Promise.resolve({}) });
const request = (): Extract<SpeechRequest, { cmd: "speak_text" }> => ({
  cmd: "speak_text", text: raw, profile: "auto", format: "plain", wait: false,
});
const unavailable = (code = "ENOENT") => async (_request: SpeechRequest) => { throw Object.assign(new Error("unavailable"), { code }); };
let root: string, fixture: string, savedRoot: string, stderr: string[], stdout: string[];
let contexts: archive.SpeakArchiveContext[], spies: Array<{ mockRestore(): void }>;
let start: ReturnType<typeof spyOn<typeof tts, "speakText">>;
let stop: ReturnType<typeof spyOn<typeof tts, "stopPlayback">>;
let drain: ReturnType<typeof spyOn<typeof tts, "awaitCurrentPlayback">>;
let log: ReturnType<typeof spyOn<typeof console, "error">>;
let listeners: { int: ReturnType<typeof process.listeners>; term: ReturnType<typeof process.listeners> };
const io = () => ({ readStdin: async () => raw, readFile: async (path: string) => fs.readFileSync(path, "utf8"),
  stderr: (s: string) => { stderr.push(s); }, stdout: (s: string) => { stdout.push(s); } });
const metadata = (context: archive.SpeakArchiveContext) => JSON.parse(fs.readFileSync(join(context.path, "metadata.json"), "utf8"));
function retained(context: archive.SpeakArchiveContext, status = "received") {
  expect(context.id).toMatch(/^\d{4}-\d\d-\d\dT\d\d-\d\d-\d\d-\d{3}Z-[a-f0-9]{8}$/);
  const path = join(root, context.id.slice(0, 10), context.id);
  expect(context.path).toBe(path);
  for (const directory of [root, dirname(path), path]) {
    const stat = fs.lstatSync(directory);
    expect(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o7777) === 0o700).toBe(true);
  }
  for (const name of ["input.txt", "metadata.json"]) {
    const stat = fs.lstatSync(join(path, name));
    expect(stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1 && stat.uid === process.getuid?.() && (stat.mode & 0o7777) === 0o600).toBe(true);
  }
  expect(fs.readFileSync(join(path, "input.txt"))).toEqual(Buffer.from(raw));
  const m = metadata(context);
  expect(m).toMatchObject({ source: "speak", status, generation_id: null, request_source: "cli", connection: null, blocking: true,
    input: { bytes: Buffer.byteLength(raw), sha256: createHash("sha256").update(raw).digest("hex") },
    requested: { mode: null, engine: null, voice: null, rate: null },
    build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } });
  expect(m.artifacts ?? []).toEqual([]);
  expect(m.lifecycle?.summary.generated_audio_ms ?? null).toBeNull();
  expect(m.lifecycle?.summary.player_reported_played_ms ?? null).toBeNull();
  expect(m.lifecycle?.played_spans ?? []).toEqual([]);
  expect(fs.readdirSync(path).filter(name => !name.endsWith(".partial")).sort()).toEqual(["input.txt", "metadata.json"]);
  if (status === "received") expect(m).toEqual(context.metadata);
}
function restored() {
  expect(process.listeners("SIGINT")).toEqual(listeners.int);
  expect(process.listeners("SIGTERM")).toEqual(listeners.term);
}

describe("CLI local raw ingress (real creator/store; controlled speech and socket seams)", () => {
  beforeEach(() => {
    spies = []; contexts = []; stderr = []; stdout = []; fixture = "";
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, redirected = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !redirected ||
        dirname(run) !== resolve(import.meta.dir, "../../.test-tmp") ||
        !new RegExp(`^${process.pid}-[a-f0-9]{4}$`).test(basename(run)) || fs.realpathSync(run) !== run ||
        !redirected.startsWith(run + "/") || fs.realpathSync(redirected) !== redirected) throw new Error("canonical isolated preload required");
    for (const path of [run, redirected]) {
      const stat = fs.lstatSync(path);
      expect(stat.isDirectory() && !stat.isSymbolicLink() && stat.uid === process.getuid?.() && (stat.mode & 0o7777) === 0o700).toBe(true);
    }
    savedRoot = redirected; fixture = fs.mkdtempSync(join(redirected, "cli-ingress-"));
    root = join(fixture, "recordings"); fs.mkdirSync(root, { mode: 0o700 }); process.env.QA_VOICE_RECORDINGS_DIR = root;
    listeners = { int: process.listeners("SIGINT"), term: process.listeners("SIGTERM") };
    spies.push(spyOn(archive, "createSpeakReceipt").mockImplementation(value => {
      const receipt = realCreate(value); if (receipt.kind === "created") contexts.push(receipt.context); return receipt;
    }));
    start = spyOn(tts, "speakText").mockImplementation(() => handle()); spies.push(start);
    stop = spyOn(tts, "stopPlayback").mockReturnValue(true); spies.push(stop);
    drain = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined); spies.push(drain);
    log = spyOn(console, "error").mockImplementation(() => {}); spies.push(log);
  });
  afterEach(() => {
    try { if (fixture) restored(); }
    finally {
      for (const spy of spies.reverse()) spy.mockRestore();
      if (fixture) { process.env.QA_VOICE_RECORDINGS_DIR = savedRoot; fs.rmSync(fixture, { recursive: true, force: true }); }
    }
  });

  for (const code of ["ENOENT", "ECONNREFUSED"]) for (const wait of [false, true])
    for (const origin of ["literal", "stdin", "file"]) it(`raw ${origin}, ${code}, wait=${wait}`, async () => {
      const path = join(fixture, "read.MD"); fs.writeFileSync(path, raw, { mode: 0o600 });
      const args = origin === "literal" ? [raw] : origin === "stdin" ? ["-", "--markdown"] : ["--file", path];
      const format = origin === "literal" ? "plain" : "markdown";
      const profile = origin === "file" ? "long" : origin === "stdin" ? "short" : "auto";
      const transport = spyOn({ request: unavailable(code) }, "request"); spies.push(transport);
      expect(await runSpeakCli([...args, "--profile", profile, ...(wait ? ["--wait"] : [])], {
        ...io(), request: async value => {
          expect(archive.createSpeakReceipt).not.toHaveBeenCalled(); expect(fs.readdirSync(root)).toEqual([]);
          return transport(value);
        }, local: speakLocally,
      })).toBe(0);
      expect(transport.mock.calls).toEqual([[{ cmd: "speak_text", text: raw, profile, format, wait }]]);
      expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(1); expect(contexts).toHaveLength(1);
      const context = contexts[0]; retained(context);
      expect(context.metadata.request_id).toMatch(/^[a-f0-9-]{36}$/);
      expect(context.metadata.requested).toEqual({ mode: null, profile, engine: null, voice: null, rate: null });
      expect(context.metadata.format).toBe(format);
      expect(start.mock.calls).toEqual([[format === "markdown" ? "שלום🙂 fu… no, full" : raw, profile, { archiveContext: context }]]);
      expect(stdout).toEqual([]); expect(stderr).toEqual(["VoiceLayer daemon unavailable; speaking locally in the foreground (Ctrl-C to stop; no teleprompter).\n"]);
      expect(stop).not.toHaveBeenCalled(); expect(drain).not.toHaveBeenCalled();
    });
  it("repeated local invocations retain distinct receipts without an ID registry", async () => {
    await speakLocally(request()); await speakLocally(request());
    expect(contexts).toHaveLength(2); expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(2);
    expect(contexts[0].id).not.toBe(contexts[1].id);
    expect(contexts[0].metadata.request_id).not.toBe(contexts[1].metadata.request_id);
    contexts.forEach(context => retained(context)); expect(start).toHaveBeenCalledTimes(2);
  });
  for (const code of ["ENOENT", "ECONNREFUSED"]) it(`real requestSpeech initial ${code} enters local exactly once`, async () => {
    const entered = fixtureBarrier<net.Socket>();
    const readSecret = spyOn(secret, "readSpeechSecret"); spies.push(readSecret,
      spyOn(net, "createConnection").mockImplementation(() => { const socket = new net.Socket(); entered.push(socket); return socket; }));
    const pending = runSpeakCli([raw], { ...io(), request: value => requestSpeech(value), local: speakLocally });
    const socket = await entered.at(0);
    try {
      expect(archive.createSpeakReceipt).not.toHaveBeenCalled();
      socket.emit("error", Object.assign(new Error("synthetic connect failure"), { code }));
      expect(await pending).toBe(0); expect(readSecret).not.toHaveBeenCalled();
      expect(contexts).toHaveLength(1); expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(1);
      expect(start.mock.calls).toEqual([[raw, "auto", { archiveContext: contexts[0] }]]); retained(contexts[0]);
    } finally { socket.destroy(); }
  });
  for (const outcome of ["success", "refusal", "auth", "connected-ENOENT", "connected-ECONNREFUSED", "closed", "secret-read"])
    it(`real requestSpeech ${outcome} never creates a local receipt or replay`, async () => {
      const entered = fixtureBarrier<net.Socket>(), ephemeral = randomUUID();
      spies.push(spyOn(secret, "readSpeechSecret").mockImplementation(() => {
        if (outcome === "secret-read") throw new Error("synthetic read failure"); return ephemeral;
      }), spyOn(net, "createConnection").mockImplementation(() => {
        const socket = new net.Socket();
        spies.push(spyOn(socket, "write").mockImplementation(payload => {
          expect(JSON.parse(String(payload))).toEqual({ jsonrpc: "2.0", id: 1, method: "voicelayer/speech",
            params: { ...request(), source: "cli", token: ephemeral } });
          return true;
        }));
        entered.push(socket); return socket;
      }));
      const running = runSpeakCli([raw], { ...io(), request: value => requestSpeech(value), local: speakLocally });
      const socket = await entered.at(0);
      try {
        socket.emit("connect");
        if (outcome.startsWith("connected-")) socket.emit("error", Object.assign(new Error("synthetic disconnect"), { code: outcome.slice(10) }));
        else if (outcome === "closed") socket.emit("close");
        else if (outcome !== "secret-read") socket.emit("data", JSON.stringify({ id: 1,
          ...(outcome === "success" ? { result: { status: "started" } } : { error: { message: outcome === "auth" ? "Unauthorized speech control" : "busy" } }) }) + "\n");
        expect(await running).toBe(outcome === "success" ? 0 : 1);
        expect(archive.createSpeakReceipt).not.toHaveBeenCalled(); expect(start).not.toHaveBeenCalled();
        expect(contexts).toEqual([]); expect(fs.readdirSync(root)).toEqual([]); expect(stdout).toEqual([]);
        expect(stderr.join("")).not.toContain("speaking locally"); expect(stderr.join("")).not.toContain(ephemeral);
        if (outcome.startsWith("connected-") || outcome === "closed") expect(stderr.join("")).toContain("delivery may have occurred");
      } finally { socket.destroy(); }
    });
  for (const args of [["--stop"], ["--oops"], ["--profile", "bad"], [" "], ["x".repeat(200_001)], ["--help"]])
    it(`excludes non-speech or invalid arguments (${args[0].slice(0, 20)})`, async () => {
      expect(await runSpeakCli(args, { ...io(), request: unavailable(), local: speakLocally })).toBe(args[0] === "--help" ? 0 : 1);
      expect(archive.createSpeakReceipt).not.toHaveBeenCalled(); expect(start).not.toHaveBeenCalled(); expect(fs.readdirSync(root)).toEqual([]);
    });
  it("archive creation fault refuses before conversion or speech without reading private error accessors", async () => {
    let accessed = false;
    const fault = Object.defineProperties({}, { message: { get() { accessed = true; throw new Error(raw); } },
      toString: { value() { accessed = true; throw new Error(root); } } });
    spies.push(spyOn(fs, "writeFileSync").mockImplementation(() => { throw fault; }));
    const convert = spyOn(markdown, "markdownToSpeech"); spies.push(convert);
    expect(await runSpeakCli([raw, "--markdown"], { ...io(), request: unavailable(), local: speakLocally })).toBe(1);
    expect(stderr.at(-1)).toBe("voicelayer speak: Speech refused: input archive unavailable (IO_ERROR)\n");
    expect(accessed).toBe(false); expect(convert).not.toHaveBeenCalled(); expect(start).not.toHaveBeenCalled();
    expect(contexts).toEqual([]); expect(log).not.toHaveBeenCalled(); expect(stop).not.toHaveBeenCalled(); expect(drain).not.toHaveBeenCalled();
  });
  for (const message of ["TTS is disabled", tts.SPEAKER_OUTPUT_REFUSED_MESSAGE, "synthetic synthesis failure"])
    it(`synchronous local failure retains honest lifecycle: ${message}`, async () => {
      start.mockImplementation(() => { throw new Error(message); });
      await expect(speakLocally(request())).rejects.toThrow(message);
      const rejected = message !== "synthetic synthesis failure"; retained(contexts[0], rejected ? "rejected" : "failed");
      expect(metadata(contexts[0]).lifecycle).toEqual({ status: rejected ? "rejected" : "failed", generation_id: null,
        timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
        summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: rejected ? "REJECTED" : "OUTPUT_UNAVAILABLE" }, played_spans: [] });
      expect(stop).not.toHaveBeenCalled(); expect(drain).not.toHaveBeenCalled();
    });
  for (const phase of ["completion", "started"]) it(`post-handle ${phase} error retains uncertainty`, async () => {
    start.mockReturnValue({ ...handle(), [phase]: Promise.resolve({ error: "synthetic late failure" }) });
    await expect(speakLocally(request())).rejects.toThrow("synthetic late failure");
    retained(contexts[0]); expect(stop).not.toHaveBeenCalled();
  });
  it("late store failure is redacted and preserves the original refusal", async () => {
    const rename = fs.renameSync;
    spies.push(spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(from).endsWith(".partial")) throw new Error(`private ${root} ${raw}`); rename(from, to);
    }));
    start.mockImplementation(() => { throw new Error("TTS is disabled"); });
    await expect(speakLocally(request())).rejects.toThrow("TTS is disabled"); retained(contexts[0]);
    expect(log.mock.calls).toEqual([["[voicelayer] speak archive update failed: WRITE_UNCERTAIN"]]);
    expect(stop).not.toHaveBeenCalled(); expect(drain).not.toHaveBeenCalled();
  });
  for (const signal of ["SIGINT", "SIGTERM"] as const) for (const phase of ["before-handle", "after-handle"])
    it(`controlled ${signal} ${phase} preserves stop/drain and listener custody`, async () => {
      const entered = fixtureBarrier<void>(), complete = deferredFixture<{ error?: string }>();
      let signalListener: ReturnType<typeof process.listeners>[number] | undefined;
      start.mockImplementation(() => {
        expect(process.listeners("SIGINT")).toHaveLength(listeners.int.length + 1);
        expect(process.listeners("SIGTERM")).toHaveLength(listeners.term.length + 1);
        const prior = signal === "SIGINT" ? listeners.int : listeners.term;
        const own = process.listeners(signal).filter(value => !prior.includes(value));
        expect(own).toHaveLength(1); signalListener = own[0];
        if (phase === "before-handle") { signalListener(); throw new Error(`Local speech interrupted (${signal})`); }
        entered.push(); return { ...handle(), completion: complete.promise };
      });
      const pending = speakLocally(request());
      const outcome = pending.then(() => "resolved", error => error instanceof Error ? error.message : "unexpected");
      if (phase === "after-handle") {
        await entered.at(0); expect(drain).not.toHaveBeenCalled();
        if (!signalListener) throw new Error("missing owned signal listener"); signalListener(); complete.resolve({});
      }
      expect(await outcome).toBe(`Local speech interrupted (${signal})`);
      expect(stop).toHaveBeenCalledTimes(1); expect(drain).toHaveBeenCalledTimes(1);
      retained(contexts[0], phase === "before-handle" ? "stopped" : "received"); restored();
    });
  it("foreground waits for completion then started for a non-wait request", async () => {
    const entered = fixtureBarrier<void>(), completing = deferredFixture<{ error?: string }>(), starting = deferredFixture<{ error?: string }>();
    const seen = fixtureBarrier<string>();
    start.mockImplementation(() => {
      const read = { ...handle(), completion: completing.promise };
      Object.defineProperty(read, "started", { get() { seen.push("started"); return starting.promise; } });
      entered.push(); return read;
    });
    let ended = false;
    const pending = speakLocally(request()).then(() => { ended = true; });
    await entered.at(0); expect(ended).toBe(false); expect(seen.values).toEqual([]);
    completing.resolve({}); expect(await seen.at(0)).toBe("started"); expect(ended).toBe(false);
    starting.resolve({}); await pending; retained(contexts[0]); restored();
  });
  it("local boundary carries one real receipt into real long-read synthetic synthesis/player teardown", async () => {
    const entered = fixtureBarrier<archive.SpeakArchiveContext | undefined>();
    const synthesized: string[] = [], played: string[] = [], disposed: string[] = [];
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
      spyOn(socketClient, "broadcast").mockImplementation(() => {}),
      spyOn(runner, "runLongRead").mockImplementation((texts, id, signal, deps, lookahead) => {
        entered.push(deps.archiveContext);
        return realRun(texts, id, signal, { ...deps,
          synthesize: async text => { synthesized.push(text); return { audioFile: "synthetic-no-file", durationMs: 1, wordBoundaries: [] }; },
          play: chunk => { played.push(chunk.audioFile); return { started: Promise.resolve(false),
            exited: Promise.resolve({ status: "failed", stopped_at_ms: 0 }) }; },
          saveHistory: async () => { throw new Error("unstarted synthetic player must not save history"); },
          dispose: chunk => { disposed.push(chunk.audioFile); },
        }, lookahead);
      }));
    start.mockImplementation((text, _profile, identity) => tts.speakLongRead(text,
      { engine: "edge", voice: "synthetic", rate: "+0%" }, Date.now(), identity));
    await expect(speakLocally(request())).rejects.toThrow("Speech stopped before playback");
    expect(await entered.at(0)).toBe(contexts[0]); expect(contexts).toHaveLength(1);
    expect(archive.createSpeakReceipt).toHaveBeenCalledTimes(1);
    expect(fs.readFileSync(join(contexts[0].path, "input.txt"), "utf8")).toBe(raw);
    expect(metadata(contexts[0]).speech).toMatchObject({ state: "failed", reason: "SPEECH_FAILED" });
    // PROSODY v2 (b): the bold-only first line is planned as its own emphasized utterance, so this raw
    // fixture is two chunks and lookahead may synthesize chunk 1 before chunk 0's player fails. Every
    // synthesized chunk is still disposed exactly once, and only chunk 0 ever reached a player.
    expect(synthesized.length).toBeGreaterThanOrEqual(1); expect(played).toEqual(["synthetic-no-file"]);
    expect(disposed).toEqual(synthesized.map(() => "synthetic-no-file"));
  });
});

describe("CLI terminal persistence before returning", () => {
  it("flushes queued terminal writes before the caller can exit", async () => {
    const { beginSpeechArchive } = await import("../speech-archive-live");
    let saved: archive.SpeakArchiveContext | undefined;
    const play = spyOn(tts, "speakText").mockImplementation((_text, _profile, identity) => {
      saved = identity?.archiveContext;
      const live = beginSpeechArchive(raw, saved);
      live.move("playing"); live.finish("completed", "PLAYBACK_COMPLETED");
      return handle();
    });
    try {
      await speakLocally(request());
      expect(saved).toBeDefined();
      expect(metadata(saved!).speech.state).toBe("completed");
    } finally { play.mockRestore(); }
  });
});
