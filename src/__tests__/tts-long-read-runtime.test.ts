import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "fs";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import * as qwen from "../tts/qwen3";
import * as input from "../input";
import * as booking from "../session-booking";
import { handleVoiceAsk } from "../handlers";
import { awaitCurrentPlayback, getPlaybackQueueDepth, loadHistory, speak, speakLongRead, stopPlayback } from "../tts";
import { handleSocketCommand } from "../socket-handlers";
import { TTS_HISTORY_FILE } from "../paths";

function deferred<T>() { let resolve!: (v: T) => void; const promise = new Promise<T>((r) => { resolve = r; }); return { promise, resolve }; }
async function until(predicate: () => boolean) {
  const deadline = performance.now() + 2000;
  while (!predicate()) { if (performance.now() > deadline) throw new Error("fixture did not advance"); await Bun.sleep(1); }
}
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

  beforeEach(() => {
    synths = []; players = []; events = []; handles = []; historyInputs = []; spies = [];
    holdSynth = false; autoPlay = false;
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
    spies.push(spyOn(socket, "broadcast").mockImplementation((event) => events.push(structuredClone(event))));
    spies.push(spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"));
    // Only platform probing uses spawnSync; all synth/play/decode/conversion spawns are fakes.
    Bun.spawnSync = ((argv: string[]) => ({ exitCode: argv[0] === "ffprobe" ? 0 : 1, stdout: Buffer.from(argv[0] === "ffprobe" ? "1\n" : ""), stderr: Buffer.alloc(0) })) as any;
    Bun.spawn = ((argv: string[]) => {
      if (argv.some((arg) => arg.startsWith("--text="))) {
        const media = argv.find((arg) => arg.startsWith("--write-media="))!.split("=").slice(1).join("=");
        const metadata = argv.find((arg) => arg.startsWith("--write-metadata="))!.split("=").slice(1).join("=");
        writeFileSync(media, "fake audio"); writeFileSync(metadata, JSON.stringify({ text: "Sentence", offset: 0, duration: 5000000 }));
        const exit = deferred<number>(); const item = { argv, exit, killed: false }; synths.push(item);
        if (!holdSynth || synths.length === 1) exit.resolve(0);
        return { pid: 71000 + synths.length, exited: exit.promise, kill: () => { item.killed = true; exit.resolve(143); } };
      }
      if (argv[0] === "ffmpeg") {
        if (argv.includes("concat")) {
          const playlist = argv[argv.indexOf("-i") + 1];
          historyInputs.push(readFileSync(playlist, "utf8").split("\n"));
          writeFileSync(argv.at(-1)!, "combined audio");
        }
        return { pid: 72000, exited: Promise.resolve(0), stdout: new Blob([new Uint8Array(8)]).stream(), kill: () => {} };
      }
      const exit = deferred<number>(); const item = { exit, killed: false, synthCount: synths.length }; players.push(item);
      if (autoPlay) exit.resolve(0);
      return { pid: 73000 + players.length, exited: exit.promise, kill: () => { item.killed = true; exit.resolve(143); } };
    }) as any;
  });
  afterEach(async () => {
    stopPlayback(); for (const h of handles) await h.done; await awaitCurrentPlayback();
    for (const spy of spies) spy.mockRestore(); Bun.spawn = originalSpawn; Bun.spawnSync = originalSpawnSync;
    try { unlinkSync(TTS_HISTORY_FILE); } catch {}
  });
  const start = (engine: "edge" | "clone" = "edge", readText = text) => { const h = speakLongRead(readText, { engine, voice: "fixture", rate: "+0%" }); handles.push(h); return h; };

  it("stop socket kills in-flight edge synthesis and player without retry or later spawns", async () => {
    holdSynth = true; const h = start(); await until(() => synths.length === 2);
    expect(players[0].synthCount).toBe(1);
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
    holdSynth = true; const old = start(); await until(() => synths.length === 2);
    const current = start(); await until(() => synths.length === 3);
    expect(synths[1].killed).toBe(true); synths[2].exit.resolve(0);
    await until(() => players.length === 2); stopPlayback(120); await Promise.all([old.done, current.done]);
    expect(players).toHaveLength(2);
    expect(events.filter((e) => e.state === "speaking" && !e.long_read?.preparing).map((e) => e.long_read.id)).toEqual([old.id, current.id]);
  });

  it("ordinary speak preempts a long read while retaining short-speech semantics", async () => {
    holdSynth = true; const old = start(); await until(() => synths.length === 2);
    holdSynth = false; await speak("A short update."); await until(() => players.length === 2);
    expect(synths[1].killed).toBe(true); stopPlayback(); await old.done;
  });

  it("refuses chunk-only replay during a long read to keep its history and timeline coherent", async () => {
    holdSynth = true; const h = start(); await until(() => synths.length === 2);
    expect(handleSocketCommand({ cmd: "replay" })).toMatchObject({ outcome: "reject", reason: "busy" });
    expect(players).toHaveLength(1); stopPlayback(100); await h.done;
  });

  it("voice_ask preempts synthesis before waiting on its prompt and recording", async () => {
    holdSynth = true; const old = start(); await until(() => synths.length === 2);
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true, owner: { pid: process.pid, sessionId: "fixture", startedAt: new Date().toISOString() } }));
    const capture = spyOn(input, "waitForInput").mockResolvedValue("fixture answer"); spies.push(capture);
    holdSynth = false; autoPlay = true;
    const answer = await handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
    await old.done;
    expect(answer.isError).not.toBe(true); expect(capture).toHaveBeenCalledTimes(1);
    expect(synths[1].killed).toBe(true); expect(players[0].killed).toBe(true);
    expect(players).toHaveLength(2);
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
    expect(events.some((e) => e.type === "subtitle")).toBe(false); expect(loadHistory()).toHaveLength(1);
  });

  it("keeps the ring bounded at twenty entries", async () => {
    autoPlay = true;
    for (let i = 0; i < 22; i++) { const h = speakLongRead(`Read ${i}.`, { engine: "edge", voice: "fixture", rate: "+0%" }); handles.push(h); await h.done; }
    expect(loadHistory()).toHaveLength(20); expect(new Set(loadHistory().map((e) => e.id)).size).toBe(20);
  });
});
