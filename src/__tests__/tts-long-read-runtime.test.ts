import { afterEach, beforeEach, describe, expect, it, jest, spyOn } from "bun:test";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import * as qwen from "../tts/qwen3";
import * as alignment from "../tts/clone-alignment";
import * as binaries from "../resolve-binary";
import { createHash } from "node:crypto";
import * as input from "../input";
import * as booking from "../session-booking";
import * as longReadRunner from "../tts/long-read";
import { handleVoiceAsk } from "../handlers";
import { awaitCurrentPlayback, getPlaybackQueueDepth, loadHistory, speak, speakLongRead, stopPlayback, seekPlayback, cancelPlayback, playAudioNonBlocking, reserveCaptureAdmission } from "../tts";
import { handleSocketCommand } from "../socket-handlers";
import { TTS_HISTORY_FILE } from "../paths";
import { readTTSControlsStatus, recordFirstAudio } from "../tts-controls-status";
import { fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

function deferred<T>() { let resolve!: (v: T) => void, reject!: (e: Error) => void; const promise = new Promise<T>((r, fail) => { resolve = r; reject = fail; }); return { promise, resolve, reject }; }
const text = Array.from({ length: 80 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" ");

describe("long-read real runtime with owned synth/player fakes", () => {
  const originalSpawn = Bun.spawn, originalSpawnSync = Bun.spawnSync;
  let synths: { argv: string[]; exit: ReturnType<typeof deferred<number>>; killed: boolean }[];
  let players: { exit: ReturnType<typeof deferred<number>>; killed: boolean; synthCount: number; argv: string[]; signals: string[] }[];
  let events: any[];
  let holdSynth: boolean, autoPlay: boolean, holdPlayerExit: boolean;
  let handles: { done: Promise<void> }[];
  let spies: ReturnType<typeof spyOn>[];
  let historyInputs: string[][];
  let holdHistory: boolean, holdDecoder: boolean;
  let failHistory: boolean;
  type Child = { exit: ReturnType<typeof deferred<number>>; killed: boolean };
  let synthBarrier: ReturnType<typeof fixtureBarrier<typeof synths[number]>>;
  let playerBarrier: ReturnType<typeof fixtureBarrier<typeof players[number]>>;
  let historyBarrier: ReturnType<typeof fixtureBarrier<Child>>;
  let decoderBarrier: ReturnType<typeof fixtureBarrier<Child>>;
  let histories: Child[], decoders: Child[];
  let clockMs: number;
  let releaseAlignments: (() => void)[];

  beforeEach(() => {
    synths = []; players = []; events = []; handles = []; historyInputs = []; spies = [];
    holdSynth = false; autoPlay = false; holdPlayerExit = false; holdHistory = false; holdDecoder = false;
    failHistory = false;
    clockMs = 100_000;
    releaseAlignments = [];
    spies.push(spyOn(Date, "now").mockImplementation(() => clockMs));
    synthBarrier = fixtureBarrier(); playerBarrier = fixtureBarrier();
    historyBarrier = fixtureBarrier(); decoderBarrier = fixtureBarrier(); histories = []; decoders = [];
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
    spies.push(spyOn(socket, "broadcast").mockImplementation((event) => events.push(structuredClone(event))));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    spies.push(spyOn(alignment, "alignCloneAudio").mockResolvedValue({ status: "untimed", identity: {} as any, words: [] }));
    // Only platform probing uses spawnSync; all synth/play/decode/conversion spawns are fakes.
    Bun.spawnSync = ((argv: string[]) => {
      if (argv.includes("-af")) { writeFileSync(argv.at(-1)!, "adjusted audio"); return { exitCode: 0 }; }
      if (argv[0] === "which" && ["ffprobe", "ffmpeg"].includes(argv[1])) return {exitCode:0, stdout:Buffer.from(argv[1]), stderr:Buffer.alloc(0)};
      return ({ exitCode: ["ffprobe", "ffmpeg"].includes(argv[0]) ? 0 : 1, stdout: Buffer.from(argv[0] === "ffprobe" ? "1\n" : ""), stderr: Buffer.alloc(0) }); }) as any;
    Bun.spawn = ((argv: string[]) => {
      if (argv[1] === "-version") return {pid: 70001, exited: Promise.resolve(argv[0] === "ffmpeg" ? 0 : 1), kill() {}};
      if (argv[0] === "which") return { pid: 70000, exited: Promise.resolve(0), stdout: new Blob(["ffmpeg"]).stream(), kill: () => {} };
      if (argv.some((arg) => arg.startsWith("--text="))) {
        const media = argv.find((arg) => arg.startsWith("--write-media="))!.split("=").slice(1).join("=");
        const metadata = argv.find((arg) => arg.startsWith("--write-metadata="))!.split("=").slice(1).join("=");
        const spoken = argv.find(a => a.startsWith("--text="))!.slice(7);
        writeFileSync(media, "fake audio"); writeFileSync(metadata, spoken.split(/\s+/).map((text, i) => JSON.stringify({text, offset: i * 120000, duration: 100000})).join("\n"));
        const exit = deferred<number>(); const item = { argv, exit, killed: false }; synths.push(item); synthBarrier.push(item);
        if (!holdSynth || synths.length === 1) exit.resolve(0);
        return { pid: 71000 + synths.length, exited: exit.promise, kill: () => { item.killed = true; exit.resolve(143); } };
      }
      if (argv[0] === "ffmpeg") {
        if (argv.includes("-af")) writeFileSync(argv.at(-1)!, "adjusted audio");
        if (argv.includes("-ss")) writeFileSync(argv.at(-1)!, "trimmed audio");
        if (argv.includes("concat") && failHistory) throw Object.assign(new Error("EBADARCH"), {code: "EBADARCH"});
        if (argv.includes("concat")) {
          const playlist = argv[argv.indexOf("-i") + 1];
          historyInputs.push(readFileSync(playlist, "utf8").split("\n"));
          writeFileSync(argv.at(-1)!, "combined audio");
        }
        const exit = deferred<number>(); const item = { exit, killed: false };
        if (argv.includes("concat")) { histories.push(item); historyBarrier.push(item); if (!holdHistory) exit.resolve(0); }
        else { decoders.push(item); decoderBarrier.push(item); if (!holdDecoder) exit.resolve(0); }
        return { pid: 72000 + decoders.length + histories.length, exited: exit.promise,
          stdout: new Blob([new Uint8Array(8)]).stream(), kill: () => { item.killed = true; exit.resolve(143); } };
      }
      const exit = deferred<number>(); const item = { exit, killed: false, synthCount: synths.length, argv, signals: [] as string[] }; players.push(item); playerBarrier.push(item);
      if (autoPlay) exit.resolve(0);
      return { pid: 73000 + players.length, exited: exit.promise, kill: (signal: string) => { item.signals.push(signal); item.killed = true; if (!holdPlayerExit) exit.resolve(143); } };
    }) as any;
  });
  afterEach(async () => {
    stopPlayback(); for (const release of releaseAlignments) release(); for (const player of players) player.exit.resolve(143); for (const child of histories) child.exit.resolve(0); for (const h of handles) await h.done; await awaitCurrentPlayback();
    for (const spy of spies) spy.mockRestore(); Bun.spawn = originalSpawn; Bun.spawnSync = originalSpawnSync;
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
  });
  const start = (engine: "edge" | "clone" = "edge", readText = text) => { const h = speakLongRead(readText, { engine, voice: "fixture", rate: "+0%" }); handles.push(h); return h; };

  it("SEL11 preserves request identity and original-text hash in Preparing and player receipts", async () => {
    const identity = { request_id: "selection-B", text_hash: createHash("sha256").update("**hello** world").digest("hex") };
    const h = speakLongRead("hello world", { engine: "edge", voice: "fixture", rate: "+0%" }, Date.now(), identity);
    handles.push(h);
    await playerBarrier.at(0);
    await fixtureCheckpoint();
    const receipts = events.filter(e => e.type === "state" && e.state === "speaking");
    expect(receipts.length).toBeGreaterThanOrEqual(2);
    for (const receipt of receipts) expect(receipt).toMatchObject(identity);
    players[0].exit.resolve(0);
    await h.done;
  });

  function cloneFixture() {
    spies.push(spyOn(qwen, "synthesizeCloned").mockResolvedValue(Buffer.from("clone audio")));
    spies.push(spyOn(qwen, "loadProfile").mockReturnValue({ engine: "qwen3-tts", reference_clips: [], reference_clip: "", fallback: "jenny" } as any));
    const entered = fixtureBarrier<alignment.CloneAlignmentRequest>();
    const pending: ReturnType<typeof deferred<alignment.CloneAlignmentResult>>[] = [];
    const reaps: ReturnType<typeof deferred<number>>[] = [];
    spies.push(spyOn(alignment, "alignCloneAudio").mockImplementation(request => {
      const result = deferred<alignment.CloneAlignmentResult>(); pending.push(result); entered.push(request);
      // This pending adapter represents an unreaped native child, not preparation.
      const reap = deferred<number>(); reaps.push(reap);
      request.onChildSpawned?.(reap.promise);
      void result.promise.then(() => reap.resolve(0));
      releaseAlignments.push(() => result.resolve({ status: "untimed", identity: {} as any, words: [] })); return result.promise;
    }));
    const result = (request: alignment.CloneAlignmentRequest): alignment.CloneAlignmentResult => ({
      status: "partial", identity: { requestId: request.requestId, chunkId: request.chunkId, playbackRate: request.playbackRate,
        audioSha256: createHash("sha256").update(readFileSync(request.audioPath)).digest("hex") },
      words: Array.from(request.displayText.matchAll(/\S+/gu), (word, i) => ({ text: word[0], displayRange: { start: word.index, end: word.index + word[0].length },
        offset_ms: i === 1 ? null : i * 100, duration_ms: i === 1 ? null : 80 })),
    });
    return { entered, pending, reaps, result };
  }

  for (const route of ["speak", "long"] as const) it(`CLN1b ${route}: playback starts before partial timings and preserves display indices`, async () => {
    const fixture = cloneFixture(), display = "Export MP3 now.";
    if (route === "speak") await speak(display, { voice: "fixture", rate: "+50%" });
    else { const h = speakLongRead(display, { engine: "clone", voice: "fixture", rate: "+50%" }); handles.push(h); }
    await playerBarrier.at(0);
    expect(events.some(e => e.type === "subtitle")).toBe(false);
    const request = await fixture.entered.at(0);
    expect(request.audioPath).toBe(players[0].argv.at(-1)!);
    expect(request).toMatchObject({ displayText: display, speechText: "Export M P three now.", playbackRate: 1, lowPriority: true });
    const published = fixtureBarrier<any>();
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(structuredClone(event)); if (event.type === "subtitle") published.push(event); }));
    fixture.pending[0].resolve(fixture.result(request));
    expect(await published.at(0)).toEqual({ type: "subtitle", words: [], aligned_words: [
      { word_index: 0, text: "Export", offset_ms: 0, duration_ms: 80 },
      { word_index: 1, text: "MP3", offset_ms: null, duration_ms: null },
      { word_index: 2, text: "now.", offset_ms: 200, duration_ms: 80 },
    ] });
  });

  for (const cmd of ["stop", "cancel"] as const) it(`R2 ${cmd} ack waits for alignment child reap after audio exits`, async () => {
    const f = cloneFixture(), h = start("clone", "Question?"); await playerBarrier.at(0); const request = await f.entered.at(0);
    if (cmd === "cancel") { players[0].exit.resolve(0); await h.done; }
    let acknowledged = false;
    const ack = Promise.resolve(handleSocketCommand({ cmd, playback_elapsed_ms: 250 })).then(() => { acknowledged = true; });
    await h.done; await fixtureCheckpoint(); expect(request.signal!.aborted).toBe(true); expect(acknowledged).toBe(false);
    releaseAlignments[0](); await ack; expect(acknowledged).toBe(true);
  });
  for (const failed of [false, true]) it(`R2 scoped terminal and quiesced-attempt fences include alignment child reap; failed=${failed}`, async () => {
    const f = cloneFixture(); let playback: any;
    await speak("Question?", { voice: "fixture", onPlaybackQueued: handle => { playback = handle; } });
    await playerBarrier.at(0); await f.entered.at(0);
    if (failed) players[0].exit.reject(new Error("fixture player exit")); else players[0].exit.resolve(0);
    await playback.exited;
    const settled: string[] = [], mark = (label: string, work: Promise<unknown>) => work.then(() => settled.push(label), () => settled.push(label));
    const waits = [mark("terminal", playback.playerExited), mark("snapshot", playback.waitForPlayerExit()), mark("drain", awaitCurrentPlayback())];
    await fixtureCheckpoint(); expect(settled).toEqual([]); releaseAlignments[0](); await Promise.all(waits); expect(settled.sort()).toEqual(["drain", "snapshot", "terminal"]);
  });
  it("R2 Ask cannot start capture until its clone alignment child is reaped", async () => {
    const f = cloneFixture();
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    const answer = handleVoiceAsk({ message: "Question?", voice: "fixture", timeout_seconds: 5 });
    await playerBarrier.at(0); await f.entered.at(0); players[0].exit.resolve(0);
    await fixtureCheckpoint(); await Bun.sleep(5); expect(capture).not.toHaveBeenCalled();
    releaseAlignments[0](); await answer; expect(capture).toHaveBeenCalledTimes(1);
  });
  it("INT1 Ask starts capture while cancelled binary lookup is still held, with no alignment child", async () => {
    const f = cloneFixture(), lookup = deferred<string>(), entered = fixtureBarrier<void>();
    spies.push(spyOn(binaries, "resolveBinaryAsync").mockImplementation(async name => {
      if (name === "ffmpeg") return "ffmpeg";
      entered.push(); return lookup.promise;
    }));
    releaseAlignments.push(() => lookup.resolve("fixture-binary"));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    const answer = handleVoiceAsk({ message: "Question?", voice: "fixture", timeout_seconds: 5 });
    await playerBarrier.at(0); await entered.at(0); players[0].exit.resolve(0);
    try {
      expect(await Promise.race([answer.then(() => "captured"), Bun.sleep(150).then(() => "blocked")])).toBe("captured");
      expect(capture).toHaveBeenCalledTimes(1); expect(f.pending).toHaveLength(0);
    } finally { lookup.resolve("fixture-binary"); await answer; }
  });
  it("INT1 Ask waits for the spawned child, then captures while adapter cleanup is still held", async () => {
    const f = cloneFixture();
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    const answer = handleVoiceAsk({ message: "Question?", voice: "fixture", timeout_seconds: 5 });
    await playerBarrier.at(0); const request = await f.entered.at(0); players[0].exit.resolve(0);
    await fixtureCheckpoint(); expect(request.signal!.aborted).toBe(true); expect(capture).not.toHaveBeenCalled();
    f.reaps[0].resolve(137);
    expect(await Promise.race([answer.then(() => "captured"), Bun.sleep(150).then(() => "blocked")])).toBe("captured");
    expect(capture).toHaveBeenCalledTimes(1); releaseAlignments[0](); await answer;
  });
  for (const confirmed of [true, false]) it(`INT1 R2 P1 rejected child exit permits a second alignment and later Ask; confirmed=${confirmed}`, async () => {
    const f = cloneFixture(), failure = new Error("fixture child exit watcher failed");
    const logs = spyOn(console, "error").mockImplementation(() => {}); spies.push(logs);
    let playback: any;
    await speak("First question?", { voice: "fixture", onPlaybackQueued: handle => { playback = handle; } });
    const terminal = playback.playerExited.then(() => "ready", () => "unconfirmed");
    await playerBarrier.at(0); const request = await f.entered.at(0);
    f.reaps[0].reject(failure); await fixtureCheckpoint();
    // The adapter's final reap attempt independently confirms termination, or
    // reports the physical state as unknown, before artifact cleanup completes.
    request.onChildrenReaped?.(confirmed ? undefined : failure);
    releaseAlignments[0](); players[0].exit.resolve(0); await playback.exited;
    const firstState = await terminal;
    await speak("Second question?", { voice: "fixture" }); await playerBarrier.at(1);
    expect(await Promise.race([f.entered.at(1).then(() => "spawned"), Bun.sleep(150).then(() => "missing")])).toBe("spawned");
    expect(f.reaps).toHaveLength(2);
    if (confirmed) expect(firstState).toBe("ready");
    else expect(logs.mock.calls.some(([line]) => /alignment.*unconfirmed/i.test(String(line)))).toBe(true);
    releaseAlignments[1](); players[1].exit.resolve(0); await awaitCurrentPlayback();
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    autoPlay = true;
    const answer = await handleVoiceAsk({ message: "Question?", voice: "fixture", timeout_seconds: 5 });
    expect(answer.isError).not.toBe(true); expect(capture).toHaveBeenCalledTimes(1);
    expect(getPlaybackQueueDepth()).toBe(0);
  });
  it("R2 replacement audio starts while cancelled alignment cleanup is still held", async () => {
    const f = cloneFixture(), old = start("clone", "Old question?"); await playerBarrier.at(0); await f.entered.at(0);
    const replacement = start("edge", "New answer."); await playerBarrier.at(1); await old.done;
    expect(players).toHaveLength(2); releaseAlignments[0](); stopPlayback(); await replacement.done;
  });

  for (const stale of ["requestId", "chunkId", "audioSha256", "playbackRate", "text", "audio", "stop", "seek", "recording", "transcribing"] as const)
    it(`CLN1b drops ${stale} alignment and cancels owned work`, async () => {
      const fixture = cloneFixture(); start("clone", "Export MP3 now."); await playerBarrier.at(0);
      const request = await fixture.entered.at(0), result = fixture.result(request);
      if (stale === "stop") stopPlayback();
      else if (stale === "seek") { seekPlayback(0); await playerBarrier.at(1); }
      else if (stale === "recording" || stale === "transcribing") {
        recording.setRecordingState(stale); expect(request.signal!.aborted).toBe(true); recording.setRecordingState("idle");
      } else if (stale === "text") result.words[0].text = "wrong";
      else if (stale === "audio") writeFileSync(request.audioPath, "replaced audio");
      else (result.identity as any)[stale] = stale === "playbackRate" ? 2 : "stale";
      fixture.pending[0].resolve(result);
      await fixtureCheckpoint(); await Bun.sleep(25);
      expect(events.some(e => e.type === "subtitle")).toBe(false);
      // Release any seek replacement's deferred alignment before teardown.
      for (let i = 1; i < fixture.pending.length; i++) fixture.pending[i].resolve({ ...result, status: "untimed" });
    });

  it("CLN1b next chunk playback never waits for old alignment and publishes local offsets", async () => {
    const fixture = cloneFixture(); start("clone"); await playerBarrier.at(0);
    const first = await fixture.entered.at(0), oldResult = fixture.result(first);
    expect(qwen.synthesizeCloned).toHaveBeenCalledTimes(2); // current + one lookahead
    players[0].exit.resolve(0); await playerBarrier.at(1);
    expect(first.signal!.aborted).toBe(true);
    fixture.pending[0].resolve(oldResult);
    const second = await fixture.entered.at(1);
    expect(events.some(e => e.type === "subtitle")).toBe(false);
    expect(events.filter(e => e.state === "speaking").at(-1).long_read.chunk_start_ms).toBe(1000);
    const published = fixtureBarrier<any>();
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(structuredClone(event)); if (event.type === "subtitle") published.push(event); }));
    fixture.pending[1].resolve(fixture.result(second));
    expect((await published.at(0)).aligned_words[0].offset_ms).toBe(0);
    expect(second.chunkId).toBe("1");
  });

  for (const engine of ["edge", "clone", "fallback"] as const) it(`SPK1 normalizes ${engine} long reads while display/history stay original`, async () => {
    const display = "Play MP3 from INCIDENT-INVENTORY.md.";
    const spoken = engine === "clone" ? "Play M P three from incident inventory dot M D." : "Play MP3 from incident inventory dot M D.";
    const calls: string[] = [];
    if (engine !== "edge") spies.push(spyOn(qwen, "synthesizeCloned").mockImplementation(async part => {
      calls.push(part); return engine === "fallback" ? null : Buffer.from("fixture audio");
    }));
    autoPlay = true; await start(engine === "edge" ? "edge" : "clone", display).done;
    if (engine === "fallback") expect(calls).toEqual(["Play M P three from incident inventory dot M D."]);
    expect(engine === "clone" ? calls : synths.map(s => s.argv.find(a => a.startsWith("--text="))!.slice(7))).toEqual([spoken]);
    expect(events.find(e => e.state === "speaking" && !e.long_read?.preparing).text).toBe(display);
    expect(loadHistory()[0].text).toBe(display);
    if (engine === "clone") expect(events.some(e => e.type === "subtitle")).toBe(false);
    else expect(events.find(e => e.type === "subtitle").words.map((w: any) => w.text)).toEqual(display.split(" "));
  });

  for (const cmd of ["stop", "cancel"] as const) it(`R1-1 ${cmd} ack waits for history and file disposal`, async () => {
    holdSynth = true; holdHistory = true;
    const h = start(); await playerBarrier.at(0); await synthBarrier.at(1);
    let acknowledged = false;
    const ack = Promise.resolve(handleSocketCommand({ cmd, playback_elapsed_ms: 250 })).then((value) => { acknowledged = true; return value; });
    const history = await historyBarrier.at(0);
    await fixtureCheckpoint();
    expect(acknowledged).toBe(false);
    const inputs = historyInputs[0].map((line) => line.slice(6, -1));
    expect(inputs.every(existsSync)).toBe(true);
    history.exit.resolve(0); await ack; await h.done;
    expect(inputs.every((path) => !existsSync(path))).toBe(true);
  });

  it("R1-1 voice_ask waits for the captured cancelled generation before its prompt", async () => {
    holdSynth = true; holdHistory = true;
    const old = start(); await playerBarrier.at(0); await synthBarrier.at(1);
    clockMs += 250;
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true, owner: { pid: process.pid, sessionId: "fixture", startedAt: new Date().toISOString() } }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    holdSynth = false; autoPlay = true;
    const answer = handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
    const history = await historyBarrier.at(0); await fixtureCheckpoint();
    expect(synths).toHaveLength(2); expect(capture).not.toHaveBeenCalled();
    holdHistory = false; history.exit.resolve(0); await answer; await old.done;
    expect(capture).toHaveBeenCalledTimes(1);
  });

  it("R1-2 stopped history excludes every chunk that never played", async () => {
    holdSynth = true; const h = start(); await playerBarrier.at(0); await synthBarrier.at(1);
    const spokenChunk = events.find((e) => e.state === "speaking" && !e.long_read?.preparing).text;
    await handleSocketCommand({ cmd: "stop", playback_elapsed_ms: 250 }); await h.done;
    expect(loadHistory()[0].text).toBe(spokenChunk);
    expect(loadHistory()[0].text).not.toBe(text);
  });

  it("R1-6 a replacement read cannot synthesize while the predecessor history job is running", async () => {
    holdSynth = true; holdHistory = true;
    const old = start(); await playerBarrier.at(0); await synthBarrier.at(1);
    stopPlayback(200); const history = await historyBarrier.at(0);
    const current = start(); await fixtureCheckpoint();
    expect(synths).toHaveLength(2);
    holdHistory = false; history.exit.resolve(0); await old.done;
    const next = await synthBarrier.at(2); next.exit.resolve(0); await playerBarrier.at(1);
    stopPlayback(100); await current.done;
  });

  it("R1-6 ordinary speak cannot synthesize while cancelled history is running", async () => {
    holdSynth = true; holdHistory = true;
    const old = start(); await playerBarrier.at(0); await synthBarrier.at(1);
    clockMs += 250;
    holdSynth = false; autoPlay = true;
    const next = speak("A new update."); const history = await historyBarrier.at(0); await fixtureCheckpoint();
    expect(synths).toHaveLength(2);
    holdHistory = false; history.exit.resolve(0); await next; await old.done;
  });

  it("R1-7 stop during amplitude preparation never starts afplay and completes as not-started", async () => {
    const actualRun = longReadRunner.runLongRead;
    const starts: Promise<boolean>[] = [];
    spies.push(spyOn(longReadRunner, "runLongRead").mockImplementation((texts, id, signal, deps, lookahead) =>
      actualRun(texts, id, signal, { ...deps, play: (...args) => {
        const playback = deps.play(...args); starts.push(playback.started); return playback;
      } }, lookahead)));
    holdSynth = true; holdDecoder = true;
    const h = start(); const decoder = await decoderBarrier.at(0);
    expect(players).toHaveLength(0);
    const stopped = handleSocketCommand({ cmd: "stop" });
    await stopped; await h.done; await fixtureCheckpoint();
    expect(await starts[0]).toBe(false);
    expect(decoder.killed).toBe(true); expect(players).toHaveLength(0);
    expect(events.some((e) => e.state === "speaking" && !e.long_read?.preparing)).toBe(false);
    expect(events.find((e) => e.type === "playback_outcome")).toMatchObject({ status: "skipped", stopped_at_ms: 0 });
    expect(loadHistory()).toHaveLength(0);
  });

  it("stop socket kills in-flight edge synthesis and player without retry or later spawns", async () => {
    holdSynth = true; const h = start(); await synthBarrier.at(1); await playerBarrier.at(0);
    expect(players[0].synthCount).toBe(2);
    // Chunk one is still held; first audio depends only on chunk zero completion.
    expect(synths[1].killed).toBe(false);
    const ack = await handleSocketCommand({ cmd: "stop", playback_elapsed_ms: 250 });
    expect(ack).toMatchObject({ outcome: "accept" }); await h.done;
    expect(synths[1].killed).toBe(true); expect(players[0].killed).toBe(true);
    expect(synths).toHaveLength(2); expect(players).toHaveLength(1);
    expect(loadHistory()).toHaveLength(1); expect(historyInputs[0]).toHaveLength(1);
  });

  for (const cmd of ["stop", "cancel"] as const) for (const guard of ["clear", "recording", "admission"] as const)
    it(`FX-2.1 ${cmd} during initial synthesis preserves idle ownership (${guard})`, async () => {
      const admission = guard === "admission" ? reserveCaptureAdmission() : undefined;
      if (guard === "admission") expect(admission).toBeDefined();
      try {
        holdSynth = true;
        // First request is held too: consume the auto-complete slot before starting.
        synths.push({ argv: [], exit: deferred<number>(), killed: false });
        const h = start(); const synth = await synthBarrier.at(0);
        expect(getPlaybackQueueDepth()).toBe(1);
        expect(events.find((event) => event.state === "speaking")).toMatchObject({
          text: "Preparing speech…", long_read: { id: h.id, preparing: true },
        });
        if (guard === "recording") spies[2].mockReturnValue("recording");
        const ack = await handleSocketCommand({ cmd }); await h.done; await awaitCurrentPlayback();
        expect(ack).toMatchObject({ outcome: "accept" }); expect(synth.killed).toBe(true);
        expect(players).toHaveLength(0); expect(loadHistory()).toHaveLength(0); expect(getPlaybackQueueDepth()).toBe(0);
        const states = events.filter((event) => event.type === "state");
        expect(states.filter((event) => event.state === "idle")).toHaveLength(guard === "clear" ? 1 : 0);
        if (guard === "clear") expect(states.at(-1)).toEqual({ type: "state", state: "idle", source: "playback" });
      } finally { admission?.release(); }
    });

  it("PLAYER0 new speakLongRead cannot stop another agent's active or queued job", async () => {
    const other = playAudioNonBlocking("foreign-current.mp3"); await playerBarrier.at(0);
    const pending = playAudioNonBlocking("foreign-pending.mp3");
    let skipped = false; void pending.exited.then(o => { skipped = o.status !== "completed"; });
    start("edge", "New long read."); await fixtureCheckpoint();
    expect(players[0].killed).toBe(false); expect(skipped).toBe(false);
    players[0].exit.resolve(0); await other.exited;
    await playerBarrier.at(1); players[1].exit.resolve(0); await pending.exited;
  });

  it("new long read preempts the old generation and stale results never restart it", async () => {
    holdSynth = true; const old = start(); await synthBarrier.at(1); await playerBarrier.at(0);
    const current = start(); await synthBarrier.at(2);
    expect(synths[1].killed).toBe(true); synths[2].exit.resolve(0);
    await playerBarrier.at(1); stopPlayback(120); await Promise.all([old.done, current.done]);
    expect(players).toHaveLength(2);
    expect(events.filter((e) => e.state === "speaking" && !e.long_read?.preparing).map((e) => e.long_read.id)).toEqual([old.id, current.id]);
  });

  it("ordinary speak preempts a long read while retaining short-speech semantics", async () => {
    holdSynth = true; const old = start(); await synthBarrier.at(1); await playerBarrier.at(0);
    holdSynth = false; await speak("A short update."); await playerBarrier.at(1);
    expect(synths[1].killed).toBe(true); stopPlayback(); await old.done;
  });

  for (const engine of ["edge", "clone", "fallback"] as const) for (const readText of ["A single sentence.", text])
    it(`REP1 restarts ${engine} ${readText === text ? "multi" : "one"}-chunk reads at global zero`, async () => {
    if (engine !== "edge") spies.push(spyOn(qwen, "synthesizeCloned").mockResolvedValue(engine === "clone" ? Buffer.from("fixture audio") : null));
    holdSynth = true; const h = start(engine === "edge" ? "edge" : "clone", readText); await playerBarrier.at(0);
    const generation = h.generation;
    clockMs += 250;
    expect(handleSocketCommand({ cmd: "replay", id: "restart" })).toMatchObject({ outcome: "accept", id: "restart" });
    await playerBarrier.at(1);
    expect(players[0].killed).toBe(true);
    expect(players[1].argv).toEqual(players[0].argv);
    expect(h.generation).toBe(generation + 1);
    expect(cancelPlayback({ id: h.id, generation })).toBe(false);
    expect(events.filter(e => e.state === "speaking" && !e.long_read?.preparing).at(-1)).toMatchObject({
      playback_offset_ms: 0, long_read: { id: h.id, chunk_index: 0, chunk_start_ms: 0 },
    });
    clockMs += 100; stopPlayback(100); await h.done;
    // HISTDUP1: the restart re-heard 0-100 ms of the 0-250 ms already heard; history keeps it once.
    expect(loadHistory()).toHaveLength(1); expect(readText.startsWith(loadHistory()[0].text)).toBe(true);
    expect(historyInputs[0]).toHaveLength(1);
  });

  it("REP1 replays the prefix after a cross-chunk seek without resynthesis", async () => {
    const h = start(); await playerBarrier.at(0); await fixtureCheckpoint();
    expect(seekPlayback(1250).outcome).toBe("accept"); await playerBarrier.at(1);
    expect(events.filter(e => e.state === "speaking").at(-1).long_read.chunk_index).toBe(1);
    const count = synths.length;
    expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("accept"); await playerBarrier.at(2);
    expect(players[2].argv).toEqual(players[0].argv); expect(synths).toHaveLength(count);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 0, long_read: { id: h.id, chunk_index: 0 } });
    stopPlayback(100); await h.done;
  });

  it("REP1 repeated clicks coalesce while reaping and preserve foreign queued work", async () => {
    holdPlayerExit = true;
    const h = start("edge", "Owned sentence."); await playerBarrier.at(0);
    const foreign = playAudioNonBlocking("foreign-pending.mp3", { text: "Foreign" });
    let settled = false; void foreign.exited.then(() => { settled = true; });
    for (let i = 0; i < 4; i++) expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("accept");
    await fixtureCheckpoint(); expect(players).toHaveLength(1); expect(settled).toBe(false);
    players[0].exit.resolve(143); await playerBarrier.at(1);
    expect(players[1].argv.at(-1)).toBe("foreign-pending.mp3"); expect(players[1].killed).toBe(false);
    players[1].exit.resolve(0); await foreign.playerExited; await playerBarrier.at(2);
    expect(players[2].argv).toEqual(players[0].argv);
    players[2].exit.resolve(0); await h.done;
    expect(players).toHaveLength(3); expect(loadHistory()).toHaveLength(1);
  });

  it("REP1 Stop wins while the old replay player has not physically exited", async () => {
    holdPlayerExit = true;
    const h = start("edge", "Owned sentence."); await playerBarrier.at(0);
    expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("accept");
    let acknowledged = false;
    const stopped = Promise.resolve(handleSocketCommand({ cmd: "stop" })).then(ack => { acknowledged = true; return ack; });
    await fixtureCheckpoint(); expect(acknowledged).toBe(false); expect(players).toHaveLength(1);
    players[0].exit.resolve(143); expect(await stopped).toMatchObject({ outcome: "accept" }); await h.done;
    expect(players).toHaveLength(1); expect(getPlaybackQueueDepth()).toBe(0);
  });

  for (const stop of [false, true]) it(`REP1 restart during amplitude preparation preserves decoder ownership; Stop=${stop}`, async () => {
    holdDecoder = true;
    const h = start("edge", "Owned sentence."); const decoder = await decoderBarrier.at(0);
    expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("accept");
    if (stop) {
      stopPlayback(); await h.done;
      expect(await h.started).toHaveProperty("error"); expect(players).toHaveLength(0);
      expect(loadHistory()).toHaveLength(0);
    } else {
      await playerBarrier.at(0);
      expect(events.filter(e => e.state === "speaking" && !e.long_read?.preparing).at(-1)).toMatchObject({
        playback_offset_ms: 0, long_read: { id: h.id, chunk_index: 0 },
      });
      stopPlayback(100); await h.done;
    }
    expect(decoder.killed).toBe(true); expect(decoders).toHaveLength(1);
    expect(getPlaybackQueueDepth()).toBe(0);
  });

  it("REP1 FX-3 replay re-arms the replacement watchdog and retires the old deadline", async () => {
    jest.useFakeTimers();
    try {
      const h = start("edge", "Owned sentence."); await playerBarrier.at(0);
      jest.advanceTimersByTime(500); clockMs += 500;
      expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("accept"); await playerBarrier.at(1);
      expect(players[0].signals).toEqual(["SIGTERM"]);
      jest.advanceTimersByTime(5500); clockMs += 5500; await fixtureCheckpoint();
      expect(players[1].signals).toEqual([]); // Original player's 6000ms deadline has passed.
      jest.advanceTimersByTime(499); clockMs += 499; await fixtureCheckpoint();
      expect(players[1].signals).toEqual([]);
      jest.advanceTimersByTime(1); clockMs += 1; await fixtureCheckpoint();
      expect(players[1].signals).toEqual(["SIGKILL"]); await h.done;
      expect(await h.completion).toMatchObject({ error: "Speech playback failed: player-error" });
      expect(events.filter(e => e.type === "error" && /watchdog/.test(e.message))).toHaveLength(1);
    } finally { jest.useRealTimers(); }
  });

  it("REP1 explicitly rejects Replay before the prefix is synthesized", async () => {
    holdSynth = true; synths.push({ argv: [], exit: deferred<number>(), killed: false });
    const h = start(); await synthBarrier.at(0);
    expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("reject");
    expect(events.some(e => e.type === "error" && /Replay prefix audio unavailable/.test(e.message))).toBe(true);
    expect(synths[1].killed).toBe(false); expect(players).toHaveLength(0);
    stopPlayback(); await h.done;
  });

  for (const missingIndex of [0, 1]) it(`REP1 reports unavailable prefix chunk ${missingIndex} and leaves its current player intact`, async () => {
    const h = start(); await playerBarrier.at(0);
    for (let i = 0; i <= missingIndex; i++) { players[i].exit.resolve(0); await playerBarrier.at(i + 1); }
    unlinkSync(players[missingIndex].argv.at(-1)!);
    const generation = h.generation;
    expect(handleSocketCommand({ cmd: "replay" }).outcome).toBe("reject"); await fixtureCheckpoint();
    expect(events.some(e => e.type === "error" && e.source === "seek" && /prefix.*unavailable/i.test(e.message))).toBe(true);
    expect(h.generation).toBe(generation);
    expect(players[missingIndex + 1].killed).toBe(false); expect(players).toHaveLength(missingIndex + 2);
    stopPlayback(100); await h.done;
  });

  it("voice_ask preempts synthesis before waiting on its prompt and recording", async () => {
    holdSynth = true; const old = start(); await synthBarrier.at(1); await playerBarrier.at(0);
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true, owner: { pid: process.pid, sessionId: "fixture", startedAt: new Date().toISOString() } }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    holdSynth = false; autoPlay = true;
    const answer = await handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
    await old.done;
    expect(answer.isError).not.toBe(true); expect(capture).toHaveBeenCalledTimes(1);
    expect(synths[1].killed).toBe(true); expect(players[0].killed).toBe(true);
    expect(players).toHaveLength(2);
  });

  it("records long-read first audio at player spawn once, including held preparation", async () => {
    recordFirstAudio("long", 9999); recordFirstAudio("short", 1234);
    const logs = spyOn(console, "error").mockImplementation(() => {}); spies.push(logs);
    holdDecoder = true; const h = start();
    const decoder = await decoderBarrier.at(0);
    expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(9999);
    clockMs += 650; holdDecoder = false; decoder.exit.resolve(0);
    await playerBarrier.at(0); await h.started;
    expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(650);
    expect(readTTSControlsStatus().profiles.short.last_first_audio_ms).toBe(1234);
    expect(readTTSControlsStatus().profiles.long.last_first_audio).toEqual({engine: "edge-tts", origin: "speak", fallback: false});
    clockMs += 400; players[0].exit.resolve(0); await playerBarrier.at(1);
    expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(650);
    expect(logs.mock.calls.filter(([line]) => String(line) === `[tts] first_audio_ms=650 profile=long engine=edge-tts voice=fixture chars=${text.length}`)).toHaveLength(1);
    stopPlayback(1200); await h.done;
  });

  it("records the actual edge engine when a long-read clone falls back", async () => {
    spies.push(spyOn(qwen, "synthesizeCloned").mockResolvedValue(null));
    autoPlay = true; await start("clone", "A sentence.").done;
    expect(readTTSControlsStatus().profiles.long.last_first_audio).toEqual({engine: "edge-tts", origin: "speak", fallback: true});
  });

  it("publishes all synthesized duration at player start after held preparation", async () => {
    holdDecoder = true; const h = start();
    const decoder = await decoderBarrier.at(0); await synthBarrier.at(1); await fixtureCheckpoint();
    holdDecoder = false; decoder.exit.resolve(0); await playerBarrier.at(0);
    expect(events.find(e => e.state === "speaking" && !e.long_read?.preparing).duration_ms).toBe(2000);
    stopPlayback(200); await h.done;
  });

  it("seeks across retained chunks through the real queue and converts global stop time", async () => {
    const h = start(); await playerBarrier.at(0);
    players[0].exit.resolve(0); await playerBarrier.at(1); await synthBarrier.at(2);
    clockMs += 200;
    expect(seekPlayback(250)).toMatchObject({ outcome: "accept", offset_ms: 250 });
    await playerBarrier.at(2);
    const back = events.filter(e => e.state === "speaking" && !e.long_read?.preparing).at(-1);
    expect(back).toMatchObject({ playback_offset_ms: 250, long_read: { chunk_index: 0 } });
    expect(back.duration_ms).toBeGreaterThanOrEqual(2000);
    expect(synths.filter(item => item.argv.includes(synths[0].argv.find(arg => arg.startsWith("--text="))!))).toHaveLength(1);
    players[2].exit.resolve(0); await playerBarrier.at(3);
    expect(events.filter(e => e.state === "speaking").at(-1)).toMatchObject({ playback_offset_ms: 1000, long_read: { chunk_index: 1 } });
    stopPlayback(1250); await h.done;
    expect(events.filter(e => e.type === "playback_outcome").at(-1).stopped_at_ms).toBe(250);
    expect(seekPlayback(0).outcome).toBe("noop"); expect(players).toHaveLength(4);
  });

  it("streams edge chunks with local subtitles, global metadata, no lost text, and one history entry", async () => {
    autoPlay = true; const h = start(); await h.done;
    const speaking = events.filter((e) => e.state === "speaking" && !e.long_read?.preparing);
    expect(speaking.length).toBeGreaterThan(1);
    expect(speaking.map((e) => e.text).join(" ")).toBe(text);
    expect(speaking.map((e) => e.long_read.chunk_start_ms)).toEqual(speaking.map((_, i) => i * 1000));
    expect(speaking.every((e) => e.long_read.id === h.id && e.long_read.chunk_count === speaking.length)).toBe(true);
    expect(events.filter((e) => e.type === "subtitle").every((e) => e.words[0].offset_ms === 0)).toBe(true);
    expect(loadHistory()).toHaveLength(1); expect(loadHistory()[0].text).toBe(text);
    expect(historyInputs[0]).toHaveLength(speaking.length);
    for (const line of historyInputs[0]) expect(existsSync(line.slice(6, -1))).toBe(false);
  });

  it("chunks the Qwen3 tier directly and supplies the same cancellable generation", async () => {
    const longText = Array.from({ length: 1000 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" ");
    const calls: string[] = [], signals: AbortSignal[] = [];
    spies.push(spyOn(qwen, "synthesizeCloned").mockImplementation(async (part, _voice, signal) => {
      calls.push(part); signals.push(signal!); return Buffer.from("clone audio");
    }));
    autoPlay = true; await start("clone", longText).done;
    expect(longText.length).toBeGreaterThan(50_000);
    expect(calls.join(" ")).toBe(longText); expect(calls.length).toBeGreaterThan(1);
    expect(new Set(signals).size).toBe(1);
    expect(readTTSControlsStatus().profiles.long.last_first_audio).toEqual({engine: "qwen3-tts", origin: "speak", fallback: false});
    expect(events.some((e) => e.type === "subtitle")).toBe(false); expect(loadHistory()).toHaveLength(1);
  });

  it("history failure warns without failing a successful playback completion", async () => {
    failHistory = true; autoPlay = true;
    const warning = spyOn(console, "error").mockImplementation(() => {}); spies.push(warning);
    const h = start("edge", "A sentence.");
    expect(await h.started).toEqual({});
    expect(await h.completion).toEqual({});
    expect(warning.mock.calls.some(([line]) => String(line).includes("Long-read history could not be saved: EBADARCH"))).toBe(true);
    expect(loadHistory()).toHaveLength(0);
  });

  it("exposes first playback and reports failed playback to CLI waiters", async () => {
    const h = start("edge", "A sentence.");
    expect(await h.started).toEqual({});
    players[0].exit.resolve(1);
    expect(await h.completion).toMatchObject({ error: "Speech playback failed: player-error" });
  });

  it("reports cancellation before playback through the start lifecycle", async () => {
    recordFirstAudio("long", 9999);
    holdSynth = true;
    synths.push({ argv: [], exit: deferred<number>(), killed: false });
    const h = start(); stopPlayback();
    expect(await h.started).toEqual({ error: "Speech stopped before playback" });
    expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(9999);
    await h.done;
  });

  it("keeps the ring bounded at twenty entries", async () => {
    autoPlay = true;
    for (let i = 0; i < 22; i++) { const h = speakLongRead(`Read ${i}.`, { engine: "edge", voice: "fixture", rate: "+0%" }); handles.push(h); await h.done; }
    expect(loadHistory()).toHaveLength(20); expect(new Set(loadHistory().map((e) => e.id)).size).toBe(20);
  });
});
