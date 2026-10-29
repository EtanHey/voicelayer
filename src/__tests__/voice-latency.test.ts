import { afterEach, expect, it, spyOn } from "bun:test";
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import * as tts from "../tts";
import * as input from "../input";
import * as booking from "../session-booking";
import * as recording from "../recording-state";
import * as socket from "../socket-client";
import * as vad from "../vad";
import * as audio from "../audio-utils";
import * as recorder from "../recorder-binary";
import * as amplitude from "../playback-amplitude";
import * as health from "../tts-health";
import { beginSpeechArchive, flushSpeechArchives } from "../speech-archive-live";
import { handleVoiceAsk } from "../handlers";
import { linkVoiceTrace, traceStage, traceStageOnce, traceExit } from "../voice-trace";
import { analyzeVoiceTrace } from "../../scripts/measure-voice-turn-latency";

const root = process.env.VOICELAYER_TEST_RUN_ROOT;
if (!root) throw new Error("isolated preload required");
const file = join(root, "latency.ndjson");
const previousTrace = process.env.VOICELAYER_TRACE_FILE;
const spies: Array<{ mockRestore(): void }> = [];
afterEach(async () => {
  await flushSpeechArchives();
  for (const spy of spies.splice(0).reverse()) spy.mockRestore();
  if (previousTrace === undefined) delete process.env.VOICELAYER_TRACE_FILE;
  else process.env.VOICELAYER_TRACE_FILE = previousTrace;
  rmSync(file, { force: true });
});

it("stubbed Ask preserves ordered, private monotonic stages under one request", async () => {
  process.env.VOICELAYER_TRACE_FILE = file;
  const spawn = Bun.spawn;
  spies.push(spyOn(booking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true }),
    spyOn(recording, "getEffectiveRecordingState").mockReturnValue("idle"),
    spyOn(input, "getRecordingState").mockReturnValue("idle"),
    spyOn(input, "clearInput").mockImplementation(() => {}),
    spyOn(socket, "isConnected").mockReturnValue(true),
    spyOn(socket, "broadcast").mockImplementation(() => {}),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(health, "synthesizeWithRetry").mockImplementation(async (_text, _voice, _rate, path) => {
      writeFileSync(path, "synthetic audio");
      return { success: true, attempts: 1, audioFile: path, wordBoundaries: [] };
    }),
    spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({ result: Promise.resolve(undefined), cancel: () => {} }),
    spyOn(Bun, "spawn").mockImplementation(() => spawn([process.execPath, "-e", ""], { env: process.env, stdout: "ignore", stderr: "ignore" })),
    spyOn(input, "waitForInput").mockImplementation(async (_ms, _mode, _push, options) => {
      for (const stage of ["recorder_spawn", "first_pcm", "first_vad_speech", "end_decision", "recorder_exit_confirmed", "stt_start", "stt_end"] as const) traceStage(options?.signal, stage);
      return "private answer";
    }));
  const result = await handleVoiceAsk({ message: "private question", voice: "en-US-JennyNeural" });
  expect(result.isError).not.toBe(true);
  const raw = readFileSync(file, "utf8");
  const events = raw.trim().split("\n").map(line => JSON.parse(line));
  expect(events.map(event => event.stage)).not.toContain("tool_result_emitted");
  expect(events.map(event => event.stage)).toEqual(["tool_received", "admission_done", "drain_start", "drain_end", "synth_start", "probe_start", "probe_end", "synth_end", "probe_start", "probe_end", "job_queued", "envelope_start", "envelope_end", "probe_start", "probe_end", "player_spawn", "player_exit_confirmed", "recorder_spawn", "first_pcm", "first_vad_speech", "end_decision", "recorder_exit_confirmed", "stt_start", "stt_end", "handler_returned"]);
  expect(new Set(events.map(event => event.request_id)).size).toBe(1);
  expect(raw).not.toContain("private");
  for (let i = 1; i < events.length; i++) expect(BigInt(events[i].monotonic_ns)).toBeGreaterThanOrEqual(BigInt(events[i - 1].monotonic_ns));
});

it("off writes nothing; unknown content fields cannot leak; exit rejection is not proof", async () => {
  delete process.env.VOICELAYER_TRACE_FILE;
  const source = {};
  traceStage(source, "tool_received");
  expect(existsSync(file)).toBe(false);
  process.env.VOICELAYER_TRACE_FILE = file;
  traceStage(source, "tool_received", JSON.parse('{"prompt":"private","transcript":"private","audio":"private"}'));
  const child = {}; linkVoiceTrace(source, child);
  traceStageOnce(child, "first_pcm"); traceStageOnce(child, "first_pcm");
  traceExit(child, "recorder_exit_confirmed", Promise.reject(new Error("private")));
  await Promise.resolve();
  expect(readFileSync(file, "utf8")).not.toContain("private");
  expect(readFileSync(file, "utf8").match(/first_pcm/g)).toHaveLength(1);
  expect(readFileSync(file, "utf8")).not.toContain("recorder_exit_confirmed");
  traceExit(child, "recorder_exit_confirmed", Promise.resolve(0));
  await Promise.resolve();
  expect(readFileSync(file, "utf8")).toContain("recorder_exit_confirmed");
  process.env.VOICELAYER_TRACE_FILE = join(root, "missing", "trace");
  expect(() => traceStage(child, "end_decision")).not.toThrow();
});

it("analyzer computes clock-local spans and refuses guessed onset/last speech", () => {
  const fixture = ["tool_received", "player_spawn", "player_exit_confirmed", "first_pcm", "first_vad_speech", "end_decision", "tool_result_emitted"]
    .map((stage, i) => JSON.stringify({ request_id: "fixture", stage, monotonic_ns: String(BigInt(i) * 1_000_000n) })).join("\n");
  const output = analyzeVoiceTrace(fixture);
  expect(output).toContain("tool→player_spawn (proxy): 1.000 ms");
  expect(output).toContain("question_end→first_pcm: 1.000 ms");
  expect(output).toContain("output onset: UNMEASURED");
  expect(output).toContain("last_speech→tool_result: UNMEASURED");
  expect(output).toContain("recorder_exit_confirmed: UNMEASURED");
  writeFileSync(file, fixture);
  const cli = Bun.spawnSync([process.execPath, "scripts/measure-voice-turn-latency.ts", file], { env: process.env });
  expect(cli.exitCode).toBe(0); expect(cli.stdout.toString()).toContain(output);
  const clocks = fixture.split("\n").map((line, i) => JSON.stringify({ ...JSON.parse(line), clock_id: i + 1 })).join("\n");
  expect(analyzeVoiceTrace(clocks)).not.toMatch(/proxy\): \d/);
  expect(analyzeVoiceTrace(fixture + '\n' + JSON.stringify({ request_id: "fixture", stage: "last_speech", monotonic_ns: "4500000" }))).toContain("last_speech→tool_result: 1.500 ms");
  const handlerOnly = fixture.replace("tool_result_emitted", "handler_returned") + '\n' +
    JSON.stringify({ request_id: "fixture", stage: "last_speech", monotonic_ns: "4500000" });
  expect(analyzeVoiceTrace(handlerOnly)).toContain("last_speech→tool_result: UNMEASURED");
});

it("native PCM is traced before VAD; recorder exit waits for the real child", async () => {
  process.env.VOICELAYER_TRACE_FILE = file;
  const signal = new AbortController().signal;
  traceStage(signal, "tool_received");
  const spawn = Bun.spawn;
  let child: ReturnType<typeof Bun.spawn> | undefined;
  let calls = 0;
  spies.push(spyOn(socket, "broadcast").mockImplementation(() => {}),
    spyOn(recorder, "resolveRecorderBinary").mockReturnValue("synthetic-rec"),
    spyOn(audio, "detectNativeInputFormat").mockReturnValue({ sampleRate: 16000, channels: 1 }),
    spyOn(vad, "resetVAD").mockResolvedValue(undefined),
    spyOn(vad, "processVADChunk").mockImplementation(async () => {
      expect(readFileSync(file, "utf8")).toContain("first_pcm");
      return calls++ === 0 ? 0.99 : 0;
    }),
    spyOn(Bun, "spawn").mockImplementation(() => {
      child = spawn([process.execPath, "-e", 'process.stdout.write(Buffer.alloc(1024 * 30)); setInterval(() => {}, 1000)'], { env: process.env, stdout: "pipe", stderr: "pipe" });
      return child;
    }));
  try {
    expect(await input.recordToBuffer(2000, "quick", false, undefined, signal)).toBeInstanceOf(Uint8Array);
  } finally {
    child?.kill(); await child?.exited;
  }
  await Promise.resolve();
  const events = readFileSync(file, "utf8").trim().split("\n").map(line => JSON.parse(line).stage);
  expect(events).toEqual(["tool_received", "recorder_spawn", "first_pcm", "first_vad_speech", "end_decision", "recorder_exit_confirmed"]);
}, 5000);

it("real queue hooks surround synthetic decode and a silent player child", async () => {
  process.env.VOICELAYER_TRACE_FILE = file;
  const archive = beginSpeechArchive("private question");
  traceStage(archive, "tool_received");
  const spawn = Bun.spawn;
  spies.push(spyOn(socket, "broadcast").mockImplementation(() => {}),
    spyOn(amplitude, "startPlaybackAmplitudeEnvelopeExtraction").mockReturnValue({ result: Promise.resolve(undefined), cancel: () => {} }),
    spyOn(Bun, "spawn").mockImplementation(() => spawn([process.execPath, "-e", ""], { env: process.env, stdout: "ignore", stderr: "ignore" })));
  try {
    const player = tts.playAudioNonBlocking(join(root, "synthetic.mp3"), { speechArchive: archive, text: "private question", voice: "fixture" });
    await player.exited; await player.playerExited;
    const stages = readFileSync(file, "utf8").trim().split("\n").map(line => JSON.parse(line).stage);
    expect(stages).toEqual(["tool_received", "job_queued", "envelope_start", "envelope_end", "probe_start", "probe_end", "player_spawn", "player_exit_confirmed"]);
  } finally {
    tts.stopPlayback(); await tts.awaitCurrentPlayback(); await flushSpeechArchives();
  }
}, 5000);
