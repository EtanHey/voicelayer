import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
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
): Promise<void> {
  const startedAt = Date.now();
  while (!predicate()) {
    if (Date.now() - startedAt > 500) {
      throw new Error(`Timed out waiting for ${label}`);
    }
    await Bun.sleep(1);
  }
}

function installFakeRecorder(chunks: Uint8Array[], keepStdoutOpen: boolean) {
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
    return originalSpawnSync(cmd);
  }) as typeof Bun.spawnSync;

  Bun.spawn = (() => {
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
  };
}

describe("input recording durability", () => {
  let tmpRoot: string;
  let retainedPath: string;
  let savedRetainedPath: string | undefined;
  let savedRecordingsDir: string | undefined;
  let savedRecordingStatePath: string | undefined;
  let savedRecordingHoldPath: string | undefined;

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "voicelayer-input-durability-"));
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
    installFakeRecorder(
      Array.from({ length: 24 }, () => makePcmChunk(1800)),
      false,
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
    function writeAskArchive(options: {
      id?: string;
      schemaVersion?: 2 | 3;
      source?: "voice_ask" | "voicebar";
      metadataId?: string;
      audio?: Uint8Array;
      transcript?: string | null;
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
        await expect(retranscribeVoiceAskArchive(archive.id)).rejects.toThrow(
          /injected/,
        );
      } finally {
        injectedSpy.mockRestore();
      }

      expect(readFileSync(transcriptPath)).toEqual(previousTranscript);
      expect(readFileSync(metadataPath)).toEqual(previousMetadata);
      expect(readFileSync(audioPath)).toEqual(previousAudio);
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
            path.startsWith("/tmp/voicelayer-recording-")
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
