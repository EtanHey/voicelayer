import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import * as qwen from "../tts/qwen3";
import * as input from "../input";
import * as booking from "../session-booking";
import * as longReadRunner from "../tts/long-read";
import { handleVoiceAsk } from "../handlers";
import { awaitCurrentPlayback, getPlaybackQueueDepth, loadHistory, speak, speakLongRead, stopPlayback, seekPlayback } from "../tts";
import { handleSocketCommand } from "../socket-handlers";
import { TTS_HISTORY_FILE } from "../paths";
import { readTTSControlsStatus, recordFirstAudio } from "../tts-controls-status";
import { fixtureBarrier, fixtureCheckpoint } from "./long-read-fixture-barriers";

function deferred<T>() { let resolve!: (v: T) => void; const promise = new Promise<T>((r) => { resolve = r; }); return { promise, resolve }; }
const text = Array.from({ length: 80 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" ");

describe("long-read real runtime with owned synth/player fakes", () => {
  const originalSpawn = Bun.spawn, originalSpawnSync = Bun.spawnSync;
  let synths: { argv: string[]; exit: ReturnType<typeof deferred<number>>; killed: boolean }[];
  let players: { exit: ReturnType<typeof deferred<number>>; killed: boolean; synthCount: number }[];
  let events: any[];
  let holdSynth: boolean, autoPlay: boolean;
  let handles: { done: Promise<void> }[];
  let spies: ReturnType<typeof spyOn>[];
  let historyInputs: string[][];
  let holdHistory: boolean, holdDecoder: boolean;
  type Child = { exit: ReturnType<typeof deferred<number>>; killed: boolean };
  let synthBarrier: ReturnType<typeof fixtureBarrier<typeof synths[number]>>;
  let playerBarrier: ReturnType<typeof fixtureBarrier<typeof players[number]>>;
  let historyBarrier: ReturnType<typeof fixtureBarrier<Child>>;
  let decoderBarrier: ReturnType<typeof fixtureBarrier<Child>>;
  let histories: Child[], decoders: Child[];
  let clockMs: number;

  beforeEach(() => {
    synths = []; players = []; events = []; handles = []; historyInputs = []; spies = [];
    holdSynth = false; autoPlay = false; holdHistory = false; holdDecoder = false;
    clockMs = 100_000;
    spies.push(spyOn(Date, "now").mockImplementation(() => clockMs));
    synthBarrier = fixtureBarrier(); playerBarrier = fixtureBarrier();
    historyBarrier = fixtureBarrier(); decoderBarrier = fixtureBarrier(); histories = []; decoders = [];
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
    spies.push(spyOn(socket, "broadcast").mockImplementation((event) => events.push(structuredClone(event))));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    // Only platform probing uses spawnSync; all synth/play/decode/conversion spawns are fakes.
    Bun.spawnSync = ((argv: string[]) => ({ exitCode: argv[0] === "ffprobe" ? 0 : 1, stdout: Buffer.from(argv[0] === "ffprobe" ? "1\n" : ""), stderr: Buffer.alloc(0) })) as any;
    Bun.spawn = ((argv: string[]) => {
      if (argv[0] === "which") return { pid: 70000, exited: Promise.resolve(0), stdout: new Blob(["ffmpeg"]).stream(), kill: () => {} };
      if (argv.some((arg) => arg.startsWith("--text="))) {
        const media = argv.find((arg) => arg.startsWith("--write-media="))!.split("=").slice(1).join("=");
        const metadata = argv.find((arg) => arg.startsWith("--write-metadata="))!.split("=").slice(1).join("=");
        writeFileSync(media, "fake audio"); writeFileSync(metadata, JSON.stringify({ text: "Sentence", offset: 0, duration: 5000000 }));
        const exit = deferred<number>(); const item = { argv, exit, killed: false }; synths.push(item); synthBarrier.push(item);
        if (!holdSynth || synths.length === 1) exit.resolve(0);
        return { pid: 71000 + synths.length, exited: exit.promise, kill: () => { item.killed = true; exit.resolve(143); } };
      }
      if (argv[0] === "ffmpeg") {
        if (argv.includes("-ss")) writeFileSync(argv.at(-1)!, "trimmed audio");
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
      const exit = deferred<number>(); const item = { exit, killed: false, synthCount: synths.length }; players.push(item); playerBarrier.push(item);
      if (autoPlay) exit.resolve(0);
      return { pid: 73000 + players.length, exited: exit.promise, kill: () => { item.killed = true; exit.resolve(143); } };
    }) as any;
  });
  afterEach(async () => {
    stopPlayback(); for (const child of histories) child.exit.resolve(0); for (const h of handles) await h.done; await awaitCurrentPlayback();
    for (const spy of spies) spy.mockRestore(); Bun.spawn = originalSpawn; Bun.spawnSync = originalSpawnSync;
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
  });
  const start = (engine: "edge" | "clone" = "edge", readText = text) => { const h = speakLongRead(readText, { engine, voice: "fixture", rate: "+0%" }); handles.push(h); return h; };

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

  it("cancel is active during initial synthesis even with no queued player", async () => {
    holdSynth = true;
    // First request is held too: consume the auto-complete slot before starting.
    synths.push({ argv: [], exit: deferred<number>(), killed: false });
    const h = start(); expect(getPlaybackQueueDepth()).toBe(1);
    expect(events.find((event) => event.state === "speaking")).toMatchObject({
      text: "Preparing speech…", long_read: { id: h.id, preparing: true },
    });
    const ack = await handleSocketCommand({ cmd: "cancel" }); await h.done;
    expect(ack).toMatchObject({ outcome: "accept" }); expect(players).toHaveLength(0); expect(loadHistory()).toHaveLength(0);
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

  it("refuses chunk-only replay during a long read to keep its history and timeline coherent", async () => {
    holdSynth = true; const h = start(); await synthBarrier.at(1); await playerBarrier.at(0);
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "reject", reason: "busy" });
    expect(players).toHaveLength(1); stopPlayback(100); await h.done;
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
