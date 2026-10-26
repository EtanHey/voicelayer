import { LiveSpeechArchive, beginSpeechArchive, flushSpeechArchives } from "../speech-archive-live";
import { readFileSync } from "fs";
import { join } from "path";
/**
 * STOP1 N8 regression (imported from 8fe22c83). Run this file alone with bunfig.toml's safety preload.
 * Real handlers and synthesis-to-queue path; every external
 * synthesis/player effect is held or faked. No subprocess is launched.
 */
import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
import { existsSync, writeFileSync } from "node:fs";
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { deferredFixture, fixtureCheckpoint } from "./long-read-fixture-barriers";
import * as tts from "../tts";
import * as health from "../tts-health";
import * as settings from "../tts-settings";
import * as amplitude from "../playback-amplitude";
import * as binaries from "../resolve-binary";
import * as xtts from "../tts/xtts";
import * as f5 from "../tts/f5tts";
import * as qwen from "../tts/qwen3";
import * as pronunciation from "../pronunciation";
import * as socket from "../socket-client";
import * as launcher from "../voice-bar-launcher";
import * as recording from "../recording-state";
import * as booking from "../session-booking";
import { hasActiveVoiceOperation } from "../voice-operation-reservation";
import * as input from "../input";
import { handleMcpRequest } from "../mcp-handler";
import { handleVoiceAsk, handleVoiceSpeak } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
import { STOP_FILE, ttsFilePath } from "../paths";

describe("STOP1 Stop during speech preparation", () => {
  let spies: ReturnType<typeof spyOn>[];
  let players: {
    exit: ReturnType<typeof deferredFixture<number>>;
    exited: boolean;
    kills: string[];
  }[];
  let events: any[];
  let releaseSynthesis: (() => void) | undefined;
  let speech: Promise<unknown> | undefined;
  let synthesize: ReturnType<typeof spyOn<typeof health, "synthesizeWithRetry">>;

  beforeEach(() => {
    // Fail closed if somebody bypasses the standard preload.
    expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
    expect(process.env.VOICELAYER_TEST_FAKE_REC).toBe("1");
    expect(STOP_FILE).toStartWith(`${process.cwd()}/.test-tmp/`);
    spies = []; players = []; events = [];
    releaseSynthesis = undefined; speech = undefined;
    recording.setRecordingState("idle");
    booking.clearStopSignal(); booking.clearCancelSignal();
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
    spies.push(spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(() => {}));
    spies.push(spyOn(settings, "resolveSpeakProfile").mockReturnValue({
      kind: "short", engine: "edge", voice: "en-US-JennyNeural", rate: "+0%",
      rateSource: "default", engineSource: "default",
    }));
    spies.push(spyOn(qwen, "hasClonedProfile").mockReturnValue(false));
    spies.push(spyOn(pronunciation, "pronunciationRules").mockReturnValue([]));
    spies.push(spyOn(binaries, "resolveBinary").mockReturnValue(null));
    spies.push(spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockImplementation(() => ({
      result: Promise.resolve({ source: "unavailable", sample_interval_ms: 50, samples: [] }),
      cancel() {},
    })));
    spies.push(spyOn(Bun, "spawnSync").mockImplementation(() => ({
      exitCode: 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0),
    }) as any));
    spies.push(spyOn(Bun, "spawn").mockImplementation((cmd: any) => {
      const argv = Array.isArray(cmd) ? cmd : cmd.cmd;
      if (!["afplay", "mpg123", "mpv", "ffplay"].includes(argv[0])) {
        throw new Error(`SM0 refused unexpected subprocess: ${argv[0]}`);
      }
      const player = { exit: deferredFixture<number>(), exited: false, kills: [] as string[] };
      players.push(player);
      void player.exit.promise.then(() => { player.exited = true; });
      return {
        pid: 98000 + players.length, exited: player.exit.promise,
        // Kill is a request, not physical-exit proof. The test owns that barrier.
        kill(signal: string) { player.kills.push(signal); },
      } as any;
    }));
    // A test that forgets to install its held synthesizer must never reach Edge.
    synthesize = spyOn(health, "synthesizeWithRetry").mockRejectedValue(new Error("SM0 synthesis not configured"));
    spies.push(synthesize);
  });

  afterEach(async () => {
    releaseSynthesis?.();
    await speech;
    tts.stopPlayback();
    for (const player of players) player.exit.resolve(0);
    await tts.awaitCurrentPlayback(); await flushSpeechArchives();
    booking.releaseVoiceSession(); booking.clearStopSignal(); booking.clearCancelSignal();
    recording.setRecordingState("idle");
    for (const spy of spies.reverse()) spy.mockRestore();
  });

  it("Ask matches main: admits capture before unrelated preparation finishes", async () => {
    const entered = deferredFixture<void>(), release = deferredFixture<void>();
    releaseSynthesis = () => release.resolve();
    synthesize.mockImplementation(async (_text, _voice, _rate, file) => {
      entered.resolve(); await release.promise; writeFileSync(file, "fixture audio");
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    speech = tts.speak("Preparing speak before Ask."); await entered.promise;
    let resolved = false;
    const wait = tts.awaitCurrentPlayback({ forCaptureAdmission: true }).then(() => { resolved = true; });
    await fixtureCheckpoint();
    expect(resolved).toBe(true);
    const admission = tts.reserveCaptureAdmission();
    expect(admission).toBeDefined();
    try {
      release.resolve(); await speech; await fixtureCheckpoint();
      expect(players).toHaveLength(0);
    } finally { admission?.release(); }
    await fixtureCheckpoint(); expect(players).toHaveLength(1);
    let drained = false;
    const playingWait = tts.awaitCurrentPlayback({ forCaptureAdmission: true }).then(() => { drained = true; });
    await fixtureCheckpoint(); expect(drained).toBe(false);
    players[0].exit.resolve(0); await playingWait; await wait;
    const late = tts.reserveCaptureAdmission(); expect(late).toBeDefined(); late?.release();
  });

  it("archive player-start faults leave the player running", async () => {
    synthesize.mockImplementation(async (_text, _voice, _rate, file) => {
      writeFileSync(file, "fixture audio");
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    spies.push(spyOn(LiveSpeechArchive.prototype, "playerStarted").mockImplementation(() => { throw Error("fixture archive fault"); }));
    speech = tts.speak("Speech must survive its archive fault."); await speech;
    expect(players).toHaveLength(1); expect(players[0].kills).toEqual([]);
    players[0].exit.resolve(0); await tts.awaitCurrentPlayback();
  });

  it("SPEECH-WIRE Cancel during preparation aborts generation", async () => {
    const entered = deferredFixture<void>();
    let signal: AbortSignal | undefined;
    synthesize.mockImplementation(async (_text, _voice, _rate, _file, _script, _retries, abort) => {
      signal = abort; entered.resolve();
      await new Promise<void>(resolve => { releaseSynthesis = resolve; abort?.addEventListener("abort", () => resolve(), { once: true }); });
      throw abort?.reason;
    });
    const archive = beginSpeechArchive("Cancel fixture.");
    await archive.settled();
    speech = tts.speak("Cancel fixture.", { archiveContext: archive.context }).catch(error => error);
    await entered.promise;
    const ack = await handleSocketCommand({ cmd: "cancel" });
    expect(ack).toMatchObject({ outcome: "accept" });
    expect(signal?.aborted).toBe(true);
    await flushSpeechArchives();
    expect(JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8")).speech.state).toBe("cancelled");
  });
  it("N8 Stop during held Edge voice_speak synthesis prevents later playback", async () => {
    const entered = deferredFixture<void>();
    const synthesis = deferredFixture<void>();
    releaseSynthesis = () => synthesis.resolve();
    let signal: AbortSignal | undefined;
    synthesize.mockImplementation(async (_text, _voice, _rate, file, _script, _retries, abort) => {
      signal = abort;
      entered.resolve();
      await synthesis.promise;
      writeFileSync(file, "fake mp3 bytes; never decoded or played");
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    speech = handleVoiceSpeak({ message: "Held synthesis probe.", mode: "announce", voice: "en-US-JennyNeural" })
      .catch(error => ({ cancelledOrFailed: String(error) }));
    await entered.promise;
    expect(hasActiveVoiceOperation()).toBe(true);
    expect(tts.getPlaybackQueueDepth()).toBe(0);
    expect(players).toHaveLength(0);

    // Send Stop before releasing a synthesizer that ignores cancellation.
    const stop = Promise.resolve(handleSocketCommand({ cmd: "stop", id: "sm0-n8" }));
    await fixtureCheckpoint();
    const stopFileWhileHeld = existsSync(STOP_FILE);
    const abortedWhileHeld = signal?.aborted;
    releaseSynthesis();
    const ack = await stop;
    await speech;
    await fixtureCheckpoint();
    console.log("SM0 N8", JSON.stringify({ ack, stopFileWhileHeld, synthCalls: synthesize.mock.calls.length,
      playerStarts: players.length, speakingEvents: events.filter(e => e.type === "state" && e.state === "speaking").length }));
    expect(synthesize).toHaveBeenCalledTimes(1);
    expect(ack).toMatchObject({ outcome: "accept" });
    expect(stopFileWhileHeld).toBe(true);
    expect(abortedWhileHeld).toBe(true);
    expect(players).toHaveLength(0); // Baseline starts one fake player after Stop.
  });


  for (const tier of ["qwen", "qwen-failure", "xtts", "f5", "xtts-audio", "f5-audio"] as const) {
    it(`Stop fences late ${tier} completion and prevents fallback`, async () => {
      const entered = deferredFixture<void>();
      const synthesis = deferredFixture<void>();
      releaseSynthesis = () => synthesis.resolve();
      spyOn(qwen, "hasClonedProfile").mockReturnValue(true);
      spies.push(spyOn(qwen, "loadProfile").mockReturnValue({
        name: "fixture", engine: tier.startsWith("f5") ? "f5-tts-mlx" : "qwen3-tts",
        reference_clip: "fixture.wav", reference_text: "Fixture reference.",
        reference_clips: [], model_path: "", fallback: "en-US-JennyNeural", created: "",
      }));
      spies.push(spyOn(xtts, "isXTTSAvailable").mockReturnValue(tier.startsWith("xtts")));
      spies.push(spyOn(f5, "isF5TTSAvailable").mockReturnValue(tier.startsWith("f5")));
      let signal: AbortSignal | undefined;
      const qwenSynth = spyOn(qwen, "synthesizeCloned").mockImplementation(async (_text, _voice, abort) => {
        signal = abort; entered.resolve(); await synthesis.promise;
        return tier === "qwen-failure" ? null : Buffer.from("fixture audio");
      });
      spies.push(qwenSynth);
      const wavFile = ttsFilePath(process.pid, 90000).replace(".mp3", ".wav");
      const lateWav = async () => {
        entered.resolve(); await synthesis.promise;
        if (!tier.endsWith("-audio")) return null;
        writeFileSync(wavFile, "late WAV fixture"); return wavFile;
      };
      const xttsSynth = spyOn(xtts, "synthesizeXTTS").mockImplementation(lateWav);
      const f5Synth = spyOn(f5, "synthesizeF5TTS").mockImplementation(lateWav);
      spies.push(xttsSynth, f5Synth);
      speech = tts.speak("Held cloned speech preparation.", { voice: "fixture" }).catch(error => error);
      await entered.promise;
      let acknowledged = false;
      const stopped = Promise.resolve(handleSocketCommand({ cmd: "stop" })).then(ack => { acknowledged = true; return ack; });
      await fixtureCheckpoint();
      expect(acknowledged).toBe(false); // No success receipt while generation still owns work.
      releaseSynthesis(); const ack = await stopped; await speech; await fixtureCheckpoint();
      expect(ack).toMatchObject({ outcome: "accept" });
      if (tier.startsWith("qwen")) expect(signal?.aborted).toBe(true);
      else expect(qwenSynth).not.toHaveBeenCalled();
      expect(existsSync(wavFile)).toBe(false);
      expect(synthesize).not.toHaveBeenCalled();
      expect(players).toHaveLength(0);
    });
  }

  for (const engine of ["edge", "clone"] as const) {
    it(`Stop during ${engine} long-read preparation aborts and fences a late result`, async () => {
      const entered = deferredFixture<void>();
      const synthesis = deferredFixture<void>();
      releaseSynthesis = () => synthesis.resolve();
      let signal: AbortSignal | undefined;
      if (engine === "edge") {
        synthesize.mockImplementation(async (_text, _voice, _rate, file, _script, _retries, abort) => {
          signal = abort; entered.resolve(); await synthesis.promise;
          writeFileSync(file, "late fixture audio");
          return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
        });
      } else {
        spies.push(spyOn(qwen, "synthesizeCloned").mockImplementation(async (_text, _voice, abort) => {
          signal = abort; entered.resolve(); await synthesis.promise; return Buffer.from("late fixture audio");
        }));
      }
      const read = tts.speakLongRead("Held long-read preparation.", { engine, voice: "fixture", rate: "+0%" });
      speech = read.done;
      await entered.promise;
      const stop = Promise.resolve(handleSocketCommand({ cmd: "stop" }));
      await fixtureCheckpoint();
      expect(signal?.aborted).toBe(true);
      releaseSynthesis();
      expect(await stop).toMatchObject({ outcome: "accept" });
      await read.done;
      expect(await read.started).toMatchObject({ error: "Speech stopped before playback" });
      expect(players).toHaveLength(0);
    });
  }

  it("true idle stays noop without writing a Stop signal", async () => {
    expect(await handleSocketCommand({ cmd: "stop" })).toMatchObject({ outcome: "noop", reason: "already idle" });
    expect(existsSync(STOP_FILE)).toBe(false);
  });

  it("a stopped operation cannot enqueue after a newer speech starts", async () => {
    const entered = deferredFixture<void>();
    const synthesis = deferredFixture<void>();
    releaseSynthesis = () => synthesis.resolve();
    const signals: AbortSignal[] = [];
    synthesize.mockImplementation(async (text, _voice, _rate, file, _script, _retries, signal) => {
      if (signal) signals.push(signal);
      if (text.startsWith("Old")) { entered.resolve(); await synthesis.promise; }
      writeFileSync(file, "fixture audio");
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    speech = tts.speak("Old speech.").catch(error => error);
    await entered.promise;
    const stopped = Promise.resolve(handleSocketCommand({ cmd: "stop" }));
    await tts.speak("New speech.");
    await fixtureCheckpoint();
    expect(signals).toHaveLength(2);
    expect(signals[0].aborted).toBe(true);
    expect(signals[1].aborted).toBe(false);
    releaseSynthesis(); await speech; await fixtureCheckpoint();
    expect(await stopped).toMatchObject({ outcome: "accept" });
    expect(players).toHaveLength(1);
    expect(events.filter(e => e.type === "state" && e.state === "speaking").map(e => e.text)).toEqual(["New speech."]);
  });

  it("Stop aborts an observing Edge synthesizer before its manual completion", async () => {
    const entered = deferredFixture<void>();
    const synthesis = deferredFixture<void>();
    releaseSynthesis = () => synthesis.resolve();
    let observedAbort = false;
    synthesize.mockImplementation(async (_text, _voice, _rate, file, _script, _retries, signal) => {
      const aborted = new Promise<never>((_resolve, reject) => signal?.addEventListener("abort", () => {
        observedAbort = true; reject(new DOMException("Aborted", "AbortError"));
      }, { once: true }));
      entered.resolve();
      await Promise.race([synthesis.promise, aborted]);
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    speech = tts.speak("Abort-observing speech.").catch(error => error);
    await entered.promise;
    const ack = await handleSocketCommand({ cmd: "stop" });
    await fixtureCheckpoint();
    const abortedBeforeManualCompletion = observedAbort;
    releaseSynthesis(); await speech;
    expect(ack).toMatchObject({ outcome: "accept" });
    expect(abortedBeforeManualCompletion).toBe(true);
    expect(players).toHaveLength(0);
    expect(events.some(e => e.type === "error")).toBe(false);
  });

  it("SPEECH-WIRE keeps finished chunks when later generation is cancelled", async () => {
    const entered = deferredFixture<void>(), held = deferredFixture<void>();
    releaseSynthesis = () => held.resolve();
    let calls = 0;
    synthesize.mockImplementation(async (_text, _voice, _rate, file) => {
      if (++calls === 2) { entered.resolve(); await held.promise; }
      writeFileSync(file, "finished chunk bytes");
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    const archive = beginSpeechArchive("Original selection");
    await archive.settled();
    speech = tts.speak("A sentence with enough words for multiple generated chunks. ".repeat(50), { archiveContext: archive.context }).catch(error => error);
    await entered.promise;
    const stopped = Promise.resolve(handleSocketCommand({ cmd: "cancel" }));
    releaseSynthesis(); await stopped; await speech;
    await flushSpeechArchives();
    const m = JSON.parse(readFileSync(join(archive.context.path, "metadata.json"), "utf8"));
    expect(m.speech.state).toBe("cancelled"); expect(m.speech.generated).toHaveLength(1);
    expect(readFileSync(join(archive.context.path, m.speech.generated[0].audio_path), "utf8")).toBe("finished chunk bytes");
  });
  it("Stop during multi-chunk Edge preparation prevents the next chunk", async () => {
    const entered = deferredFixture<void>();
    const synthesis = deferredFixture<void>();
    releaseSynthesis = () => synthesis.resolve();
    synthesize.mockImplementation(async (_text, _voice, _rate, file) => {
      entered.resolve(); await synthesis.promise; writeFileSync(file, "late chunk");
      return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
    });
    speech = tts.speak("A long sentence with enough words for several preparation chunks. ".repeat(100)).catch(error => error);
    await entered.promise;
    const stopped = Promise.resolve(handleSocketCommand({ cmd: "stop" }));
    releaseSynthesis(); const ack = await stopped; await speech;
    expect(ack).toMatchObject({ outcome: "accept" });
    expect(synthesize).toHaveBeenCalledTimes(1);
    expect(players).toHaveLength(0);
  });

  const mcpCall = (name: "voice_speak" | "voice_ask", mode = "announce") => handleMcpRequest({
    jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name, arguments: { message: "Held question or announcement.", ...(name === "voice_speak" ? { mode } : {}) } },
  }, { executeTool: (name, args, context) => name === "voice_ask" ? handleVoiceAsk(args, context) : handleVoiceSpeak(args, context) });

  for (const [tool, mode] of [["voice_speak", "announce"], ["voice_speak", "brief"], ["voice_speak", "consult"], ["voice_ask", "converse"]] as const) {
    it(`MCP ${tool}/${mode} treats its owned preparation Stop as a non-error`, async () => {
      const entered = deferredFixture<void>(), synthesis = deferredFixture<void>();
      releaseSynthesis = () => synthesis.resolve();
      const record = spyOn(input, "waitForInput").mockRejectedValue(new Error("Unexpected recorder start")); spies.push(record);
      synthesize.mockImplementation(async (_text, _voice, _rate, file) => {
        entered.resolve(); await synthesis.promise; writeFileSync(file, "late fixture audio");
        return { success: true, attempts: 1, audioFile: file, wordBoundaries: [] };
      });
      const pending = mcpCall(tool, mode); speech = pending;
      await entered.promise;
      const stopped = Promise.resolve(handleSocketCommand({ cmd: "stop" }));
      releaseSynthesis();
      expect(await stopped).toMatchObject({ outcome: "accept" });
      const response = await pending;
      expect(response?.error).toBeUndefined();
      expect(response?.result?.isError).not.toBe(true);
      const text = (response?.result?.content as { text: string }[])[0].text;
      expect(text).toContain(tool === "voice_ask"
        ? "Stopped by the user before the question was spoken. Nothing was recorded."
        : "Stopped by the user before playback.");
      if (tool === "voice_ask") {
        expect(text).toStartWith("┌─ voice_ask\n");
        expect(text).not.toMatch(/Archive:|timeout|Error:/);
      }
      expect(record).not.toHaveBeenCalled();
      expect(players).toHaveLength(0);
      expect(tts.isCaptureAdmissionReserved()).toBe(false);
      expect(hasActiveVoiceOperation()).toBe(false);
      await fixtureCheckpoint();
      expect(events.filter(e => e.type === "state").at(-1)).toMatchObject({ state: "idle" });
    });
  }

  for (const tool of ["voice_speak", "voice_ask"] as const) {
    for (const error of [new Error("Genuine synthesis failure"), new DOMException("Aborted", "AbortError")]) {
      it(`MCP ${tool} preserves an unowned ${error.message} as an error`, async () => {
        const record = spyOn(input, "waitForInput").mockRejectedValue(new Error("Unexpected recorder start")); spies.push(record);
        synthesize.mockRejectedValue(error);
        const pending = mcpCall(tool); speech = pending;
        const response = await pending;
        expect(response?.error).toBeUndefined();
        expect(response?.result?.isError).toBe(true);
        expect((response?.result?.content as { text: string }[])[0].text).toContain(error.message);
        expect(record).not.toHaveBeenCalled();
        expect(players).toHaveLength(0);
        expect(tts.isCaptureAdmissionReserved()).toBe(false);
        expect(hasActiveVoiceOperation()).toBe(false);
      });
    }
  }
});
