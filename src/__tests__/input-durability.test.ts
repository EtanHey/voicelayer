import { afterEach, beforeEach, expect, it, spyOn } from "bun:test";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { diagnosticLeaks } from "./setup/privacy-canary";
import { createHash } from "crypto";
import {
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  symlinkSync,
  writeSync,
  writeFileSync,
} from "fs";
import * as fsModule from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  clearCancelSignal,
  clearStopSignal,
  setCancelSignal,
} from "../session-booking";
import { STOP_FILE } from "../paths";
import * as paths from "../paths";
import * as socketClient from "../socket-client";
import * as stt from "../stt";
import * as sttPolish from "../stt-polish";
import * as tts from "../tts";
import * as vad from "../vad";
import * as voiceBarLauncher from "../voice-bar-launcher";

// Real subprocesses: standalone p95 <= 353 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

const VAD_CHUNK_SAMPLES = 512;
const VAD_CHUNK_BYTES = VAD_CHUNK_SAMPLES * 2;

let vadMode: "silence" | "throw" = "silence";
let onVadCall: (() => void) | null = null;
let vadCallCount = 0;
let vadProbabilityForCall: ((call: number) => number) | null = null;
let backendMode: "ok" | "throw-on-get" | "hang" = "ok";
let backendTranscribeCalls = 0;
let backendTranscribedDataSize: number | undefined;
let backendTranscribedFileBytes: number | undefined;
let backendText = "retained transcript";
let finishHangingTranscription: (() => void) | undefined;
let broadcasts: any[] = [];
let vadProcessSpy: ReturnType<typeof spyOn> | undefined;
let vadResetSpy: ReturnType<typeof spyOn> | undefined;
let getBackendSpy: ReturnType<typeof spyOn> | undefined;
let broadcastSpy: ReturnType<typeof spyOn> | undefined;
let polishSpy: ReturnType<typeof spyOn> | undefined;
let polishSurfaces: string[] = [];

const originalSpawn = Bun.spawn;
const originalSpawnSync = Bun.spawnSync;

function makePcmChunk(sample = 1200): Uint8Array {
  const chunk = new Uint8Array(VAD_CHUNK_BYTES);
  const view = new DataView(chunk.buffer);
  for (let offset = 0; offset < chunk.byteLength; offset += 2) {
    view.setInt16(offset, sample, true);
  }
  return chunk;
}

function makeWav(pcmData: Uint8Array): Uint8Array {
  const wav = new Uint8Array(44 + pcmData.byteLength);
  const view = new DataView(wav.buffer);
  writeAscii(wav, 0, "RIFF");
  view.setUint32(4, 36 + pcmData.byteLength, true);
  writeAscii(wav, 8, "WAVE");
  writeAscii(wav, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true);
  view.setUint32(28, 32000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(wav, 36, "data");
  view.setUint32(40, pcmData.byteLength, true);
  wav.set(pcmData, 44);
  return wav;
}

function makeWavWithListChunkBeforeData(pcmData: Uint8Array): Uint8Array {
  const listPayload = 4;
  const extraChunkBytes = 8 + listPayload;
  const wav = new Uint8Array(44 + extraChunkBytes + pcmData.byteLength);
  const view = new DataView(wav.buffer);
  writeAscii(wav, 0, "RIFF");
  view.setUint32(4, 36 + extraChunkBytes + pcmData.byteLength, true);
  writeAscii(wav, 8, "WAVE");
  writeAscii(wav, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16000, true);
  view.setUint32(28, 32000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(wav, 36, "LIST");
  view.setUint32(40, listPayload, true);
  writeAscii(wav, 44, "INFO");
  writeAscii(wav, 48, "data");
  view.setUint32(52, pcmData.byteLength, true);
  wav.set(pcmData, 56);
  return wav;
}

function pcmWithConstantSample(sample: number, durationMs: number): Uint8Array {
  const samples = Math.floor((16000 * durationMs) / 1000);
  const buffer = new Uint8Array(samples * 2);
  const view = new DataView(buffer.buffer);
  for (let i = 0; i < samples; i++) {
    view.setInt16(i * 2, sample, true);
  }
  return buffer;
}

function makePttWavWithLongQuietTail(): Uint8Array {
  const speech = pcmWithConstantSample(2000, 2000);
  const quietTail = pcmWithConstantSample(0, 9000);
  const pcm = new Uint8Array(speech.byteLength + quietTail.byteLength);
  pcm.set(speech);
  pcm.set(quietTail, speech.byteLength);
  return makeWav(pcm);
}

function writeAscii(buffer: Uint8Array, offset: number, text: string): void {
  for (let index = 0; index < text.length; index++) {
    buffer[offset + index] = text.charCodeAt(index);
  }
}

function readAscii(buffer: Buffer, start: number, end: number): string {
  return buffer.subarray(start, end).toString("ascii");
}

function readWavDataSize(path: string): number {
  const retained = readFileSync(path);
  const view = new DataView(
    retained.buffer,
    retained.byteOffset,
    retained.byteLength,
  );
  return view.getUint32(40, true);
}

function expectValidRetainedWav(
  path: string,
  expectedDataBytes?: number,
): void {
  const retained = readFileSync(path);
  expect(retained.byteLength).toBeGreaterThan(44);
  expect(readAscii(retained, 0, 4)).toBe("RIFF");
  expect(readAscii(retained, 8, 12)).toBe("WAVE");
  expect(readAscii(retained, 36, 40)).toBe("data");

  const view = new DataView(
    retained.buffer,
    retained.byteOffset,
    retained.byteLength,
  );
  const riffSize = view.getUint32(4, true);
  const dataSize = view.getUint32(40, true);
  expect(riffSize).toBe(retained.byteLength - 8);
  expect(dataSize).toBeGreaterThan(0);
  expect(dataSize).toBe(retained.byteLength - 44);
  if (expectedDataBytes !== undefined) {
    expect(dataSize).toBe(expectedDataBytes);
  }
}

function rewriteWavHeaderDataSize(path: string, dataSize: number): void {
  const fd = openSync(path, "r+");
  try {
    const riffSize = Buffer.alloc(4);
    riffSize.writeUInt32LE(36 + dataSize, 0);
    const dataSizeBytes = Buffer.alloc(4);
    dataSizeBytes.writeUInt32LE(dataSize, 0);
    writeSync(fd, riffSize, 0, riffSize.byteLength, 4);
    writeSync(fd, dataSizeBytes, 0, dataSizeBytes.byteLength, 40);
  } finally {
    closeSync(fd);
  }
}

async function waitUntil(
  predicate: () => boolean,
  label: string,
  timeoutMs = 500,
): Promise<void> {
  const startedAt = performance.now();
  while (!predicate()) {
    if (performance.now() - startedAt > timeoutMs) {
      throw new Error(`Timed out waiting for ${label}`);
    }
    await Bun.sleep(1);
  }
}

function installFakeRecorder(chunks: Uint8Array[], keepStdoutOpen: boolean, beforeMicOpen?: () => void) {
  let spawned = false;
  let stdoutController: ReadableStreamDefaultController<Uint8Array> | undefined;
  let stderrController: ReadableStreamDefaultController<Uint8Array> | undefined;

  Bun.spawnSync = ((cmd: string[]) => {
    if (cmd[0] === "which" && cmd[1] === "rec") {
      return {
        exitCode: 0,
        stdout: Buffer.from("/tmp/fake-rec\n"),
        stderr: new Uint8Array(),
        success: true,
      };
    }
    if (cmd[0] === "/tmp/fake-rec" && cmd.includes("-n")) {
      return {
        exitCode: 0,
        stdout: new Uint8Array(),
        stderr: Buffer.from("Sample Rate : 16000\nChannels : 1\n"),
        success: true,
      };
    }
    return originalSpawnSync(cmd, { env: process.env });
  }) as typeof Bun.spawnSync;

  Bun.spawn = (() => {
    beforeMicOpen?.();
    spawned = true;
    return {
      stdout: new ReadableStream<Uint8Array>({
        start(controller) {
          stdoutController = controller;
          for (const chunk of chunks) {
            controller.enqueue(chunk);
          }
          if (!keepStdoutOpen) {
            controller.close();
          }
        },
      }),
      stderr: new ReadableStream<Uint8Array>({
        start(controller) {
          stderrController = controller;
          controller.close();
        },
      }),
      kill: () => {
        try {
          stdoutController?.close();
        } catch {}
        try {
          stderrController?.close();
        } catch {}
      },
      exited: Promise.resolve(0),
    };
  }) as typeof Bun.spawn;

  return {
    waitForSpawn: () => waitUntil(() => spawned, "fake recorder spawn"),
    push: (chunk: Uint8Array) => stdoutController!.enqueue(chunk),
    /** The recorder exiting on its own: stdout EOF before our teardown. */
    end: () => stdoutController!.close(),
  };
}

// Only recording deadlines/polls use the fake clock; stream processing and
// recorder cleanup keep their real scheduling. No microphone or live paths.
function installRecordingClock(deadlineDurations = [90_000]) {
  let now = 0;
  let poll = () => {};
  const deadlines = new Map<ReturnType<typeof setTimeout>, { at: number; run: () => void }>();
  const realTimeout = globalThis.setTimeout;
  const realClearTimeout = globalThis.clearTimeout;
  const realInterval = globalThis.setInterval;
  const nowSpy = spyOn(Date, "now").mockImplementation(() => now);
  const timeoutSpy = spyOn(globalThis, "setTimeout").mockImplementation(((run: () => void, ms: number) => {
    if (!deadlineDurations.includes(ms)) return realTimeout(run, ms);
    const handle = realTimeout(() => {}, ms);
    deadlines.set(handle, { at: now + ms, run });
    return handle;
  }) as typeof setTimeout);
  const clearSpy = spyOn(globalThis, "clearTimeout").mockImplementation((handle) => {
    deadlines.delete(handle as ReturnType<typeof setTimeout>);
    realClearTimeout(handle);
  });
  const intervalSpy = spyOn(globalThis, "setInterval").mockImplementation(((run: () => void, ms: number) => {
    if (ms !== 50) return realInterval(run, ms);
    poll = run;
    return realInterval(() => {}, 90_000);
  }) as typeof setInterval);
  return {
    advance(ms: number) {
      now += ms;
      poll();
      for (const [handle, deadline] of [...deadlines]) {
        if (deadline.at <= now && deadlines.has(handle)) {
          deadlines.delete(handle);
          realClearTimeout(handle);
          deadline.run();
        }
      }
    },
    restore() {
      for (const handle of deadlines.keys()) realClearTimeout(handle);
      nowSpy.mockRestore();
      timeoutSpy.mockRestore();
      clearSpy.mockRestore();
      intervalSpy.mockRestore();
    },
  };
}

describe("input recording durability", () => {
  let tmpRoot: string;
  let retainedPath: string;
  let savedRetainedPath: string | undefined;
  let savedRecordingsDir: string | undefined;
  let savedRecordingStatePath: string | undefined;
  let savedRecordingHoldPath: string | undefined;

  for (const [label, source, pushToEnd, physicalPress] of [
    ["physical dictation", "voicebar", true, true],
    ["physical chunked", "voicebar", true, true],
    ["physical no click", "voicebar", true, true],
    ["legacy stop", "voicebar", true, false],
    ["Ask push_to_end", "voice_ask", true, true],
    ["VAD dictation", "voicebar", false, true],
    ["timeout", "voicebar", true, true],
    ["cancel", "voicebar", true, true],
  ] as const) {
    it(`P5b ${label}: STT cutoff is scoped and archive keeps every byte`, async () => {
      const { waitForInput } = await import("../input");
      const { handleSocketCommand } = await import("../socket-handlers");
      const { parseCommand } = await import("../socket-protocol");
      const durationMs = label === "physical no click" ? 11000 : 2400;
      const pcm = pcmWithConstantSample(1500, durationMs);
      const view = new DataView(pcm.buffer);
      for (let i = 2000 * 16; i < durationMs * 16; i++) view.setInt16(i * 2, 10, true);
      if (label !== "physical no click") for (let i = 0; i < 320; i++) view.setInt16((2150 * 16 + i) * 2, (i % 2 ? -1 : 1) * 9000 * Math.exp(-i / 55), true);
      const expectedArchive = makeWav(pcm);
      const recorder = installFakeRecorder([pcm], true);
      const stopSpy = spyOn(tts, "stopPlayback").mockImplementation(() => {});
      const playbackSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined);
      const savedChunked = process.env.QA_VOICE_CHUNKED_STT;
      process.env.QA_VOICE_CHUNKED_STT = label === "physical chunked" ? "1" : "0";
      vadProbabilityForCall = () => 0.95;
      let archivePath = "";
      const recording = waitForInput(label === "timeout" ? 80 : 4000, "thoughtful", pushToEnd, {
        archiveSource: source,
        ...(source === "voice_ask" ? { voiceAskArtifacts: {
          agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]), agentAudioFormat: "mp3" as const,
          agentTranscript: "Synthetic question", agentTtsEngine: "edge-tts" as const, agentTtsVoice: "fixture",
        } } : {}),
        onArchiveCreated: path => { archivePath = path; },
      });
      try {
        await recorder.waitForSpawn();
        await Bun.sleep(20);
        if (label === "cancel") setCancelSignal();
        if (label !== "timeout") await handleSocketCommand(parseCommand(JSON.stringify({ cmd: "stop", ...(physicalPress ? { physical_press: true } : {}) }))!);
        await recording;
        expect(readFileSync(join(archivePath, "audio.wav"))).toEqual(Buffer.from(expectedArchive));
        expect(backendTranscribedDataSize).toBe(label === "cancel" ? undefined :
          (label === "physical no click" ? durationMs : label.startsWith("physical") ? 2145 : 2400) * 32);
      } finally {
        await recording.catch(() => null);
        stopSpy.mockRestore(); playbackSpy.mockRestore();
        if (savedChunked === undefined) delete process.env.QA_VOICE_CHUNKED_STT;
        else process.env.QA_VOICE_CHUNKED_STT = savedChunked;
      }
    }, SUBPROCESS_TEST_TIMEOUT_MS);
  }

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(process.env.PRIV11_PRIVATE_ROOT ?? tmpdir(),
      process.env.PRIV11_NONCE ? `CANARY-HOME-${process.env.PRIV11_NONCE}-` : "voicelayer-input-durability-"));
    retainedPath = join(tmpRoot, "last-recording.wav");
    savedRetainedPath = process.env.QA_VOICE_RETAINED_RECORDING_PATH;
    savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
    savedRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
    savedRecordingHoldPath = process.env.QA_VOICE_RECORDING_HOLD_PATH;
    process.env.QA_VOICE_RETAINED_RECORDING_PATH = retainedPath;
    process.env.QA_VOICE_RECORDINGS_DIR = join(tmpRoot, "recordings");
    process.env.QA_VOICE_RECORDING_STATE_PATH = join(
      tmpRoot,
      "recording-state.json",
    );
    process.env.QA_VOICE_RECORDING_HOLD_PATH = join(tmpRoot, "recording-hold");
    vadMode = "silence";
    onVadCall = null;
    vadCallCount = 0;
    vadProbabilityForCall = null;
    backendMode = "ok";
    backendTranscribeCalls = 0;
    backendTranscribedDataSize = undefined;
    backendTranscribedFileBytes = undefined;
    backendText = "retained transcript";
    finishHangingTranscription = undefined;
    broadcasts = [];
    polishSurfaces = [];
    vadProcessSpy = spyOn(vad, "processVADChunk").mockImplementation(
      async () => {
        vadCallCount++;
        onVadCall?.();
        if (vadMode === "throw") {
          throw new Error("vad exploded after capture");
        }
        return vadProbabilityForCall?.(vadCallCount) ?? 0;
      },
    );
    vadResetSpy = spyOn(vad, "resetVAD").mockImplementation(async () => {});
    getBackendSpy = spyOn(stt, "getBackend").mockImplementation(async () => {
      if (backendMode === "throw-on-get") {
        throw new Error("whisper backend is still warming");
      }
      return {
        name: "fake-stt",
        isAvailable: async () => true,
        transcribe: async (path: string) => {
          backendTranscribeCalls++;
          backendTranscribedDataSize = readWavDataSize(path);
          backendTranscribedFileBytes = readFileSync(path).byteLength;
          if (backendMode === "hang") {
            await new Promise<void>((resolve) => {
              finishHangingTranscription = resolve;
            });
          }
          return {
            text: backendText,
            backend: "fake-stt",
            durationMs: 1,
          };
        },
      };
    });
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (message: any) => {
        broadcasts.push(message);
      },
    );
    polishSpy = spyOn(sttPolish, "polishTranscriptionText").mockImplementation(
      async (input) => {
        const surface = input.surface ?? "dictation";
        polishSurfaces.push(surface);
        return {
          inputText: input.cleanedText,
          text: input.cleanedText,
          polishedText: null,
          mode: "on",
          status: "skipped",
          surface,
          changed: false,
          retried: false,
          latencyMs: 0,
          polished: false,
          reason: "test-double",
        };
      },
    );
    clearStopSignal();
    clearCancelSignal();
  });

  afterEach(() => {
    vadProcessSpy?.mockRestore();
    vadResetSpy?.mockRestore();
    getBackendSpy?.mockRestore();
    broadcastSpy?.mockRestore();
    polishSpy?.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
    clearStopSignal();
    clearCancelSignal();
    if (process.env.PRIV11_NONCE) {
      const tokens = [`CANARY-TXT-${process.env.PRIV11_NONCE}`, `CANARY-HOME-${process.env.PRIV11_NONCE}`];
      expect(diagnosticLeaks(tmpRoot, tokens, tmpRoot), "Canary in diagnostics before fixture cleanup").toEqual([]);
    }
    rmSync(tmpRoot, { recursive: true, force: true });
    if (savedRetainedPath === undefined) {
      delete process.env.QA_VOICE_RETAINED_RECORDING_PATH;
    } else {
      process.env.QA_VOICE_RETAINED_RECORDING_PATH = savedRetainedPath;
    }
    if (savedRecordingsDir === undefined) {
      delete process.env.QA_VOICE_RECORDINGS_DIR;
    } else {
      process.env.QA_VOICE_RECORDINGS_DIR = savedRecordingsDir;
    }
    if (savedRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = savedRecordingStatePath;
    }
    if (savedRecordingHoldPath === undefined) {
      delete process.env.QA_VOICE_RECORDING_HOLD_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_HOLD_PATH = savedRecordingHoldPath;
    }
  });

  for (const surface of ["dictation", "voice_ask", "archived", "retained"] as const) {
    for (const suppressed of [false, true]) {
      it(`PRIV11 PRIV1 R2 ${surface} ${suppressed ? "suppressed" : "final"} logs metadata while retaining content`, async () => {
        const input = await import("../input");
        backendText = suppressed ? "music playing" : `PRIVATE_TRANSCRIPT_שלום ${process.env.PRIV11_TEXT ?? "keep my words"}.`;
        const originalError = console.error;
        const log = spyOn(console, "error").mockImplementation((...args) => {
          if (process.env.PRIV11_CHILD) originalError(...args);
        });
        let archiveDir: string | undefined;
        let result: string | null;
        try {
          if (surface === "archived") {
            archiveDir = join(process.env.QA_VOICE_RECORDINGS_DIR!, "2026-06-25", "2026-06-25T10-11-12-000Z-abcd1234");
            mkdirSync(archiveDir, { recursive: true });
            const audioPath = join(archiveDir, "audio.wav");
            writeFileSync(audioPath, makeWav(makePcmChunk()));
            backendMode = "hang";
            const pending = input.retranscribeRecordingCapture(audioPath);
            await waitUntil(() => finishHangingTranscription !== undefined, "private archived result");
            finishHangingTranscription!();
            result = await pending;
          } else if (surface === "retained") {
            writeFileSync(retainedPath, makeWav(makePcmChunk()));
            result = await input.retranscribeLastCapture();
          } else {
            vadProcessSpy.mockResolvedValue(0.95);
            installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
            result = await input.waitForInput(2_000, "standard", true, {
              archiveSource: surface === "voice_ask" ? "voice_ask" : "voicebar",
              ...(surface === "voice_ask" ? { voiceAskArtifacts: {
                agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]), agentAudioFormat: "mp3" as const,
                agentTranscript: process.env.PRIV11_TEXT ?? "Synthetic private question", agentTtsEngine: "edge-tts" as const, agentTtsVoice: "fixture",
              } } : {}),
              onArchiveCreated: path => { archiveDir = path; },
            });
          }
          if (surface === "dictation" && !suppressed && archiveDir) {
            await waitUntil(() => broadcasts.some(e => e.type === "archive_metadata_updated" &&
              e.recording_path === join(archiveDir!, "audio.wav")), "deferred archive metadata write");
          }
          const output = log.mock.calls.flat().join("\n");
          expect(output).not.toContain(backendText);
          expect(output).not.toContain("PRIVATE_TRANSCRIPT");
          expect(output).not.toContain(tmpRoot);
          expect(output).toContain(`chars=${result?.length ?? 0}`);
          if (suppressed) {
            expect(result).toBeNull();
            expect(output).toContain("Suppressed non-meaningful");
          } else {
            expect(result).toContain("PRIVATE_TRANSCRIPT");
            const event = broadcasts.find(e => e.type === "transcription");
            expect(event?.text).toBe(result);
            if (archiveDir) {
              expect(event?.recording_path).toBe(join(archiveDir, "audio.wav"));
              expect(readFileSync(join(archiveDir, "voicelayer-transcript.txt"), "utf8")).toBe(result!);
            }
          }
        } finally { log.mockRestore(); }
      });
    }
  }

  for (const failure of ["invalid path", "backend error"] as const) {
    it(`PRIV1 R2 rejected retranscribe_recording ${failure} never echoes its WAV path`, async () => {
      const { handleSocketCommand } = await import("../socket-handlers");
      const { setRecordingState } = await import("../recording-state");
      setRecordingState("idle");
      const audioPath = failure === "invalid path"
        ? join(tmpRoot, "PRIVATE_OWNER", "rejected.wav")
        : join(process.env.QA_VOICE_RECORDINGS_DIR!, "2026-06-25", "2026-06-25T10-11-12-000Z-abcd1234", "audio.wav");
      if (failure === "backend error") {
        mkdirSync(join(audioPath, ".."), { recursive: true });
        writeFileSync(audioPath, makeWav(makePcmChunk()));
        backendMode = "throw-on-get";
      }
      const log = spyOn(console, "error").mockImplementation(() => {});
      try {
        expect(await handleSocketCommand({ cmd: "retranscribe_recording", audio_path: audioPath })).toMatchObject({ outcome: "accept" });
        await waitUntil(() => log.mock.calls.some(c => String(c[0]).includes("Retranscribe archived recording failed")), "private rejection log");
        const output = log.mock.calls.flat().join("\n");
        expect(output).not.toContain(audioPath);
        expect(output).not.toContain(tmpRoot);
        expect(output).not.toContain("PRIVATE_OWNER");
        // Error replies stay actionable; only the console sink is redacted.
        expect(broadcasts.some(e => e.type === "error" && e.message.includes(audioPath))).toBe(true);
      } finally { log.mockRestore(); }
    });
  }

  it("PRIV11 archive diagnostics omit corrupt metadata content and filesystem error paths", async () => {
    const input = await import("../input");
    backendText = process.env.PRIV11_TEXT ? `${process.env.PRIV11_TEXT}.` : "Synthetic private transcript.";
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    broadcastSpy!.mockImplementation((event: any) => {
      broadcasts.push(event);
      if (event.type === "transcription") {
        const metadata = event.recording_path.replace("audio.wav", "metadata.json");
        rmSync(metadata); mkdirSync(metadata); // Deferred spoken-duration write must fail.
      }
    });
    const originalError = console.error;
    const log = spyOn(console, "error").mockImplementation((...args) => originalError(...args));
    try {
      const result = await input.waitForInput(2_000, "standard", true, { archiveSource: "voicebar" });
      expect(result).toBe(backendText);
      await waitUntil(() => log.mock.calls.some(call => String(call[0]).startsWith(
        "[voicelayer] Failed to record spoken length:")), "deferred spoken-duration failure");
    } finally { log.mockRestore(); }
    const audioPath = capturedVoiceBarAudio()[0];
    const metadata = audioPath.replace("audio.wav", "metadata.json");
    rmSync(metadata, { recursive: true });
    writeFileSync(metadata, `invalid ${backendText}`);
    input.updateArchivedTranscript(audioPath, backendText, { backend: "fake-stt", languageMode: "auto" });
    expect(readFileSync(audioPath.replace("audio.wav", "voicelayer-transcript.txt"), "utf8")).toBe(backendText);
  });

  it("keeps recording idle when stale HOLD cleanup fails before capture", async () => {
    const holdPath = process.env.QA_VOICE_RECORDING_HOLD_PATH!;
    mkdirSync(holdPath);
    const { getRecordingState, recordToBuffer } = await import("../input");

    await expect(recordToBuffer(1000, "quick", false)).rejects.toThrow();

    expect(getRecordingState()).toBe("idle");
  });

  it("keeps push-to-end capture open through VAD-length silence until explicit stop", async () => {
    const quickSilenceChunks = vad.silenceChunksForMode("quick");
    const chunks = [
      makePcmChunk(1800),
      ...Array.from({ length: quickSilenceChunks + 2 }, () => makePcmChunk(0)),
    ];
    const recorder = installFakeRecorder(chunks, true);
    const { recordToBuffer } = await import("../input");
    let recordingSettled = false;
    const recording = recordToBuffer(2_000, "quick", true).finally(() => {
      recordingSettled = true;
    });

    try {
      await recorder.waitForSpawn();
      await waitUntil(
        () =>
          existsSync(retainedPath) &&
          readWavDataSize(retainedPath) === VAD_CHUNK_BYTES * chunks.length,
        "push-to-end PCM persistence",
      );

      expect(vadCallCount).toBe(0);
      expect(recordingSettled).toBe(false);

      writeFileSync(STOP_FILE, "stop");
      await expect(recording).resolves.toBeInstanceOf(Uint8Array);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }
  });

  for (const pushToEnd of [true, false]) {
    it(`keeps the event loop responsive when a ${pushToEnd ? "push-to-end" : "VAD"} recorder stalls without EOF`, async () => {
      const chunks = Array.from({ length: 25 }, () => makePcmChunk(1800));
      if (!pushToEnd) {
        vadProbabilityForCall = () => 0.95;
      }
      const recorder = installFakeRecorder(chunks, true);
      const { recordToBuffer } = await import("../input");
      let intervalTicks = 0;
      let stopWrittenAt = 0;
      let consumedAtTick = 0;
      const interval = setInterval(() => {
        intervalTicks += 1;
        if (intervalTicks === 5) {
          stopWrittenAt = Date.now();
          writeFileSync(STOP_FILE, "stop");
        } else if (stopWrittenAt > 0 && consumedAtTick === 0 && !existsSync(STOP_FILE)) {
          consumedAtTick = intervalTicks;
        }
      }, 10);
      const recording = recordToBuffer(2_000, "thoughtful", pushToEnd);

      try {
        await recorder.waitForSpawn();
        await waitUntil(
          () =>
            existsSync(retainedPath) &&
            readWavDataSize(retainedPath) === VAD_CHUNK_BYTES * chunks.length,
          "stalled recorder PCM persistence",
        );
        await waitUntil(
          () => consumedAtTick > 0,
          "event-loop stop poll during recorder stall",
        );

        expect(intervalTicks).toBeGreaterThanOrEqual(5);
        // Stop latency in event-loop turns, not wall-clock ms: the recorder's stop
        // poll must run within ~20 loop turns (~200 ms unloaded) of the stop, and
        // the bound scales with load instead of failing on a busy CI runner.
        expect(consumedAtTick - 5).toBeLessThanOrEqual(20);
        const captured = await Promise.race([
          recording,
          Bun.sleep(10_000).then(() => "timed-out" as const),
        ]);
        expect(captured).not.toBe("timed-out");
        expect(captured).toBeInstanceOf(Uint8Array);
        expect((captured as Uint8Array).byteLength).toBe(
          VAD_CHUNK_BYTES * 25,
        );
      } finally {
        clearInterval(interval);
        writeFileSync(STOP_FILE, "stop");
        await recording.catch(() => null);
        clearStopSignal();
      }
    });
  }

  for (const pushToEnd of [true, false]) {
    it(`keeps the event loop responsive when a real child pipe stalls in ${pushToEnd ? "push-to-end" : "VAD"} mode`, async () => {
      if (!pushToEnd) {
        vadProbabilityForCall = () => 0.95;
      }
      const savedFakeRecBin = process.env.VOICELAYER_TEST_FAKE_REC_BIN;
      process.env.VOICELAYER_TEST_FAKE_REC_BIN = join(
        process.cwd(),
        "src",
        "__tests__",
        "setup",
        "fake-rec-stall.sh",
      );
      const { recordToBuffer } = await import("../input");
      const recording = recordToBuffer(4_000, "thoughtful", pushToEnd);
      let intervalTicks = 0;
      let stopWrittenAt = 0;
      let consumedAtTick = 0;
      let interval: ReturnType<typeof setInterval> | undefined;

      try {
        await waitUntil(
          () =>
            existsSync(retainedPath) &&
            readWavDataSize(retainedPath) === VAD_CHUNK_BYTES * 25,
          "real child recorder to enter its post-PCM stall",
          15_000,
        );
        interval = setInterval(() => {
          intervalTicks += 1;
          if (intervalTicks === 5) {
            stopWrittenAt = Date.now();
            writeFileSync(STOP_FILE, "stop");
          } else if (stopWrittenAt > 0 && consumedAtTick === 0 && !existsSync(STOP_FILE)) {
            consumedAtTick = intervalTicks;
          }
        }, 10);
        await waitUntil(
          () => consumedAtTick > 0,
          "event-loop stop poll during real child-pipe stall",
          5_000,
        );

        expect(intervalTicks).toBeGreaterThanOrEqual(5);
        // Stop latency in event-loop turns, not wall-clock ms: the recorder's stop
        // poll must run within ~20 loop turns (~200 ms unloaded) of the stop, and
        // the bound scales with load instead of failing on a busy CI runner.
        expect(consumedAtTick - 5).toBeLessThanOrEqual(20);
        const captured = await Promise.race([
          recording,
          Bun.sleep(10_000).then(() => "timed-out" as const),
        ]);
        expect(captured).not.toBe("timed-out");
        expect(captured).toBeInstanceOf(Uint8Array);
        expect((captured as Uint8Array).byteLength).toBe(
          VAD_CHUNK_BYTES * 25,
        );
      } finally {
        if (interval) clearInterval(interval);
        if (savedFakeRecBin === undefined) {
          delete process.env.VOICELAYER_TEST_FAKE_REC_BIN;
        } else {
          process.env.VOICELAYER_TEST_FAKE_REC_BIN = savedFakeRecBin;
        }
        writeFileSync(STOP_FILE, "stop");
        await recording.catch(() => null);
        clearStopSignal();
      }
      // AIDEV-NOTE: the waits above are transition waits; their deadlines and this timeout are liveness
      // only. Spawning the real child recorder overran 5 s under load (2 of 5 background-QoS runs with a
      // concurrent Swift build). The behaviour bound is the loop-turn count above.
    }, 30_000);
  }

  it("keeps the absent push-to-end default on VAD and auto-closes after silence", async () => {
    const quickSilenceChunks = vad.silenceChunksForMode("quick");
    const chunks = [
      makePcmChunk(1800),
      ...Array.from({ length: quickSilenceChunks }, () => makePcmChunk(0)),
    ];
    vadProbabilityForCall = (call) => (call === 1 ? 0.95 : 0);
    installFakeRecorder(chunks, true);
    const { recordToBuffer } = await import("../input");

    await expect(recordToBuffer(2_000, "quick")).resolves.toBeInstanceOf(
      Uint8Array,
    );
    expect(vadCallCount).toBe(chunks.length);
  });

  it("keeps live quick-mode capture open while held then closes after a fresh full countdown", async () => {
    const holdPath = process.env.QA_VOICE_RECORDING_HOLD_PATH!;
    const quickSilenceChunks = vad.silenceChunksForMode("quick");
    const heldSilentChunks = quickSilenceChunks + 2;
    const releaseCall = 2 + heldSilentChunks;
    const closingCall = releaseCall + quickSilenceChunks - 1;
    const chunks = Array.from(
      { length: 1 + heldSilentChunks + quickSilenceChunks },
      () => makePcmChunk(),
    );
    let recordingSettled = false;
    let sawHeldThreshold!: () => void;
    let sawFreshCountdown!: () => void;
    const heldThresholdObserved = new Promise<void>((resolve) => {
      sawHeldThreshold = resolve;
    });
    const freshCountdownObserved = new Promise<void>((resolve) => {
      sawFreshCountdown = resolve;
    });
    vadProbabilityForCall = (call) => (call === 1 ? 0.95 : 0);
    onVadCall = () => {
      if (vadCallCount === 1) {
        writeFileSync(holdPath, "hold", { mode: 0o600 });
      }
      if (vadCallCount === releaseCall) {
        expect(recordingSettled).toBe(false);
        expect(existsSync(holdPath)).toBe(true);
        sawHeldThreshold();
        rmSync(holdPath, { force: true });
      }
      if (vadCallCount === closingCall) {
        expect(recordingSettled).toBe(false);
        sawFreshCountdown();
      }
    };
    const recorder = installFakeRecorder(chunks, true);
    const { recordToBuffer } = await import("../input");
    const recording = recordToBuffer(2_000, "quick", false).finally(() => {
      recordingSettled = true;
    });

    try {
      await recorder.waitForSpawn();
      await expect(
        Promise.race([
          heldThresholdObserved.then(() => "held-threshold"),
          recording.then(() => "recording-settled"),
        ]),
      ).resolves.toBe("held-threshold");
      await freshCountdownObserved;
      await expect(recording).resolves.toBeInstanceOf(Uint8Array);
      expect(existsSync(holdPath)).toBe(false);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }
  });

  const timeoutPromptArtifacts = {
    agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
    agentAudioFormat: "mp3" as const,
    agentTranscript: "Synthetic timeout question",
    agentTtsEngine: "edge-tts" as const,
    agentTtsVoice: "en-US-JennyNeural",
  };

  // VA-TIMEOUT: fail-first specification tests. These exercise the real
  // waitForInput/recordToBuffer path with synthetic PCM and an isolated archive.
  for (const silenceMode of ["quick", "standard", "thoughtful"] as const) {
    it(`VA-TIMEOUT speech cancels the no-speech deadline until ${silenceMode} silence`, async () => {
      const { waitForInput, getRecordingState } = await import("../input");
      const recorder = installFakeRecorder([], true);
      const clock = installRecordingClock();
      const abort = new AbortController();
      let archivePath: string | undefined;
      let settled = false;
      vadProbabilityForCall = (call) => call <= 25 ? 0.95 : 0;
      const recording = waitForInput(90_000, silenceMode, false, {
        archiveSource: "voice_ask",
        voiceAskArtifacts: timeoutPromptArtifacts,
        signal: abort.signal,
        onArchiveCreated: (path) => { archivePath = path; },
      }).finally(() => { settled = true; });
      void recording.catch(() => null);
      try {
        await recorder.waitForSpawn();
        for (let i = 0; i < 25; i++) recorder.push(makePcmChunk(1800));
        await waitUntil(() => vadCallCount === 25, "speech processed");
        expect(broadcasts.some((event) => event.type === "speech" && event.detected)).toBe(true);
        clock.advance(90_001);
        expect(getRecordingState()).toBe("recording");
        expect(settled).toBe(false);

        // Speech has arrived, so only the unchanged mode-specific silence
        // window should end this capture below the safety ceiling.
        const silenceChunks = vad.silenceChunksForMode(silenceMode);
        for (let i = 0; i < silenceChunks - 1; i++) recorder.push(makePcmChunk(0));
        await waitUntil(() => vadCallCount === 25 + silenceChunks - 1, "silence below threshold");
        expect(getRecordingState()).toBe("recording");
        recorder.push(makePcmChunk(0));
        expect(await recording).toBe("Retained transcript.");
        expectValidRetainedWav(join(archivePath!, "audio.wav"));
      } finally {
        abort.abort();
        await recording.catch(() => null);
        clock.restore();
      }
    });
  }

  it("VA-TIMEOUT detected speech also cancels the handler capture watchdog", async () => {
    const { handleConverse } = await import("../handlers");
    const { getRecordingState } = await import("../input");
    const sessionBooking = await import("../session-booking");
    const recorder = installFakeRecorder([], true);
    // Advance only the outer 90s + 15s watchdog. The inner 90s timer keeps
    // real scheduling, so it cannot mask whether the handler aborts speech.
    const clock = installRecordingClock([105_000]);
    const bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: true,
      ownedByUs: true,
      owner: { pid: process.pid, sessionId: "synthetic-timeout", startedAt: new Date().toISOString() },
    });
    const playbackSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined);
    const speakSpy = spyOn(tts, "speak").mockResolvedValue({
      displayText: "Synthetic outer-watchdog question",
      engine: "edge-tts",
      voice: "en-US-JennyNeural",
      audioArtifact: { bytes: new Uint8Array([0x49, 0x44, 0x33]), format: "mp3" },
    });
    let settled = false;
    vadProbabilityForCall = () => 0.95;
    const converse = handleConverse({ message: "Synthetic question?", timeout_seconds: 90 })
      .finally(() => { settled = true; });
    try {
      await recorder.waitForSpawn();
      for (let i = 0; i < 25; i++) recorder.push(makePcmChunk(1800));
      await waitUntil(() => vadCallCount === 25, "handler speech processed");
      expect(broadcasts.some((event) => event.type === "speech" && event.detected)).toBe(true);
      clock.advance(105_001);
      expect(getRecordingState()).toBe("recording");
      expect(settled).toBe(false);
      writeFileSync(STOP_FILE, "stop");
      clock.advance(0);
      const result = await converse;
      expect(result.isError).not.toBe(true);
      expect(JSON.stringify(result)).toContain("Retained transcript.");
      expectValidRetainedWav(retainedPath);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      clock.advance(0);
      await converse;
      speakSpy.mockRestore();
      playbackSpy.mockRestore();
      bookingSpy.mockRestore();
      clock.restore();
    }
  });

  it("VA-TIMEOUT no speech uses the configured mic-open budget instead of 15 seconds", async () => {
    const { waitForInput, getRecordingState } = await import("../input");
    // 500 chunks = 16 seconds of actual silent PCM at 16 kHz. The existing
    // chunk-based 15-second cutoff must not bypass a configured 90-second guard.
    const chunks = Array.from({ length: 500 }, () => makePcmChunk(0));
    const recorder = installFakeRecorder(chunks, true);
    const clock = installRecordingClock();
    const abort = new AbortController();
    let archivePath: string | undefined;
    let noSpeech = 0;
    const recording = waitForInput(90_000, "thoughtful", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: timeoutPromptArtifacts,
      signal: abort.signal,
      onNoSpeech: () => { noSpeech++; },
      onArchiveCreated: (path) => { archivePath = path; },
    });
    void recording.catch(() => null);
    try {
      await recorder.waitForSpawn();
      // Observe either completion or all PCM processed so the baseline fails
      // on behavior, rather than hanging while waiting for discarded chunks.
      await waitUntil(() => vadCallCount === 500 || getRecordingState() !== "recording", "silent PCM outcome");
      expect(getRecordingState()).toBe("recording");
      clock.advance(89_999);
      expect(getRecordingState()).toBe("recording");
      expect(noSpeech).toBe(0);
      clock.advance(1);
      expect(await recording).toBeNull();
      expect(noSpeech).toBe(1);
      expectValidRetainedWav(join(archivePath!, "audio.wav"), 500 * VAD_CHUNK_BYTES);
    } finally {
      abort.abort();
      await recording.catch(() => null);
      clock.restore();
    }
  });

  it("VA-TIMEOUT grants the full no-speech budget after delayed mic opening", async () => {
    const { waitForInput, getRecordingState } = await import("../input");
    const clock = installRecordingClock();
    const recorder = installFakeRecorder([makePcmChunk(0)], true, () => clock.advance(20_000));
    const abort = new AbortController();
    let captureStarts = 0;
    let noSpeech = 0;
    let archivePath: string | undefined;
    const recording = waitForInput(90_000, "thoughtful", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: timeoutPromptArtifacts,
      signal: abort.signal,
      onCaptureStart: () => { captureStarts++; },
      onNoSpeech: () => { noSpeech++; },
      onArchiveCreated: (path) => { archivePath = path; },
    });
    void recording.catch(() => null);
    try {
      await recorder.waitForSpawn();
      await waitUntil(() => vadCallCount === 1, "delayed-mic silent PCM");
      expect(captureStarts).toBe(1);
      clock.advance(70_000);
      // 90 seconds since the timer was armed, only 70 since capture opened.
      expect(getRecordingState()).toBe("recording");
      expect(noSpeech).toBe(0);
      clock.advance(19_999);
      expect(getRecordingState()).toBe("recording");
      clock.advance(1);
      expect(await recording).toBeNull();
      expect(noSpeech).toBe(1);
      expectValidRetainedWav(join(archivePath!, "audio.wav"), VAD_CHUNK_BYTES);
    } finally {
      abort.abort();
      await recording.catch(() => null);
      clock.restore();
    }
  });

  for (const held of [false, true]) {
    it(`VA-TIMEOUT speech safety ceiling ends ${held ? "held" : "unlocked"} capture at 30 minutes and keeps its audio`, async () => {
      const { waitForInput, getRecordingState } = await import("../input");
      const { setRecordingHold } = await import("../recording-hold");
      const logSpy = spyOn(console, "error");
      const recorder = installFakeRecorder([], true);
      const clock = installRecordingClock([3_600_000, 1_800_000]);
      const abort = new AbortController();
      let archivePath: string | undefined;
      vadProbabilityForCall = () => 0.95;
      // The public schema permits 3600 seconds. A larger no-speech budget must
      // not postpone the separate 30-minute cap after detected speech.
      const recording = waitForInput(3_600_000, "thoughtful", false, {
        archiveSource: "voice_ask",
        voiceAskArtifacts: timeoutPromptArtifacts,
        signal: abort.signal,
        onArchiveCreated: (path) => { archivePath = path; },
      });
      void recording.catch(() => null);
      try {
        await recorder.waitForSpawn();
        clock.advance(60_000);
        for (let i = 0; i < 25; i++) recorder.push(makePcmChunk(1800));
        await waitUntil(() => vadCallCount === 25, "safety-ceiling speech processed");
        if (held) { setRecordingHold(true); clock.advance(0); }
        clock.advance(1_799_999);
        expect(getRecordingState()).toBe("recording");
        clock.advance(1);
        expect(getRecordingState()).not.toBe("recording");
        expect(await recording).toBe("Retained transcript.");
        expectValidRetainedWav(join(archivePath!, "audio.wav"), 25 * VAD_CHUNK_BYTES);
        expect(logSpy.mock.calls.some((args) => /safety ceiling.*30.*min/i.test(args.join(" ")))).toBe(true);
      } finally {
        abort.abort();
        await recording.catch(() => null);
        clock.restore();
        logSpy.mockRestore();
      }
    });
  }

  for (const ending of ["stop", "cancel", "unlock"] as const) {
    it(`locked voice_ask survives timeout and thoughtful silence until ${ending}`, async () => {
      const { waitForInput, getRecordingState } = await import("../input");
      const { setRecordingHold, isRecordingHoldEngaged } = await import("../recording-hold");
      const recorder = installFakeRecorder([], true);
      const clock = installRecordingClock();
      const abort = new AbortController();
      let settled = false;
      const holdEdges: boolean[] = [];
      const recording = waitForInput(90_000, "thoughtful", false, {
        archiveSource: "voice_ask",
        voiceAskArtifacts: {
          agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
          agentAudioFormat: "mp3",
          agentTranscript: "Synthetic lock question",
          agentTtsEngine: "edge-tts",
          agentTtsVoice: "en-US-JennyNeural",
        },
        signal: abort.signal,
        onRecordingHoldChange: (held) => { holdEdges.push(held); },
      }).finally(() => { settled = true; });
      // Avoid an unhandled rejection when a failed assertion triggers cleanup.
      void recording.catch(() => null);
      try {
        await recorder.waitForSpawn();
        setRecordingHold(true);
        clock.advance(0);
        vadProbabilityForCall = (call) => call === 1 ? 0.95 : 0;
        const chunks = vad.silenceChunksForMode("thoughtful") + 2;
        for (let i = 0; i < chunks; i++) recorder.push(makePcmChunk());
        await waitUntil(() => vadCallCount === chunks, "held silence processed");
        clock.advance(180_000);
        expect(getRecordingState()).toBe("recording");
        expect(settled).toBe(false);
        expect(isRecordingHoldEngaged()).toBe(true);
        expect(holdEdges).toEqual([true]);

        if (ending === "unlock") {
          setRecordingHold(false);
          clock.advance(0);
          expect(holdEdges).toEqual([true, false]);
          clock.advance(89_999);
          expect(getRecordingState()).toBe("recording");
          expect(settled).toBe(false);
          clock.advance(1);
          expect(getRecordingState()).toBe("recording");
          for (let i = 0; i < vad.silenceChunksForMode("thoughtful"); i++) recorder.push(makePcmChunk(0));
        } else {
          if (ending === "cancel") setCancelSignal();
          writeFileSync(STOP_FILE, ending);
          clock.advance(0);
        }
        const result = await recording;
        expect(ending === "cancel" ? result === null : result !== null).toBe(true);
        expect(isRecordingHoldEngaged()).toBe(false);
        expect(existsSync(retainedPath)).toBe(true);
      } finally {
        abort.abort();
        await recording.catch(() => null);
        clock.restore();
      }
    });
  }

  for (const speechBeforeHold of [false, true]) {
    it(`unlock after a PCM gap restarts ${speechBeforeHold ? "post" : "pre"}-speech silence`, async () => {
      const { recordToBuffer, getRecordingState } = await import("../input");
      const { setRecordingHold } = await import("../recording-hold");
      const recorder = installFakeRecorder([], true);
      const clock = installRecordingClock();
      const abort = new AbortController();
      const recording = recordToBuffer(90_000, "thoughtful", false, undefined, abort.signal);
      void recording.catch(() => null);
      try {
        await recorder.waitForSpawn();
        const threshold = speechBeforeHold
          ? vad.silenceChunksForMode("thoughtful")
          : Math.ceil(15 * (16_000 / VAD_CHUNK_SAMPLES));
        vadProbabilityForCall = (call) => speechBeforeHold && call === 1 ? 0.95 : 0;
        const beforeHold = threshold - 1 + Number(speechBeforeHold);
        for (let i = 0; i < beforeHold; i++) recorder.push(makePcmChunk());
        await waitUntil(() => vadCallCount === beforeHold, "pre-lock chunks");
        setRecordingHold(true);
        clock.advance(0);
        // No chunks arrive while locked: neither timeout nor old silence debt
        // may terminate the session on release.
        clock.advance(180_000);
        expect(getRecordingState()).toBe("recording");
        setRecordingHold(false);
        clock.advance(0);
        for (let i = 0; i < threshold - 1; i++) recorder.push(makePcmChunk());
        await waitUntil(() => vadCallCount === beforeHold + threshold - 1, "fresh silence window");
        expect(getRecordingState()).toBe("recording");
        recorder.push(makePcmChunk());
        await recording;
        expect(getRecordingState()).toBe("idle");
      } finally {
        abort.abort();
        await recording.catch(() => null);
        clock.restore();
      }
    });
  }

  for (const pushToEnd of [false, true]) {
    it(pushToEnd ? "PTT retains its timeout even if a hold flag is sent" : "F5 VAD retains its recording timeout after speech", async () => {
      const { recordToBuffer, getRecordingState } = await import("../input");
      const { setRecordingHold } = await import("../recording-hold");
      vadProbabilityForCall = () => 0.95;
      const recorder = installFakeRecorder([makePcmChunk()], true);
      const clock = installRecordingClock();
      const abort = new AbortController();
      const recording = recordToBuffer(90_000, "thoughtful", pushToEnd, undefined, abort.signal);
      void recording.catch(() => null);
      try {
        await recorder.waitForSpawn();
        if (pushToEnd) setRecordingHold(true);
        else await waitUntil(() => vadCallCount === 1, "dictation speech processed");
        clock.advance(90_000);
        expect(getRecordingState()).toBe("idle");
        await recording;
      } finally {
        abort.abort();
        await recording.catch(() => null);
        clock.restore();
      }
    });
  }

  it("clears an engaged live HOLD marker whenever capture resolves", async () => {
    const holdPath = process.env.QA_VOICE_RECORDING_HOLD_PATH!;
    const recorder = installFakeRecorder([], true);
    const { recordToBuffer } = await import("../input");
    const recording = recordToBuffer(1_000, "quick", false);

    await recorder.waitForSpawn();
    writeFileSync(holdPath, "hold", { mode: 0o600 });
    writeFileSync(STOP_FILE, "stop");

    await expect(recording).resolves.toBeNull();
    expect(existsSync(holdPath)).toBe(false);
  });

  it("keeps the retained WAV valid while batching recovery fsyncs during capture", async () => {
    const fsyncSpy = spyOn(fsModule, "fsyncSync");
    let sawAllVadChunks!: () => void;
    const allVadChunksProcessed = new Promise<void>((resolve) => {
      sawAllVadChunks = resolve;
    });
    const chunks = Array.from({ length: 12 }, (_, index) =>
      makePcmChunk(400 + index * 10),
    );
    let vadCalls = 0;
    onVadCall = () => {
      vadCalls++;
      expectValidRetainedWav(retainedPath, VAD_CHUNK_BYTES * vadCalls);
      if (vadCalls === chunks.length) {
        sawAllVadChunks();
      }
    };
    const recorder = installFakeRecorder(chunks, true);
    const { recordToBuffer } = await import("../input");
    const recording = recordToBuffer(1000, "quick", false);

    try {
      await recorder.waitForSpawn();
      await allVadChunksProcessed;

      const fsyncCallsBeforeFinish = fsyncSpy.mock.calls.length;
      expect(fsyncCallsBeforeFinish).toBeGreaterThan(0);
      expect(fsyncCallsBeforeFinish).toBeLessThanOrEqual(5);

      writeFileSync(STOP_FILE, "stop");
      await expect(recording).resolves.toBeNull();
      expectValidRetainedWav(retainedPath, VAD_CHUNK_BYTES * chunks.length);
      expect(fsyncSpy.mock.calls.length).toBeLessThanOrEqual(8);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
      fsyncSpy.mockRestore();
    }
  });

  it("incrementally writes a valid retained WAV before a captured no-speech recording returns null", async () => {
    let sawVadChunk!: () => void;
    const vadStarted = new Promise<void>((resolve) => {
      sawVadChunk = resolve;
    });
    onVadCall = sawVadChunk;
    const recorder = installFakeRecorder([makePcmChunk()], true);
    const { recordToBuffer } = await import("../input");
    const recording = recordToBuffer(1000, "quick", false);

    try {
      await recorder.waitForSpawn();
      await vadStarted;

      expect(existsSync(retainedPath)).toBe(true);
      expectValidRetainedWav(retainedPath);

      writeFileSync(STOP_FILE, "stop");
      await expect(recording).resolves.toBeNull();
      expectValidRetainedWav(retainedPath);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }
  });

  it("returns captured silent PCM when voice_ask must archive a no-speech outcome", async () => {
    let sawVadChunk!: () => void;
    const vadStarted = new Promise<void>((resolve) => {
      sawVadChunk = resolve;
    });
    onVadCall = sawVadChunk;
    const silentChunk = makePcmChunk();
    const recorder = installFakeRecorder([silentChunk], true);
    const { recordToBuffer } = await import("../input");
    const recording = recordToBuffer(
      1_000,
      "quick",
      false,
      undefined,
      undefined,
      true,
    );

    try {
      await recorder.waitForSpawn();
      await vadStarted;
      writeFileSync(STOP_FILE, "stop");

      const captured = await recording;
      expect(captured).toBeInstanceOf(Uint8Array);
      expect(captured).toEqual(silentChunk);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }
  });

  it("terminates an in-flight recorder when its abort signal fires", async () => {
    const recorder = installFakeRecorder([], true);
    const { getRecordingState, recordToBuffer } = await import("../input");
    const controller = new AbortController();
    const recording = recordToBuffer(
      1_000,
      "quick",
      false,
      undefined,
      controller.signal,
    );

    await recorder.waitForSpawn();
    controller.abort(new Error("outer voice_ask timeout"));

    await expect(recording).rejects.toThrow("outer voice_ask timeout");
    expect(getRecordingState()).toBe("idle");
    expect(broadcasts.some((event) => event.type === "transcription")).toBe(
      false,
    );
  });

  it("reports capture start only after the recorder opens", async () => {
    const recorder = installFakeRecorder([], true);
    const { waitForInput } = await import("../input");
    let captureStarts = 0;
    const recording = waitForInput(2_000, "quick", false, {
      onCaptureStart: () => {
        captureStarts += 1;
      },
    });

    try {
      await recorder.waitForSpawn();
      await waitUntil(() => captureStarts === 1, "capture-start observer");
      expect(captureStarts).toBe(1);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }
  });

  it("stays idle when capture-start observation aborts synchronously", async () => {
    const controller = new AbortController();
    installFakeRecorder([], true);
    const { getRecordingState, recordToBuffer } = await import("../input");

    await expect(
      recordToBuffer(
        2_000,
        "quick",
        false,
        undefined,
        controller.signal,
        false,
        {
          onCaptureStart: () => {
            controller.abort(new Error("capture guard already ended"));
          },
        },
      ),
    ).rejects.toThrow("capture guard already ended");

    expect(getRecordingState()).toBe("idle");
    expect(
      broadcasts.some(
        (event) => event.type === "state" && event.state === "recording",
      ),
    ).toBe(false);
  });

  it("archives PCM already read from the mic while VAD is still backlogged", async () => {
    const controller = new AbortController();
    let releaseVad!: () => void;
    let lateSpeechStarts = 0;
    vadProcessSpy?.mockImplementation(async () => {
      vadCallCount += 1;
      await new Promise<void>((resolve) => {
        releaseVad = resolve;
      });
      return 0.95;
    });
    const fullChunks = Array.from({ length: 8 }, () => makePcmChunk(1800));
    const partialChunk = makePcmChunk(1800).slice(0, 256);
    installFakeRecorder([...fullChunks, partialChunk], true);
    const { waitForInput } = await import("../input");

    const capture = waitForInput(2_000, "thoughtful", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
        agentAudioFormat: "mp3",
        agentTranscript: "Keep every queued byte",
        agentTtsEngine: "edge-tts",
        agentTtsVoice: "en-US-JennyNeural",
        createdAt: new Date("2026-08-01T13:14:02.000Z"),
      },
      signal: controller.signal,
      onSpeechStart: () => { lateSpeechStarts++; },
    });

    try {
      await waitUntil(() => vadCallCount === 1, "backlogged VAD start");
      await Bun.sleep(10);
      controller.abort(new Error("voice_ask capture stage timed out"));
      await expect(capture).rejects.toThrow(
        "voice_ask capture stage timed out",
      );

      const dayDir = join(tmpRoot, "recordings", "2026-08-01");
      const archiveDir = join(dayDir, readdirSync(dayDir)[0]);
      expectValidRetainedWav(
        join(archiveDir, "audio.wav"),
        VAD_CHUNK_BYTES * fullChunks.length + partialChunk.byteLength,
      );
      releaseVad();
      await Bun.sleep(1);
      expect(lateSpeechStarts).toBe(0);
    } finally {
      releaseVad?.();
      await capture.catch(() => null);
    }
  });

  it("archives queued PCM when a backlogged capture reaches its normal timeout", async () => {
    let releaseVad!: () => void;
    vadProcessSpy?.mockImplementation(async () => {
      vadCallCount += 1;
      await new Promise<void>((resolve) => {
        releaseVad = resolve;
      });
      return 0.95;
    });
    const chunks = Array.from({ length: 6 }, () => makePcmChunk(1800));
    installFakeRecorder(chunks, true);
    const { waitForInput } = await import("../input");

    const capture = waitForInput(100, "thoughtful", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
        agentAudioFormat: "mp3",
        agentTranscript: "Keep timeout audio",
        agentTtsEngine: "edge-tts",
        agentTtsVoice: "en-US-JennyNeural",
        createdAt: new Date("2026-08-01T13:14:02.000Z"),
      },
    });

    try {
      await waitUntil(() => vadCallCount === 1, "timeout VAD backlog");
      await expect(capture).resolves.toBeNull();

      const dayDir = join(tmpRoot, "recordings", "2026-08-01");
      const archiveDir = join(dayDir, readdirSync(dayDir)[0]);
      expectValidRetainedWav(
        join(archiveDir, "audio.wav"),
        VAD_CHUNK_BYTES * chunks.length,
      );
    } finally {
      releaseVad?.();
      await capture.catch(() => null);
    }
  });

  it("archives queued PCM when a backlogged capture is cancelled", async () => {
    let releaseVad!: () => void;
    vadProcessSpy?.mockImplementation(async () => {
      vadCallCount += 1;
      await new Promise<void>((resolve) => {
        releaseVad = resolve;
      });
      return 0.95;
    });
    const chunks = Array.from({ length: 7 }, () => makePcmChunk(1800));
    installFakeRecorder(chunks, true);
    const { waitForInput } = await import("../input");

    const capture = waitForInput(2_000, "thoughtful", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
        agentAudioFormat: "mp3",
        agentTranscript: "Keep cancelled audio",
        agentTtsEngine: "edge-tts",
        agentTtsVoice: "en-US-JennyNeural",
        createdAt: new Date("2026-08-01T13:14:02.000Z"),
      },
    });

    try {
      await waitUntil(() => vadCallCount === 1, "cancel VAD backlog");
      await Bun.sleep(10);
      setCancelSignal();
      writeFileSync(STOP_FILE, "cancel");
      await expect(capture).resolves.toBeNull();

      const dayDir = join(tmpRoot, "recordings", "2026-08-01");
      const archiveDir = join(dayDir, readdirSync(dayDir)[0]);
      expectValidRetainedWav(
        join(archiveDir, "audio.wav"),
        VAD_CHUNK_BYTES * chunks.length,
      );
    } finally {
      releaseVad?.();
      writeFileSync(STOP_FILE, "stop");
      await capture.catch(() => null);
    }
  });

  it("archives captured PCM with prompt artifacts before an abort rejects", async () => {
    const controller = new AbortController();
    let publishedArchivePath: string | undefined;
    vadProbabilityForCall = () => 0.95;
    onVadCall = () => {
      if (vadCallCount === 3) {
        controller.abort(new Error("voice_ask capture stage timed out"));
      }
    };
    installFakeRecorder(
      Array.from({ length: 8 }, () => makePcmChunk(1800)),
      true,
    );
    const { waitForInput } = await import("../input");
    const agentAudio = new Uint8Array([0x49, 0x44, 0x33, 0xaa, 0xbb]);

    await expect(
      waitForInput(2_000, "thoughtful", false, {
        archiveSource: "voice_ask",
        voiceAskArtifacts: {
          agentAudioBytes: agentAudio,
          agentAudioFormat: "mp3",
          agentTranscript: "Keep the captured answer",
          agentTtsEngine: "edge-tts",
          agentTtsVoice: "en-US-JennyNeural",
          createdAt: new Date("2026-08-01T13:14:02.000Z"),
        },
        onArchiveCreated: (archivePath) => {
          publishedArchivePath = archivePath;
        },
        signal: controller.signal,
      }),
    ).rejects.toThrow("voice_ask capture stage timed out");

    const dayDir = join(tmpRoot, "recordings", "2026-08-01");
    expect(existsSync(dayDir)).toBe(true);
    const archiveIds = readdirSync(dayDir);
    expect(archiveIds).toHaveLength(1);
    const archiveDir = join(dayDir, archiveIds[0]);
    expect(publishedArchivePath).toBe(archiveDir);
    expect(readdirSync(archiveDir).sort()).toEqual([
      "agent-audio.mp3",
      "agent-transcript.txt",
      "audio.wav",
      "metadata.json",
    ]);
    expect(readFileSync(join(archiveDir, "agent-audio.mp3"))).toEqual(
      Buffer.from(agentAudio),
    );
    expect(readFileSync(join(archiveDir, "agent-transcript.txt"), "utf8")).toBe(
      "Keep the captured answer",
    );
    expectValidRetainedWav(join(archiveDir, "audio.wav"));
    expect(
      JSON.parse(readFileSync(join(archiveDir, "metadata.json"), "utf8")),
    ).toMatchObject({
      source: "voice_ask",
      transcription_status: "captured",
      backend: null,
      retention_policy: "indefinite",
    });

    const archivedAudioPath = join(archiveDir, "audio.wav");
    const archivedAudioBeforeLaterCapture = readFileSync(archivedAudioPath);
    writeFileSync(retainedPath, makeWav(makePcmChunk(400)));
    expect(readFileSync(archivedAudioPath)).toEqual(
      archivedAudioBeforeLaterCapture,
    );

    const { retranscribeRecordingCapture } = await import("../input");
    await expect(retranscribeRecordingCapture(archivedAudioPath)).resolves.toBe(
      "retained transcript",
    );
    expect(
      readFileSync(join(archiveDir, "voicelayer-transcript.txt"), "utf8"),
    ).toBe("retained transcript");
    expect(polishSurfaces).toEqual([]);
    expect(
      JSON.parse(readFileSync(join(archiveDir, "metadata.json"), "utf8")),
    ).toMatchObject({
      source: "voice_ask",
      transcription_status: "transcribed",
      backend: "fake-stt",
      user_transcript_chars: "retained transcript".length,
    });
  });

  it("restores idle when abort fires while VAD reset is still pending", async () => {
    installFakeRecorder([], true);
    let releaseReset!: () => void;
    let resetStarted!: () => void;
    const started = new Promise<void>((resolve) => {
      resetStarted = resolve;
    });
    vadResetSpy!.mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          releaseReset = resolve;
          resetStarted();
        }),
    );
    const { getRecordingState, recordToBuffer } = await import("../input");
    const controller = new AbortController();
    const recording = recordToBuffer(
      1_000,
      "quick",
      false,
      undefined,
      controller.signal,
    );

    await started;
    controller.abort(new Error("abort during VAD reset"));
    releaseReset();

    await expect(recording).rejects.toThrow("abort during VAD reset");
    expect(getRecordingState()).toBe("idle");
  });

  it("keeps a valid retained WAV when recording throws after capturing audio", async () => {
    vadMode = "throw";
    installFakeRecorder([makePcmChunk()], false);
    const { recordToBuffer } = await import("../input");

    await expect(recordToBuffer(1000, "quick", false)).rejects.toThrow(
      "vad exploded after capture",
    );
    expect(existsSync(retainedPath)).toBe(true);
    expectValidRetainedWav(retainedPath);
  });

  it("preserves fsynced PCM beyond a stale retained WAV header when appending the next chunk", async () => {
    let vadCalls = 0;
    let sawThirdVadChunk!: () => void;
    const thirdVadStarted = new Promise<void>((resolve) => {
      sawThirdVadChunk = resolve;
    });
    onVadCall = () => {
      vadCalls++;
      if (vadCalls === 2) {
        rewriteWavHeaderDataSize(retainedPath, VAD_CHUNK_BYTES);
        expect(readWavDataSize(retainedPath)).toBe(VAD_CHUNK_BYTES);
      }
      if (vadCalls === 3) {
        sawThirdVadChunk();
      }
    };
    const recorder = installFakeRecorder(
      [makePcmChunk(400), makePcmChunk(800), makePcmChunk(1200)],
      true,
    );
    const { recordToBuffer } = await import("../input");
    const recording = recordToBuffer(1000, "quick", false);

    try {
      await recorder.waitForSpawn();
      await thirdVadStarted;

      expectValidRetainedWav(retainedPath, VAD_CHUNK_BYTES * 3);

      writeFileSync(STOP_FILE, "stop");
      await expect(recording).resolves.toBeNull();
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }
  });

  it("rejects a corrupt retained WAV clearly without deleting it or calling STT", async () => {
    const corrupt = Buffer.from("RIFF");
    writeFileSync(retainedPath, corrupt);
    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).rejects.toThrow(
      /retained recording is not a valid WAV/i,
    );
    expect(readFileSync(retainedPath)).toEqual(corrupt);
    expect(backendTranscribeCalls).toBe(0);
    expect(
      broadcasts.some(
        (message) =>
          message.type === "error" &&
          /retained recording is not a valid WAV/i.test(message.message),
      ),
    ).toBe(true);
  });

  it("polishes a retained capture with dictation when a fresh daemon has no persisted surface", async () => {
    writeFileSync(retainedPath, makeWav(makePcmChunk()));
    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(polishSurfaces).toEqual(["dictation"]);
  });

  it("persists and restores the retained capture's original polish surface", async () => {
    const metadataPath = `${retainedPath}.metadata.json`;
    const { retainLastCaptureForRecovery, retranscribeLastCapture } =
      await import("../input");

    retainLastCaptureForRecovery(makeWav(makePcmChunk()), "voice_ask");

    expect(JSON.parse(readFileSync(metadataPath, "utf8"))).toMatchObject({
      schema_version: 1,
      polish_surface: "voice_ask",
    });
    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(polishSurfaces).toEqual(["voice_ask"]);
  });

  it("preserves the previous retained surface when replacing the WAV fails", async () => {
    const metadataPath = `${retainedPath}.metadata.json`;
    const originalWav = makeWav(makePcmChunk(400));
    const { retainLastCaptureForRecovery, retranscribeLastCapture } =
      await import("../input");
    retainLastCaptureForRecovery(originalWav, "voice_ask");
    const renameSpy = spyOn(fsModule, "renameSync").mockImplementationOnce(
      () => {
        throw new Error("simulated disk failure");
      },
    );

    try {
      expect(() =>
        retainLastCaptureForRecovery(makeWav(makePcmChunk(800)), "dictation"),
      ).toThrow("simulated disk failure");
    } finally {
      renameSpy.mockRestore();
    }

    expect(readFileSync(retainedPath)).toEqual(Buffer.from(originalWav));
    expect(JSON.parse(readFileSync(metadataPath, "utf8"))).toMatchObject({
      polish_surface: "voice_ask",
    });
    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(polishSurfaces).toEqual(["voice_ask"]);
  });

  it("falls back to dictation when retained metadata belongs to different audio", async () => {
    const { retainLastCaptureForRecovery, retranscribeLastCapture } =
      await import("../input");
    retainLastCaptureForRecovery(makeWav(makePcmChunk(400)), "voice_ask");
    writeFileSync(retainedPath, makeWav(makePcmChunk(800)));

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(polishSurfaces).toEqual(["dictation"]);
  });

  it("repairs a stale retained WAV header to include fsynced trailing PCM before retranscribing", async () => {
    const retainedPcm = Buffer.concat([
      Buffer.from(makePcmChunk(400)),
      Buffer.from(makePcmChunk(800)),
    ]);
    writeFileSync(retainedPath, makeWav(retainedPcm));
    rewriteWavHeaderDataSize(retainedPath, VAD_CHUNK_BYTES);
    expect(readWavDataSize(retainedPath)).toBe(VAD_CHUNK_BYTES);

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(backendTranscribeCalls).toBe(1);
    expect(backendTranscribedDataSize).toBe(VAD_CHUNK_BYTES * 2);
    expect(backendTranscribedFileBytes).toBe(44 + VAD_CHUNK_BYTES * 2);
    expectValidRetainedWav(retainedPath, VAD_CHUNK_BYTES * 2);
  });

  it("keeps the retained WAV and surfaces backend startup failures with retry guidance", async () => {
    const wav = makeWav(makePcmChunk());
    writeFileSync(retainedPath, wav);
    backendMode = "throw-on-get";
    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).rejects.toThrow(
      /could not retranscribe the retained recording/i,
    );
    expect(readFileSync(retainedPath)).toEqual(Buffer.from(wav));
    expect(backendTranscribeCalls).toBe(0);
  });

  /**
   * Push-to-end captures run "until stop signal or timeout", and a fake recorder's EOF doesn't end one.
   * Without a stop these tests waited out the full 2 s timer per capture, which ran past bun's 5 s test
   * timeout / the 4 s STT wait under CI load (#162). Stop on the transition instead: once the retained WAV
   * holds every fake PCM byte.
   */
  async function stopPushToEndOnceCaptured(expectedBytes: number): Promise<void> {
    await waitUntil(
      () => existsSync(retainedPath) && readWavDataSize(retainedPath) === expectedBytes,
      "push-to-end capture to hold all fake PCM",
      10_000,
    );
    writeFileSync(STOP_FILE, "stop");
  }

  function capturedVoiceBarAudio(): string[] {
    const root = process.env.QA_VOICE_RECORDINGS_DIR!;
    if (!existsSync(root)) return [];
    return Array.from(
      new Bun.Glob("*/*/audio.wav").scanSync({ cwd: root, absolute: true }),
    );
  }

  function expectCaptureLinked(audioPath: string): void {
    const metadata = JSON.parse(readFileSync(`${retainedPath}.metadata.json`, "utf8"));
    expect(metadata.archive_audio_path).toBe(audioPath);
    expect(metadata.audio_sha256).toBe(createHash("sha256").update(readFileSync(retainedPath)).digest("hex"));
  }

  function voiceBarArchiveMetadata(audioPath: string): Record<string, unknown> {
    return JSON.parse(readFileSync(audioPath.replace("audio.wav", "metadata.json"), "utf8"));
  }

  // NOTX1: a kept recording that never got a transcript must say why, not a bare "captured".
  it("NOTX1 records silent-input when a push-to-end capture is digital silence", async () => {
    vadProcessSpy!.mockResolvedValue(0);
    // ±1 LSB for 1.9 s: the shape of the 2026-10-19 06:31 capture (wireless mic link dropped).
    const chunks = Array.from({ length: 60 }, () => makePcmChunk(1));
    installFakeRecorder(chunks, false);
    const { waitForInput } = await import("../input");
    const result = waitForInput(5_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(60 * VAD_CHUNK_BYTES);
    expect(await result).toBeNull();
    expect(backendTranscribeCalls).toBe(0);
    const archives = capturedVoiceBarAudio();
    expect(archives).toHaveLength(1);
    const metadata = voiceBarArchiveMetadata(archives[0]);
    expect(metadata).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "silent-input",
    });
    expect(metadata.input_dbfs as number).toBeLessThan(-85);
  });

  it("NOTX1 records no-speech when an audible push-to-end capture has no voice", async () => {
    vadProcessSpy!.mockResolvedValue(0);
    installFakeRecorder(Array.from({ length: 60 }, () => makePcmChunk(1800)), false);
    const { waitForInput } = await import("../input");
    const result = waitForInput(5_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(60 * VAD_CHUNK_BYTES);
    expect(await result).toBeNull();
    const [archive] = capturedVoiceBarAudio();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "no-speech",
    });
  });

  it("NOTX1 records the STT failure reason and a later re-transcribe clears it", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    backendMode = "throw-on-get";
    const { waitForInput, retranscribeRecordingCapture } = await import("../input");
    const failed = waitForInput(2_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(24 * VAD_CHUNK_BYTES);
    await expect(failed).rejects.toThrow("whisper backend is still warming");
    const [archive] = capturedVoiceBarAudio();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "transcription-failed",
      not_transcribed_detail: "whisper backend is still warming",
    });

    backendMode = "ok";
    await expect(retranscribeRecordingCapture(archive)).resolves.toBe("Retained transcript.");
    const metadata = voiceBarArchiveMetadata(archive);
    expect(metadata.transcription_status).toBe("transcribed");
    expect(metadata).not.toHaveProperty("not_transcribed_reason");
    expect(metadata).not.toHaveProperty("not_transcribed_detail");
  });

  it("NOTX1 keeps the original reason when a re-transcribe of silence finds no words", async () => {
    vadProcessSpy!.mockResolvedValue(0);
    installFakeRecorder(Array.from({ length: 60 }, () => makePcmChunk(1)), false);
    const { waitForInput, retranscribeRecordingCapture } = await import("../input");
    const result = waitForInput(5_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(60 * VAD_CHUNK_BYTES);
    await result;
    const [archive] = capturedVoiceBarAudio();
    backendText = "";
    await expect(retranscribeRecordingCapture(archive)).resolves.toBeNull();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "silent-input",
    });
  });

  // NOTX1 round 2 (Sol #1): History caches rows and only re-reads one on archive_metadata_updated.
  function metadataUpdates(): unknown[] {
    return broadcasts.filter((event) => event.type === "archive_metadata_updated");
  }

  async function silentVoiceBarArchive(): Promise<string> {
    vadProcessSpy!.mockResolvedValue(0);
    installFakeRecorder(Array.from({ length: 60 }, () => makePcmChunk(1)), false);
    const { waitForInput } = await import("../input");
    const result = waitForInput(5_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(60 * VAD_CHUNK_BYTES);
    await result;
    return capturedVoiceBarAudio()[0];
  }

  it("NOTX1 tells History when a live capture is kept with a reason", async () => {
    const archive = await silentVoiceBarArchive();
    expect(metadataUpdates()).toEqual([
      { type: "archive_metadata_updated", recording_path: archive },
    ]);
  });

  it("NOTX1 tells History when a failed Re-transcribe changes the reason", async () => {
    const archive = await silentVoiceBarArchive();
    broadcasts = [];
    backendMode = "throw-on-get";
    const { retranscribeRecordingCapture } = await import("../input");
    await expect(retranscribeRecordingCapture(archive)).rejects.toThrow("whisper backend is still warming");
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      not_transcribed_reason: "transcription-failed",
    });
    expect(metadataUpdates()).toEqual([
      { type: "archive_metadata_updated", recording_path: archive },
    ]);
  });

  it("NOTX1 tells History when an empty Re-transcribe gives a legacy row its reason", async () => {
    const archive = await silentVoiceBarArchive();
    // A row archived before NOTX1 has no reason fields.
    const metadataPath = archive.replace("audio.wav", "metadata.json");
    const legacy = voiceBarArchiveMetadata(archive);
    delete legacy.not_transcribed_reason;
    delete legacy.not_transcribed_detail;
    delete legacy.input_dbfs;
    writeFileSync(metadataPath, `${JSON.stringify(legacy, null, 2)}\n`);
    broadcasts = [];
    backendText = "";
    const { retranscribeRecordingCapture } = await import("../input");
    await expect(retranscribeRecordingCapture(archive)).resolves.toBeNull();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      not_transcribed_reason: "empty-transcript",
    });
    expect(metadataUpdates()).toEqual([
      { type: "archive_metadata_updated", recording_path: archive },
    ]);
  });

  it("NOTX1 records empty-transcript when the live decode returns no words", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    backendText = "";
    const { waitForInput } = await import("../input");
    const result = waitForInput(2_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(24 * VAD_CHUNK_BYTES);
    expect(await result).toBeNull();
    expect(backendTranscribeCalls).toBe(1);
    const [archive] = capturedVoiceBarAudio();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "empty-transcript",
    });
  });

  // NOTX1-FU: the reason always reflects the LATEST outcome, and whitespace counts as no words.
  it("NOTX1-FU replaces a stale transcription-failed reason when a Re-transcribe finds no words", async () => {
    const archive = await silentVoiceBarArchive();
    backendMode = "throw-on-get";
    const { retranscribeRecordingCapture } = await import("../input");
    await expect(retranscribeRecordingCapture(archive)).rejects.toThrow("whisper backend is still warming");
    broadcasts = [];
    backendMode = "ok";
    backendText = "";
    await expect(retranscribeRecordingCapture(archive)).resolves.toBeNull();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "empty-transcript",
      not_transcribed_detail: null,
    });
    expect(metadataUpdates()).toEqual([
      { type: "archive_metadata_updated", recording_path: archive },
    ]);
  });

  // Identity mode hands the raw decode back untouched, so whitespace reaches the success check.
  async function withIdentityCorrector(run: () => Promise<void>): Promise<void> {
    const saved = process.env.QA_VOICE_CORRECTOR;
    process.env.QA_VOICE_CORRECTOR = "identity";
    try {
      await run();
    } finally {
      if (saved === undefined) delete process.env.QA_VOICE_CORRECTOR;
      else process.env.QA_VOICE_CORRECTOR = saved;
    }
  }

  it("NOTX1-FU records empty-transcript when the live decode returns only whitespace", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    backendText = "  \n\t ";
    const { waitForInput } = await import("../input");
    await withIdentityCorrector(async () => {
      const result = waitForInput(2_000, "standard", true, { archiveSource: "voicebar" });
      await stopPushToEndOnceCaptured(24 * VAD_CHUNK_BYTES);
      expect(await result).toBeNull();
    });
    expect(backendTranscribeCalls).toBe(1);
    const [archive] = capturedVoiceBarAudio();
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "empty-transcript",
    });
    expect(broadcasts.some((event) => event.type === "transcription")).toBe(false);
  });

  it("NOTX1-FU treats a whitespace-only Re-transcribe as no words", async () => {
    const archive = await silentVoiceBarArchive();
    const metadataPath = archive.replace("audio.wav", "metadata.json");
    const legacy = voiceBarArchiveMetadata(archive);
    delete legacy.not_transcribed_reason;
    writeFileSync(metadataPath, `${JSON.stringify(legacy, null, 2)}\n`);
    broadcasts = [];
    backendText = " \n ";
    const { retranscribeRecordingCapture } = await import("../input");
    await withIdentityCorrector(async () => {
      await expect(retranscribeRecordingCapture(archive)).resolves.toBeNull();
    });
    expect(voiceBarArchiveMetadata(archive)).toMatchObject({
      transcription_status: "captured",
      not_transcribed_reason: "empty-transcript",
    });
    expect(broadcasts.some((event) => event.type === "transcription")).toBe(false);
    expect(metadataUpdates()).toEqual([
      { type: "archive_metadata_updated", recording_path: archive },
    ]);
  });

  // MICDROP2: the device dies mid-dictation. Only OS evidence (recorder EOF, a CoreAudio device
  // event) decides; flatness only locates. Synthetic only: fake recorder streams, zero/dither padding.
  // Dither in {-1, 0, +1} is the 06:33 dead device (docs.local/HALLU1/DONE.md); sox kept streaming it.
  const ditherChunk = () => {
    const chunk = makePcmChunk(0);
    const view = new DataView(chunk.buffer);
    for (let i = 0; i < VAD_CHUNK_SAMPLES; i++) view.setInt16(i * 2, [1, -1, 0][i % 3]!, true);
    return chunk;
  };
  // Live speech: alternating samples, never within 2 LSB.
  const liveChunks = (n: number) =>
    Array.from({ length: n }, (_, k) => makePcmChunk(k % 2 ? 2400 : -2400).map((b, i) => (i % 4 < 2 ? b : 0)));
  const archiveMetadata = (archivePath: string) =>
    JSON.parse(readFileSync(join(archivePath, "metadata.json"), "utf8"));
  const raceStillRecording = <T,>(pending: Promise<T>, ms: number) =>
    Promise.race([pending, Bun.sleep(ms).then(() => "still recording" as const)]);

  const liveCaptureId = () => broadcasts.filter(e => e.type === "state" && e.state === "recording").at(-1)?.capture_id as number;

  it("MICDROP2 recorder EOF: stops on its own, keeps and decodes every byte, shows the observed loss time", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder([...liveChunks(40), ...Array.from({ length: 20 }, () => makePcmChunk(0))], false);
    const { waitForInput } = await import("../input");
    let archivePath = "";
    // Push-to-end with no stop file: only the recorder's EOF can end this before the 20 s timer.
    const pending = waitForInput(20_000, "standard", true, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
    try {
      expect(await raceStillRecording(pending, 4_000)).toBe("Retained transcript.");
      // The gated-looking tail stays in: before the evidence it is indistinguishable from a pause (Sol R1 #4).
      expect(backendTranscribedDataSize).toBe(60 * VAD_CHUNK_BYTES);
      expectValidRetainedWav(join(archivePath, "audio.wav"), 60 * VAD_CHUNK_BYTES);
      expectValidRetainedWav(retainedPath, 60 * VAD_CHUNK_BYTES);
      expect(archiveMetadata(archivePath)).toMatchObject({
        transcription_status: "transcribed",
        mic_disconnected_at_ms: 1920,
        mic_disconnect_reason: "recorder-ended",
        mic_disconnect_note: "Mic disconnected at 0:02",
      });
      expect(broadcasts.find(e => e.type === "mic_disconnected")).toEqual({
        type: "mic_disconnected", at_ms: 1920, reason: "recorder-ended", message: "Mic disconnected at 0:02",
      });
      expect(broadcasts.some(e => e.capture_failure)).toBe(false);
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await pending.catch(() => null);
      clearStopSignal();
    }
  }, 10_000);

  // MICDROP3: a CoreAudio report never ends, stops, drains or trims a capture. It is evidence only:
  // labelled at its observed event offset when the audio after it is dead-device flat, else journal-only.
  const reportViaSocket = async (captureId: number, deviceId: number) => {
    const { parseCommand } = await import("../socket-protocol");
    const { handleSocketCommand } = await import("../socket-handlers");
    const command = parseCommand(JSON.stringify({ cmd: "input_device_lost", reason: "device-removed", capture_id: captureId, device_id: deviceId }));
    expect(command).not.toBeNull();
    handleSocketCommand(command!);
  };

  // Sol R2 #1: default A -> B at startup, sox on healthy B. If CoreAudio delivers the device-list
  // callback first, VoiceBar reports A's removal for this live capture; if the default-input callback
  // comes first, the binding is ambiguous and nothing is sent. Both orders must look like main.
  for (const ptt of [true, false]) {
    for (const [order, reported] of [["device-list callback first", true], ["default-input callback first", false]] as const) {
      it(`MICDROP3 Sol R2 ${order}, ${ptt ? "PTT" : "VAD"}: a report for the old default never stops a healthy capture or shows a label`, async () => {
        vadProcessSpy!.mockResolvedValue(0.95);
        const recorder = installFakeRecorder(liveChunks(40), true);
        const journal = await import("../control-layer-journal");
        const events = spyOn(journal, "appendControlLayerEvent").mockImplementation(() => {});
        const { waitForInput } = await import("../input");
        let archivePath = "";
        const pending = waitForInput(20_000, "standard", ptt, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
        try {
          await waitUntil(() => existsSync(retainedPath) && readWavDataSize(retainedPath) === 40 * VAD_CHUNK_BYTES,
            "capture running", 10_000);
          if (reported) await reportViaSocket(liveCaptureId(), 10);
          expect(await raceStillRecording(pending, 300)).toBe("still recording");
          // Etan keeps talking on B.
          for (const chunk of liveChunks(20)) recorder.push(chunk);
          await stopPushToEndOnceCaptured(60 * VAD_CHUNK_BYTES);
          expect(await pending).toBe("Retained transcript.");
          expect(backendTranscribedDataSize).toBe(60 * VAD_CHUNK_BYTES);
          expect(readWavDataSize(join(archivePath, "audio.wav"))).toBe(60 * VAD_CHUNK_BYTES);
          expect(broadcasts.some(e => e.type === "mic_disconnected")).toBe(false);
          expect(JSON.stringify(broadcasts)).not.toContain("Mic ");
          expect(archiveMetadata(archivePath).mic_disconnect_reason).toBeUndefined();
          const journaled = events.mock.calls.filter(([name]) => name === "capture.mic_loss_unconfirmed");
          expect(journaled.map(([, fields]) => fields)).toEqual(
            reported ? [expect.objectContaining({ reason: "device-removed", event_offset_ms: 1280 })] : [],
          );
          expect(events.mock.calls.some(([name]) => name === "capture.mic_disconnected")).toBe(false);
        } finally {
          events.mockRestore();
          writeFileSync(STOP_FILE, "stop");
          await pending.catch(() => null);
          clearStopSignal();
        }
      }, 10_000);
    }
  }

  // Sol R2 #2: event at 1,280 ms, then 20 post-event chunks. The label is the event offset (0:01),
  // never the capture end (0:02); the report stops nothing and every byte is decoded.
  for (const ending of ["user stop", "VAD silence", "recorder EOF"] as const) {
    it(`MICDROP3 real loss: a report, then dead dither, ends by ${ending}; the label shows the event offset`, async () => {
      if (ending === "VAD silence") vadProbabilityForCall = call => (call <= 40 ? 0.95 : 0);
      else vadProcessSpy!.mockResolvedValue(0.95);
      const tail = ending === "VAD silence" ? 100 : 20;
      const recorder = installFakeRecorder(liveChunks(40), true);
      const { waitForInput, reportInputDeviceLost } = await import("../input");
      let archivePath = "";
      const pending = waitForInput(20_000, "standard", ending !== "VAD silence", { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
      try {
        await waitUntil(() => existsSync(retainedPath) && readWavDataSize(retainedPath) === 40 * VAD_CHUNK_BYTES,
          "first 40 chunks captured", 10_000);
        expect(reportInputDeviceLost("device-removed", liveCaptureId())).toBe(true);
        expect(await raceStillRecording(pending, 300)).toBe("still recording");
        for (let n = 0; n < tail; n++) recorder.push(ditherChunk());
        if (ending === "user stop") await stopPushToEndOnceCaptured((40 + tail) * VAD_CHUNK_BYTES);
        if (ending === "recorder EOF") {
          await waitUntil(() => readWavDataSize(retainedPath) === (40 + tail) * VAD_CHUNK_BYTES, "tail captured", 10_000);
          recorder.end();
        }
        expect(await raceStillRecording(pending, 6_000)).toBe("Retained transcript.");
        expect(backendTranscribedDataSize).toBe((40 + tail) * VAD_CHUNK_BYTES);
        expect(readWavDataSize(join(archivePath, "audio.wav"))).toBe((40 + tail) * VAD_CHUNK_BYTES);
        expect(broadcasts.find(e => e.type === "mic_disconnected")).toEqual({
          type: "mic_disconnected", at_ms: 1280, reason: "device-removed", message: "Mic disconnected at 0:01",
        });
        expect(archiveMetadata(archivePath)).toMatchObject({
          mic_disconnected_at_ms: 1280, mic_disconnect_reason: "device-removed", mic_disconnect_note: "Mic disconnected at 0:01",
        });
      } finally {
        writeFileSync(STOP_FILE, "stop");
        await pending.catch(() => null);
        clearStopSignal();
      }
    }, 10_000);
  }

  it("MICDROP2 a stale or another capture's device report is rejected and stops nothing (Sol R1 #3)", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(liveChunks(24), true);
    const { recordToBuffer, reportInputDeviceLost } = await import("../input");
    expect(reportInputDeviceLost("device-removed", 1)).toBe(false); // no capture running
    const captureState: { micDisconnect?: unknown } = {};
    const recording = recordToBuffer(20_000, "standard", true, undefined, undefined, true, captureState as never);
    try {
      await waitUntil(() => existsSync(retainedPath) && readWavDataSize(retainedPath) === 24 * VAD_CHUNK_BYTES,
        "capture running", 10_000);
      const id = liveCaptureId();
      expect(Number.isSafeInteger(id) && id > 0).toBe(true);
      expect(reportInputDeviceLost("device-removed", id - 1)).toBe(false);
      expect(await raceStillRecording(recording, 300)).toBe("still recording");
      writeFileSync(STOP_FILE, "stop");
      expect((await recording)?.byteLength).toBe(24 * VAD_CHUNK_BYTES);
      expect(captureState.micDisconnect).toBeUndefined();
      expect(reportInputDeviceLost("device-removed", id)).toBe(false); // finished: stale
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
      clearStopSignal();
    }
  }, 10_000);

  it("MICDROP3 a gated pause right before the unplug: the clock is the event, and every byte stays (Sol R1 #4)", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    const recorder = installFakeRecorder([...liveChunks(40), ...Array.from({ length: 100 }, () => makePcmChunk(0))], true);
    const { recordToBuffer, reportInputDeviceLost } = await import("../input");
    const captureState: { micDisconnect?: { atMs: number | null; lastSignalMs: number | null } } = {};
    const recording = recordToBuffer(20_000, "standard", true, undefined, undefined, true, captureState as never);
    try {
      await waitUntil(() => existsSync(retainedPath) && readWavDataSize(retainedPath) === 140 * VAD_CHUNK_BYTES,
        "full gated pause", 10_000);
      expect(reportInputDeviceLost("device-removed", liveCaptureId())).toBe(true);
      for (let n = 0; n < 20; n++) recorder.push(makePcmChunk(0));
      await stopPushToEndOnceCaptured(160 * VAD_CHUNK_BYTES);
      expect((await recording)?.byteLength).toBe(160 * VAD_CHUNK_BYTES);
      expect(captureState.micDisconnect).toMatchObject({ atMs: 4480, lastSignalMs: 1280 });
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
      clearStopSignal();
    }
  }, 10_000);

  it("MICDROP3 chunked STT, VAD backlogged at a CoreAudio report: recording continues and the decoder gets every byte (Sol R1 #2)", async () => {
    const previous = process.env.QA_VOICE_CHUNKED_STT;
    process.env.QA_VOICE_CHUNKED_STT = "1";
    let release!: () => void;
    let blocked = false;
    let calls = 0;
    const gate = new Promise<void>(resolve => { release = resolve; });
    vadProcessSpy!.mockImplementation(async () => {
      if (++calls === 11) { blocked = true; await gate; }
      return 0.95;
    });
    installFakeRecorder(liveChunks(40), true);
    const { waitForInput, reportInputDeviceLost } = await import("../input");
    let archivePath = "";
    const pending = waitForInput(20_000, "standard", false, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
    try {
      await waitUntil(() => blocked, "VAD suspended on chunk 11", 10_000);
      expect(reportInputDeviceLost("device-removed", liveCaptureId())).toBe(true);
      expect(await raceStillRecording(pending, 300)).toBe("still recording");
      release();
      await stopPushToEndOnceCaptured(40 * VAD_CHUNK_BYTES);
      expect(await raceStillRecording(pending, 4_000)).toBe("Retained transcript.");
      expect(readWavDataSize(join(archivePath, "audio.wav"))).toBe(40 * VAD_CHUNK_BYTES);
      expect(backendTranscribedDataSize).toBe(40 * VAD_CHUNK_BYTES);
      // Nothing arrived after the report: no flat evidence, so no label.
      expect(broadcasts.some(e => e.type === "mic_disconnected")).toBe(false);
    } finally {
      release();
      await pending.catch(() => null);
      if (previous === undefined) delete process.env.QA_VOICE_CHUNKED_STT;
      else process.env.QA_VOICE_CHUNKED_STT = previous;
    }
  }, 10_000);

  // MICDROP3 R1 (Sol): any loss evidence bypasses the legacy PTT silence trimmer, so the backend,
  // the rebuilt chunked session and recovery all get the complete capture. 40 live chunks, then a
  // 6.4 s tail (200 chunks, well past the trim threshold). Without evidence main's trimmer still runs.
  const quietLiveChunk = () => {
    const chunk = makePcmChunk(0);
    const view = new DataView(chunk.buffer);
    for (let i = 0; i < VAD_CHUNK_SAMPLES; i++) view.setInt16(i * 2, [0, 18, -3, -18, 7, 1][i % 6]!, true);
    return chunk; // 36 LSB: a live quiet floor, never dead-device flat
  };
  const withChunking = async (chunked: boolean, body: () => Promise<void>) => {
    const previous = process.env.QA_VOICE_CHUNKED_STT;
    process.env.QA_VOICE_CHUNKED_STT = chunked ? "1" : "0";
    try { await body(); } finally {
      if (previous === undefined) delete process.env.QA_VOICE_CHUNKED_STT;
      else process.env.QA_VOICE_CHUNKED_STT = previous;
    }
  };
  for (const chunked of [false, true]) {
    for (const ending of ["confirmed report", "unconfirmed report", "recorder EOF", "no-event control"] as const) {
      it(`MICDROP3 R1 long tail past the PTT trimmer, chunked=${chunked}, ${ending}: exact bytes in archive, recovery and backend`, async () => {
        await withChunking(chunked, async () => {
          vadProcessSpy!.mockResolvedValue(0.95);
          const recorder = installFakeRecorder(liveChunks(40), true);
          const { waitForInput, reportInputDeviceLost } = await import("../input");
          let archivePath = "";
          const pending = waitForInput(20_000, "standard", true, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
          try {
            await waitUntil(() => existsSync(retainedPath) && readWavDataSize(retainedPath) === 40 * VAD_CHUNK_BYTES,
              "live first", 10_000);
            if (ending.endsWith("report")) expect(reportInputDeviceLost("device-removed", liveCaptureId())).toBe(true);
            const tail = ending === "unconfirmed report" ? quietLiveChunk : ditherChunk;
            for (let n = 0; n < 200; n++) recorder.push(tail());
            await waitUntil(() => readWavDataSize(retainedPath) === 240 * VAD_CHUNK_BYTES, "long tail", 10_000);
            if (ending === "recorder EOF") recorder.end();
            else writeFileSync(STOP_FILE, "stop");
            expect(await raceStillRecording(pending, 6_000)).toBe("Retained transcript.");
            // Main's trimmer output for this fixture (Sol R1: 80,000 bytes, 2,500 ms) when there is no evidence.
            const expected = ending === "no-event control" ? 80_000 : 240 * VAD_CHUNK_BYTES;
            expect({
              archive: readWavDataSize(join(archivePath, "audio.wav")),
              recovery: readWavDataSize(retainedPath),
              backend: backendTranscribedDataSize,
            }).toEqual({ archive: 240 * VAD_CHUNK_BYTES, recovery: expected, backend: expected });
            const loss = broadcasts.find(e => e.type === "mic_disconnected");
            if (ending === "confirmed report") expect(loss).toMatchObject({ at_ms: 1280, reason: "device-removed" });
            else if (ending === "recorder EOF") expect(loss).toMatchObject({ at_ms: 7680, reason: "recorder-ended" });
            else expect(loss).toBeUndefined();
          } finally {
            writeFileSync(STOP_FILE, "stop");
            await pending.catch(() => null);
            clearStopSignal();
          }
        });
      }, 15_000);
    }
  }

  it("MICDROP3 R1 a quiet live floor BEFORE a confirmed report is decoded whole (Sol R1 pre-event control)", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    const recorder = installFakeRecorder([...liveChunks(40), ...Array.from({ length: 200 }, quietLiveChunk)], true);
    const { waitForInput, reportInputDeviceLost } = await import("../input");
    let archivePath = "";
    const pending = waitForInput(20_000, "standard", true, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
    try {
      await waitUntil(() => existsSync(retainedPath) && readWavDataSize(retainedPath) === 240 * VAD_CHUNK_BYTES,
        "quiet live floor before the event", 10_000);
      expect(reportInputDeviceLost("device-removed", liveCaptureId())).toBe(true);
      for (let n = 0; n < 20; n++) recorder.push(ditherChunk());
      await stopPushToEndOnceCaptured(260 * VAD_CHUNK_BYTES);
      expect(await pending).toBe("Retained transcript.");
      expect({
        archive: readWavDataSize(join(archivePath, "audio.wav")),
        recovery: readWavDataSize(retainedPath),
        backend: backendTranscribedDataSize,
      }).toEqual({ archive: 260 * VAD_CHUNK_BYTES, recovery: 260 * VAD_CHUNK_BYTES, backend: 260 * VAD_CHUNK_BYTES });
      expect(broadcasts.find(e => e.type === "mic_disconnected")).toMatchObject({ at_ms: 7680, message: "Mic disconnected at 0:08" });
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await pending.catch(() => null);
      clearStopSignal();
    }
  }, 15_000);

  it("MICDROP3 R1 trimmed: chunked PTT, a report with a zero tail past the trimmer → the rebuilt session gets every byte", async () => {
    await withChunking(true, async () => {
      vadProcessSpy!.mockResolvedValue(0.95);
      installFakeRecorder([...liveChunks(40), ...Array.from({ length: 200 }, () => makePcmChunk(0))], true);
      const { waitForInput, reportInputDeviceLost } = await import("../input");
      let archivePath = "";
      const pending = waitForInput(20_000, "standard", true, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
      try {
        await waitUntil(() => Number.isSafeInteger(liveCaptureId()), "capture running", 10_000);
        expect(reportInputDeviceLost("device-removed", liveCaptureId())).toBe(true);
        await stopPushToEndOnceCaptured(240 * VAD_CHUNK_BYTES);
        expect(await pending).toBe("Retained transcript.");
        expect({
          archive: readWavDataSize(join(archivePath, "audio.wav")),
          recovery: readWavDataSize(retainedPath),
          backend: backendTranscribedDataSize,
        }).toEqual({ archive: 240 * VAD_CHUNK_BYTES, recovery: 240 * VAD_CHUNK_BYTES, backend: 240 * VAD_CHUNK_BYTES });
      } finally {
        writeFileSync(STOP_FILE, "stop");
        await pending.catch(() => null);
        clearStopSignal();
      }
    });
  }, 15_000);

  for (const [label, tail] of [
    ["gated zeros", () => makePcmChunk(0)],
    ["dead-device dither", ditherChunk],
  ] as const) {
    it(`MICDROP2 no OS event: a ${label} final pause on an open recorder changes nothing`, async () => {
      vadProcessSpy!.mockResolvedValue(0.95);
      installFakeRecorder([...liveChunks(40), ...Array.from({ length: 40 }, tail)], true);
      const { waitForInput } = await import("../input");
      let archivePath = "";
      const pending = waitForInput(20_000, "standard", true, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
      try {
        await stopPushToEndOnceCaptured(80 * VAD_CHUNK_BYTES);
        expect(await pending).toBe("Retained transcript.");
        // Main's decoder input, byte for byte (Sol R2 #1 probe: 81,920 bytes, no loss event).
        expect(backendTranscribedDataSize).toBe(80 * VAD_CHUNK_BYTES);
        expect(broadcasts.some(e => e.type === "mic_disconnected")).toBe(false);
        expect(archiveMetadata(archivePath).mic_disconnect_reason).toBeUndefined();
      } finally {
        await pending.catch(() => null);
        clearStopSignal();
      }
    }, 10_000);
  }

  it("MICDROP2: a live mic noise-gated to zeros for 4.5 s keeps recording and keeps the words after it", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    const gatedPause = Array.from({ length: 140 }, () => makePcmChunk(0)); // 4.48 s of exact zeros
    installFakeRecorder([...liveChunks(40), ...gatedPause, ...liveChunks(40)], true);
    const { recordToBuffer } = await import("../input");
    const captureState: { micDisconnect?: unknown } = {};
    const recording = recordToBuffer(20_000, "standard", true, undefined, undefined, true, captureState as never);
    try {
      await stopPushToEndOnceCaptured(220 * VAD_CHUNK_BYTES);
      expect((await recording)?.byteLength).toBe(220 * VAD_CHUNK_BYTES);
      expect(captureState.micDisconnect).toBeUndefined();
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
      clearStopSignal();
    }
  }, 15_000);

  for (const silenceMode of ["quick", "standard", "thoughtful"] as const) {
    it(`MICDROP2 VAD ${silenceMode}: EOF evidence holds against a pending silence close, and nothing is cut`, async () => {
      vadProbabilityForCall = call => (call <= 50 ? 0.95 : 0);
      // Interior gated gap, then dither and EOF queued before VAD reaches the silence that would close it.
      installFakeRecorder([...liveChunks(30), ...Array.from({ length: 10 }, () => makePcmChunk(0)),
        ...liveChunks(10), ...Array.from({ length: 100 }, ditherChunk)], false);
      const { waitForInput } = await import("../input");
      let archivePath = "";
      const pending = waitForInput(20_000, silenceMode, false, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
      try {
        expect(await raceStillRecording(pending, 6_000)).toBe("Retained transcript.");
        expect(backendTranscribedDataSize).toBe(150 * VAD_CHUNK_BYTES);
        expect(readWavDataSize(join(archivePath, "audio.wav"))).toBe(150 * VAD_CHUNK_BYTES);
        expect(broadcasts.find(e => e.type === "mic_disconnected")).toEqual({
          type: "mic_disconnected", at_ms: 4800, reason: "recorder-ended", message: "Mic disconnected at 0:05",
        });
      } finally {
        writeFileSync(STOP_FILE, "stop");
        await pending.catch(() => null);
        clearStopSignal();
      }
    }, 10_000);
  }

  it("MICDROP2: a recorder that ends having never carried signal says so, with no fake 0:00", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 10 }, ditherChunk), false);
    const { waitForInput } = await import("../input");
    let archivePath = "";
    const pending = waitForInput(20_000, "standard", true, { archiveSource: "voicebar", onArchiveCreated: p => { archivePath = p; } });
    try {
      expect(await raceStillRecording(pending, 4_000)).toBeNull();
      expect(broadcasts.some(e => e.type === "mic_disconnected")).toBe(false);
      expect(JSON.stringify(broadcasts)).not.toContain("0:00");
      expect(broadcasts.find(e => e.type === "error")?.message).toBe("Mic produced no signal");
      expectValidRetainedWav(join(archivePath, "audio.wav"), 10 * VAD_CHUNK_BYTES);
      expect(archiveMetadata(archivePath)).toMatchObject({
        mic_disconnected_at_ms: null, mic_disconnect_reason: "recorder-ended", mic_disconnect_note: "Mic produced no signal",
      });
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await pending.catch(() => null);
      clearStopSignal();
    }
  }, 10_000);

  it("MICDROP2: the EOF our own teardown causes is never evidence", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(liveChunks(24), true);
    const { recordToBuffer } = await import("../input");
    const captureState: { micDisconnect?: unknown } = {};
    const recording = recordToBuffer(2_000, "standard", true, undefined, undefined, true, captureState as never);
    await stopPushToEndOnceCaptured(24 * VAD_CHUNK_BYTES);
    expect((await recording)?.byteLength).toBe(24 * VAD_CHUNK_BYTES);
    expect(captureState.micDisconnect).toBeUndefined();
  });

  it("permanently archives failed VoiceBar STT before another capture overwrites recovery", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    const chunks = Array.from({ length: 24 }, () => makePcmChunk(1800));
    installFakeRecorder(chunks, false);
    backendMode = "throw-on-get";
    const { waitForInput, recordToBuffer } = await import("../input");

    const failed = waitForInput(2_000, "standard", true, { archiveSource: "voicebar" });
    await stopPushToEndOnceCaptured(24 * VAD_CHUNK_BYTES);
    await expect(failed).rejects.toThrow("whisper backend is still warming");
    const archives = capturedVoiceBarAudio();
    expect(archives).toHaveLength(1);
    const preserved = readFileSync(archives[0]);
    expectCaptureLinked(archives[0]);
    expectValidRetainedWav(archives[0], 24 * VAD_CHUNK_BYTES);
    expect(JSON.parse(readFileSync(archives[0].replace("audio.wav", "metadata.json"), "utf8")))
      .toMatchObject({ source: "voicebar", transcription_status: "captured" });

    installFakeRecorder([makePcmChunk(2500)], false);
    const next = recordToBuffer(2_000, "standard", true);
    await stopPushToEndOnceCaptured(VAD_CHUNK_BYTES);
    await next;
    expect(readFileSync(retainedPath)).not.toEqual(preserved);
    expect(readFileSync(archives[0])).toEqual(preserved);
  });

  for (const termination of ["abort", "cancel"] as const) {
    it(`publishes VoiceBar audio while STT hangs and keeps it after ${termination}`, async () => {
      vadProcessSpy!.mockResolvedValue(0.95);
      backendMode = "hang";
      installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
      const { waitForInput } = await import("../input");
      const controller = new AbortController();
      const pending = waitForInput(2_000, "standard", true, {
        archiveSource: "voicebar", signal: controller.signal,
      });
      const settled = pending.then(value => value, error => error);
      try {
        await stopPushToEndOnceCaptured(24 * VAD_CHUNK_BYTES);
        await waitUntil(() => backendTranscribeCalls === 1, "hung VoiceBar STT", 4_000);
        const archives = capturedVoiceBarAudio();
        expect(archives).toHaveLength(1);
        expectValidRetainedWav(archives[0], 24 * VAD_CHUNK_BYTES);
        if (termination === "abort") controller.abort(new Error("STT deadline"));
        else setCancelSignal();
        finishHangingTranscription?.();
        const result = await settled;
        if (termination === "abort") expect(result).toBeInstanceOf(Error);
        else {
          expect(result).toBeNull();
          expect(broadcasts.some(event => event.type === "transcription")).toBe(false);
          expect(existsSync(archives[0].replace("audio.wav", "voicelayer-transcript.txt"))).toBe(false);
          expect(JSON.parse(readFileSync(archives[0].replace("audio.wav", "metadata.json"), "utf8")))
            .toMatchObject({ transcription_status: "cancelled", voicelayer_transcript_chars: 0 });
        }
        expect(broadcasts.some((event) => event.dictation_receipt)).toBe(false);
        expect(capturedVoiceBarAudio()).toEqual(archives);
        expectCaptureLinked(archives[0]);
        expectValidRetainedWav(archives[0], 24 * VAD_CHUNK_BYTES);
      } finally {
        controller.abort(new Error("test cleanup"));
        finishHangingTranscription?.();
        await settled;
      }
    });
  }

  it("finalizes the pre-STT VoiceBar archive in place without a duplicate row", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    const { waitForInput } = await import("../input");
    let capturePath: string | undefined;
    await expect(waitForInput(2_000, "standard", true, {
      archiveSource: "voicebar",
      onCaptureEnd: () => {
        const archives = capturedVoiceBarAudio();
        expect(archives).toHaveLength(1);
        capturePath = archives[0];
        expectCaptureLinked(capturePath);
      },
    })).resolves.toBe("Retained transcript.");
    const originalTime = JSON.parse(readFileSync(capturePath!.replace("audio.wav", "metadata.json"), "utf8")).created_at;
    expect(broadcasts.find(event => event.type === "transcription")?.recording_created_at).toBe(originalTime);
    broadcasts = [];
    const { retranscribeRecordingCapture } = await import("../input");
    await retranscribeRecordingCapture(capturePath!);
    expect(broadcasts.find(event => event.type === "transcription")?.recording_created_at).toBe(originalTime);
    expect(capturedVoiceBarAudio()).toEqual([capturePath]);
    if (!capturePath) throw new Error("no pre-STT archive");
    expect(JSON.parse(readFileSync(capturePath.replace("audio.wav", "metadata.json"), "utf8")))
      .toMatchObject({ transcription_status: "transcribed", backend: "fake-stt" });
    expect(readFileSync(capturePath.replace("audio.wav", "voicelayer-transcript.txt"), "utf8"))
      .toBe("Retained transcript.");
  });

  for (const legacy of [undefined, "1"]) {
    it(`short dictations skip timing work at all three call sites (legacy smart-boundaries env ${legacy ?? "unset"})`, async () => {
      const input = await import("../input");
      const journal = await import("../control-layer-journal");
      // Smart boundaries was removed (2026-10-19); a leftover env var must not
      // bring back the per-dictation audio read and Silero pass.
      const saved = process.env.VOICELAYER_STT_SMART_BOUNDARIES;
      if (legacy === undefined) delete process.env.VOICELAYER_STT_SMART_BOUNDARIES;
      else process.env.VOICELAYER_STT_SMART_BOUNDARIES = legacy;
      const build = spyOn(input, "buildBoundaryContext").mockResolvedValue(undefined);
      const events = spyOn(journal, "appendControlLayerEvent").mockImplementation(() => {});
      vadProbabilityForCall = () => .95;
      installFakeRecorder(Array.from({length:24},()=>makePcmChunk(1800)),false);
      let archive: string | undefined;
      try {
        expect(await input.waitForInput(2_000,"standard",true,{
          archiveSource:"voicebar",onArchiveCreated:path=>{archive=join(path,"audio.wav");},
        })).toBe("Retained transcript.");
        expect(archive).toBeDefined();
        await input.retranscribeRecordingCapture(archive!);
        await input.retranscribeLastCapture();
        expect(build).toHaveBeenCalledTimes(0);
      } finally {
        build.mockRestore(); events.mockRestore();
        if (saved === undefined) delete process.env.VOICELAYER_STT_SMART_BOUNDARIES;
        else process.env.VOICELAYER_STT_SMART_BOUNDARIES = saved;
      }
    });
  }

  for (const characters of [399, 400, 401]) {
    it(`paragraph timing threshold at ${characters} chars covers all three call sites`, async () => {
      const input = await import("../input");
      const journal = await import("../control-layer-journal");
      const savedParagraphs = process.env.VOICELAYER_STT_PAUSE_PARAGRAPHS;
      process.env.VOICELAYER_STT_PAUSE_PARAGRAPHS = "1";
      backendText = "A" + "b".repeat(characters - 2) + ".";
      expect(backendText.length).toBe(characters);
      const build = spyOn(input, "buildBoundaryContext").mockResolvedValue(undefined);
      const events = spyOn(journal, "appendControlLayerEvent").mockImplementation(() => {});
      vadProbabilityForCall = () => .95;
      installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
      const expectedPerCall = characters >= 400 ? 1 : 0;
      let archive: string | undefined;
      try {
        expect(await input.waitForInput(2_000, "standard", true, {
          archiveSource: "voicebar", onArchiveCreated: path => { archive = join(path, "audio.wav"); },
        })).toBe(backendText);
        expect(build).toHaveBeenCalledTimes(expectedPerCall);
        expect(archive).toBeDefined();
        await input.retranscribeRecordingCapture(archive!);
        expect(build).toHaveBeenCalledTimes(2 * expectedPerCall);
        await input.retranscribeLastCapture();
        expect(build).toHaveBeenCalledTimes(3 * expectedPerCall);
      } finally {
        build.mockRestore(); events.mockRestore();
        if (savedParagraphs === undefined) delete process.env.VOICELAYER_STT_PAUSE_PARAGRAPHS;
        else process.env.VOICELAYER_STT_PAUSE_PARAGRAPHS = savedParagraphs;
      }
    });
  }

  it("archives captured VoiceBar PCM when the recorder fails", async () => {
    vadMode = "throw";
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    const { waitForInput, retranscribeLastCapture } = await import("../input");
    await expect(waitForInput(2_000, "quick", false, {
      archiveSource: "voicebar",
    })).rejects.toThrow("vad exploded after capture");
    const archives = capturedVoiceBarAudio();
    expect(archives).toHaveLength(1);
    expectValidRetainedWav(archives[0]);
    await expect(retranscribeLastCapture()).resolves.toBe("Retained transcript.");
    expect(JSON.parse(readFileSync(archives[0].replace("audio.wav", "metadata.json"), "utf8")))
      .toMatchObject({ transcription_status: "transcribed", backend: "fake-stt" });
    expect(capturedVoiceBarAudio()).toEqual(archives);
    expect(broadcasts).toContainEqual(expect.objectContaining({
      type: "transcription", recording_path: archives[0],
    }));
  });

  for (const exit of ["cancel", "abort", "gate"] as const) {
    it(`keeps the pre-STT VoiceBar archive linked after ${exit}`, async () => {
      installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(0)), false);
      const { waitForInput } = await import("../input");
      const controller = new AbortController();
      const pending = waitForInput(2_000, "standard", true, {
        archiveSource: "voicebar", signal: controller.signal,
        onCaptureEnd: () => {
          if (exit === "cancel") setCancelSignal();
          if (exit === "abort") controller.abort(new Error("capture abort"));
        },
      });
      if (exit === "abort") await expect(pending).rejects.toThrow("capture abort");
      else await expect(pending).resolves.toBeNull();
      const archives = capturedVoiceBarAudio();
      expect(archives).toHaveLength(1);
      expectCaptureLinked(archives[0]);
      expect(backendTranscribeCalls).toBe(0);
      expect(broadcasts.some((event) => event.dictation_receipt)).toBe(false);
    });
  }

  it("warns and delivers VoiceBar STT when its permanent capture archive cannot be written", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    const root = join(tmpRoot, "archive-root-file");
    writeFileSync(root, "not a directory");
    process.env.QA_VOICE_RECORDINGS_DIR = root;
    const { waitForInput } = await import("../input");
    await expect(waitForInput(2_000, "standard", true, {
      archiveSource: "voicebar",
    })).resolves.toBe("Retained transcript.");
    expect(backendTranscribeCalls).toBe(1);
    expect(broadcasts).toContainEqual({
      type: "error",
      message: expect.stringContaining("voicebar archive failed"),
      recoverable: true,
    });
    expect(broadcasts).toContainEqual(expect.objectContaining({
      type: "transcription", text: "Retained transcript.",
    }));
    expect(
      broadcasts.find((event) => event.type === "transcription")?.dictation_receipt,
    ).toBeUndefined();
    expectValidRetainedWav(retainedPath, 24 * VAD_CHUNK_BYTES);
  });

  it("publishes idle when both VoiceBar recording and archive creation fail", async () => {
    vadMode = "throw";
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    const root = join(tmpRoot, "archive-root-file");
    writeFileSync(root, "not a directory");
    process.env.QA_VOICE_RECORDINGS_DIR = root;
    const { waitForInput } = await import("../input");
    await expect(waitForInput(2_000, "quick", false, {
      archiveSource: "voicebar",
    })).rejects.toThrow("vad exploded after capture");
    expect(broadcasts).toContainEqual(expect.objectContaining({
      type: "error", recoverable: true,
      message: expect.stringContaining("vad exploded after capture"),
    }));
    expect(broadcasts).toContainEqual({
      type: "state", state: "idle", source: "recording",
    });
    expectValidRetainedWav(retainedPath);
  });

  it("delivers text without claiming archive finalization when metadata cannot be updated", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(Array.from({ length: 24 }, () => makePcmChunk(1800)), false);
    const { waitForInput } = await import("../input");
    await expect(waitForInput(2_000, "standard", true, {
      archiveSource: "voicebar",
      onCaptureEnd: () => {
        const metadata = capturedVoiceBarAudio()[0].replace("audio.wav", "metadata.json");
        rmSync(metadata);
        mkdirSync(metadata);
      },
    })).resolves.toBe("Retained transcript.");
    expect(broadcasts).toContainEqual(expect.objectContaining({
      type: "error", message: expect.stringContaining("archive finalization failed"),
    }));
    const event = broadcasts.find((event) => event.type === "transcription");
    expect(event?.text).toBe("Retained transcript.");
    expect(event?.recording_path).toBeUndefined();
    expect(event?.dictation_receipt).toBeUndefined();
    expectValidRetainedWav(capturedVoiceBarAudio()[0], 24 * VAD_CHUNK_BYTES);
  });

  it("adds measured receipt metadata to the actual completed VoiceBar event", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
    );
    const { waitForInput } = await import("../input");
    const clockValues = [1_000, 1_123.6];
    let clockReads = 0;

    await expect(
      waitForInput(2_000, "standard", true, {
        archiveSource: "voicebar",
        monotonicNow: () => clockValues[clockReads++]!,
      }),
    ).resolves.toBe("Retained transcript.");

    const event = broadcasts.find(
      (candidate) => candidate.type === "transcription",
    );
    expect(event).toEqual(
      expect.objectContaining({
        type: "transcription",
        text: "Retained transcript.",
        recording_path: capturedVoiceBarAudio()[0],
        dictation_receipt: {
          audio_duration_ms: 768,
          processing_duration_ms: 124,
        },
      }),
    );
    expect(event?.partial).toBeUndefined();
    expect(backendTranscribeCalls).toBe(1);
    expect(clockReads).toBe(2);
  });

  it("persists processing time and spoken length into the VoiceBar archive metadata (F1)", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    // 512 ms speech · 1024 ms pause · 512 ms speech = 2048 ms of mic-on time.
    installFakeRecorder(
      [
        ...Array.from({ length: 16 }, () => makePcmChunk(1800)),
        ...Array.from({ length: 32 }, () => makePcmChunk(0)),
        ...Array.from({ length: 16 }, () => makePcmChunk(1800)),
      ],
      false,
    );
    const { waitForInput } = await import("../input");
    const clockValues = [1_000, 2_234.4];
    let clockReads = 0;

    await expect(
      waitForInput(2_500, "standard", true, {
        archiveSource: "voicebar",
        monotonicNow: () => clockValues[clockReads++]!,
      }),
    ).resolves.toBe("Retained transcript.");

    const readMetadata = () =>
      JSON.parse(
        readFileSync(
          capturedVoiceBarAudio()[0].replace("audio.wav", "metadata.json"),
          "utf8",
        ),
      );
    const atReturn = readMetadata();
    expect(atReturn.duration_ms).toBe(2048);
    expect(atReturn.processing_duration_ms).toBe(1234);
    // Measured off the paste hot path: not yet written when the transcript is delivered.
    expect("spoken_duration_ms" in atReturn).toBe(false);
    const completedEvents = () =>
      broadcasts.filter((event) => event.type === "archive_metadata_updated");
    expect(completedEvents()).toEqual([]);

    await new Promise((resolve) => setImmediate(resolve));
    const later = readMetadata();
    // F1 round 2: once the write is durable, History is told to drop its cached copy of this entry.
    expect(completedEvents()).toEqual([
      { type: "archive_metadata_updated", recording_path: capturedVoiceBarAudio()[0] },
    ]);
    expect(broadcasts.findIndex((event) => event.type === "archive_metadata_updated"))
      .toBeGreaterThan(broadcasts.findIndex((event) => event.type === "transcription"));
    // The pause is visible: spoken time excludes it, at the 250 ms window grain.
    expect(later.spoken_duration_ms).toBeGreaterThanOrEqual(1024);
    expect(later.spoken_duration_ms).toBeLessThanOrEqual(2048 - 500);
    expect(later.processing_duration_ms).toBe(1234);
  });

  for (const throwOnRead of [1, 2]) {
    it(`preserves the completed VoiceBar transcript when receipt clock read ${throwOnRead} throws`, async () => {
      vadProcessSpy!.mockResolvedValue(0.95);
      installFakeRecorder(
        Array.from({ length: 24 }, () => makePcmChunk(1800)),
        false,
      );
      const { waitForInput } = await import("../input");
      let clockReads = 0;

      await expect(waitForInput(2_000, "standard", true, {
        archiveSource: "voicebar",
        monotonicNow: () => {
          if (++clockReads === throwOnRead) throw new Error("receipt clock failed");
          return 1_000 + clockReads;
        },
      })).resolves.toBe("Retained transcript.");

      const event = broadcasts.find((candidate) => candidate.type === "transcription");
      expect(event?.text).toBe("Retained transcript.");
      expect(event?.recording_path).toBe(capturedVoiceBarAudio()[0]);
      expect(event?.dictation_receipt).toBeUndefined();
      expect(backendTranscribeCalls).toBe(1);
    });
  }

  it("runs production waitForInput through STT into an indefinite paired voice_ask archive", async () => {
    vadProcessSpy.mockResolvedValue(0.95);
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
    );
    const { waitForInput } = await import("../input");
    const agentAudio = new Uint8Array([0x49, 0x44, 0x33, 4, 5, 6]);
    let phaseChangeCount = 0;

    const response = await waitForInput(2_000, "standard", true, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: agentAudio,
        agentAudioFormat: "mp3",
        agentTranscript: "Production-path question",
        agentTtsEngine: "f5-tts-mlx",
        agentTtsVoice: "etan-f5",
        createdAt: new Date("2026-07-16T20:30:00.000Z"),
      },
      onPhaseChange: () => {
        phaseChangeCount += 1;
        throw new Error("progress observer failed");
      },
    });

    expect(response).toBe("Retained transcript.");
    expect(phaseChangeCount).toBe(1);
    const dayDir = join(tmpRoot, "recordings", "2026-07-16");
    const archiveIds = readdirSync(dayDir);
    expect(archiveIds).toHaveLength(1);
    const archiveDir = join(dayDir, archiveIds[0]);
    expect(readdirSync(archiveDir).sort()).toEqual([
      "agent-audio.mp3",
      "agent-transcript.txt",
      "audio.wav",
      "metadata.json",
      "voicelayer-transcript.txt",
    ]);
    expect(readFileSync(join(archiveDir, "agent-audio.mp3"))).toEqual(
      Buffer.from(agentAudio),
    );
    expect(
      readFileSync(join(archiveDir, "voicelayer-transcript.txt"), "utf8"),
    ).toBe("Retained transcript.");
    const metadata = JSON.parse(
      readFileSync(join(archiveDir, "metadata.json"), "utf8"),
    );
    expect(metadata).toMatchObject({
      source: "voice_ask",
      retention_policy: "indefinite",
      transcription_status: "transcribed",
      agent_tts_engine: "f5-tts-mlx",
      agent_tts_voice: "etan-f5",
    });
    expect(
      broadcasts.some(
        (event) =>
          event.type === "transcription" &&
          event.recording_path === join(archiveDir, "audio.wav"),
      ),
    ).toBe(true);
    expect(
      broadcasts.find((event) => event.type === "transcription")
        ?.dictation_receipt,
    ).toBeUndefined();
  });

  it("reports an archived exact-silence voice_ask capture as no speech", async () => {
    vadProcessSpy.mockResolvedValue(0);
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(0)),
      false,
    );
    const { waitForInput } = await import("../input");
    let noSpeechCount = 0;

    const response = await waitForInput(2_000, "standard", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33, 7, 8, 9]),
        agentAudioFormat: "mp3",
        agentTranscript: "Are you there?",
        agentTtsEngine: "edge-tts",
        agentTtsVoice: "en-US-AndrewNeural",
        createdAt: new Date("2026-07-18T11:04:10.000Z"),
      },
      onNoSpeech: () => {
        noSpeechCount += 1;
        throw new Error("no-speech observer failed");
      },
    });

    expect(response).toBeNull();
    expect(noSpeechCount).toBe(1);
    expect(backendTranscribeCalls).toBe(0);
    const dayDir = join(tmpRoot, "recordings", "2026-07-18");
    const archiveIds = readdirSync(dayDir);
    expect(archiveIds).toHaveLength(1);
    expect(
      JSON.parse(
        readFileSync(join(dayDir, archiveIds[0], "metadata.json"), "utf8"),
      ),
    ).toMatchObject({
      source: "voice_ask",
      transcription_status: "captured",
      retention_policy: "indefinite",
    });
  });

  it("archives high-energy VAD no-speech without sending ambient PCM to STT", async () => {
    vadProcessSpy.mockResolvedValue(0);
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
    );
    const { waitForInput } = await import("../input");
    let noSpeechCount = 0;

    const response = await waitForInput(2_000, "standard", false, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33, 6, 5, 4]),
        agentAudioFormat: "mp3",
        agentTranscript: "Did you answer?",
        agentTtsEngine: "edge-tts",
        agentTtsVoice: "en-US-AndrewNeural",
        createdAt: new Date("2026-07-18T11:04:20.000Z"),
      },
      onNoSpeech: () => {
        noSpeechCount += 1;
      },
    });

    expect(response).toBeNull();
    expect(noSpeechCount).toBe(1);
    expect(backendTranscribeCalls).toBe(0);
    const dayDir = join(tmpRoot, "recordings", "2026-07-18");
    const archiveIds = readdirSync(dayDir);
    expect(archiveIds).toHaveLength(1);
    expect(
      JSON.parse(
        readFileSync(join(dayDir, archiveIds[0], "metadata.json"), "utf8"),
      ),
    ).toMatchObject({
      source: "voice_ask",
      transcription_status: "captured",
      retention_policy: "indefinite",
    });
  });

  it("publishes the paired voice_ask capture before a timed-out STT can fail", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    backendMode = "hang";
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
    );
    const { waitForInput } = await import("../input");
    const controller = new AbortController();
    const pending = waitForInput(2_000, "standard", true, {
      archiveSource: "voice_ask",
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33, 9, 8, 7]),
        agentAudioFormat: "mp3",
        agentTranscript: "Archive the failure case",
        agentTtsEngine: "f5-tts-mlx",
        agentTtsVoice: "etan-f5",
        createdAt: new Date("2026-07-18T11:04:10.000Z"),
      },
      signal: controller.signal,
    });

    while (backendTranscribeCalls === 0) await Bun.sleep(1);
    controller.abort(new Error("voice_ask return stage timed out"));

    const dayDir = join(tmpRoot, "recordings", "2026-07-18");
    const archiveIds = readdirSync(dayDir);
    expect(archiveIds).toHaveLength(1);
    const archiveDir = join(dayDir, archiveIds[0]);
    expect(readdirSync(archiveDir).sort()).toEqual([
      "agent-audio.mp3",
      "agent-transcript.txt",
      "audio.wav",
      "metadata.json",
    ]);
    expect(
      JSON.parse(readFileSync(join(archiveDir, "metadata.json"), "utf8")),
    ).toMatchObject({
      source: "voice_ask",
      transcription_status: "captured",
      retention_policy: "indefinite",
    });

    finishHangingTranscription?.();
    await expect(pending).rejects.toThrow("voice_ask return stage timed out");
  });

  it("labels paired archive failures at the capture-end boundary", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    // Open stdout: a recorder EOF would be MICDROP2 device-loss evidence, not this test's subject.
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      true,
    );
    const archiveRootFile = join(tmpRoot, "archive-root-is-a-file");
    writeFileSync(archiveRootFile, "not a directory");
    process.env.QA_VOICE_RECORDINGS_DIR = archiveRootFile;
    const { waitForInput } = await import("../input");

    await expect(
      waitForInput(2_000, "standard", true, {
        archiveSource: "voice_ask",
        voiceAskArtifacts: {
          agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
          agentAudioFormat: "mp3",
          agentTranscript: "Archive failure question",
          agentTtsEngine: "edge-tts",
          agentTtsVoice: "en-US-JennyNeural",
        },
      }),
    ).rejects.toThrow("voice_ask archive failed");

    const errorEvent = broadcasts.find((event) => event.type === "error");
    expect(errorEvent?.message).toStartWith("voice_ask archive failed:");
  });

  it("restores idle and preserves the capture when its completion callback throws", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
    );
    const { getRecordingState, waitForInput } = await import("../input");

    await expect(
      waitForInput(2_000, "standard", true, {
        archiveSource: "voice_ask",
        voiceAskArtifacts: {
          agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33, 4, 5, 6]),
          agentAudioFormat: "mp3",
          agentTranscript: "Keep the capture if the callback fails",
          agentTtsEngine: "f5-tts-mlx",
          agentTtsVoice: "etan-f5",
          createdAt: new Date("2026-07-18T11:05:10.000Z"),
        },
        onCaptureEnd: () => {
          throw new Error("capture completion callback failed");
        },
      }),
    ).rejects.toThrow("capture completion callback failed");

    expect(getRecordingState()).toBe("idle");
    expect(
      broadcasts.some(
        (event) =>
          event.type === "state" &&
          event.state === "idle" &&
          event.source === "recording",
      ),
    ).toBe(true);
    const dayDir = join(tmpRoot, "recordings", "2026-07-18");
    expect(readdirSync(dayDir)).toHaveLength(1);
  });

  it("retranscribes a specific archived recording through the current finalizer and updates the history event in place", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-abcd1234",
    );
    mkdirSync(archiveDir, { recursive: true });
    const audioPath = join(archiveDir, "audio.wav");
    const transcriptPath = join(archiveDir, "voicelayer-transcript.txt");
    writeFileSync(audioPath, makeWav(makePcmChunk()));
    writeFileSync(transcriptPath, "Ethan confirmed the old transcript.");

    const { retranscribeRecordingCapture } = await import("../input");

    await expect(retranscribeRecordingCapture(audioPath)).resolves.toBe(
      "Retained transcript.",
    );
    expect(backendTranscribeCalls).toBe(1);
    expect(readFileSync(transcriptPath, "utf8")).toBe("Retained transcript.");
    const transcriptionEvent = broadcasts.find(
      (event) => event.type === "transcription",
    );
    expect(transcriptionEvent).toMatchObject({
      type: "transcription",
      text: "Retained transcript.",
      recording_path: audioPath,
    });
    expect(typeof transcriptionEvent?.polished).toBe("boolean");
    expect(typeof transcriptionEvent?.polish_status).toBe("string");
    if (transcriptionEvent?.polished === false) {
      expect(typeof transcriptionEvent.polish_reason).toBe("string");
    }
    expect(polishSurfaces).toEqual(["dictation"]);
  });

  it("identifies the newest dictation against the archive, including cancelled audio", async () => {
    const { retranscribeRecordingCapture } = await import("../input");
    const capture = (day: string, id: string, source = "voicebar") => {
      const dir = join(process.env.QA_VOICE_RECORDINGS_DIR!, day, id);
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "audio.wav"), makeWav(makePcmChunk()));
      writeFileSync(join(dir, "metadata.json"), JSON.stringify({
        source, created_at: `${day}T10:00:00.000Z`, transcription_status: "cancelled",
      }));
      return join(dir, "audio.wav");
    };
    const old = capture("2026-06-25", "2026-06-25T10-00-00-000Z-00000001");
    const newest = capture("2026-06-28", "2026-06-28T10-00-00-000Z-00000002");
    capture("2026-06-29", "2026-06-29T10-00-00-000Z-00000003", "voice_ask");
    capture("2026-06-30", ".tmp-unpublished");
    const backup = capture("2026-06-28", "backup-old");
    await retranscribeRecordingCapture(old);
    expect(broadcasts.find(event => event.type === "transcription")?.recording_is_latest).toBe(false);
    broadcasts = [];
    await retranscribeRecordingCapture(newest);
    expect(broadcasts.find(event => event.type === "transcription")?.recording_is_latest).toBe(true);
    broadcasts = [];
    await retranscribeRecordingCapture(backup);
    expect(broadcasts.find(event => event.type === "transcription")?.recording_is_latest).toBe(false);
    // Unknown newer archive metadata cannot authorize promotion over an undated legacy row.
    const unknown = capture("2026-07-01", "2026-07-01T10-00-00-000Z-00000004");
    writeFileSync(unknown.replace("audio.wav", "metadata.json"), "invalid synthetic metadata");
    broadcasts = [];
    await retranscribeRecordingCapture(newest);
    expect(broadcasts.find(event => event.type === "transcription")?.recording_is_latest).toBe(false);
    for (const source of ["unknown", undefined]) {
      writeFileSync(unknown.replace("audio.wav", "metadata.json"), JSON.stringify({
        created_at: "2026-07-01T10:00:00.000Z", source, transcription_status: "cancelled",
      }));
      broadcasts = [];
      await retranscribeRecordingCapture(unknown);
      expect(broadcasts.find(event => event.type === "transcription")?.recording_is_latest).toBe(false);
    }
  });

  it("refreshes archived metadata audio checksum after retranscribe repairs a stale WAV header", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-repair123",
    );
    mkdirSync(archiveDir, { recursive: true });
    const audioPath = join(archiveDir, "audio.wav");
    const transcriptPath = join(archiveDir, "voicelayer-transcript.txt");
    const metadataPath = join(archiveDir, "metadata.json");
    const pcm = makePcmChunk();
    writeFileSync(audioPath, makeWav(pcm));
    rewriteWavHeaderDataSize(audioPath, pcm.byteLength - 2);
    writeFileSync(transcriptPath, "Ethan confirmed the old transcript.");
    writeFileSync(
      metadataPath,
      JSON.stringify(
        {
          transcription_status: "transcribed",
          voicelayer_transcript_chars: 34,
          audio_sha256: "stale-checksum",
          backend: "old-stt",
          language_mode: "english",
        },
        null,
        2,
      ),
    );

    const { retranscribeRecordingCapture } = await import("../input");

    await expect(retranscribeRecordingCapture(audioPath)).resolves.toBe(
      "Retained transcript.",
    );

    const repairedAudio = readFileSync(audioPath);
    const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
    expect(readWavDataSize(audioPath)).toBe(pcm.byteLength);
    expect(metadata.audio_sha256).toBe(
      createHash("sha256").update(repairedAudio).digest("hex"),
    );
    expect(metadata.voicelayer_transcript_chars).toBe(
      "Retained transcript.".length,
    );
    expect(metadata.backend).toBe("fake-stt");
    expect(metadata.language_mode).toBe("auto");
  });

  it("retranscribeLastCapture updates the linked archive transcript and broadcasts recording_path", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-menu1234",
    );
    mkdirSync(archiveDir, { recursive: true });
    const archivedAudioPath = join(archiveDir, "audio.wav");
    const transcriptPath = join(archiveDir, "voicelayer-transcript.txt");
    const metadataPath = join(archiveDir, "metadata.json");
    const retainedWav = makeWav(makePcmChunk());
    writeFileSync(archivedAudioPath, retainedWav);
    writeFileSync(transcriptPath, "Old menu transcript.");
    writeFileSync(
      metadataPath,
      JSON.stringify(
        {
          id: "2026-06-25T10-11-12-000Z-menu1234",
          source: "voicebar",
          mode: "ptt",
          transcription_status: "transcribed",
          backend: "old-stt",
          language_mode: "english",
        },
        null,
        2,
      ),
    );
    writeFileSync(retainedPath, retainedWav);
    writeFileSync(
      `${retainedPath}.metadata.json`,
      `${JSON.stringify(
        {
          schema_version: 1,
          polish_surface: "dictation",
          audio_sha256: createHash("sha256").update(retainedWav).digest("hex"),
          archive_audio_path: archivedAudioPath,
        },
        null,
        2,
      )}\n`,
    );

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(readFileSync(transcriptPath, "utf8")).toBe("Retained transcript.");
    const transcriptionEvent = broadcasts.find(
      (event) => event.type === "transcription",
    );
    expect(transcriptionEvent).toMatchObject({
      type: "transcription",
      text: "Retained transcript.",
      recording_path: archivedAudioPath,
    });
    expect(JSON.parse(readFileSync(metadataPath, "utf8"))).toMatchObject({
      transcription_status: "transcribed",
      backend: "fake-stt",
      voicelayer_transcript_chars: "Retained transcript.".length,
    });
  });

  it("retranscribeLastCapture trims trailing silence before STT for linked ptt archives", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-trimlast",
    );
    mkdirSync(archiveDir, { recursive: true });
    const archivedAudioPath = join(archiveDir, "audio.wav");
    const archiveWav = makePttWavWithLongQuietTail();
    const retainedWav = makeWav(pcmWithConstantSample(2000, 5000));
    writeFileSync(archivedAudioPath, archiveWav);
    writeFileSync(
      join(archiveDir, "metadata.json"),
      JSON.stringify({ mode: "ptt", transcription_status: "transcribed" }),
    );
    writeFileSync(retainedPath, retainedWav);
    writeFileSync(
      `${retainedPath}.metadata.json`,
      `${JSON.stringify(
        {
          schema_version: 1,
          polish_surface: "dictation",
          audio_sha256: createHash("sha256").update(retainedWav).digest("hex"),
          archive_audio_path: archivedAudioPath,
        },
        null,
        2,
      )}\n`,
    );

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(backendTranscribedDataSize).toBe(16000 * 2 * 3);
    expect(readWavDataSize(archivedAudioPath)).toBe(16000 * 2 * 11);
    expect(readWavDataSize(retainedPath)).toBe(16000 * 2 * 5);
  });

  it("retranscribeRecordingCapture trims trailing silence before STT for ptt archives", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-trimhist",
    );
    mkdirSync(archiveDir, { recursive: true });
    const audioPath = join(archiveDir, "audio.wav");
    writeFileSync(audioPath, makePttWavWithLongQuietTail());
    writeFileSync(
      join(archiveDir, "metadata.json"),
      JSON.stringify({ mode: "ptt", transcription_status: "transcribed" }),
    );
    writeFileSync(
      join(archiveDir, "voicelayer-transcript.txt"),
      "Old history transcript.",
    );

    const { retranscribeRecordingCapture } = await import("../input");

    await expect(retranscribeRecordingCapture(audioPath)).resolves.toBe(
      "Retained transcript.",
    );
    expect(backendTranscribedDataSize).toBe(16000 * 2 * 3);
    expect(readWavDataSize(audioPath)).toBe(16000 * 2 * 11);
  });

  it("waitForInput links retained capture metadata to the archived audio path", async () => {
    vadProcessSpy!.mockResolvedValue(0.95);
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
    );
    const { waitForInput } = await import("../input");

    await waitForInput(2_000, "standard", true, {
      archiveSource: "voicebar",
    });

    const dayDir = join(
      tmpRoot,
      "recordings",
      new Date().toISOString().slice(0, 10),
    );
    const archiveDir = join(dayDir, readdirSync(dayDir)[0]);
    const archivedAudioPath = join(archiveDir, "audio.wav");
    const retainedMetadata = JSON.parse(
      readFileSync(`${retainedPath}.metadata.json`, "utf8"),
    );
    expect(retainedMetadata).toMatchObject({
      schema_version: 1,
      archive_audio_path: archivedAudioPath,
    });
  });

  it("links a cancelled VoiceBar archive so retranscribe last can replace that row", async () => {
    const recorder = installFakeRecorder(
      [makePcmChunk(1800), makePcmChunk(1800), makePcmChunk(1800)],
      true,
    );
    const { waitForInput, retranscribeLastCapture } = await import("../input");
    const recording = waitForInput(2_000, "quick", true, {
      archiveSource: "voicebar",
    });

    try {
      await recorder.waitForSpawn();
      setCancelSignal();
      writeFileSync(STOP_FILE, "stop");
      await expect(recording).resolves.toBeNull();
    } finally {
      writeFileSync(STOP_FILE, "stop");
      await recording.catch(() => null);
    }

    const dayDir = join(
      tmpRoot,
      "recordings",
      new Date().toISOString().slice(0, 10),
    );
    const archiveDir = join(dayDir, readdirSync(dayDir)[0]);
    const archivedAudioPath = join(archiveDir, "audio.wav");
    const transcriptPath = join(archiveDir, "voicelayer-transcript.txt");
    expect(
      JSON.parse(readFileSync(`${retainedPath}.metadata.json`, "utf8")),
    ).toMatchObject({
      archive_audio_path: archivedAudioPath,
    });
    expect(existsSync(transcriptPath)).toBe(false);

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(readFileSync(transcriptPath, "utf8")).toBe("Retained transcript.");
    expect(
      broadcasts.some(
        (event) =>
          event.type === "transcription" &&
          event.recording_path === archivedAudioPath,
      ),
    ).toBe(true);
    expect(
      broadcasts.find((event) => event.type === "transcription")
        ?.dictation_receipt,
    ).toBeUndefined();
  });

  it("retranscribeLastCapture ignores a non-string archive_audio_path instead of throwing", async () => {
    writeFileSync(retainedPath, makeWav(makePcmChunk()));
    writeFileSync(
      `${retainedPath}.metadata.json`,
      `${JSON.stringify(
        {
          schema_version: 1,
          polish_surface: "dictation",
          audio_sha256: createHash("sha256")
            .update(readFileSync(retainedPath))
            .digest("hex"),
          archive_audio_path: 123,
        },
        null,
        2,
      )}\n`,
    );

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
  });

  it("retranscribeLastCapture does not write a transcript outside the archive root", async () => {
    const outsideDir = join(tmpRoot, "outside");
    mkdirSync(outsideDir, { recursive: true });
    const outsideAudioPath = join(outsideDir, "audio.wav");
    const retainedWav = makeWav(makePcmChunk());
    writeFileSync(outsideAudioPath, retainedWav);
    writeFileSync(retainedPath, retainedWav);
    writeFileSync(
      `${retainedPath}.metadata.json`,
      `${JSON.stringify(
        {
          schema_version: 1,
          polish_surface: "dictation",
          audio_sha256: createHash("sha256").update(retainedWav).digest("hex"),
          archive_audio_path: outsideAudioPath,
        },
        null,
        2,
      )}\n`,
    );

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(existsSync(join(outsideDir, "voicelayer-transcript.txt"))).toBe(
      false,
    );
    const transcriptionEvent = broadcasts.find(
      (event) => event.type === "transcription",
    );
    expect(transcriptionEvent).toMatchObject({
      type: "transcription",
      text: "Retained transcript.",
    });
    expect(transcriptionEvent.recording_path).toBeUndefined();
  });

  it("retranscribeLastCapture does not trim unlinked retained audio", async () => {
    writeFileSync(retainedPath, makePttWavWithLongQuietTail());

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    expect(backendTranscribedDataSize).toBe(16000 * 2 * 11);
    expect(readWavDataSize(retainedPath)).toBe(16000 * 2 * 11);
  });

  it("linkRetainedCaptureToArchive does not throw when the retained WAV cannot be read", async () => {
    mkdirSync(retainedPath);
    const { linkRetainedCaptureToArchive } = await import("../input");

    expect(() =>
      linkRetainedCaptureToArchive(join(tmpRoot, "recordings", "audio.wav")),
    ).not.toThrow();
  });

  it("retranscribeLastCapture rejects an archived WAV whose data chunk is not at offset 36", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-riffchunks",
    );
    mkdirSync(archiveDir, { recursive: true });
    const archivedAudioPath = join(archiveDir, "audio.wav");
    const transcriptPath = join(archiveDir, "voicelayer-transcript.txt");
    const pcm = makePcmChunk();
    const retainedWav = makeWav(pcm);
    writeFileSync(archivedAudioPath, makeWavWithListChunkBeforeData(pcm));
    writeFileSync(transcriptPath, "Old riff transcript.");
    writeFileSync(
      join(archiveDir, "metadata.json"),
      JSON.stringify({ mode: "ptt", transcription_status: "transcribed" }),
    );
    writeFileSync(retainedPath, retainedWav);
    writeFileSync(
      `${retainedPath}.metadata.json`,
      `${JSON.stringify(
        {
          schema_version: 1,
          polish_surface: "dictation",
          audio_sha256: createHash("sha256").update(retainedWav).digest("hex"),
          archive_audio_path: archivedAudioPath,
        },
        null,
        2,
      )}\n`,
    );

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).rejects.toThrow(
      /missing the PCM data chunk/,
    );
    expect(backendTranscribeCalls).toBe(0);
    expect(readFileSync(transcriptPath, "utf8")).toBe("Old riff transcript.");
  });

  it("retranscribeLastCapture refuses an archive whose audio no longer matches the retained capture", async () => {
    const archiveDir = join(
      process.env.QA_VOICE_RECORDINGS_DIR!,
      "2026-06-25",
      "2026-06-25T10-11-12-000Z-swapped",
    );
    mkdirSync(archiveDir, { recursive: true });
    const archivedAudioPath = join(archiveDir, "audio.wav");
    const transcriptPath = join(archiveDir, "voicelayer-transcript.txt");
    const retainedWav = makeWav(makePcmChunk());

    // A DIFFERENT recording now occupies the linked archive path.
    const otherWav = makeWav(makePcmChunk(600));
    writeFileSync(archivedAudioPath, otherWav);
    writeFileSync(transcriptPath, "Someone else's words.");
    writeFileSync(
      join(archiveDir, "metadata.json"),
      JSON.stringify({ mode: "ptt", transcription_status: "transcribed" }),
    );

    writeFileSync(retainedPath, retainedWav);
    writeFileSync(
      `${retainedPath}.metadata.json`,
      `${JSON.stringify(
        {
          schema_version: 1,
          polish_surface: "dictation",
          audio_sha256: createHash("sha256").update(retainedWav).digest("hex"),
          archive_audio_path: archivedAudioPath,
          // Hash captured when the link was made, i.e. of the ORIGINAL archive.
          archive_audio_sha256: createHash("sha256")
            .update(makeWav(makePcmChunk()))
            .digest("hex"),
        },
        null,
        2,
      )}\n`,
    );

    const { retranscribeLastCapture } = await import("../input");

    await expect(retranscribeLastCapture()).resolves.toBe(
      "Retained transcript.",
    );
    // The other recording's transcript must not be overwritten.
    expect(readFileSync(transcriptPath, "utf8")).toBe("Someone else's words.");
    const transcriptionEvent = broadcasts.find(
      (event) => event.type === "transcription",
    );
    expect(transcriptionEvent.recording_path).toBeUndefined();
  });

  describe("ask-safe archive retranscription", () => {
    it("backfills a cut-off MCP Ask and announces only its durable History update", async () => {
      backendText = "Recovered synthetic answer, fu… keep keep the retraction.";
      const target = writeAskArchive({ transcript: null });
      const newer = writeAskArchive({
        id: "2026-08-20T10-11-14-000Z-deadbeef",
        transcript: "Newer synthetic answer.",
      });
      const { handleVoiceAsk } = await import("../handlers");
      broadcastSpy!.mockImplementation((event: any) => {
        if (event.type === "archive_metadata_updated") {
          expect(readFileSync(join(target.archiveDir, "voicelayer-transcript.txt"), "utf8"))
            .toBe(backendText);
          expect(JSON.parse(readFileSync(join(target.archiveDir, "metadata.json"), "utf8")))
            .toMatchObject({ transcription_status: "transcribed" });
        }
        broadcasts.push(event);
      });

      const result = await handleVoiceAsk({ retranscribe_archive_id: target.id });

      expect(result.isError).toBeUndefined();
      expect(result.content[0].text).toContain(backendText);
      expect(readFileSync(join(target.archiveDir, "voicelayer-transcript.txt"), "utf8"))
        .toBe(backendText);
      expect(JSON.parse(readFileSync(join(target.archiveDir, "metadata.json"), "utf8")))
        .toMatchObject({ id: target.id, source: "voice_ask", transcription_status: "transcribed" });
      expect(readFileSync(join(newer.archiveDir, "voicelayer-transcript.txt"), "utf8"))
        .toBe("Newer synthetic answer.");
      expect(broadcasts.filter((event) => event.type === "archive_metadata_updated"))
        .toEqual([{ type: "archive_metadata_updated", recording_path: fsModule.realpathSync(join(target.archiveDir, "audio.wav")) }]);
      expect(broadcasts.some((event) => event.type === "transcription")).toBe(false);
      expect(polishSurfaces).toEqual([]);
    });

    function writeAskArchive(options: {
      id?: string;
      schemaVersion?: 2 | 3;
      source?: "voice_ask" | "voicebar";
      metadataId?: string;
      audio?: Uint8Array;
      transcript?: string | null;
      provenance?: Record<string, unknown>;
    } = {}) {
      const id =
        options.id ?? "2026-08-20T10-11-12-000Z-abcd1234";
      const archiveDir = join(
        process.env.QA_VOICE_RECORDINGS_DIR!,
        id.slice(0, 10),
        id,
      );
      mkdirSync(archiveDir, { recursive: true });
      const audio = options.audio ?? makeWav(makePcmChunk(1800));
      const audioHash = createHash("sha256").update(audio).digest("hex");
      const agentAudio = Buffer.from([0x49, 0x44, 0x33, 1, 2, 3]);
      const agentAudioHash = createHash("sha256")
        .update(agentAudio)
        .digest("hex");
      const transcript = options.transcript === undefined
        ? "Previous exact transcript."
        : options.transcript;
      const schemaVersion = options.schemaVersion ?? 3;
      const metadata = {
        id: options.metadataId ?? id,
        created_at: "2026-08-20T10:11:12.000Z",
        source: options.source ?? "voice_ask",
        mode: "ptt",
        silence_mode: "thoughtful",
        duration_ms: 11_000,
        raw_duration_ms: 11_000,
        transcribed_duration_ms: 3_000,
        sample_rate: 16_000,
        channels: 1,
        backend: transcript === null ? null : "old-stt",
        agent_tts_engine: "edge-tts",
        agent_tts_voice: "en-US-AndrewNeural",
        language_mode: "english",
        transcription_status: transcript === null ? "captured" : "transcribed",
        retention_policy: "indefinite",
        voicelayer_transcript_chars: transcript?.length ?? 0,
        agent_transcript_chars: 17,
        user_transcript_chars: transcript?.length ?? 0,
        audio_sha256: audioHash,
        agent_audio_sha256: agentAudioHash,
        user_audio_sha256: audioHash,
        artifacts: {
          agent_audio: "agent-audio.mp3",
          agent_transcript: "agent-transcript.txt",
          user_audio: "audio.wav",
          user_transcript: "voicelayer-transcript.txt",
        },
        app_version: null,
        schema_version: schemaVersion,
        ...(options.provenance ? { provenance: options.provenance } : {}),
      };
      writeFileSync(join(archiveDir, "audio.wav"), audio);
      writeFileSync(join(archiveDir, "agent-audio.mp3"), agentAudio);
      writeFileSync(
        join(archiveDir, "agent-transcript.txt"),
        "Archived question?",
      );
      writeFileSync(
        join(archiveDir, "metadata.json"),
        `${JSON.stringify(metadata, null, 2)}\n`,
      );
      if (transcript !== null) {
        writeFileSync(
          join(archiveDir, "voicelayer-transcript.txt"),
          transcript,
        );
      }
      return {
        id,
        archiveDir,
        audio,
        audioHash,
        agentAudio,
        agentAudioHash,
        metadata,
        transcript,
      };
    }

    it("preserves raw words and sends the complete immutable Ask WAV to STT", async () => {
      const raw = "  yes yes, I mean no, fu… carry on  ";
      backendText = raw;
      const archive = writeAskArchive({
        audio: makePttWavWithLongQuietTail(),
      });
      const audioPath = join(archive.archiveDir, "audio.wav");
      const beforeAudio = readFileSync(audioPath);
      const { retranscribeVoiceAskArchive } = await import("../input");

      await expect(retranscribeVoiceAskArchive(archive.id)).resolves.toBe(
        raw.trim(),
      );

      expect(backendTranscribedDataSize).toBe(16_000 * 2 * 11);
      expect(backendTranscribedFileBytes).toBe(beforeAudio.byteLength);
      expect(readFileSync(audioPath)).toEqual(beforeAudio);
      expect(
        readFileSync(
          join(archive.archiveDir, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe(raw.trim());
      expect(polishSurfaces).toEqual([]);
      expect(broadcasts.some((event) => event.type === "transcription")).toBe(
        false,
      );
      expect(
        JSON.parse(
          readFileSync(join(archive.archiveDir, "metadata.json"), "utf8"),
        ),
      ).toMatchObject({
        schema_version: 3,
        source: "voice_ask",
        duration_ms: 11_000,
        raw_duration_ms: 11_000,
        transcribed_duration_ms: 11_000,
        backend: "fake-stt",
        language_mode: "auto",
        transcription_status: "transcribed",
        voicelayer_transcript_chars: raw.trim().length,
        user_transcript_chars: raw.trim().length,
        audio_sha256: archive.audioHash,
        user_audio_sha256: archive.audioHash,
        created_at: "2026-08-20T10:11:12.000Z",
        mode: "ptt",
        silence_mode: "thoughtful",
        agent_tts_engine: "edge-tts",
        agent_tts_voice: "en-US-AndrewNeural",
        agent_transcript_chars: 17,
      });
      expect(
        readFileSync(join(archive.archiveDir, "agent-transcript.txt"), "utf8"),
      ).toBe("Archived question?");
    });

    it("preserves capture-machine provenance when an Ask is retranscribed", async () => {
      const archive = writeAskArchive({
        provenance: {
          host: "capture-mac",
          chip: "Apple M1 Pro",
        },
      });
      const { retranscribeVoiceAskArchive } = await import("../input");

      await retranscribeVoiceAskArchive(archive.id);

      const metadata = JSON.parse(
        readFileSync(join(archive.archiveDir, "metadata.json"), "utf8"),
      ) as Record<string, unknown>;
      expect(metadata.provenance).toMatchObject({
        host: "capture-mac",
        chip: "Apple M1 Pro",
        whisper_backend: "fake-stt",
      });
    });

    it("routes the existing exact-path History wrapper through the Ask-raw policy", async () => {
      const raw = "  keep keep this retraction, fu… exactly  ";
      backendText = raw;
      const archive = writeAskArchive({
        audio: makePttWavWithLongQuietTail(),
      });
      const audioPath = join(archive.archiveDir, "audio.wav");
      const beforeAudio = readFileSync(audioPath);
      const { retranscribeRecordingCapture } = await import("../input");

      await expect(retranscribeRecordingCapture(audioPath)).resolves.toBe(
        raw.trim(),
      );

      expect(backendTranscribedDataSize).toBe(16_000 * 2 * 11);
      expect(readFileSync(audioPath)).toEqual(beforeAudio);
      expect(polishSurfaces).toEqual([]);
      expect(
        broadcasts.find((event) => event.type === "transcription"),
      ).toMatchObject({
        type: "transcription",
        text: raw.trim(),
        recording_path: expect.stringContaining(
          `${archive.id}/audio.wav`,
        ),
      });
    });

    it("blocks voice_speak while exact-path History retranscription is pending", async () => {
      const archive = writeAskArchive();
      const audioPath = join(archive.archiveDir, "audio.wav");
      backendMode = "hang";
      const speakSpy = spyOn(tts, "speak").mockResolvedValue({});
      const launcherSpy = spyOn(
        voiceBarLauncher,
        "ensureVoiceBarRunning",
      ).mockImplementation(() => {});
      const { retranscribeRecordingCapture } = await import("../input");
      const { handleVoiceSpeak } = await import("../handlers");
      const pendingHistory = retranscribeRecordingCapture(audioPath);

      try {
        await waitUntil(
          () => finishHangingTranscription !== undefined,
          "hanging History retranscription",
        );

        const racedSpeak = await handleVoiceSpeak({
          message: "Do not overlap History retranscription",
          mode: "announce",
        });

        expect(racedSpeak.isError).toBe(true);
        expect(racedSpeak.content[0].text).toContain(
          "archive retranscription voice operation is in progress",
        );
        expect(speakSpy).not.toHaveBeenCalled();
      } finally {
        finishHangingTranscription?.();
        await pendingHistory;
        launcherSpy.mockRestore();
        speakSpy.mockRestore();
      }
    });

    it("broadcasts Ask validation failures to the exact-path History caller", async () => {
      const archive = writeAskArchive();
      const audioPath = join(archive.archiveDir, "audio.wav");
      const metadataPath = join(archive.archiveDir, "metadata.json");
      const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
      metadata.user_audio_sha256 = "0".repeat(64);
      writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
      const { retranscribeRecordingCapture } = await import("../input");

      await expect(retranscribeRecordingCapture(audioPath)).rejects.toThrow(
        /checksum mismatch/,
      );

      expect(
        broadcasts.filter((event) => event.type === "error"),
      ).toEqual([
        expect.objectContaining({
          type: "error",
          message: expect.stringContaining("checksum mismatch"),
          recoverable: true,
        }),
      ]);
      expect(backendTranscribeCalls).toBe(0);
    });

    it("keeps the public receipt action bound to its exact archive and never falls back", async () => {
      backendText = "target raw retry";
      const target = writeAskArchive();
      const newerF5 = writeAskArchive({
        id: "2026-08-20T10-11-13-000Z-feedface",
        source: "voicebar",
        transcript: "Newer F5 transcript.",
      });
      const newerAsk = writeAskArchive({
        id: "2026-08-20T10-11-14-000Z-deadbeef",
        transcript: "Newer Ask transcript.",
      });
      const missingId = "2026-08-20T10-11-15-000Z-bad0cafe";
      const { handleVoiceAsk } = await import("../handlers");

      const exactResult = await handleVoiceAsk({
        retranscribe_archive_id: target.id,
      });
      expect(exactResult.isError).toBeUndefined();
      expect(exactResult.content[0].text).toContain("target raw retry");
      expect(exactResult.content[0].text).toContain(target.id);
      expect(
        broadcasts.some((event) => event.type === "transcription"),
      ).toBe(false);
      expect(
        readFileSync(
          join(target.archiveDir, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe("target raw retry");
      expect(
        readFileSync(
          join(newerF5.archiveDir, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe("Newer F5 transcript.");
      expect(
        readFileSync(
          join(newerAsk.archiveDir, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe("Newer Ask transcript.");

      const missingResult = await handleVoiceAsk({
        retranscribe_archive_id: missingId,
      });
      expect(missingResult.isError).toBe(true);
      expect(missingResult.content[0].text).toContain(missingId);
      expect(backendTranscribeCalls).toBe(1);
      expect(
        readFileSync(
          join(newerAsk.archiveDir, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe("Newer Ask transcript.");
    });

    it("keeps known schema v2 and checksum aliases coherent", async () => {
      const archive = writeAskArchive({ schemaVersion: 2 });
      const { retranscribeVoiceAskArchive } = await import("../input");

      await retranscribeVoiceAskArchive(archive.id);

      expect(
        JSON.parse(
          readFileSync(join(archive.archiveDir, "metadata.json"), "utf8"),
        ),
      ).toMatchObject({
        schema_version: 2,
        audio_sha256: archive.audioHash,
        user_audio_sha256: archive.audioHash,
      });
    });

    it("can recover a captured Ask that has no prior transcript", async () => {
      const archive = writeAskArchive({ transcript: null });
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const { retranscribeVoiceAskArchive } = await import("../input");

      expect(existsSync(transcriptPath)).toBe(false);
      await expect(retranscribeVoiceAskArchive(archive.id)).resolves.toBe(
        "retained transcript",
      );
      expect(readFileSync(transcriptPath, "utf8")).toBe(
        "retained transcript",
      );
    });

    it.each([
      ["wrong source", { source: "voicebar" as const }],
      ["mismatched metadata id", { metadataId: "other-id" }],
    ])("fails closed for %s without changing the old transcript", async (_label, options) => {
      const archive = writeAskArchive(options);
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const { retranscribeVoiceAskArchive } = await import("../input");

      await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow();
      expect(backendTranscribeCalls).toBe(0);
      expect(readFileSync(transcriptPath, "utf8")).toBe(archive.transcript);
    });

    it.each([
      ["missing audio", "missing"],
      ["corrupt audio", "corrupt"],
      ["incoherent checksum alias", "checksum"],
      ["symlinked audio", "symlink"],
      ["missing agent audio", "missing-agent-audio"],
      ["missing agent transcript", "missing-agent-transcript"],
      ["symlinked metadata", "symlink-metadata"],
      ["symlinked agent audio", "symlink-agent-audio"],
      ["symlinked agent transcript", "symlink-agent-transcript"],
      ["tampered artifact map", "artifact-map"],
    ])("fails closed for %s and preserves the prior pair", async (_label, mode) => {
      const archive = writeAskArchive();
      const audioPath = join(archive.archiveDir, "audio.wav");
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const metadataPath = join(archive.archiveDir, "metadata.json");
      const previousMetadata = readFileSync(metadataPath);
      if (mode === "missing") {
        rmSync(audioPath);
      } else if (mode === "corrupt") {
        writeFileSync(audioPath, "not a wav");
      } else if (mode === "checksum") {
        const metadata = JSON.parse(previousMetadata.toString("utf8"));
        metadata.user_audio_sha256 = "0".repeat(64);
        writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
      } else if (mode === "symlink") {
        const outsideAudio = join(tmpRoot, "outside-ask-audio.wav");
        writeFileSync(outsideAudio, archive.audio);
        rmSync(audioPath);
        symlinkSync(outsideAudio, audioPath);
      } else if (mode === "missing-agent-audio") {
        rmSync(join(archive.archiveDir, "agent-audio.mp3"));
      } else if (mode === "missing-agent-transcript") {
        rmSync(join(archive.archiveDir, "agent-transcript.txt"));
      } else if (mode === "symlink-metadata") {
        const outsideMetadata = join(tmpRoot, "outside-ask-metadata.json");
        writeFileSync(outsideMetadata, previousMetadata);
        rmSync(metadataPath);
        symlinkSync(outsideMetadata, metadataPath);
      } else if (mode === "symlink-agent-audio") {
        const agentAudioPath = join(archive.archiveDir, "agent-audio.mp3");
        const outsideAgentAudio = join(tmpRoot, "outside-agent-audio.mp3");
        writeFileSync(outsideAgentAudio, archive.agentAudio);
        rmSync(agentAudioPath);
        symlinkSync(outsideAgentAudio, agentAudioPath);
      } else if (mode === "symlink-agent-transcript") {
        const agentTranscriptPath = join(
          archive.archiveDir,
          "agent-transcript.txt",
        );
        const outsideAgentTranscript = join(
          tmpRoot,
          "outside-agent-transcript.txt",
        );
        writeFileSync(outsideAgentTranscript, "Archived question?");
        rmSync(agentTranscriptPath);
        symlinkSync(outsideAgentTranscript, agentTranscriptPath);
      } else {
        const metadata = JSON.parse(previousMetadata.toString("utf8"));
        metadata.artifacts.user_audio = "another.wav";
        writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
      }
      const expectedMetadata = readFileSync(metadataPath);
      const { retranscribeVoiceAskArchive } = await import("../input");

      const retranscription = expect(retranscribeVoiceAskArchive(archive.id))
        .rejects;
      if (mode === "corrupt") {
        await retranscription.toThrow(/44-byte RIFF\/WAVE header/);
      } else {
        await retranscription.toThrow();
      }
      expect(backendTranscribeCalls).toBe(0);
      expect(readFileSync(transcriptPath, "utf8")).toBe(archive.transcript);
      expect(readFileSync(metadataPath)).toEqual(expectedMetadata);
    });

    it("rejects a full-sized malformed Ask WAV with the explicit header error", async () => {
      const archive = writeAskArchive();
      const audioPath = join(archive.archiveDir, "audio.wav");
      const metadataPath = join(archive.archiveDir, "metadata.json");
      const malformed = Buffer.alloc(46, 0x20);
      writeFileSync(audioPath, malformed);
      const malformedHash = createHash("sha256").update(malformed).digest("hex");
      const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
      metadata.audio_sha256 = malformedHash;
      metadata.user_audio_sha256 = malformedHash;
      writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
      const { retranscribeVoiceAskArchive } = await import("../input");

      await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow(
        /missing the RIFF\/WAVE header/,
      );
      expect(backendTranscribeCalls).toBe(0);
    });

    it("does not reinterpret corrupt Ask metadata as a Recording retranscription", async () => {
      const archive = writeAskArchive();
      const audioPath = join(archive.archiveDir, "audio.wav");
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      writeFileSync(join(archive.archiveDir, "metadata.json"), "{broken");
      const { retranscribeRecordingCapture } = await import("../input");

      await expect(retranscribeRecordingCapture(audioPath)).rejects.toThrow(
        /metadata/i,
      );
      expect(backendTranscribeCalls).toBe(0);
      expect(readFileSync(transcriptPath, "utf8")).toBe(archive.transcript);
    });

    it("rejects traversal-shaped and symlinked archive receipts", async () => {
      const target = writeAskArchive();
      const linkId = "2026-08-20T10-11-13-000Z-deadbeef";
      const linkPath = join(
        process.env.QA_VOICE_RECORDINGS_DIR!,
        linkId.slice(0, 10),
        linkId,
      );
      symlinkSync(target.archiveDir, linkPath, "dir");
      const { retranscribeVoiceAskArchive } = await import("../input");

      await expect(
        retranscribeVoiceAskArchive(`../${target.id}`),
      ).rejects.toThrow(/receipt/i);
      await expect(retranscribeVoiceAskArchive(linkId)).rejects.toThrow(
        /regular archive directory|symlink/i,
      );
      expect(backendTranscribeCalls).toBe(0);
    });

    it.each([
      ["backend startup failure", "throw"],
      ["empty backend text", "empty"],
    ])("preserves the prior transcript and metadata on %s", async (_label, mode) => {
      const archive = writeAskArchive();
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const metadataPath = join(archive.archiveDir, "metadata.json");
      const previousTranscript = readFileSync(transcriptPath);
      const previousMetadata = readFileSync(metadataPath);
      if (mode === "throw") backendMode = "throw-on-get";
      else backendText = "   ";
      const { retranscribeVoiceAskArchive } = await import("../input");

      await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow();
      expect(readFileSync(transcriptPath)).toEqual(previousTranscript);
      expect(readFileSync(metadataPath)).toEqual(previousMetadata);
      expect(readFileSync(join(archive.archiveDir, "audio.wav"))).toEqual(
        Buffer.from(archive.audio),
      );
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );
      expect(getEffectiveRecordingState()).toBe("idle");
    });

    it.each(["recording", "transcribing"] as const)(
      "refuses direct Ask retranscription while voice state is %s",
      async (state) => {
        const archive = writeAskArchive();
        const recordingState = await import("../recording-state");
        const { retranscribeVoiceAskArchive } = await import("../input");
        recordingState.setRecordingState(state);

        try {
          await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow(
            "requires idle voice state",
          );
        } finally {
          recordingState.setRecordingState("idle");
        }

        expect(backendTranscribeCalls).toBe(0);
      },
    );

    it("gives one simultaneous Ask caller exclusive ownership until it releases", async () => {
      const firstArchive = writeAskArchive();
      const secondArchive = writeAskArchive({
        id: "2026-08-20T10-11-13-000Z-b16b00b5",
      });
      let releaseFirst!: () => void;
      const firstBackendCall = new Promise<void>((resolve) => {
        releaseFirst = resolve;
      });
      getBackendSpy!.mockImplementation(async () => ({
        name: "fake-stt",
        isAvailable: async () => true,
        transcribe: async () => {
          backendTranscribeCalls++;
          if (backendTranscribeCalls === 1) {
            await firstBackendCall;
            return {
              text: "first raw result",
              backend: "fake-stt",
              durationMs: 1,
            };
          }
          throw new Error("second caller entered the backend");
        },
      }));
      const { retranscribeVoiceAskArchive } = await import("../input");
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );

      const first = retranscribeVoiceAskArchive(firstArchive.id);
      await waitUntil(
        () => backendTranscribeCalls === 1,
        "first Ask backend entry",
      );
      await expect(
        retranscribeVoiceAskArchive(secondArchive.id),
      ).rejects.toThrow("already in progress");
      expect(backendTranscribeCalls).toBe(1);
      expect(getEffectiveRecordingState()).toBe("transcribing");

      releaseFirst();
      await expect(first).resolves.toBe("first raw result");
      expect(getEffectiveRecordingState()).toBe("idle");
    });

    it("rejects a same-name archive replacement during the backend await", async () => {
      const archive = writeAskArchive();
      const oldTranscriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      backendMode = "hang";
      const { retranscribeVoiceAskArchive } = await import("../input");
      const pending = retranscribeVoiceAskArchive(archive.id);
      await waitUntil(
        () => finishHangingTranscription !== undefined,
        "hanging Ask retranscription",
      );

      const movedArchivePath = `${archive.archiveDir}-moved`;
      renameSync(archive.archiveDir, movedArchivePath);
      const replacement = writeAskArchive({
        id: archive.id,
        transcript: "Replacement transcript.",
        audio: makeWav(makePcmChunk(700)),
      });
      finishHangingTranscription?.();

      await expect(pending).rejects.toThrow(/changed during retranscription/);
      expect(
        readFileSync(
          join(movedArchivePath, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe(archive.transcript);
      expect(
        readFileSync(
          join(replacement.archiveDir, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe("Replacement transcript.");
      expect(existsSync(oldTranscriptPath)).toBe(true);
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );
      expect(getEffectiveRecordingState()).toBe("idle");
    });

    it("rejects an in-place metadata-only swap during the backend await", async () => {
      const archive = writeAskArchive();
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const metadataPath = join(archive.archiveDir, "metadata.json");
      backendMode = "hang";
      const { retranscribeVoiceAskArchive } = await import("../input");
      const pending = retranscribeVoiceAskArchive(archive.id);
      await waitUntil(
        () => finishHangingTranscription !== undefined,
        "hanging Ask retranscription",
      );

      const metadata = JSON.parse(readFileSync(metadataPath, "utf8"));
      metadata.agent_tts_voice = "mutated-during-stt";
      writeFileSync(metadataPath, `${JSON.stringify(metadata, null, 2)}\n`);
      const swappedMetadata = readFileSync(metadataPath);
      finishHangingTranscription?.();

      await expect(pending).rejects.toThrow(/changed during retranscription/);
      expect(readFileSync(transcriptPath, "utf8")).toBe(archive.transcript);
      expect(readFileSync(metadataPath)).toEqual(swappedMetadata);
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );
      expect(getEffectiveRecordingState()).toBe("idle");
    });

    it("rejects a concurrent transcript edit during the backend await", async () => {
      const archive = writeAskArchive();
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const metadataPath = join(archive.archiveDir, "metadata.json");
      const previousMetadata = readFileSync(metadataPath);
      backendMode = "hang";
      const { retranscribeVoiceAskArchive } = await import("../input");
      const pending = retranscribeVoiceAskArchive(archive.id);
      await waitUntil(
        () => finishHangingTranscription !== undefined,
        "hanging Ask retranscription",
      );

      writeFileSync(transcriptPath, "Concurrent transcript edit.");
      finishHangingTranscription?.();

      await expect(pending).rejects.toThrow(/changed during retranscription/);
      expect(readFileSync(transcriptPath, "utf8")).toBe(
        "Concurrent transcript edit.",
      );
      expect(readFileSync(metadataPath)).toEqual(previousMetadata);
      expect(readFileSync(join(archive.archiveDir, "audio.wav"))).toEqual(
        Buffer.from(archive.audio),
      );
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );
      expect(getEffectiveRecordingState()).toBe("idle");
    });

    it("uses exclusive-create staging for both Ask transcript pair files", async () => {
      const archive = writeAskArchive();
      const originalWrite = fsModule.writeFileSync;
      const stageOptions: Array<Record<string, unknown>> = [];
      const writeSpy = spyOn(fsModule, "writeFileSync").mockImplementation(
        ((path: any, data: any, options?: any) => {
          if (typeof path === "string" && path.endsWith(".new")) {
            stageOptions.push(options);
          }
          return (originalWrite as any)(path, data, options);
        }) as typeof fsModule.writeFileSync,
      );
      const { retranscribeVoiceAskArchive } = await import("../input");

      try {
        await retranscribeVoiceAskArchive(archive.id);
      } finally {
        writeSpy.mockRestore();
      }

      expect(stageOptions).toHaveLength(2);
      expect(stageOptions.every((options) => options.flag === "wx")).toBe(
        true,
      );
    });

    it.each([
      ["transcript stage write", "transcript-write"],
      ["metadata stage write", "metadata-write"],
      ["metadata rename", "metadata-rename"],
      ["post-commit fsync", "post-commit-fsync"],
    ])("rolls back the transcript/metadata pair after an injected %s failure", async (_label, mode) => {
      const archive = writeAskArchive();
      const transcriptPath = join(
        archive.archiveDir,
        "voicelayer-transcript.txt",
      );
      const metadataPath = join(archive.archiveDir, "metadata.json");
      const audioPath = join(archive.archiveDir, "audio.wav");
      const previousTranscript = readFileSync(transcriptPath);
      const previousMetadata = readFileSync(metadataPath);
      const previousAudio = readFileSync(audioPath);
      let injectedSpy: { mockRestore(): void };

      if (mode.endsWith("write")) {
        const originalWrite = fsModule.writeFileSync;
        const suffix = mode === "transcript-write"
          ? "-transcript.new"
          : "-metadata.new";
        injectedSpy = spyOn(fsModule, "writeFileSync").mockImplementation(
          ((path: any, ...args: any[]) => {
            if (typeof path === "string" && path.endsWith(suffix)) {
              throw new Error(`injected ${mode}`);
            }
            return (originalWrite as any)(path, ...args);
          }) as typeof fsModule.writeFileSync,
        );
      } else if (mode === "metadata-rename") {
        const originalRename = fsModule.renameSync;
        let injected = false;
        injectedSpy = spyOn(fsModule, "renameSync").mockImplementation(
          ((from: any, to: any) => {
            if (
              !injected &&
              typeof to === "string" &&
              to.endsWith("/metadata.json")
            ) {
              injected = true;
              throw new Error("injected metadata rename");
            }
            return originalRename(from, to);
          }) as typeof fsModule.renameSync,
        );
      } else {
        const originalFsync = fsModule.fsyncSync;
        let fsyncCalls = 0;
        injectedSpy = spyOn(fsModule, "fsyncSync").mockImplementation(
          ((fd: number) => {
            fsyncCalls++;
            if (fsyncCalls === 4) {
              throw new Error("injected post-commit fsync");
            }
            return originalFsync(fd);
          }) as typeof fsModule.fsyncSync,
        );
      }

      const { retranscribeVoiceAskArchive } = await import("../input");
      try {
        await expect(retranscribeVoiceAskArchive(archive.id, { delivery: "return-only" })).rejects.toThrow(
          /injected/,
        );
      } finally {
        injectedSpy.mockRestore();
      }

      expect(readFileSync(transcriptPath)).toEqual(previousTranscript);
      expect(readFileSync(metadataPath)).toEqual(previousMetadata);
      expect(readFileSync(audioPath)).toEqual(previousAudio);
      expect(broadcasts.some((event) => event.type === "archive_metadata_updated")).toBe(false);
      expect(
        readdirSync(archive.archiveDir).some((name) =>
          name.startsWith(".retranscribe-"),
        ),
      ).toBe(false);
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );
      expect(getEffectiveRecordingState()).toBe("idle");
    });

    it("releases the Ask owner when publishing transcribing state fails", async () => {
      const archive = writeAskArchive();
      const stateWriteSpy = spyOn(
        paths,
        "safeWriteFileSync",
      ).mockImplementation(() => {
        throw new Error("injected state publish failure");
      });
      const { retranscribeVoiceAskArchive } = await import("../input");
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );

      try {
        await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow(
          /Unable to publish recording state \(transcribing\)/,
        );
      } finally {
        stateWriteSpy.mockRestore();
      }

      expect(getEffectiveRecordingState()).toBe("idle");
      expect(backendTranscribeCalls).toBe(0);
      await expect(retranscribeVoiceAskArchive(archive.id)).resolves.toBe(
        "retained transcript",
      );
    });

    it("releases the Ask owner and recording state when the working-copy write fails", async () => {
      const archive = writeAskArchive();
      const originalWrite = fsModule.writeFileSync;
      const workingCopyWriteSpy = spyOn(
        fsModule,
        "writeFileSync",
      ).mockImplementation(
        ((path: any, ...args: any[]) => {
          if (
            typeof path === "string" &&
            // AIDEV-NOTE: R-014 — the working copy follows the (now overridable)
            // ephemeral root, so match on paths.TMP_ROOT, not a literal /tmp.
            path.startsWith(`${paths.TMP_ROOT}/voicelayer-recording-`)
          ) {
            throw new Error("injected working-copy write failure");
          }
          return (originalWrite as any)(path, ...args);
        }) as typeof fsModule.writeFileSync,
      );
      const { retranscribeVoiceAskArchive } = await import("../input");
      const { getEffectiveRecordingState } = await import(
        "../recording-state"
      );

      try {
        await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow(
          "injected working-copy write failure",
        );
      } finally {
        workingCopyWriteSpy.mockRestore();
      }

      expect(getEffectiveRecordingState()).toBe("idle");
      await expect(retranscribeVoiceAskArchive(archive.id)).resolves.toBe(
        "retained transcript",
      );
      expect(getEffectiveRecordingState()).toBe("idle");
    });
  });
});
