import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  spyOn,
} from "bun:test";
import { createHash } from "crypto";
import {
  closeSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  openSync,
  readFileSync,
  rmSync,
  writeSync,
  writeFileSync,
} from "fs";
import * as fsModule from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { clearCancelSignal, clearStopSignal } from "../session-booking";
import { STOP_FILE } from "../paths";
import * as socketClient from "../socket-client";
import * as stt from "../stt";
import * as vad from "../vad";

const VAD_CHUNK_SAMPLES = 512;
const VAD_CHUNK_BYTES = VAD_CHUNK_SAMPLES * 2;

let vadMode: "silence" | "throw" = "silence";
let onVadCall: (() => void) | null = null;
let backendMode: "ok" | "throw-on-get" = "ok";
let backendTranscribeCalls = 0;
let backendTranscribedDataSize: number | undefined;
let backendTranscribedFileBytes: number | undefined;
let broadcasts: any[] = [];
let vadProcessSpy: ReturnType<typeof spyOn> | undefined;
let vadResetSpy: ReturnType<typeof spyOn> | undefined;
let getBackendSpy: ReturnType<typeof spyOn> | undefined;
let broadcastSpy: ReturnType<typeof spyOn> | undefined;

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
  let stdoutController:
    | ReadableStreamDefaultController<Uint8Array>
    | undefined;
  let stderrController:
    | ReadableStreamDefaultController<Uint8Array>
    | undefined;

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

  beforeEach(() => {
    tmpRoot = mkdtempSync(join(tmpdir(), "voicelayer-input-durability-"));
    retainedPath = join(tmpRoot, "last-recording.wav");
    savedRetainedPath = process.env.QA_VOICE_RETAINED_RECORDING_PATH;
    savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
    process.env.QA_VOICE_RETAINED_RECORDING_PATH = retainedPath;
    process.env.QA_VOICE_RECORDINGS_DIR = join(tmpRoot, "recordings");
    vadMode = "silence";
    onVadCall = null;
    backendMode = "ok";
    backendTranscribeCalls = 0;
    backendTranscribedDataSize = undefined;
    backendTranscribedFileBytes = undefined;
    broadcasts = [];
    vadProcessSpy = spyOn(vad, "processVADChunk").mockImplementation(
      async () => {
        onVadCall?.();
        if (vadMode === "throw") {
          throw new Error("vad exploded after capture");
        }
        return 0;
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
          return {
            text: "retained transcript",
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
    clearStopSignal();
    clearCancelSignal();
  });

  afterEach(() => {
    vadProcessSpy?.mockRestore();
    vadResetSpy?.mockRestore();
    getBackendSpy?.mockRestore();
    broadcastSpy?.mockRestore();
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
    expect(broadcasts).toContainEqual({
      type: "transcription",
      text: "Retained transcript.",
      recording_path: audioPath,
    });
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
  });
});
