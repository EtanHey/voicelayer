import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { existsSync, writeFileSync } from "fs";
import * as tts from "../tts";
import * as amplitude from "../playback-amplitude";
import * as socket from "../socket-client";
import * as recording from "../recording-state";
import * as input from "../input";
import * as health from "../tts-health";
import * as qwen from "../tts/qwen3";
import * as binaries from "../resolve-binary";
import * as booking from "../session-booking";
import { handleVoiceAsk } from "../handlers";
import { handleSocketCommand } from "../socket-handlers";
import { resolveBinaryAsync, resolveBinary, __setBinarySpawnForTests, __resetBinarySpawnForTests } from "../resolve-binary";
import { runLongRead } from "../tts/long-read";
import { TEST_TMP } from "./setup/test-tmp";
import { deferredFixture as deferred, fixtureBarrier, fixtureCheckpoint as checkpoint } from "./long-read-fixture-barriers";

const unavailable = { source: "unavailable", sample_interval_ms: 50, samples: [] } as const;
const spies: ReturnType<typeof spyOn>[] = [];
afterEach(async () => { tts.stopPlayback(); await tts.awaitCurrentPlayback(); for (const spy of spies.splice(0)) spy.mockRestore(); __resetBinarySpawnForTests(); });

describe("seek review regressions", () => {
  let players: ReturnType<typeof fixtureBarrier<any>>, cuts: ReturnType<typeof fixtureBarrier<any>>;
  let decodes: ReturnType<typeof fixtureBarrier<any>>, events: any[], now: number;
  let holdDecode: boolean, synthWords: any[];
  let recordingSpy: ReturnType<typeof spyOn>, localSpy: ReturnType<typeof spyOn>;
  const source = `${TEST_TMP}/review-seek-source.mp3`;
  beforeEach(() => {
    players = fixtureBarrier(); cuts = fixtureBarrier(); decodes = fixtureBarrier(); events = [];
    now = 100000; holdDecode = false; synthWords = [];
    writeFileSync(source, "source");
    spies.push(spyOn(Date, "now").mockImplementation(() => now));
    recordingSpy = spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"); spies.push(recordingSpy);
    localSpy = spyOn(input, "getRecordingState").mockReturnValue("idle"); spies.push(localSpy);
    spies.push(spyOn(socket, "broadcast").mockImplementation(event => { events.push(event); }));
    spies.push(spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockImplementation(() => {
      const result = deferred<any>(); decodes.push(result);
      if (!holdDecode) result.resolve(unavailable);
      return { result: result.promise, cancel: () => result.resolve(unavailable) };
    }));
    spies.push(spyOn(health, "synthesizeWithRetry").mockImplementation(async (_text, _voice, _rate, file) => {
      writeFileSync(file, "synthesized"); return { success: true, wordBoundaries: synthWords };
    }));
    spies.push(spyOn(Bun, "spawnSync").mockImplementation(((argv: string[]) => ({ exitCode: argv[0] === "ffprobe" ? 0 : 1, stdout: Buffer.from("2\n"), stderr: Buffer.alloc(0) })) as any));
    let pid = 94000;
    spies.push(spyOn(Bun, "spawn").mockImplementation(((argv: string[]) => {
      const exit = deferred<number>(); const child = { argv, exit, killed: false };
      const proc = { pid: ++pid, exited: exit.promise, stdout: new Blob(["/fake/ffmpeg"]).stream(), kill: () => { child.killed = true; exit.resolve(143); } };
      if (argv[0] === "which" || argv[1] === "-version") exit.resolve(0);
      else if (argv.includes("concat")) { writeFileSync(argv.at(-1)!, "history"); exit.resolve(0); }
      else if (argv.includes("-ss")) cuts.push(child);
      else players.push(child);
      return proc;
    }) as any));
  });
  async function start() {
    const handle = tts.playAudioNonBlocking(source, { text: "Source", voice: "fixture", durationMs: 2000 });
    await players.at(0); return handle;
  }
  function completeCut(index: number, code = 0) {
    const cut = cuts.values[index]; if (code === 0) writeFileSync(cut.argv.at(-1), "slice"); cut.exit.resolve(code);
  }

  for (const words of [[], [{ offset_ms: 0, duration_ms: 400, text: "Hello" }], [{ offset_ms: 0, duration_ms: 2500, text: "Hello" }]]) {
    it(`R1-1 short speech duration uses probe and boundary maximum (${words.length ? words[0].duration_ms : "no words"})`, async () => {
      synthWords = words;
      await tts.speak("Hello", { voice: "jenny", mode: "announce" }); await players.at(0);
      expect(events.find(event => event.state === "speaking").duration_ms).toBe(Math.max(2000, words[0]?.duration_ms ?? 0));
      expect(tts.seekPlayback(1500)).toMatchObject({ outcome: "accept", offset_ms: 1500, clamped: false });
    });
  }
  it("R1-2 a completed slice starts playback without waiting for amplitude decoding", async () => {
    await start(); holdDecode = true;
    tts.seekPlayback(300); await cuts.at(0); completeCut(0); await checkpoint();
    expect(players.values).toHaveLength(2);
    expect(events.filter(event => event.state === "speaking").at(-1).playback_offset_ms).toBe(300);
  });
  it("R1-3 a failed conversion leaves current playback and clock intact", async () => {
    const handle = await start(); let settled = false; void handle.exited.then(() => { settled = true; });
    tts.seekPlayback(300); await cuts.at(0); completeCut(0, 8); await checkpoint();
    expect(players.values[0].killed).toBe(false); expect(settled).toBe(false);
    expect(events.filter(event => event.state === "speaking")).toHaveLength(1);
    expect(events.some(event => event.type === "error" && event.source === "seek" && event.recoverable)).toBe(true);
    expect(existsSync(cuts.values[0].argv.at(-1))).toBe(false);
  });
  it("R1-3 a missing converter preserves the current short utterance", async () => {
    await start(); spies.push(spyOn(binaries, "resolveBinaryAsync").mockResolvedValue(null));
    tts.seekPlayback(300); await checkpoint();
    expect(players.values[0].killed).toBe(false); expect(cuts.values).toHaveLength(0);
    expect(events.some(event => event.type === "error" && /ffmpeg unavailable/.test(event.message))).toBe(true);
  });
  for (const engine of ["edge", "clone"] as const) {
    it(`R1-2/3 ${engine} long seek preflights without stopping and bypasses amplitude on success`, async () => {
      if (engine === "clone") spies.push(spyOn(qwen, "synthesizeCloned").mockResolvedValue(Buffer.from("cloned fixture")));
      const h = tts.speakLongRead("One sentence. ".repeat(100), { engine, voice: "fixture", rate: "+0%" });
      try {
        await players.at(0); now += 100;
        tts.seekPlayback(300); await cuts.at(0);
        expect(players.values[0].killed).toBe(false);
        completeCut(0, 8); await checkpoint(); expect(players.values[0].killed).toBe(false);
        expect(events.some(event => event.type === "error" && event.source === "seek")).toBe(true);
        holdDecode = true; tts.seekPlayback(400); await cuts.at(1); completeCut(1); await checkpoint();
        expect(players.values).toHaveLength(2);
        expect(events.filter(event => event.state === "speaking").at(-1).playback_offset_ms).toBe(400);
      } finally { tts.stopPlayback(400); await h.done; }
    });
  }
  it("R1-3 natural completion cancels a stale conversion before the next queued utterance", async () => {
    const first = await start(); tts.seekPlayback(300); await cuts.at(0);
    const second = tts.playAudioNonBlocking(source, { text: "Next", voice: "fixture", durationMs: 2000 });
    players.values[0].exit.resolve(0); await first.exited; await players.at(1); await checkpoint();
    expect(cuts.values[0].killed).toBe(true); expect(players.values).toHaveLength(2);
    expect(events.filter(event => event.state === "speaking").at(-1).text).toBe("Next");
    players.values[1].exit.resolve(0); await second.exited;
  });
  it("R1-4 seek zero and restart after seek both play the original without ffmpeg or decoder waits", async () => {
    await start(); holdDecode = true;
    tts.seekPlayback(0); await checkpoint();
    expect(cuts.values).toHaveLength(0); expect(players.values).toHaveLength(2);
    expect(players.values[1].argv.at(-1)).toBe(source);
    tts.seekPlayback(300); await cuts.at(0); completeCut(0); await checkpoint();
    expect(players.values).toHaveLength(3);
    expect(tts.restartPlayback()).toBe(true); await checkpoint();
    expect(cuts.values).toHaveLength(1); expect(players.values).toHaveLength(4);
    expect(players.values[3].argv.at(-1)).toBe(source);
  });
  it("R1-6 refuses seek during voice_ask recording", async () => {
    const capture = deferred<string>(), captured = fixtureBarrier<void>();
    spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true, owner: { pid: process.pid, sessionId: "fixture", startedAt: new Date().toISOString() } }));
    spies.push(spyOn(input, "waitForInput").mockImplementation(async () => {
      recordingSpy.mockReturnValue("recording"); localSpy.mockReturnValue("recording"); captured.push(); return capture.promise;
    }));
    const ask = handleVoiceAsk({ message: "Question?", timeout_seconds: 5 });
    try {
      const prompt = await players.at(0); prompt.exit.resolve(0); await captured.at(0);
      expect(handleSocketCommand({ cmd: "seek", offset_ms: 100 })).toMatchObject({ outcome: "reject", reason: "busy" });
      expect(cuts.values).toHaveLength(0);
    } finally { recordingSpy.mockReturnValue("idle"); localSpy.mockReturnValue("idle"); capture.resolve("Answer"); await ask; }
  });
  it("R1-6 ten seeks in 180ms retain the player until the newest slice is ready", async () => {
    await start();
    for (let i = 0; i < 10; i++) {
      now = 100000 + i * 20;
      expect(tts.seekPlayback(100 + i * 50).outcome).toBe("accept"); await cuts.at(i);
    }
    expect(players.values).toHaveLength(1); expect(players.values[0].killed).toBe(false);
    expect(cuts.values.slice(0, 9).every(cut => cut.killed)).toBe(true);
    completeCut(9); await checkpoint();
    expect(players.values).toHaveLength(2);
    expect(events.filter(event => event.state === "speaking").at(-1).playback_offset_ms).toBe(550);
    tts.stopPlayback(); await tts.awaitCurrentPlayback();
    expect(cuts.values.every(cut => !existsSync(cut.argv.at(-1)))).toBe(true);
  });
});

describe("seek readiness and exact chunk mapping", () => {
  it("R1-5 acknowledges initial synthesis as explicitly not ready", async () => {
    const first = deferred<any>(), controller = new AbortController(); let control: any;
    const done = runLongRead(["First"], "preparing", controller.signal, {
      registerSeek: value => { control = value; }, synthesize: () => first.promise,
      play: () => { throw new Error("aborted work cannot play"); }, saveHistory: async () => {}, dispose: () => {},
    });
    try { expect(control.seek(100)).toMatchObject({ outcome: "noop", reason: "not ready" }); }
    finally { controller.abort(); first.resolve({ audioFile: "first.mp3", durationMs: 1000, wordBoundaries: [] }); await done; }
  });
  it("R1-3 a newer preflight cannot discard an already committed long-read cursor", async () => {
    const controller = new AbortController(), plays = fixtureBarrier<any>(), preparations = fixtureBarrier<any>(), interrupts = fixtureBarrier<void>();
    let control: any;
    const done = runLongRead(["A", "B"], "cursor-race", controller.signal, {
      registerSeek: value => { control = value; },
      synthesize: async (_text, index) => ({ audioFile: `${index}.mp3`, durationMs: 1000, wordBoundaries: [] }),
      prepareSeek: async () => { const result = deferred<string>(); preparations.push(result); return result.promise; },
      disposeSeek: () => {},
      play: (_chunk, _text, _info, position) => {
        const exit = deferred<any>(); plays.push({ position, exit });
        return { started: Promise.resolve(true), exited: exit.promise, interrupt: () => interrupts.push() };
      }, saveHistory: async () => {}, dispose: () => {},
    });
    try {
      await plays.at(0); control.seek(100); (await preparations.at(0)).resolve("first.wav"); await interrupts.at(0);
      control.seek(200); await preparations.at(1);
      plays.values[0].exit.resolve({ status: "interrupted", stopped_at_ms: 300 }); await checkpoint();
      expect(plays.values).toHaveLength(2); expect(plays.values[1].position.offsetMs).toBe(100);
      preparations.values[1].resolve("latest.wav"); await interrupts.at(1);
      plays.values[1].exit.resolve({ status: "interrupted", stopped_at_ms: 300 });
      const latest = await plays.at(2); expect(latest.position.offsetMs).toBe(200);
    } finally {
      controller.abort(); for (const preparation of preparations.values) preparation.resolve("cancelled.wav");
      for (const play of plays.values) play.exit.resolve({ status: "interrupted", stopped_at_ms: 0 }); await done;
    }
  });
  it("R1-6 maps chunk starts and last milliseconds exactly", async () => {
    const controller = new AbortController(), plays = fixtureBarrier<any>(); let control: any;
    const done = runLongRead(["A", "B", "C"], "mapping", controller.signal, {
      registerSeek: value => { control = value; },
      synthesize: async (_text, index) => ({ audioFile: `${index}.mp3`, durationMs: 1000, wordBoundaries: [] }),
      play: (_chunk, _text, info, position) => {
        const exit = deferred<any>(); plays.push({ info, position, exit });
        return { started: Promise.resolve(true), exited: exit.promise, interrupt: () => exit.resolve({ status: "interrupted", stopped_at_ms: 100 }) };
      }, saveHistory: async () => {}, dispose: () => {},
    }, 2);
    try {
      await plays.at(0); await checkpoint();
      for (const [i, offset] of [999, 1000, 1999, 2000, 2999].entries()) {
        expect(control.seek(offset).offset_ms).toBe(offset);
        const play = await plays.at(i + 1);
        expect(play.info.chunk_index).toBe(Math.floor(offset / 1000));
        expect(play.position.offsetMs).toBe(offset % 1000);
      }
    } finally { controller.abort(); plays.values.at(-1).exit.resolve({ status: "interrupted", stopped_at_ms: 0 }); await done; }
  });
});

describe("ffmpeg candidate resolution", () => {
  it("R1-3 async fallback probes ffmpeg with -version and leaves other binaries unchanged", async () => {
    const argv: string[][] = [];
    const spawn = spyOn(Bun, "spawn").mockImplementation(((cmd: string[]) => {
      argv.push(cmd); return { pid: 95000, stdout: new Blob([]).stream(), exited: Promise.resolve(cmd[0] === "which" ? 1 : cmd[1] === "-version" ? 0 : 8), kill: () => {} };
    }) as any); spies.push(spawn);
    expect(await resolveBinaryAsync("ffmpeg")).toBe("/opt/homebrew/bin/ffmpeg");
    expect(argv[1]).toEqual(["/opt/homebrew/bin/ffmpeg", "-version"]);
    argv.length = 0; await resolveBinaryAsync("python3");
    expect(argv[1]).toEqual(["/opt/homebrew/bin/python3", "--version"]);
  });
  it("R1-3 sync fallback uses the same ffmpeg-specific version flag", () => {
    const argv: string[][] = [];
    __setBinarySpawnForTests(cmd => { argv.push(cmd); return { exitCode: cmd[0] === "which" ? 1 : cmd[1] === "-version" ? 0 : 8 }; });
    expect(resolveBinary("ffmpeg")).toBe("/opt/homebrew/bin/ffmpeg");
    expect(argv[1]).toEqual(["/opt/homebrew/bin/ffmpeg", "-version"]);
  });
});
