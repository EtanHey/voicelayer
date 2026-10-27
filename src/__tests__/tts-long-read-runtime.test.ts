import { speechArchiveWriter } from "../speech-archive-writer";
import * as speechReceipts from "../speak-archive";
import { beginSpeechArchive, LiveSpeechArchive, flushSpeechArchives } from "../speech-archive-live";
import { join } from "path";
import { serializeEvent } from "../socket-protocol";
import { projectStructuredSpeech } from "../tts/structured-speech";
import * as pronunciation from "../pronunciation";
import * as settings from "../tts-settings";
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
import { handleReplay, handleVoiceAsk } from "../handlers";
import { pausePlayback, isPlaybackPaused } from "../tts";
import { awaitCurrentPlayback, getHistoryEntry, getPlaybackQueueDepth, loadHistory, speak, speakLongRead, stopPlayback, seekPlayback, cancelPlayback, chunkTextForLongRead, playAudioNonBlocking, reserveCaptureAdmission } from "../tts";
import { handleSocketCommand, resetSelectionReadQueueForTests } from "../socket-handlers";
import * as tts from "../tts";
import { TTS_HISTORY_FILE } from "../paths";
import { readTTSControlsStatus, recordFirstAudio } from "../tts-controls-status";
import { fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";
import { PreparedReadStart } from "../tts/selection-read-preparation";

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
  let failPlayerSpawn = false;
  let synthLatencyMs = 0;
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
    failHistory = false; failPlayerSpawn = false; synthLatencyMs = 0;
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
        if (!holdSynth || synths.length === 1) {
          if (synthLatencyMs > 0) setTimeout(() => exit.resolve(0), synthLatencyMs); else exit.resolve(0);
        }
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
      if (failPlayerSpawn) throw new Error("player launch failed");
      const exit = deferred<number>(); const item = { exit, killed: false, synthCount: synths.length, argv, signals: [] as string[] }; players.push(item); playerBarrier.push(item);
      if (autoPlay) exit.resolve(0);
      return { pid: 73000 + players.length, exited: exit.promise, kill: (signal: string) => { item.signals.push(signal); item.killed = true; if (!holdPlayerExit) exit.resolve(143); } };
    }) as any;
  });
  afterEach(async () => {
    stopPlayback(); for (const release of releaseAlignments) release(); for (const player of players) player.exit.resolve(143); for (const child of histories) child.exit.resolve(0); for (const h of handles) await h.done; await awaitCurrentPlayback();
    await flushSpeechArchives();
    for (const spy of spies) spy.mockRestore(); Bun.spawn = originalSpawn; Bun.spawnSync = originalSpawnSync;
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
  });
  const start = (engine: "edge" | "clone" = "edge", readText = text) => { const h = speakLongRead(readText, { engine, voice: "fixture", rate: "+0%" }); handles.push(h); return h; };

  it("R1C playback wait includes audio enqueued by captured short-speech preparation", async () => {
    await speak("First fixture.", { voice: "en-US-JennyNeural" });
    await playerBarrier.at(0);
    holdSynth = true;
    const preparing = speak("Later fixture.", { voice: "en-US-JennyNeural" });
    const synthesis = await synthBarrier.at(1);
    let finished = false;
    const wait = awaitCurrentPlayback().then(() => { finished = true; });
    try {
      players[0].exit.resolve(0);
      await fixtureCheckpoint();
      synthesis.exit.resolve(0);
      await preparing;
      await playerBarrier.at(1);
      await fixtureCheckpoint();
      expect(finished).toBe(false);
    } finally {
      synthesis.exit.resolve(0);
      await preparing;
      for (const player of players) player.exit.resolve(0);
      await wait;
    }
    expect(finished).toBe(true);
  });

  for (const fault of ["playerEnded", "finish"] as const) it(`SPEECH-WIRE ${fault} archive fault still delivers completion observer`, async () => {
    const outcomes: unknown[] = [];
    spies.push(spyOn(LiveSpeechArchive.prototype, fault).mockImplementation(() => { throw Error("synthetic archive fault"); }));
    autoPlay = true;
    await speak("Callback fixture.", { voice: "en-US-JennyNeural", onPlaybackComplete: outcome => { outcomes.push(outcome); } });
    await awaitCurrentPlayback();
    expect(outcomes).toHaveLength(1);
  });

  it("SPEECH-WIRE rejected player-end and terminal writes preserve exactly one caller outcome", async () => {
    const archive = beginSpeechArchive("persistence fault callback"); await archive.settled();
    const write = speechArchiveWriter.write.bind(speechArchiveWriter), outcomes: unknown[] = [];
    const failed = spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => {
      if (args[1].kind === "end" || args[1].kind === "move" && args[1].to === "completed") throw Error("synthetic persistence failure");
      return write(...args);
    });
    autoPlay = true;
    try {
      await speak("Persistence fixture.", { archiveContext: archive.context, voice: "en-US-JennyNeural", onPlaybackComplete: outcome => { outcomes.push(outcome); } });
      await awaitCurrentPlayback(); await archive.settled();
      expect(outcomes).toHaveLength(1); expect(archive.failures.map(f => f.operation.kind)).toEqual(["end", "move"]);
    } finally { failed.mockRestore(); }
    await archive.retryFailed();
    const m = JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
    expect(m.speech.state).toBe("completed");
    expect(m.speech.transitions.filter((t: { to: string }) => t.to === "completed")).toHaveLength(1);
    expect(outcomes).toHaveLength(1);
  });

  for (const mode of ["short", "long"] as const) it(`SPEECH-WIRE ${mode} starts its first player while durable admission is held`, async () => {
    const gate = deferred<void>(), write = speechArchiveWriter.write.bind(speechArchiveWriter);
    let entered = false;
    spies.push(spyOn(speechArchiveWriter, "write").mockImplementation(async (...args) => { entered = true; await gate.promise; return write(...args); }));
    autoPlay = true;
    try {
      const work = mode === "short" ? speak("Latency fixture.", { voice: "en-US-JennyNeural" }) : start("edge", "Latency fixture.").done;
      await playerBarrier.at(0);
      expect(entered).toBe(true);
      const source = players[0].argv.at(-1)!;
      await work; await awaitCurrentPlayback();
      // Cleanup is requested after the player exits, but the writer still owns its source.
      expect(existsSync(source)).toBe(true);
      await fixtureCheckpoint(); // Controls/event loop progress while durable storage remains gated.
    } finally { gate.resolve(); await flushSpeechArchives(); }
  });

  for (const engine of ["edge", "clone"] as const) {
    it(`SPEECH-WIRE live ${engine} archive records actual generation and completion`, async () => {
      autoPlay = true;
      if (engine === "clone") spies.push(spyOn(qwen, "synthesizeCloned").mockResolvedValue(Buffer.from("clone audio")));
      const archive = beginSpeechArchive("  **Original** selection\n");
      await archive.settled();
      const h = speakLongRead("Actual generated words.", { engine, voice: "fixture", rate: "+0%" }, Date.now(), { archiveContext: archive.context });
      handles.push(h); await h.done; await flushSpeechArchives();
      const m = JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
      expect(m.speech.state).toBe("completed");
      expect(m.speech.generated[0]).toMatchObject({ text: "Actual generated words.", engine: engine === "edge" ? "edge-tts" : "qwen3-tts" });
      expect(existsSync(join(archive.context.path, m.speech.generated[0].audio_path))).toBe(true);
      expect(readFileSync(join(archive.context.path, "input.txt"), "utf8")).toBe("  **Original** selection\n");
    });
  }
  it("SPEECH-WIRE player errors persist failed rather than stopped", async () => {
    failPlayerSpawn = true;
    const archive = beginSpeechArchive("Failure fixture.");
    await archive.settled();
    const h = speakLongRead("Failure fixture.", { engine: "edge", voice: "fixture", rate: "+0%" }, Date.now(), { archiveContext: archive.context });
    handles.push(h); await h.done; await flushSpeechArchives();
    expect(JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).speech.state).toBe("failed");
  });
  it("SPEECH-WIRE Ask archives its real spoken question", async () => {
    const create = speechReceipts.createSpeakReceipt;
    let context: speechReceipts.SpeakArchiveContext | undefined;
    spies.push(spyOn(speechReceipts, "createSpeakReceipt").mockImplementation(request => {
      const receipt = create(request);
      if (receipt.kind === "created" && request.request_source === "ask_prompt") context = receipt.context;
      return receipt;
    }));
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
    spies.push(spyOn(input, "waitForInput").mockResolvedValue("fixture answer"));
    autoPlay = true;
    const answer = await handleVoiceAsk({ message: "  Durable question?  ", voice: "en-US-JennyNeural", timeout_seconds: 5 });
    expect(answer.isError).not.toBe(true);
    expect(context).toBeDefined();
    await flushSpeechArchives();
    const m = JSON.parse(readFileSync(join(context!.path, "metadata.json"), "utf8"));
    expect(m.speech).toMatchObject({ state: "completed", generated: [{ text: "Durable question?" }] });
    expect(readFileSync(join(context!.path, "input.txt"), "utf8")).toBe("  Durable question?  ");
  });
  it("SPEECH-WIRE real pause and resume persist the same output", async () => {
    const archive = beginSpeechArchive("Pause fixture.");
    await archive.settled();
    const h = speakLongRead("Pause fixture.", { engine: "edge", voice: "fixture", rate: "+0%" }, Date.now(), { archiveContext: archive.context });
    handles.push(h); await playerBarrier.at(0);
    expect(pausePlayback().outcome).toBe("accept");
    await flushSpeechArchives();
    expect(JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).speech.state).toBe("paused");
    expect(tts.resumePlayback().outcome).toBe("accept");
    await playerBarrier.at(1); players[1].exit.resolve(0); await h.done; await flushSpeechArchives();
    expect(JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).speech.transitions.map((t: { to: string }) => t.to))
      .toEqual(["preparing", "playing", "paused", "playing", "completed"]);
  });
  it("SPEECH-PACING prepares the next waveform while current audio plays", async () => {
    holdDecoder = true;
    const h = start("edge", "First short sentence. " + "More words for the next sentence. ".repeat(5));
    await decoderBarrier.at(0);
    decoders[0].exit.resolve(0);
    await playerBarrier.at(0);
    await synthBarrier.at(1);
    await fixtureCheckpoint();
    expect(decoders.length).toBe(2);
    // Inject 700 ms of preparation inside a 1000 ms playing chunk.
    clockMs += 700;
    decoders[1].exit.resolve(0);
    await fixtureCheckpoint();
    clockMs += 300;
    const previousAudioEnded = clockMs;
    players[0].exit.resolve(0);
    await playerBarrier.at(1);
    expect(clockMs - previousAudioEnded).toBe(0);
    expect(decoders.length).toBe(2); // No decode starts at the join.
    players[1].exit.resolve(0);
    await h.done;
  });

  it("SPEECH-PACING dismisses before slow History persistence", async () => {
    holdHistory = true;
    const h = start("edge", "Finished now.");
    await playerBarrier.at(0);
    clockMs += 1000;
    players[0].exit.resolve(0);
    await historyBarrier.at(0);
    expect(events.some(e => e.type === "state" && e.state === "idle" && e.source === "playback")).toBe(true);
    clockMs += 6500; // Persistence is still blocked long after the idle event.
    histories[0].exit.resolve(0);
    await h.done;
  });

  it("SPEECH-PACING final audio dismisses while clone alignment is still reaping", async () => {
    const fixture = cloneFixture();
    const h = start("clone", "Finished clone.");
    await playerBarrier.at(0);
    await fixture.entered.at(0);
    clockMs += 1000;
    players[0].exit.resolve(0);
    await fixtureCheckpoint();
    expect(events.some(e => e.type === "state" && e.state === "idle" && e.source === "playback")).toBe(true);
    expect(getPlaybackQueueDepth()).toBeGreaterThan(0); // Capture safety still waits for the child.
    for (const release of releaseAlignments) release();
    await h.done;
  });

  it("SPEECH-PACING measures clone startup separately from waveform preparation", async () => {
    const parts: string[] = [];
    spies.push(spyOn(qwen, "synthesizeCloned").mockImplementation(async part => {
      if (!parts.length) clockMs += 900; // Injected engine time, not a hardware benchmark.
      parts.push(part);
      return Buffer.from("clone audio");
    }));
    holdDecoder = true;
    const h = start("clone", "First sentence. " + "The rest of this read is synthesized in the background. ".repeat(8));
    await decoderBarrier.at(0);
    expect(parts[0]).toBe(chunkTextForLongRead("First sentence. " + "The rest of this read is synthesized in the background. ".repeat(8))[0]);
    clockMs += 300;
    holdDecoder = false;
    for (const child of decoders) child.exit.resolve(0);
    await playerBarrier.at(0);
    expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(1200);
    autoPlay = true;
    players[0].exit.resolve(0);
    await h.done;
  });

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
    ], duration_ms: 1000 });
    // WORDTIME1: the finished read's history entry keeps the timings replay will re-broadcast.
    players[0].exit.resolve(0);
    if (route === "long") await handles[0].done; else await awaitCurrentPlayback();
    // A long read persists the timeline it showed: the null token gets its in-chunk estimate (WORDTIME1 S3).
    expect(getHistoryEntry(0)?.alignedWords).toEqual(route === "speak" ? (await published.at(0)).aligned_words : [
      { word_index: 0, text: "Export", offset_ms: 0, duration_ms: 80 },
      { word_index: 1, text: "MP3", offset_ms: 80, duration_ms: 120, estimated: true },
      { word_index: 2, text: "now.", offset_ms: 200, duration_ms: 80 },
    ]);
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
    expect(qwen.synthesizeCloned).toHaveBeenCalledTimes(3);
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
    history.exit.resolve(0); await ack; await h.done; await flushSpeechArchives();
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

  it("HISTDUP1 stopped history keeps the whole text and names chunks with no audio", async () => {
    holdSynth = true; const h = start(); await playerBarrier.at(0); await synthBarrier.at(1);
    await handleSocketCommand({ cmd: "stop", playback_elapsed_ms: 250 }); await h.done;
    const [entry] = loadHistory(), count = events.find((e) => e.state === "speaking" && !e.long_read?.preparing).long_read.chunk_count;
    expect(entry.text).toBe(text);
    // Chunk 0 played; chunk 1 was killed mid-synthesis; the rest never started.
    expect(historyInputs[0]).toHaveLength(1);
    expect(entry.audioMissingChunks).toEqual(Array.from({ length: count - 1 }, (_, i) => i + 1));
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

  it("TELE1 Preparing carries the whole display document and each chunk's first token, once", async () => {
    const paragraphs = Array.from({ length: 12 }, (_, i) => `Paragraph ${i} keeps its own break and enough words to fill a chunk.`).join("\n\n");
    const h = start("edge", paragraphs); await fixtureCheckpoint();
    const preparing = events.find((event) => event.state === "speaking" && event.long_read?.preparing);
    const texts = chunkTextForLongRead(paragraphs);
    expect(texts.length).toBeGreaterThan(1);
    expect(preparing.long_read).toMatchObject({ id: h.id, chunk_count: texts.length, text: paragraphs });
    let words = 0;
    expect(preparing.long_read.chunk_word_starts).toEqual(texts.map((chunk) => { const at = words; words += chunk.split(/\s+/).length; return at; }));
    await playerBarrier.at(0);
    const played = events.find((event) => event.state === "speaking" && !event.long_read?.preparing);
    expect(played.text).toBe(texts[0]); // synthesis chunking and per-chunk text are unchanged
    expect(played.long_read.text).toBeUndefined();
  });

  it("P14b structured reads attach layout to every player receipt and to retained replay", async () => {
    // PROSODY v2 (b): this test used to pin "legacy synthesis/chunks" (one request "two. Alpha. 3. Beta.").
    // A numbered list is now planned utterances: each spoken number is its own request followed by the
    // 250 ms number pause (N1), so the list is two chunks of four requests. Layout, subtitles and replay
    // guarantees are unchanged and still asserted below.
    autoPlay = true;
    const structuredDisplay = projectStructuredSpeech("2. Alpha.\n3. Beta.");
    const h = speakLongRead(structuredDisplay.speechText, { engine: "edge", voice: "fixture", rate: "+0%" },
      Date.now(), { request_id: "structured-read", structuredDisplay });
    handles.push(h); await h.done; await flushSpeechArchives();
    const played = events.filter(event => event.state === "speaking" && !event.long_read?.preparing);
    expect(played.map(event => event.text)).toEqual(["2.", "Alpha. 3. Beta."]);
    const preparing = events.find(event => event.long_read?.preparing);
    expect(preparing.long_read.display.text).toBe(structuredDisplay.speechText);
    expect(JSON.parse(serializeEvent(preparing)).long_read.display).toEqual(preparing.long_read.display);
    expect(preparing.long_read.display.blocks.map((block: { marker: string }) => block.marker)).toEqual([undefined, undefined]);
    for (const event of played) expect(event.long_read.display.text).toBe(event.text);
    // Each receipt carries its own slice of the list blocks, not an empty or whole-document layout.
    expect(played.map(event => event.long_read.display.blocks.map((block: { kind: string; word_start: number; word_end: number; starts_block: boolean }) =>
      [block.kind, block.word_start, block.word_end, block.starts_block]))).toEqual([
      [["list-item", 0, 1, true]],
      [["list-item", 0, 1, false], ["list-item", 1, 3, true]],
    ]);
    expect(synths.map(synth => synth.argv.find(arg => arg.startsWith("--text=")))).toEqual(["--text=two.", "--text=Alpha.", "--text=3.", "--text=Beta."]);
    expect(events.filter(event => event.type === "subtitle").flatMap(event => event.words.map((word: { text: string }) => word.text)))
      .toEqual(["2.", "Alpha.", "3.", "Beta."]);
    expect(played.every(event => event.request_id === "structured-read")).toBe(true);
    const before = events.length;
    expect(seekPlayback(0, "readback", played[0].readback_id)).toMatchObject({ outcome: "accept" });
    await awaitCurrentPlayback();
    const replayed = events.slice(before).filter(event => event.state === "speaking" && !event.long_read?.preparing);
    expect(replayed.length).toBeGreaterThan(0);
    expect(replayed[0]).not.toBe(played[0]);
    expect(replayed[0].long_read.display).toEqual(played[0].long_read.display);
    expect(replayed[0].text).toBe(played[0].text);
  });

  for (const route of ["socket", "mcp"] as const)
  for (const engine of ["edge", "clone"] as const) it(`S3 F4 ${route} ${engine}: completed Replay preserves the original structured document`, async () => {
    autoPlay = true;
    if (engine === "clone") cloneFixture();
    const structuredDisplay = projectStructuredSpeech("## Release notes\n\n**Fixed:** שלום client/server.\n\n" +
      Array.from({ length: 45 }, (_, i) => `${i + 1}. Item ${i} keeps its formatting after completion.`).join("\n") +
      "\n\n```ts\nconst answer = 42;\n```");
    const h = speakLongRead(structuredDisplay.speechText, { engine, voice: "fixture", rate: "+0%" },
      Date.now(), { structuredDisplay });
    handles.push(h);
    await h.done;
    await awaitCurrentPlayback();
    const original = events.find(event => event.long_read?.preparing).long_read.display;
    const entry = getHistoryEntry();
    expect(entry?.text.length).toBeGreaterThan(2000);
    expect(entry).toMatchObject({ text: original.text, display: original });
    expect(entry?.audioMissingChunks).toBeUndefined();
    const before = events.length;
    if (route === "socket") expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "accept" });
    else expect((await handleReplay({ index: 0 })).isError).not.toBe(true);
    await awaitCurrentPlayback();
    const replayed = events.slice(before).find(event => event.state === "speaking");
    expect(replayed).toBeDefined();
    const wire = JSON.parse(serializeEvent(replayed));
    expect(wire.text).toBe(original.text);
    expect(wire.display).toEqual(original);
    expect(wire.long_read).toBeUndefined();
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
    const finishes = spyOn(LiveSpeechArchive.prototype, "finish"); spies.push(finishes);
    holdSynth = true; const old = start(); await synthBarrier.at(1); await playerBarrier.at(0);
    const current = start(); await synthBarrier.at(2);
    expect(finishes).toHaveBeenCalledWith("stopped", "REPLACED");
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
    // HISTDUP1: the restart re-heard chunk 0; history holds the whole text once and each
    // synthesized chunk once (clone may have chunk 1 ready; edge's is still held).
    expect(loadHistory()).toHaveLength(1); expect(loadHistory()[0].text).toBe(readText);
    expect(new Set(historyInputs[0]).size).toBe(historyInputs[0].length);
    expect(historyInputs[0].length).toBeGreaterThanOrEqual(1);
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
    await decoderBarrier.at(0);
    expect(readTTSControlsStatus().profiles.long.last_first_audio_ms).toBe(9999);
    clockMs += 650; holdDecoder = false; for (const child of decoders) child.exit.resolve(0);
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
    await flushSpeechArchives();
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
    for (let i = 0; i < 22; i++) { const h = speakLongRead(`Read ${i}.`, { engine: "edge", voice: "fixture", rate: "+0%" }); handles.push(h); await h.done; await flushSpeechArchives(); }
    expect(loadHistory()).toHaveLength(20); expect(new Set(loadHistory().map((e) => e.id)).size).toBe(20);
  });
  // P16b (Sol R2-2 probe, verbatim intent): F5's capture Stop/Cancel over a parked long read acknowledges at once.
  // The wait watchdog is compressed to 25 ms so a wait on the parked read fails fast instead of at 35 s.
  for (const cmd of ["stop", "cancel"] as const) it(`P16b parked long read: capture ${cmd} acknowledges without waiting for the park`, async () => {
    holdSynth = true;
    start(); await playerBarrier.at(0); await synthBarrier.at(1);
    clockMs += 250;
    expect(pausePlayback()).toMatchObject({ outcome: "accept" });
    await fixtureCheckpoint();
    const capture = spyOn(input, "getRecordingState").mockReturnValue("recording");
    const realTimer = globalThis.setTimeout;
    const timer = spyOn(globalThis, "setTimeout").mockImplementation(((fn: any, ms: number, ...args: any[]) =>
      realTimer(fn, ms === 35000 ? 25 : ms, ...args)) as any);
    try {
      expect(await handleSocketCommand({ cmd, id: `capture-${cmd}` })).toMatchObject({ command: cmd, outcome: "accept" });
      expect(isPlaybackPaused()).toBe(true);
    } finally { timer.mockRestore(); capture.mockRestore(); }
  });

  describe("QUEUE1 Option+F5 read queue on the real runner", () => {
    const hash = "c".repeat(64);
    // The real VoiceBar wire: A starts from idle without a queue flag; later different selections carry it.
    const select = (id: string, words: string) => handleSocketCommand({ cmd: "speak_text", id, text: words, text_hash: hash, profile: "short", source: "selection", ...(id === "A" ? {} : { queue: true }) } as any);
    const lastQueue = () => events.filter(e => e.type === "read_queue").at(-1);
    const receipts = (id: string) => events.filter(e => e.type === "state" && e.state === "speaking" && e.request_id === id);
    const settle = async () => { for (let i = 0; i < 20; i++) await fixtureCheckpoint(); await flushSpeechArchives(); };
    afterEach(() => resetSelectionReadQueueForTests());

    describe("QPRE1 prepares the next read's first chunk in the background", () => {
      const cloneProfile = { name: "fixture", engine: "qwen3-tts", model_path: "", reference_clips: [],
        reference_clip: "", fallback: "jenny", created: "" };
      it("S2 leaves prepared audio held until a predecessor finishes settling", async () => {
        select("A", "Alpha single chunk."); await playerBarrier.at(0);
        spies.push(spyOn(settings, "resolveSpeakProfile").mockReturnValue({
          kind: "short", engine: "clone", voice: "fixture", rate: "+0%",
          engineSource: "settings", rateSource: "settings",
        }), spyOn(qwen, "loadProfile").mockReturnValue(cloneProfile),
        spyOn(qwen, "synthesizeCloned").mockResolvedValue(Buffer.from("clone audio")));
        const prepare = tts.prepareSelectionReadStart, ready = deferred<void>();
        spies.push(spyOn(tts, "prepareSelectionReadStart").mockImplementation(async (...args) => {
          const prepared = await prepare(...args); ready.resolve(); return prepared;
        }));
        select("B", "## Bravo heading\n\n1. Read the next item."); await ready.promise; await settle();
        const take = spyOn(PreparedReadStart.prototype, "take"); spies.push(take);
        holdPlayerExit = true;
        try {
          expect(handleSocketCommand({ cmd: "read_next", request_id: "A" })).toMatchObject({ outcome: "accept" });
          await settle();
          expect(players[0].killed).toBe(true);
          expect(take).not.toHaveBeenCalled();
          expect(players).toHaveLength(1);
        } finally {
          stopPlayback(); holdPlayerExit = false; players[0].exit.resolve(143); await awaitCurrentPlayback();
        }
      });
      for (const playing of [false, true]) for (const command of ["stop", "read_next"] as const)
      it(`S2 ${command} aborts clone prefetch while ${playing ? "playing" : "preparing"}`, async () => {
        const heading = playing ? "Choose the complete release verification record and read every saved result before deciding whether this implementation is ready for review" : "Choose";
        spies.push(spyOn(settings, "resolveSpeakProfile").mockReturnValue({
          kind: "short", engine: "clone", voice: "fixture", rate: "+0%",
          engineSource: "settings", rateSource: "settings",
        }), spyOn(qwen, "loadProfile").mockReturnValue(cloneProfile));
        let running = 0, maximum = 0;
        const pending = deferred<void>();
        const clone = spyOn(qwen, "synthesizeCloned").mockImplementation(async (text, _voice, signal) => {
          maximum = Math.max(maximum, ++running);
          try {
            if (text === `${heading}.` || text.startsWith("Bravo")) return Buffer.from("clone audio");
            pending.resolve();
            await new Promise<void>(resolve => {
              if (signal?.aborted) resolve(); else signal?.addEventListener("abort", () => resolve(), { once: true });
            });
            return null;
          } finally { running--; }
        }); spies.push(clone);
        select("A", `## ${heading}\n- Red apple\n- Green pear\n- Blue sky`);
        await pending.promise;
        if (playing) await playerBarrier.at(0);
        else expect(players).toHaveLength(0);
        select("B", "Bravo queued read.");
        const result = await handleSocketCommand({ cmd: command, request_id: "A" });
        expect(result).toMatchObject({ outcome: "accept" });
        if (command === "read_next") await playerBarrier.at(playing ? 1 : 0);
        else await settle();
        expect(maximum).toBe(1);
        expect(clone.mock.calls.map(call => call[0])).toEqual([`${heading}.`, "Red apple.",
          ...(command === "read_next" ? ["Bravo queued read."] : [])]);
        expect(clone.mock.calls[1][2]?.aborted).toBe(true);
        await handleSocketCommand({ cmd: "stop" });
      });

      it("S1 queued structured clone reads reuse one prepared request and start gapless", async () => {
        select("A", "Alpha single chunk.");
        await playerBarrier.at(0);
        spies.push(spyOn(settings, "resolveSpeakProfile").mockReturnValue({
          kind: "short", engine: "clone", voice: "fixture", rate: "+0%",
          engineSource: "settings", rateSource: "settings",
        }));
        spies.push(spyOn(qwen, "loadProfile").mockReturnValue(cloneProfile));
        const clone = spyOn(qwen, "synthesizeCloned").mockImplementation(async (_text, _voice, signal) => {
          await new Promise<void>(resolve => {
            const timer = setTimeout(resolve, 150);
            signal?.addEventListener("abort", () => { clearTimeout(timer); resolve(); }, { once: true });
          });
          return signal?.aborted ? null : Buffer.from("clone audio");
        });
        const prepare = tts.prepareSelectionReadStart;
        const ready = deferred<void>();
        spies.push(clone, spyOn(tts, "prepareSelectionReadStart").mockImplementation(async (...args) => {
          const result = await prepare(...args);
          ready.resolve();
          return result;
        }));
        select("B", "## Bravo heading\n\n1. Read the next item.");
        await ready.promise; await settle();
        expect(clone.mock.calls.map(call => call[0])).toEqual(["Bravo heading."]);
        const before = performance.now();
        players[0].exit.resolve(0);
        await playerBarrier.at(1);
        expect(performance.now() - before).toBeLessThan(50);
        expect(clone.mock.calls.filter(call => call[0] === "Bravo heading.")).toHaveLength(1);
        expect(players[1].argv.at(-1)).toContain(".mp3");
        await handleSocketCommand({ cmd: "stop" });
      });

      it("SEAT-A pronunciation changes during preparation must reject stale audio", async () => {
        let rules = [{ pattern: /\bBravo\b/gi, replacement: "oldword" }];
        spies.push(spyOn(pronunciation, "pronunciationRules").mockImplementation(() => rules));
        select("A", "Alpha single chunk.");
        await playerBarrier.at(0);
        holdSynth = true;
        select("B", "Bravo queued selection.");
        const prep = await synthBarrier.at(1);
        expect(prep.argv).toContain("--text=oldword queued selection.");
        rules = [{ pattern: /\bBravo\b/gi, replacement: "newword" }];
        prep.exit.resolve(0);
        await settle();
        holdSynth = false;
        handleSocketCommand({ cmd: "read_next", request_id: "A" } as any);
        await playerBarrier.at(1);
        expect(synths).toHaveLength(3);
        expect(synths[2].argv).toContain("--text=newword queued selection.");
        expect(existsSync(media(prep))).toBe(false);
        expect(existsSync(media(prep).replace(".mp3", ".meta.ndjson"))).toBe(false);
        expect(players[1].argv).not.toContain(media(prep));
      });

      for (const changedDuring of ["clone", "edge"] as const) it(`pronunciation changes during clone→Edge preparation (${changedDuring}) reject stale audio`, async () => {
        let rules = [{ pattern: /\bBravo\b/gi, replacement: "oldword" }];
        spies.push(spyOn(pronunciation, "pronunciationRules").mockImplementation(() => rules));
        select("A", "Alpha single chunk.");
        await playerBarrier.at(0);
        spies.push(spyOn(settings, "resolveSpeakProfile").mockReturnValue({
          kind: "short", engine: "clone", voice: "fixture", rate: "+0%",
          engineSource: "settings", rateSource: "settings",
        }));
        spies.push(spyOn(qwen, "loadProfile").mockReturnValue({
          engine: "qwen3-tts", reference_clips: [], reference_clip: "", fallback: "jenny",
        } as any));
        const cloneEntered = fixtureBarrier<string>();
        const cloneExit = deferred<Buffer | null>();
        let cloneCalls = 0;
        spies.push(spyOn(qwen, "synthesizeCloned").mockImplementation(part => {
          cloneEntered.push(part);
          return ++cloneCalls === 1 ? cloneExit.promise : Promise.resolve(null);
        }));
        holdSynth = true;
        select("B", "Bravo queued selection.");
        expect(await cloneEntered.at(0)).toBe("oldword queued selection.");
        if (changedDuring === "clone") rules = [{ pattern: /\bBravo\b/gi, replacement: "newword" }];
        cloneExit.resolve(null);
        const prep = await synthBarrier.at(1);
        expect(prep.argv).toContain("--text=oldword queued selection.");
        rules = [{ pattern: /\bBravo\b/gi, replacement: "newword" }];
        prep.exit.resolve(0);
        await settle();
        holdSynth = false;
        handleSocketCommand({ cmd: "read_next", request_id: "A" } as any);
        await playerBarrier.at(1);
        expect(await cloneEntered.at(1)).toBe("newword queued selection.");
        expect(synths).toHaveLength(3);
        expect(synths[2].argv).toContain("--text=newword queued selection.");
        expect(existsSync(media(prep))).toBe(false);
        expect(existsSync(media(prep).replace(".mp3", ".meta.ndjson"))).toBe(false);
        expect(players[1].argv).not.toContain(media(prep));
      });

      const spoken = (needle: string) => synths.filter((s) => s.argv.some((a) => a.startsWith("--text=") && a.includes(needle)));
      const media = (s: typeof synths[number]) => s.argv.find((a) => a.startsWith("--write-media="))!.slice("--write-media=".length);
      const twoChunks = Array.from({ length: 9 }, (_, i) => `Alpha sentence ${i} has enough words to fill a chunk.`).join(" ");

      it("never prepares while A still has chunks to synthesize; then only B's first chunk, never C", async () => {
        expect(chunkTextForLongRead(twoChunks)).toHaveLength(3);
        holdSynth = true;
        select("A", twoChunks);
        await playerBarrier.at(0);
        await synthBarrier.at(1); // A's second chunk, held in synthesis.
        select("B", "Bravo queued selection."); select("C", "Charlie queued selection.");
        await settle();
        expect(spoken("Bravo")).toHaveLength(0);
        synths[1].exit.resolve(0);
        await fixtureCheckpoint();
        expect(spoken("Bravo")).toHaveLength(0);
        players[0].exit.resolve(0);
        await synthBarrier.at(2); // Third and final chunk.
        synths[2].exit.resolve(0);
        await synthBarrier.at(3);
        expect(spoken("Bravo")).toHaveLength(1);
        expect(spoken("Charlie")).toHaveLength(0);
        expect(players).toHaveLength(2);
        expect(receipts("B")).toEqual([]);
        expect(lastQueue()).toEqual({ type: "read_queue", count: 2, current_request_id: "A" });
      });

      /** One A→B advance; returns A's end to B's player spawn, and syntheses after A ended. */
      async function advance(first: string, second: string) {
        const p = players.length, s = synths.length;
        select(first, `${first} opening selection.`);
        await playerBarrier.at(p);
        select(second, `${second} queued selection.`);
        await settle();
        const prefetch = synths[s + 1];
        if (prefetch) { await prefetch.exit.promise; await settle(); }
        const before = synths.length, t0 = performance.now();
        players[p].exit.resolve(0);
        await playerBarrier.at(p + 1);
        const ms = performance.now() - t0;
        expect(receipts(second).length).toBeGreaterThan(0);
        return { ms, resynthesized: synths.length - before, prefetch, player: players[p + 1] };
      }

      it("consumes the prepared chunk without resynthesis: B's first audio after A ends is ≈0 vs the synth latency", async () => {
        synthLatencyMs = 150;
        const off = spyOn(tts, "prepareSelectionReadStart").mockRejectedValue(new Error("prefetch off"));
        const without = await advance("A", "B");
        off.mockRestore();
        players.at(-1)!.exit.resolve(0); await settle();
        const withPrefetch = await advance("D", "E");
        console.error(`[QPRE1 measure] synth latency ${synthLatencyMs} ms; A end -> B player spawn: `
          + `${withPrefetch.ms.toFixed(1)} ms with prefetch, ${without.ms.toFixed(1)} ms without`);
        expect(without.prefetch).toBeUndefined();
        expect(without.resynthesized).toBe(1);
        expect(withPrefetch.resynthesized).toBe(0);
        expect(withPrefetch.player.argv.join(" ")).toContain(media(withPrefetch.prefetch!));
        expect(without.ms).toBeGreaterThanOrEqual(synthLatencyMs * 0.9);
        expect(withPrefetch.ms).toBeLessThan(synthLatencyMs / 3);
      });

      for (const ready of [false, true]) it(`Stop ${ready ? "after B's chunk is ready" : "while it is synthesizing"} deletes the prepared audio; B never plays or reaches history`, async () => {
        select("A", "Alpha single chunk.");
        await playerBarrier.at(0);
        holdSynth = !ready;
        select("B", "Bravo stopped before its turn.");
        const prefetch = await synthBarrier.at(1);
        if (ready) { await prefetch.exit.promise; await settle(); }
        const file = media(prefetch);
        await handleSocketCommand({ cmd: "stop" } as any);
        await settle();
        expect(prefetch.killed).toBe(!ready);
        expect(existsSync(file)).toBe(false);
        expect(receipts("B")).toEqual([]);
        expect(players).toHaveLength(1);
        expect(loadHistory().map((e) => e.text).join(" ")).not.toContain("Bravo");
      });

      it("a failed prefetch is not retried in the background; B synthesizes normally when A ends", async () => {
        select("A", "Alpha single chunk.");
        await playerBarrier.at(0);
        holdSynth = true;
        select("B", "Bravo prefetch fails.");
        (await synthBarrier.at(1)).exit.resolve(1);
        await settle();
        expect(spoken("Bravo")).toHaveLength(1);
        holdSynth = false;
        players[0].exit.resolve(0);
        await playerBarrier.at(1);
        expect(spoken("Bravo")).toHaveLength(2);
        expect(receipts("B").length).toBeGreaterThan(0);
      });
    });

    it("auto-advances at the natural end with no idle edge between reads, and records only reads that played", async () => {
      expect(select("A", "Alpha first selection.")).toMatchObject({ outcome: "accept" });
      await playerBarrier.at(0);
      expect(select("B", "Bravo second selection.")).toMatchObject({ outcome: "accept", reason: "queued" });
      expect(select("C", "Charlie third selection.")).toMatchObject({ outcome: "accept", reason: "queued" });
      expect(receipts("B")).toEqual([]);
      const beforeEnd = events.length;
      players[0].exit.resolve(0);
      await playerBarrier.at(1);
      const between = events.slice(beforeEnd);
      const firstB = between.findIndex(e => e.type === "state" && e.request_id === "B");
      expect(firstB).toBeGreaterThanOrEqual(0);
      expect(between.slice(0, firstB).some(e => e.type === "state" && e.state === "idle")).toBe(false);
      expect(events.filter(e => e.type === "read_queue").at(-1)).toEqual({ type: "read_queue", count: 1, current_request_id: "B" });
      // Stop clears the whole queue: Charlie never starts and never reaches history.
      await handleSocketCommand({ cmd: "stop" } as any);
      await settle();
      expect(receipts("C")).toEqual([]);
      expect(events.filter(e => e.type === "read_queue").at(-1)).toEqual({ type: "read_queue", count: 0, current_request_id: null });
      const texts = loadHistory().map(e => e.text).join(" | ");
      expect(texts).toContain("Alpha");
      expect(texts).not.toContain("Charlie");
    });

    it("a paused read stays paused when a new selection queues; Next replaces the park with the queued read", async () => {
      select("A", "Alpha paused selection.");
      await playerBarrier.at(0);
      expect(handleSocketCommand({ cmd: "pause" } as any)).toMatchObject({ outcome: "accept" });
      expect(select("B", "Bravo while paused.")).toMatchObject({ outcome: "accept", reason: "queued" });
      await settle();
      expect(receipts("B")).toEqual([]);
      expect(tts.isPlaybackPaused()).toBe(true);
      expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
      await playerBarrier.at(1);
      expect(receipts("B").length).toBeGreaterThan(0);
      expect(tts.isPlaybackPaused()).toBe(false);
    });

    it("SPEECH-WIRE terminal archive fault cannot strand the queued successor", async () => {
      const finish = LiveSpeechArchive.prototype.finish;
      let injected = false;
      spies.push(spyOn(LiveSpeechArchive.prototype, "finish").mockImplementation(function(this: LiveSpeechArchive, ...args: Parameters<typeof finish>) {
        if (!injected && args[0] === "completed") { injected = true; throw Error("synthetic terminal persistence failure"); }
        return finish.apply(this, args);
      }));
      select("A", "Alpha completes despite archive failure."); await playerBarrier.at(0);
      select("B", "Bravo must advance."); players[0].exit.resolve(0);
      await settle(); await settle();
      expect(injected).toBe(true);
      expect(receipts("B").length).toBeGreaterThan(0);
      expect(players.length).toBeGreaterThan(1);
    });

    it("SOL-2: a non-zero player exit settles as failed: queued B and C never start", async () => {
      select("A", "Alpha fails to play.");
      await playerBarrier.at(0);
      select("B", "Bravo must not start."); select("C", "Charlie must not start.");
      players[0].exit.resolve(1);
      await settle();
      expect(receipts("B")).toEqual([]);
      expect(players).toHaveLength(1);
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
    });

    it("SOL-2: a player launch failure settles as failed: queued B and C never start", async () => {
      select("A", "Alpha cannot launch.");
      await synthBarrier.at(0);
      select("B", "Bravo must not start."); select("C", "Charlie must not start.");
      failPlayerSpawn = true;
      await settle(); await settle();
      expect(receipts("B")).toEqual([]);
      expect(players).toHaveLength(0);
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
    });

    it("D2: F5 over the playing read stops it; after the capture nothing plays, count 2, and Next starts B", async () => {
      select("A", "Alpha interrupted by dictation.");
      await playerBarrier.at(0);
      select("B", "Bravo waits for Next."); select("C", "Charlie waits too.");
      await handleSocketCommand({ cmd: "stop", retain_read_queue: true } as any);
      await settle();
      expect(events.some(e => e.type === "state" && e.state === "idle")).toBe(true);
      expect(receipts("B")).toEqual([]);
      expect(players).toHaveLength(1);
      expect(lastQueue()).toEqual({ type: "read_queue", count: 2, current_request_id: "A" });
      expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
      await playerBarrier.at(1);
      expect(receipts("B").length).toBeGreaterThan(0);
      expect(receipts("C")).toEqual([]);
      expect(lastQueue()).toEqual({ type: "read_queue", count: 1, current_request_id: "B" });
    });

    it("capture Cancel preserves a prefetched queued archive through completed playback", async () => {
      const create = speechReceipts.createSpeakReceipt;
      let queued: speechReceipts.SpeakArchiveContext | undefined;
      spies.push(spyOn(speechReceipts, "createSpeakReceipt").mockImplementation(request => {
        const result = create(request);
        if (request.input === "Bravo prefetched archive.") {
          if (result.kind !== "created") throw Error(result.code);
          queued = result.context;
        }
        return result;
      }));
      select("A", "Alpha active read."); await playerBarrier.at(0);
      select("B", "Bravo prefetched archive."); await synthBarrier.at(1); await settle();
      expect(queued).toBeDefined();
      const disk = () => JSON.parse(readFileSync(join(queued!.path, "metadata.json"), "utf8"));
      expect(disk().speech.state).toBe("preparing");
      await handleSocketCommand({ cmd: "stop", retain_read_queue: true } as any); await settle();
      const capture = startCapture();
      expect(await handleSocketCommand({ cmd: "cancel" })).toMatchObject({ outcome: "accept" });
      capture.state.mockReturnValue("idle"); capture.done.resolve(""); await settle();
      expect(disk().speech.state).toBe("preparing");
      expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
      await playerBarrier.at(1); players[1].exit.resolve(0);
      await awaitCurrentPlayback(); await flushSpeechArchives();
      expect(disk().speech.state).toBe("completed");
    });

    // QUEUE1b: a queue F5 retained (suspended) survives the capture, and dies on agent speech or Ask.
    async function suspendedBehindA() {
      select("A", "Alpha interrupted by dictation.");
      await playerBarrier.at(0);
      select("B", "Bravo waits for Next."); select("C", "Charlie waits too.");
      await handleSocketCommand({ cmd: "stop", retain_read_queue: true } as any);
      await settle();
      expect(lastQueue()).toEqual({ type: "read_queue", count: 2, current_request_id: "A" });
    }
    /** The real record command; only the recorder child is stubbed, so the capture state is the daemon's own. */
    function startCapture() {
      spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
      const done = deferred<string>();
      spies.push(spyOn(input, "waitForInput").mockImplementation(() => done.promise));
      expect(handleSocketCommand({ cmd: "record", id: "rec", press_to_talk: true } as any)).toMatchObject({ outcome: "accept" });
      const state = spyOn(input, "getRecordingState").mockReturnValue("recording"); spies.push(state);
      return { done, state };
    }
    async function expectNextStartsB() {
      expect(receipts("B")).toEqual([]);
      expect(players).toHaveLength(1);
      expect(lastQueue()).toEqual({ type: "read_queue", count: 2, current_request_id: "A" });
      expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "accept" });
      await playerBarrier.at(1);
      expect(receipts("B").length).toBeGreaterThan(0);
    }

    for (const end of ["release", "cancel"] as const) it(`QUEUE1b SOL-R2-1: the capture's ${end} keeps the retained queue; Next(A) starts B`, async () => {
      await suspendedBehindA();
      const capture = startCapture();
      const ack = await handleSocketCommand((end === "release" ? { cmd: "stop", physical_press: true } : { cmd: "cancel" }) as any);
      expect(ack).toMatchObject({ outcome: "accept" });
      capture.state.mockReturnValue("idle"); capture.done.resolve(""); await settle();
      await expectNextStartsB();
    });

    it("QUEUE1b: a VAD or timeout end of the capture keeps the retained queue", async () => {
      await suspendedBehindA();
      const capture = startCapture();
      capture.state.mockReturnValue("idle"); capture.done.resolve("dictated words"); await settle();
      await expectNextStartsB();
    });

    it("QUEUE1b Q1B-SOL-1: Hide during the capture discards the retained queue; Next(A) is stale and a fresh D never runs into B", async () => {
      await suspendedBehindA();
      const capture = startCapture();
      expect(await handleSocketCommand({ cmd: "cancel", discard_read_queue: true } as any)).toMatchObject({ outcome: "accept" });
      capture.state.mockReturnValue("idle"); capture.done.resolve(""); await settle();
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
      expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
      autoPlay = true;
      select("D", "Delta after unhiding.");
      await settle(); await settle();
      expect(receipts("D").length).toBeGreaterThan(0);
      expect(receipts("B")).toEqual([]);
    });

    it("QUEUE1c: an idle Cancel (no capture) ends the retained chain; Next(A) is stale and a fresh D never runs into B", async () => {
      await suspendedBehindA();
      expect(await handleSocketCommand({ cmd: "cancel" } as any)).toMatchObject({ outcome: "noop" });
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
      expect(handleSocketCommand({ cmd: "read_next", request_id: "A" } as any)).toMatchObject({ outcome: "noop", reason: "stale" });
      autoPlay = true;
      select("D", "Delta after the idle cancel.");
      await settle(); await settle();
      expect(receipts("D").length).toBeGreaterThan(0);
      expect(receipts("B")).toEqual([]);
    });

    it("QUEUE1b: explicit Stop with no capture still clears the retained queue", async () => {
      await suspendedBehindA();
      expect(await handleSocketCommand({ cmd: "stop" } as any)).toMatchObject({ outcome: "noop" });
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
    });

    it("QUEUE1b SOL-R2-2: agent voice_speak after teardown ends the retained queue; a fresh D never runs into B", async () => {
      await suspendedBehindA();
      autoPlay = true;
      await speak("Agent announcement.");
      await settle();
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
      select("D", "Delta fresh selection.");
      await settle(); await settle();
      expect(receipts("D").length).toBeGreaterThan(0);
      expect(receipts("B")).toEqual([]);
    });

    it("QUEUE1b SOL-R2-2: Ask after teardown ends the retained queue; a fresh D never runs into B", async () => {
      await suspendedBehindA();
      autoPlay = true;
      spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }));
      spies.push(spyOn(input, "waitForInput").mockResolvedValue("an answer"));
      await handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
      await settle();
      expect(lastQueue()).toEqual({ type: "read_queue", count: 0, current_request_id: null });
      select("D", "Delta fresh selection.");
      await settle(); await settle();
      expect(receipts("B")).toEqual([]);
    });

    it("an agent voice_speak keeps its priority: it preempts the user's read as before and ends the user queue", async () => {
      select("A", "Alpha before the agent.");
      await playerBarrier.at(0);
      select("B", "Bravo never reached.");
      autoPlay = true;
      players[0].exit.resolve(143);
      await speak("Agent announcement.");
      await settle();
      expect(receipts("B")).toEqual([]);
      expect(events.filter(e => e.type === "read_queue").at(-1)).toEqual({ type: "read_queue", count: 0, current_request_id: null });
    });
  });
});
