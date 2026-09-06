import { afterEach, beforeEach, it, expect, spyOn } from "bun:test";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { Database } from "bun:sqlite";
import { createHash } from "crypto";
import * as crypto from "crypto";
import ts from "typescript";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  archiveVoiceBarRecording,
  archiveVoiceBarUntranscribedRecording,
  archiveVoiceAskCapture,
  archiveWaitForInputRecording,
  calculateRMS,
  ChunkedRecordingSession,
  classifyCaptureFailure,
  consumeCancelSignalForRecording,
  createWavBuffer,
  clearInput,
  evaluateNoSpeechGate,
  evaluatePushToEndSpeechGate,
  isChunkedSTTEnabled,
  isPushToEndStopDrainComplete,
  polishSurfaceForWaitOptions,
  retainLastCaptureForRecovery,
  selectChunksWithPreRoll,
  transcribeChunkSequence,
  finalizeTranscriptionTextForSurface,
  finalizeTranscriptionText,
  finalizeVoiceAskArchive,
  trimTrailingSilenceForSTT,
  createRecorderStderrWatcher,
  terminateRecorderProcess,
  updateArchivedTranscript,
} from "../input";
import {
  __resetNativeInputFormatProbesForTests,
  __setNativeInputFormatProbesForTests,
  detectNativeInputFormat,
  resetNativeInputFormatCache,
} from "../audio-utils";
import * as inputModule from "../input";
import { VAD_CHUNK_BYTES } from "../vad";
import {
  clearCancelSignal,
  clearStopSignal,
  hasCancelSignal,
  setCancelSignal,
} from "../session-booking";
import { STOP_FILE } from "../paths";
import { PACKAGE_VERSION } from "../version";
import { retainedRecordingFilePath } from "../paths";

describe("input module", () => {
  let testStateRoot: string | undefined;
  let savedRecordingStatePath: string | undefined;
  let savedRetainedRecordingPathForSuite: string | undefined;
  let savedControlLayerDisable: string | undefined;
  let savedVocabularyPath: string | undefined;

  beforeEach(() => {
    savedRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
    savedRetainedRecordingPathForSuite =
      process.env.QA_VOICE_RETAINED_RECORDING_PATH;
    savedControlLayerDisable =
      process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
    savedVocabularyPath = process.env.QA_VOICE_STT_VOCABULARY_PATH;
    testStateRoot = mkdtempSync(join(tmpdir(), "voicelayer-input-test-"));
    process.env.QA_VOICE_RECORDING_STATE_PATH = join(
      testStateRoot,
      "recording-state.json",
    );
    process.env.QA_VOICE_RETAINED_RECORDING_PATH = join(
      testStateRoot,
      "last-recording.wav",
    );
    process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL = "1";
    process.env.QA_VOICE_STT_VOCABULARY_PATH = "";
  });

  afterEach(() => {
    if (testStateRoot) rmSync(testStateRoot, { recursive: true, force: true });
    if (savedRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = savedRecordingStatePath;
    }
    if (savedRetainedRecordingPathForSuite === undefined) {
      delete process.env.QA_VOICE_RETAINED_RECORDING_PATH;
    } else {
      process.env.QA_VOICE_RETAINED_RECORDING_PATH =
        savedRetainedRecordingPathForSuite;
    }
    if (savedControlLayerDisable === undefined) {
      delete process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
    } else {
      process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL =
        savedControlLayerDisable;
    }
    if (savedVocabularyPath === undefined) {
      delete process.env.QA_VOICE_STT_VOCABULARY_PATH;
    } else {
      process.env.QA_VOICE_STT_VOCABULARY_PATH = savedVocabularyPath;
    }
  });

  it("starts polish warmup fire-and-forget and emits a control-layer event", async () => {
    const warmPolishEndpointAtRecordingStart = (
      inputModule as {
        warmPolishEndpointAtRecordingStart?: (options: {
          env: Record<string, string | undefined>;
          warm: () => Promise<{ status: string; latencyMs: number; error?: string }>;
          appendEvent: (
            type: string,
            payload: Record<string, unknown>,
            options: { topic: string },
          ) => void;
        }) => void;
      }
    ).warmPolishEndpointAtRecordingStart;
    expect(typeof warmPolishEndpointAtRecordingStart).toBe("function");
    if (!warmPolishEndpointAtRecordingStart) {
      throw new Error("warmPolishEndpointAtRecordingStart export missing");
    }

    const events: Array<{
      type: string;
      payload: Record<string, unknown>;
      options: { topic: string };
    }> = [];
    let resolveWarmup:
      | ((result: { status: string; latencyMs: number; error?: string }) => void)
      | undefined;
    const warmup = new Promise<{ status: string; latencyMs: number; error?: string }>(
      (resolve) => {
        resolveWarmup = resolve;
      },
    );

    const startedAt = performance.now();
    warmPolishEndpointAtRecordingStart({
      env: {},
      warm: () => warmup,
      appendEvent: (type, payload, options) => {
        events.push({ type, payload, options });
      },
    });

    expect(performance.now() - startedAt).toBeLessThan(20);
    expect(events).toEqual([]);

    resolveWarmup?.({ status: "warmed", latencyMs: 12.4 });
    await warmup;
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(events).toEqual([
      {
        type: "transcription.polish.warmup",
        payload: {
          status: "warmed",
          latency_ms: 12,
          error: null,
        },
        options: { topic: "voice.transcription" },
      },
    ]);
  });

  describe("VoiceBar recording archive", () => {
    let archiveRoot: string | undefined;
    let savedRecordingsDir: string | undefined;
    let savedLanguage: string | undefined;
    let savedRetainedRecordingPath: string | undefined;
    let retainedRecordingPath: string | undefined;

    beforeEach(() => {
      savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
      savedLanguage = process.env.QA_VOICE_WHISPER_LANG;
      savedRetainedRecordingPath = process.env.QA_VOICE_RETAINED_RECORDING_PATH;
      archiveRoot = mkdtempSync(join(tmpdir(), "voicelayer-recordings-test-"));
      retainedRecordingPath = join(archiveRoot, "last-cancelled-recording.wav");
      process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
      process.env.QA_VOICE_WHISPER_LANG = "hebrew";
      process.env.QA_VOICE_RETAINED_RECORDING_PATH = retainedRecordingPath;
      clearCancelSignal();
    });

    afterEach(() => {
      clearCancelSignal();
      if (archiveRoot) rmSync(archiveRoot, { recursive: true, force: true });
      if (savedRecordingsDir === undefined) {
        delete process.env.QA_VOICE_RECORDINGS_DIR;
      } else {
        process.env.QA_VOICE_RECORDINGS_DIR = savedRecordingsDir;
      }
      if (savedLanguage === undefined) {
        delete process.env.QA_VOICE_WHISPER_LANG;
      } else {
        process.env.QA_VOICE_WHISPER_LANG = savedLanguage;
      }
      if (savedRetainedRecordingPath === undefined) {
        delete process.env.QA_VOICE_RETAINED_RECORDING_PATH;
      } else {
        process.env.QA_VOICE_RETAINED_RECORDING_PATH = savedRetainedRecordingPath;
      }
    });

    it("creates a durable archive entry for a successful dictation with complete metadata", () => {
      const audioBytes = createWavBuffer(new Uint8Array([1, 2, 3, 4]));
      const transcript = "He told me, why don't you come here?";
      const archivedPath = archiveVoiceBarRecording({
        audioBytes,
        transcript,
        createdAt: new Date("2026-05-02T07:08:09.123Z"),
        source: "voicebar",
        silenceMode: "thoughtful",
        pushToEnd: true,
        durationMs: 900,
        backend: "whisper.cpp",
      });

      expect(archivedPath).toBeTruthy();
      const dayDir = join(archiveRoot!, "2026-05-02");
      const archiveIds = readdirSync(dayDir);
      expect(archiveIds).toHaveLength(1);
      expect(archivedPath).toBe(join(dayDir, archiveIds[0]));

      const archivedAudio = readFileSync(join(archivedPath!, "audio.wav"));
      expect(archivedAudio).toEqual(Buffer.from(audioBytes));
      expect(
        readFileSync(
          join(archivedPath!, "voicelayer-transcript.txt"),
          "utf8",
        ),
      ).toBe(transcript);

      const metadata = JSON.parse(
        readFileSync(join(archivedPath!, "metadata.json"), "utf8"),
      );
      expect(metadata).toMatchObject({
        id: archiveIds[0],
        created_at: "2026-05-02T07:08:09.123Z",
        source: "voicebar",
        mode: "ptt",
        silence_mode: "thoughtful",
        duration_ms: 900,
        raw_duration_ms: 900,
        transcribed_duration_ms: 900,
        sample_rate: 16000,
        channels: 1,
        backend: "whisper.cpp",
        language_mode: "hebrew",
        transcription_status: "transcribed",
        voicelayer_transcript_chars: transcript.length,
        app_version: PACKAGE_VERSION,
        schema_version: 2,
      });
      expect(metadata.audio_sha256).toBe(
        createHash("sha256").update(audioBytes).digest("hex"),
      );
      // Provenance (metadata v2) — see input-metadata-provenance.test.ts for
      // the field-by-field contract.
      expect(metadata.provenance).toMatchObject({
        whisper_backend: "whisper.cpp",
        language_mode: "hebrew",
        app_version: PACKAGE_VERSION,
        app_version_source: "package.json",
      });
      expect(typeof metadata.provenance.host).toBe("string");
    });

    it("skips archive creation when a recording is cancelled before transcription", () => {
      const archivedPath = archiveVoiceBarRecording({
        audioBytes: createWavBuffer(new Uint8Array([1, 2])),
        transcript: null,
        source: "voicebar",
        silenceMode: "standard",
        pushToEnd: false,
        durationMs: 700,
        backend: "whisper.cpp",
      });

      expect(archivedPath).toBeNull();
      expect(readdirSync(archiveRoot!)).toHaveLength(0);
    });

    it("creates a durable untranscribed archive entry for a cancelled VoiceBar capture", () => {
      const audioBytes = createWavBuffer(new Uint8Array([1, 2, 3, 4]));

      const archivedPath = archiveVoiceBarUntranscribedRecording({
        audioBytes,
        createdAt: new Date("2026-05-22T10:11:12.345Z"),
        source: "voicebar",
        silenceMode: "thoughtful",
        pushToEnd: true,
        durationMs: 1000,
        backend: "not-transcribed",
        reason: "cancelled",
      });

      expect(archivedPath).toBeTruthy();
      expect(readFileSync(join(archivedPath!, "audio.wav"))).toEqual(
        Buffer.from(audioBytes),
      );
      expect(existsSync(join(archivedPath!, "voicelayer-transcript.txt"))).toBe(
        false,
      );

      const metadata = JSON.parse(
        readFileSync(join(archivedPath!, "metadata.json"), "utf8"),
      );
      expect(metadata).toMatchObject({
        created_at: "2026-05-22T10:11:12.345Z",
        source: "voicebar",
        mode: "ptt",
        silence_mode: "thoughtful",
        duration_ms: 1000,
        backend: "not-transcribed",
        transcription_status: "cancelled",
        voicelayer_transcript_chars: 0,
      });
    });

    it("skips archive creation when no speech produces an empty transcript", () => {
      const archivedPath = archiveVoiceBarRecording({
        audioBytes: createWavBuffer(new Uint8Array([1, 2])),
        transcript: "",
        source: "voicebar",
        silenceMode: "standard",
        pushToEnd: false,
        durationMs: 700,
        backend: "whisper.cpp",
      });

      expect(archivedPath).toBeNull();
      expect(readdirSync(archiveRoot!)).toHaveLength(0);
    });

    it("does not archive shared waitForInput results unless VoiceBar opts in", () => {
      const archivedPath = archiveWaitForInputRecording({
        options: {},
        audioBytes: createWavBuffer(new Uint8Array([1, 2, 3, 4])),
        transcript: "MCP voice ask response",
        silenceMode: "standard",
        pushToEnd: false,
        durationMs: 900,
        backend: "whisper.cpp",
      });

      expect(archivedPath).toBeNull();
      expect(readdirSync(archiveRoot!)).toHaveLength(0);
    });

    it("creates one paired archive folder for a completed voice_ask round", () => {
      const agentAudio = Buffer.from([0x49, 0x44, 0x33, 1, 2, 3, 4]);
      const userAudio = createWavBuffer(new Uint8Array([5, 6, 7, 8]));

      const archivedPath = archiveWaitForInputRecording({
        options: {
          archiveSource: "voice_ask",
          voiceAskArtifacts: {
            agentAudioBytes: agentAudio,
            agentAudioFormat: "mp3",
            agentTranscript: "What changed?",
            agentTtsEngine: "qwen3-tts",
            agentTtsVoice: "etan-clone",
            createdAt: new Date("2026-07-16T19:20:21.123Z"),
          },
        },
        audioBytes: userAudio,
        transcript: "The archive now keeps both sides.",
        silenceMode: "thoughtful",
        pushToEnd: false,
        durationMs: 1_200,
        transcribedDurationMs: 1_000,
        backend: "whisper.cpp",
      });

      expect(archivedPath).toBeTruthy();
      const dayDir = join(archiveRoot!, "2026-07-16");
      const archiveIds = readdirSync(dayDir);
      expect(archiveIds).toHaveLength(1);
      expect(archivedPath).toBe(join(dayDir, archiveIds[0]));
      expect(readdirSync(archivedPath!).sort()).toEqual([
        "agent-audio.mp3",
        "agent-transcript.txt",
        "audio.wav",
        "metadata.json",
        "voicelayer-transcript.txt",
      ]);
      expect(readFileSync(join(archivedPath!, "agent-audio.mp3"))).toEqual(
        agentAudio,
      );
      expect(
        readFileSync(join(archivedPath!, "agent-transcript.txt"), "utf8"),
      ).toBe("What changed?");
      expect(readFileSync(join(archivedPath!, "audio.wav"))).toEqual(
        Buffer.from(userAudio),
      );
      expect(
        readFileSync(join(archivedPath!, "voicelayer-transcript.txt"), "utf8"),
      ).toBe("The archive now keeps both sides.");

      const metadata = JSON.parse(
        readFileSync(join(archivedPath!, "metadata.json"), "utf8"),
      );
      expect(metadata).toMatchObject({
        id: archiveIds[0],
        created_at: "2026-07-16T19:20:21.123Z",
        source: "voice_ask",
        mode: "vad",
        silence_mode: "thoughtful",
        duration_ms: 1_200,
        raw_duration_ms: 1_200,
        transcribed_duration_ms: 1_000,
        backend: "whisper.cpp",
        agent_tts_engine: "qwen3-tts",
        agent_tts_voice: "etan-clone",
        transcription_status: "transcribed",
        agent_transcript_chars: "What changed?".length,
        user_transcript_chars: "The archive now keeps both sides.".length,
        agent_audio_sha256: createHash("sha256").update(agentAudio).digest("hex"),
        user_audio_sha256: createHash("sha256").update(userAudio).digest("hex"),
        schema_version: 4,
      });
    });

    it("publishes voice_ask audio at capture end before finalizing its transcript", () => {
      const agentAudio = Buffer.from([0x49, 0x44, 0x33, 1, 2, 3, 4]);
      const userAudio = createWavBuffer(new Uint8Array([5, 6, 7, 8]));
      const options = {
        archiveSource: "voice_ask" as const,
        voiceAskArtifacts: {
          agentAudioBytes: agentAudio,
          agentAudioFormat: "mp3" as const,
          agentTranscript: "What changed?",
          agentTtsEngine: "qwen3-tts" as const,
          agentTtsVoice: "etan-clone",
          createdAt: new Date("2026-07-18T11:04:10.000Z"),
        },
      };

      const archivedPath = archiveVoiceAskCapture({
        options,
        audioBytes: userAudio,
        silenceMode: "thoughtful",
        pushToEnd: false,
        durationMs: 1_200,
        transcribedDurationMs: 1_000,
      });

      expect(readdirSync(archivedPath).sort()).toEqual([
        "agent-audio.mp3",
        "agent-transcript.txt",
        "audio.wav",
        "metadata.json",
      ]);
      expect(
        JSON.parse(readFileSync(join(archivedPath, "metadata.json"), "utf8")),
      ).toMatchObject({
        source: "voice_ask",
        backend: null,
        transcription_status: "captured",
        user_transcript_chars: 0,
        schema_version: 4,
      });

      finalizeVoiceAskArchive(archivedPath, {
        transcript: "The capture survived its return leg.",
        backend: "whisper.cpp",
        transcribedDurationMs: 1_000,
      });

      expect(readdirSync(archivedPath).sort()).toEqual([
        "agent-audio.mp3",
        "agent-transcript.txt",
        "audio.wav",
        "metadata.json",
        "voicelayer-transcript.txt",
      ]);
      expect(
        readFileSync(join(archivedPath, "voicelayer-transcript.txt"), "utf8"),
      ).toBe("The capture survived its return leg.");
      expect(
        JSON.parse(readFileSync(join(archivedPath, "metadata.json"), "utf8")),
      ).toMatchObject({
        backend: "whisper.cpp",
        transcription_status: "transcribed",
        user_transcript_chars: "The capture survived its return leg.".length,
      });

      expect(() =>
        finalizeVoiceAskArchive(archivedPath, {
          transcript: "A late retry must not replace the accepted transcript.",
          backend: "other-backend",
        }),
      ).toThrow("already finalized");
      expect(
        readFileSync(join(archivedPath, "voicelayer-transcript.txt"), "utf8"),
      ).toBe("The capture survived its return leg.");
    });

    it("does not remove a voice_ask staging folder owned by another invocation", () => {
      const createdAt = new Date("2026-07-16T19:20:21.123Z");
      const idSuffix = "a1b2c3d4";
      const dayDir = join(archiveRoot!, "2026-07-16");
      const stagingDir = join(
        dayDir,
        `.tmp-2026-07-16T19-20-21-123Z-${idSuffix}`,
      );
      const sentinelPath = join(stagingDir, "owned-by-other-invocation");
      mkdirSync(stagingDir, { recursive: true });
      writeFileSync(sentinelPath, "keep");
      const randomBytesSpy = spyOn(crypto, "randomBytes").mockReturnValue(
        Buffer.from(idSuffix, "hex") as never,
      );

      try {
        expect(() =>
          archiveWaitForInputRecording({
            options: {
              archiveSource: "voice_ask",
              voiceAskArtifacts: {
                agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
                agentAudioFormat: "mp3",
                agentTranscript: "Collision question",
                agentTtsEngine: "edge-tts",
                agentTtsVoice: "en-US-JennyNeural",
                createdAt,
              },
            },
            audioBytes: createWavBuffer(new Uint8Array([1, 2, 3, 4])),
            transcript: "Collision answer",
            silenceMode: "standard",
            pushToEnd: false,
            durationMs: 900,
            backend: "whisper.cpp",
          }),
        ).toThrow();
        expect(readFileSync(sentinelPath, "utf8")).toBe("keep");
      } finally {
        randomBytesSpy.mockRestore();
      }
    });

    it("rejects voice_ask archive requests without immutable prompt audio", () => {
      expect(() =>
        archiveWaitForInputRecording({
          options: { archiveSource: "voice_ask" },
          audioBytes: createWavBuffer(new Uint8Array([1, 2, 3, 4])),
          transcript: "User answer",
          silenceMode: "standard",
          pushToEnd: false,
          durationMs: 900,
          backend: "whisper.cpp",
        }),
      ).toThrow("requires immutable agent audio and transcript artifacts");
    });

    it("rejects voice_ask archives without actual-used TTS engine and voice", () => {
      expect(() =>
        archiveWaitForInputRecording({
          options: {
            archiveSource: "voice_ask",
            voiceAskArtifacts: {
              agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33]),
              agentAudioFormat: "mp3",
              agentTranscript: "Question without a receipt",
            },
          },
          audioBytes: createWavBuffer(new Uint8Array([1, 2, 3, 4])),
          transcript: "User answer",
          silenceMode: "standard",
          pushToEnd: false,
          durationMs: 900,
          backend: "whisper.cpp",
        }),
      ).toThrow("actual-used TTS engine and voice");
    });

    it("consumes a late cancel signal before publishing or archiving transcription", () => {
      setCancelSignal();

      expect(consumeCancelSignalForRecording()).toBe(true);
      expect(hasCancelSignal()).toBe(false);
      expect(readdirSync(archiveRoot!)).toHaveLength(0);
    });

    it("retains the last wav before honoring a late cancel", () => {
      const source = readFileSync(join(import.meta.dir, "../input.ts"), "utf8");
      const ast = ts.createSourceFile(
        "input.ts",
        source,
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.TS,
      );
      let waitForInput: ts.FunctionDeclaration | undefined;
      ast.forEachChild((node) => {
        if (ts.isFunctionDeclaration(node) && node.name?.text === "waitForInput") {
          waitForInput = node;
        }
      });

      let retainBeforeLateCancel = false;
      const visit = (node: ts.Node) => {
        if (!ts.isBlock(node)) {
          ts.forEachChild(node, visit);
          return;
        }

        let sawRetention = false;
        for (const statement of node.statements) {
          if (
            ts.isExpressionStatement(statement) &&
            ts.isCallExpression(statement.expression) &&
            ts.isIdentifier(statement.expression.expression) &&
            statement.expression.expression.text === "retainLastCaptureForRecovery"
          ) {
            sawRetention = true;
          }

          if (
            sawRetention &&
            ts.isIfStatement(statement) &&
            ts.isCallExpression(statement.expression) &&
            ts.isIdentifier(statement.expression.expression) &&
            statement.expression.expression.text === "consumeCancelSignalForRecording"
          ) {
            retainBeforeLateCancel = true;
          }
        }

        ts.forEachChild(node, visit);
      };
      expect(waitForInput).toBeDefined();
      visit(waitForInput!);
      expect(retainBeforeLateCancel).toBe(true);
    });

    it("retains a cancelled capture before early cancel returns so it can be retranscribed", () => {
      const wavData = createWavBuffer(new Uint8Array([1, 2, 3, 4]));

      retainLastCaptureForRecovery(wavData, null);

      expect(retainedRecordingFilePath()).toBe(retainedRecordingPath);
      expect(readFileSync(retainedRecordingPath!)).toEqual(Buffer.from(wavData));
    });
  });

  describe("calculateRMS", () => {
    it("returns 0 for empty buffer", () => {
      const buffer = new Uint8Array(0);
      expect(calculateRMS(buffer)).toBe(0);
    });

    it("returns 0 for silent audio (all zeros)", () => {
      // 100 samples of silence (200 bytes, 16-bit)
      const buffer = new Uint8Array(200);
      expect(calculateRMS(buffer)).toBe(0);
    });

    it("returns high RMS for loud audio", () => {
      // Create buffer with max-amplitude 16-bit samples
      const numSamples = 100;
      const buffer = new Uint8Array(numSamples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < numSamples; i++) {
        view.setInt16(i * 2, 20000, true); // loud signal
      }

      const rms = calculateRMS(buffer);
      expect(rms).toBeGreaterThan(10000);
    });

    it("returns moderate RMS for moderate audio", () => {
      const numSamples = 100;
      const buffer = new Uint8Array(numSamples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < numSamples; i++) {
        view.setInt16(i * 2, 1000, true); // moderate signal
      }

      const rms = calculateRMS(buffer);
      expect(rms).toBeGreaterThan(500);
      expect(rms).toBeLessThan(5000);
    });

    it("handles alternating positive/negative samples", () => {
      const numSamples = 100;
      const buffer = new Uint8Array(numSamples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < numSamples; i++) {
        // Alternating +5000 / -5000 — RMS should be same as constant 5000
        view.setInt16(i * 2, i % 2 === 0 ? 5000 : -5000, true);
      }

      const rms = calculateRMS(buffer);
      expect(rms).toBeCloseTo(5000, -1); // within rounding
    });
  });

  describe("createWavBuffer", () => {
    it("creates valid WAV header", () => {
      const pcmData = new Uint8Array(32000); // 1 second of audio
      const wav = createWavBuffer(pcmData);

      // WAV file should be 44 + pcmData.length bytes
      expect(wav.byteLength).toBe(44 + pcmData.byteLength);

      // Check RIFF header
      const str = String.fromCharCode(wav[0], wav[1], wav[2], wav[3]);
      expect(str).toBe("RIFF");

      // Check WAVE marker
      const wave = String.fromCharCode(wav[8], wav[9], wav[10], wav[11]);
      expect(wave).toBe("WAVE");

      // Check fmt sub-chunk
      const fmt = String.fromCharCode(wav[12], wav[13], wav[14], wav[15]);
      expect(fmt).toBe("fmt ");

      // Check data sub-chunk
      const data = String.fromCharCode(wav[36], wav[37], wav[38], wav[39]);
      expect(data).toBe("data");
    });

    it("encodes correct file size in header", () => {
      const pcmData = new Uint8Array(1000);
      const wav = createWavBuffer(pcmData);
      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);

      // Bytes 4-7: file size - 8 = 36 + dataSize
      expect(view.getUint32(4, true)).toBe(36 + 1000);

      // Bytes 40-43: data chunk size = dataSize
      expect(view.getUint32(40, true)).toBe(1000);
    });

    it("encodes correct audio format parameters", () => {
      const pcmData = new Uint8Array(100);
      const wav = createWavBuffer(pcmData);
      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);

      // PCM format = 1
      expect(view.getUint16(20, true)).toBe(1);
      // Channels = 1
      expect(view.getUint16(22, true)).toBe(1);
      // Sample rate = 16000
      expect(view.getUint32(24, true)).toBe(16000);
      // Byte rate = 32000 (16000 * 1 * 16/8)
      expect(view.getUint32(28, true)).toBe(32000);
      // Block align = 2 (1 * 16/8)
      expect(view.getUint16(32, true)).toBe(2);
      // Bits per sample = 16
      expect(view.getUint16(34, true)).toBe(16);
    });

    it("preserves PCM data after header", () => {
      const pcmData = new Uint8Array([1, 2, 3, 4, 5, 6, 7, 8]);
      const wav = createWavBuffer(pcmData);

      // PCM data starts at offset 44
      for (let i = 0; i < pcmData.length; i++) {
        expect(wav[44 + i]).toBe(pcmData[i]);
      }
    });

    it("handles empty PCM data", () => {
      const pcmData = new Uint8Array(0);
      const wav = createWavBuffer(pcmData);

      // Should still have valid 44-byte header
      expect(wav.byteLength).toBe(44);

      const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
      expect(view.getUint32(40, true)).toBe(0); // data size = 0
    });
  });

  describe("clearInput", () => {
    it("does not throw (no-op)", () => {
      expect(() => clearInput()).not.toThrow();
    });
  });

  describe("push-to-end stop capture drain", () => {
    it("keeps recording briefly after a push-to-end stop signal to preserve final words", () => {
      expect(isPushToEndStopDrainComplete(1000, 1249, 250)).toBe(false);
      expect(isPushToEndStopDrainComplete(1000, 1250, 250)).toBe(true);
    });
  });

  describe("evaluateNoSpeechGate", () => {
    function pcmWithConstantSample(sample: number, durationMs: number): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < samples; i++) {
        view.setInt16(i * 2, sample, true);
      }
      return buffer;
    }

    it("rejects recordings shorter than 600ms before STT", () => {
      const result = evaluateNoSpeechGate(pcmWithConstantSample(5000, 500));

      expect(result.allowed).toBe(false);
      expect(result.reason).toBe("too-short");
    });

    it("rejects near-silent recordings before STT", () => {
      const result = evaluateNoSpeechGate(pcmWithConstantSample(20, 700));

      expect(result.allowed).toBe(false);
      expect(result.reason).toBe("too-quiet");
    });

    it("allows long low-energy captures through STT instead of discarding them", () => {
      const result = evaluateNoSpeechGate(pcmWithConstantSample(20, 3500));

      expect(result.allowed).toBe(true);
      expect(result.reason).toBeUndefined();
    });

    it("allows quiet-but-real recordings through the relaxed gate", () => {
      const result = evaluateNoSpeechGate(pcmWithConstantSample(100, 700));

      expect(result.allowed).toBe(true);
      expect(result.reason).toBeUndefined();
    });

    it("rejects invalid sample rates without producing NaN duration", () => {
      const result = evaluateNoSpeechGate(pcmWithConstantSample(4000, 700), 0);

      expect(result.allowed).toBe(false);
      expect(result.durationMs).toBe(0);
      expect(result.reason).toBe("invalid-sample-rate");
    });

    it("allows normal-duration audible recordings", () => {
      const result = evaluateNoSpeechGate(pcmWithConstantSample(4000, 700));

      expect(result.allowed).toBe(true);
      expect(result.reason).toBeUndefined();
    });

    it("aborts a zero-RMS payload at the gate in under 100ms", () => {
      const silence = new Uint8Array(16000 * 2 * 5);
      const started = performance.now();
      const result = evaluateNoSpeechGate(silence);
      const elapsedMs = performance.now() - started;

      expect(result.allowed).toBe(false);
      expect(result.reason).toBe("too-quiet");
      expect(elapsedMs).toBeLessThan(100);
    });
  });

  describe("trailing silence trim for STT", () => {
    function concatPcm(parts: Uint8Array[]): Uint8Array {
      const pcm = new Uint8Array(
        parts.reduce((sum, part) => sum + part.byteLength, 0),
      );
      let offset = 0;
      for (const part of parts) {
        pcm.set(part, offset);
        offset += part.byteLength;
      }
      return pcm;
    }

    function pcmWithConstantSample(
      sample: number,
      durationMs: number,
    ): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < samples; i++) {
        view.setInt16(i * 2, sample, true);
      }
      return buffer;
    }

    function pcmWithVaryingSpeech(durationMs: number): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < samples; i++) {
        view.setInt16(i * 2, 1200 + (i % 2000), true);
      }
      return buffer;
    }

    function pcmWithSineWave(peak: number, durationMs: number): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      const frequencyHz = 180;
      for (let i = 0; i < samples; i++) {
        const sample = Math.round(
          peak * Math.sin((2 * Math.PI * frequencyHz * i) / 16000),
        );
        view.setInt16(i * 2, sample, true);
      }
      return buffer;
    }

    function pcmWithSparseQuietSpeechlikeBurst(
      peak: number,
      durationMs: number,
      burstMs = 20,
    ): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      const burstSamples = Math.min(
        samples,
        Math.max(1, Math.floor((16000 * burstMs) / 1000)),
      );
      const frequencyHz = 180;
      for (let i = 0; i < burstSamples; i++) {
        const sample = Math.round(
          peak * Math.sin((2 * Math.PI * frequencyHz * i) / 16000),
        );
        view.setInt16(i * 2, sample, true);
      }
      return buffer;
    }

    it("trims a long quiet push-to-end tail before STT while preserving a short pad", () => {
      const speech = pcmWithConstantSample(2000, 2000);
      const quietTail = pcmWithConstantSample(0, 9000);
      const pcm = new Uint8Array(speech.byteLength + quietTail.byteLength);
      pcm.set(speech);
      pcm.set(quietTail, speech.byteLength);

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(true);
      expect(result.rawDurationMs).toBe(11000);
      expect(result.transcribedDurationMs).toBe(3000);
      expect(result.pcmData.byteLength).toBe(16000 * 2 * 3);
    });

    it("trims long low-level room tone after the last strong speech", () => {
      const speech = pcmWithConstantSample(2000, 2000);
      const roomTone = pcmWithConstantSample(250, 9000);
      const pcm = new Uint8Array(speech.byteLength + roomTone.byteLength);
      pcm.set(speech);
      pcm.set(roomTone, speech.byteLength);

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(true);
      expect(result.transcribedDurationMs).toBe(3000);
    });

    it("does not trim sustained quiet speech after an early loud phrase", () => {
      const opening = pcmWithConstantSample(2000, 2000);
      const shortPause = pcmWithConstantSample(0, 1500);
      const quietSpeech = pcmWithConstantSample(350, 18000);
      const finalPause = pcmWithConstantSample(0, 750);
      const pcm = new Uint8Array(
        opening.byteLength +
          shortPause.byteLength +
          quietSpeech.byteLength +
          finalPause.byteLength,
      );
      pcm.set(opening);
      pcm.set(shortPause, opening.byteLength);
      pcm.set(quietSpeech, opening.byteLength + shortPause.byteLength);
      pcm.set(
        finalPause,
        opening.byteLength + shortPause.byteLength + quietSpeech.byteLength,
      );

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(false);
      expect(result.rawDurationMs).toBe(22250);
      expect(result.transcribedDurationMs).toBe(22250);
    });

    it("does not trim speech-like low-RMS audio that the no-speech gate accepts", () => {
      const opening = pcmWithConstantSample(2000, 2000);
      const shortPause = pcmWithConstantSample(0, 1500);
      const quietSpeech = pcmWithSineWave(400, 18000);
      const finalPause = pcmWithConstantSample(0, 750);
      const pcm = new Uint8Array(
        opening.byteLength +
          shortPause.byteLength +
          quietSpeech.byteLength +
          finalPause.byteLength,
      );
      pcm.set(opening);
      pcm.set(shortPause, opening.byteLength);
      pcm.set(quietSpeech, opening.byteLength + shortPause.byteLength);
      pcm.set(
        finalPause,
        opening.byteLength + shortPause.byteLength + quietSpeech.byteLength,
      );

      expect(evaluateNoSpeechGate(quietSpeech).allowed).toBe(true);

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(false);
      expect(result.rawDurationMs).toBe(22250);
      expect(result.transcribedDurationMs).toBe(22250);
    });

    it("trims a long quiet tail even when isolated quiet-speechlike clicks appear in it", () => {
      const opening = pcmWithConstantSample(2000, 2000);
      const quietAfterSpeech = pcmWithConstantSample(0, 19250);
      const midClick = pcmWithSparseQuietSpeechlikeBurst(655, 250, 4);
      const longQuiet = pcmWithConstantSample(0, 29000);
      const stopClick = pcmWithSparseQuietSpeechlikeBurst(413, 250, 4);
      const trailingQuiet = pcmWithConstantSample(0, 353);
      const pcm = concatPcm([
        opening,
        quietAfterSpeech,
        midClick,
        longQuiet,
        stopClick,
        trailingQuiet,
      ]);

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(true);
      expect(result.rawDurationMs).toBe(51103);
      expect(result.transcribedDurationMs).toBe(3000);
    });

    it("keeps a short cluster of consecutive quiet speech after a long pause and pads 1s", () => {
      const opening = pcmWithConstantSample(2000, 2000);
      const longPause = pcmWithConstantSample(0, 14000);
      const quietSpeechCluster = concatPcm([
        pcmWithSparseQuietSpeechlikeBurst(450, 250),
        pcmWithSparseQuietSpeechlikeBurst(450, 250),
      ]);
      const trailingQuiet = pcmWithConstantSample(0, 6000);
      const pcm = concatPcm([
        opening,
        longPause,
        quietSpeechCluster,
        trailingQuiet,
      ]);

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(true);
      expect(result.transcribedDurationMs).toBe(17500);
    });

    it("does not trim ordinary short pauses before stop", () => {
      const speech = pcmWithConstantSample(2000, 2000);
      const shortPause = pcmWithConstantSample(0, 1500);
      const pcm = new Uint8Array(speech.byteLength + shortPause.byteLength);
      pcm.set(speech);
      pcm.set(shortPause, speech.byteLength);

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(false);
      expect(result.pcmData.byteLength).toBe(pcm.byteLength);
      expect(result.rawDurationMs).toBe(3500);
      expect(result.transcribedDurationMs).toBe(3500);
    });

    it("does not trim VAD recordings", () => {
      const speech = pcmWithConstantSample(2000, 2000);
      const quietTail = pcmWithConstantSample(0, 9000);
      const pcm = new Uint8Array(speech.byteLength + quietTail.byteLength);
      pcm.set(speech);
      pcm.set(quietTail, speech.byteLength);

      const result = trimTrailingSilenceForSTT(pcm, false);

      expect(result.trimmed).toBe(false);
      expect(result.pcmData).toBe(pcm);
      expect(result.rawDurationMs).toBe(11000);
      expect(result.transcribedDurationMs).toBe(11000);
    });

    it("includes final partial windows when finding the last active audio", () => {
      const speech = pcmWithConstantSample(2000, 2000);
      const quietTail = pcmWithConstantSample(0, 9000);
      const finalPartialSpeech = pcmWithConstantSample(2000, 125);
      const trailingQuiet = pcmWithConstantSample(0, 6000);
      const pcm = new Uint8Array(
        speech.byteLength +
          quietTail.byteLength +
          finalPartialSpeech.byteLength +
          trailingQuiet.byteLength,
      );
      pcm.set(speech);
      pcm.set(quietTail, speech.byteLength);
      pcm.set(finalPartialSpeech, speech.byteLength + quietTail.byteLength);
      pcm.set(
        trailingQuiet,
        speech.byteLength +
          quietTail.byteLength +
          finalPartialSpeech.byteLength,
      );

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(true);
      expect(result.transcribedDurationMs).toBe(12250);
    });

    it("keeps long low-energy push-to-end captures eligible for STT after trimming", () => {
      const speech = pcmWithConstantSample(1000, 2000);
      const veryLongSilence = pcmWithConstantSample(0, 1000000);
      const pcm = new Uint8Array(
        speech.byteLength + veryLongSilence.byteLength,
      );
      pcm.set(speech);
      pcm.set(veryLongSilence, speech.byteLength);

      const rawGate = evaluateNoSpeechGate(pcm);
      const trim = trimTrailingSilenceForSTT(pcm, true);
      const trimmedGate = evaluateNoSpeechGate(trim.pcmData);

      expect(rawGate.allowed).toBe(true);
      expect(rawGate.reason).toBeUndefined();
      expect(trim.trimmed).toBe(true);
      expect(trimmedGate.allowed).toBe(true);
    });

    it("can rebuild chunked STT segments from trimmed push-to-end audio", () => {
      const session = new ChunkedRecordingSession(16000, "thoughtful");
      const trimmedPcm = pcmWithVaryingSpeech(65000);

      session.replaceWithPCM(trimmedPcm, true);
      session.finalize();
      const segments = session.consumeSegments();

      expect(segments.length).toBeGreaterThan(1);
      expect(
        segments.reduce((sum, segment) => sum + segment.byteLength, 0),
      ).toBe(
        trimmedPcm.byteLength +
          session.currentOverlapBytes() * (segments.length - 1),
      );
    });
  });

  describe("pre-roll chunk selection", () => {
    function chunk(marker: number): Uint8Array {
      return new Uint8Array([marker, marker]);
    }

    it("keeps only bounded pre-roll before first speech to avoid retaining stale room audio", () => {
      const selected = selectChunksWithPreRoll(
        [chunk(1), chunk(2), chunk(3), chunk(4), chunk(5)],
        3,
        2,
      );

      expect(selected.map((c) => c[0])).toEqual([2, 3, 4, 5]);
    });

    it("keeps the first speech chunk when speech begins inside the first 32ms frame", () => {
      const selected = selectChunksWithPreRoll(
        [chunk(9), chunk(10), chunk(11)],
        0,
        16,
      );

      expect(selected.map((c) => c[0])).toEqual([9, 10, 11]);
    });
  });

  describe("no-speech capture classification", () => {
    function pcmWithConstantSample(sample: number, durationMs: number): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < samples; i++) {
        view.setInt16(i * 2, sample, true);
      }
      return buffer;
    }

    it("keeps long near-zero captures as silent dismisses", async () => {
      const input = (await import("../input")) as Record<string, any>;
      const gate = evaluateNoSpeechGate(pcmWithConstantSample(1, 3500));

      expect(input.classifyCaptureFailure?.(gate)).toBeNull();
    });

    it("classifies true zero-RMS captures as broken mic for VoiceBar recovery", () => {
      const gate = evaluateNoSpeechGate(pcmWithConstantSample(0, 3500));

      expect(classifyCaptureFailure(gate)).toEqual({
        type: "broken-mic",
        message: "Microphone returned silence",
      });
    });

    it("keeps ordinary quiet silence as a silent dismiss", async () => {
      const input = (await import("../input")) as Record<string, any>;
      const gate = evaluateNoSpeechGate(pcmWithConstantSample(20, 700));

      expect(input.classifyCaptureFailure?.(gate)).toBeNull();
    });
  });

  describe("push-to-end speech gate", () => {
    function fixturePCM(name: string): Uint8Array {
      const fixturePath = join(
        import.meta.dir,
        "..",
        "..",
        "flow-bar",
        "Tests",
        "VoiceBarTests",
        "Fixtures",
        name,
      );
      return new Uint8Array(readFileSync(fixturePath)).slice(44);
    }

    it("rejects high-noise captures that contain no detected speech", async () => {
      const result = await evaluatePushToEndSpeechGate(fixturePCM("high_noise.wav"));

      expect(result.detected).toBe(false);
      expect(result.speechChunks).toBe(0);
      expect(result.totalChunks).toBeGreaterThan(0);
    });

    it("allows clean speech captures through the push-to-end speech gate", async () => {
      const result = await evaluatePushToEndSpeechGate(
        fixturePCM("clean_speech.wav"),
      );

      expect(result.detected).toBe(true);
      expect(result.speechChunks).toBeGreaterThanOrEqual(2);
      expect(result.totalChunks).toBeGreaterThan(result.speechChunks);
    });

    it("requires more than a single isolated speech-positive chunk", async () => {
      const probabilities = [0.91, 0.1, 0.1];
      const pcm = new Uint8Array(VAD_CHUNK_BYTES * probabilities.length);

      const result = await evaluatePushToEndSpeechGate(pcm, {
        reset: async () => {},
        processChunk: async () => probabilities.shift() ?? 0,
        isSpeechPredicate: (probability) => probability >= 0.5,
      });

      expect(result.detected).toBe(false);
      expect(result.speechChunks).toBe(1);
      expect(result.totalChunks).toBe(3);
    });
  });

  describe("push-to-end mode exports", () => {
    it("recordToBuffer accepts pushToEnd parameter (type check)", async () => {
      const { recordToBuffer } = await import("../input");
      // Verify the function exists and has the right arity (3 params)
      expect(typeof recordToBuffer).toBe("function");
      expect(recordToBuffer.length).toBeGreaterThanOrEqual(1);
    });

    it("waitForInput accepts pushToEnd parameter (type check)", async () => {
      const { waitForInput } = await import("../input");
      expect(typeof waitForInput).toBe("function");
      expect(waitForInput.length).toBeGreaterThanOrEqual(1);
    });

    it("stops push-to-end recording promptly even when no audio chunks are processed", async () => {
      const originalSpawn = Bun.spawn;
      const originalSpawnSync = Bun.spawnSync;
      let spawned = false;
      let stdoutController: ReadableStreamDefaultController<Uint8Array>;
      let stderrController: ReadableStreamDefaultController<Uint8Array>;

      Bun.spawnSync = (() => ({
        exitCode: 0,
        stdout: Buffer.from(""),
        stderr: Buffer.from("Sample Rate : 16000\nChannels : 1\n"),
      })) as typeof Bun.spawnSync;
      Bun.spawn = (() => {
        spawned = true;
        return {
          stdout: new ReadableStream<Uint8Array>({
            start(controller) {
              stdoutController = controller;
            },
          }),
          stderr: new ReadableStream<Uint8Array>({
            start(controller) {
              stderrController = controller;
            },
          }),
          kill: () => {
            try {
              stdoutController.close();
            } catch {}
            try {
              stderrController.close();
            } catch {}
          },
          exited: Promise.resolve(0),
        };
      }) as typeof Bun.spawn;

      try {
        clearStopSignal();
        const { recordToBuffer } = await import("../input");
        const startedAt = Date.now();
        const recording = recordToBuffer(1000, "standard", true);

        while (!spawned) {
          await Bun.sleep(1);
        }
        writeFileSync(STOP_FILE, "stop");

        await recording;
        expect(Date.now() - startedAt).toBeLessThan(500);
      } finally {
        clearStopSignal();
        Bun.spawn = originalSpawn;
        Bun.spawnSync = originalSpawnSync;
      }
    });

    it("escalates recorder shutdown from SIGTERM to SIGKILL when rec does not exit", async () => {
      const signals: string[] = [];

      await terminateRecorderProcess(
        {
          kill: (signal?: string) => {
            signals.push(signal ?? "SIGTERM");
          },
          exited: new Promise(() => {}),
        },
        1,
      );

      expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
    });
  });

  describe("Phase 7 feature flag", () => {
    it("uses legacy one-shot pipeline by default", () => {
      const saved = process.env.QA_VOICE_CHUNKED_STT;
      delete process.env.QA_VOICE_CHUNKED_STT;
      try {
        expect(isChunkedSTTEnabled()).toBe(false);
      } finally {
        if (saved) process.env.QA_VOICE_CHUNKED_STT = saved;
      }
    });

    it("enables chunked pipeline when QA_VOICE_CHUNKED_STT is set", () => {
      const saved = process.env.QA_VOICE_CHUNKED_STT;
      process.env.QA_VOICE_CHUNKED_STT = "1";
      try {
        expect(isChunkedSTTEnabled()).toBe(true);
      } finally {
        if (saved) process.env.QA_VOICE_CHUNKED_STT = saved;
        else delete process.env.QA_VOICE_CHUNKED_STT;
      }
    });
  });

  describe("STT corrector feature flag", () => {
    it("preserves existing cleanup when QA_VOICE_CORRECTOR is unset or off", () => {
      expect(finalizeTranscriptionText("brain layer", {})).toBe("BrainLayer.");
      expect(finalizeTranscriptionText("brain layer", { QA_VOICE_CORRECTOR: "off" })).toBe(
        "BrainLayer.",
      );
    });

    it("can bypass cleanup with identity mode for baseline evals", () => {
      expect(
        finalizeTranscriptionText("brain layer", { QA_VOICE_CORRECTOR: "identity" }),
      ).toBe("brain layer");
    });

    it("runs the explicit rules backend when enabled", () => {
      expect(
        finalizeTranscriptionText("brain layer", { QA_VOICE_CORRECTOR: "rules" }),
      ).toBe("BrainLayer.");
    });

    it("routes both VoiceBar dictation and voice_ask through polish", async () => {
      expect(
        polishSurfaceForWaitOptions({ archiveSource: "voicebar" }),
      ).toBe("dictation");
      expect(
        polishSurfaceForWaitOptions({ archiveSource: "voice_ask" }),
      ).toBe("voice_ask");

      const tempDir = mkdtempSync(join(tmpdir(), "voicelayer-input-polish-"));
      const socketPath = join(tempDir, "polish.sock");
      const logPath = join(tempDir, "polish.jsonl");
      const controlLayerRoot = join(tempDir, "control-layer");
      const received: string[] = [];
      const server = Bun.listen<{ buffer: string }>({
        unix: socketPath,
        socket: {
          open(socket) {
            socket.data = { buffer: "" };
          },
          data(socket, raw) {
            socket.data.buffer += raw.toString("utf-8");
            const lines = socket.data.buffer.split("\n");
            socket.data.buffer = lines.pop() ?? "";
            for (const line of lines) {
              if (!line.trim()) continue;
              received.push(line);
              socket.write(`${JSON.stringify({ text: "Brain Layer." })}\n`);
            }
          },
          close() {},
          error() {},
          drain() {},
        },
      });

      const savedDisable = process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
      const savedControlLayerBase = process.env.VOICELAYER_CONTROL_LAYER_BASE;
      try {
        delete process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
        process.env.VOICELAYER_CONTROL_LAYER_BASE = controlLayerRoot;
        const env = {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_SOCKET: socketPath,
          QA_VOICE_STT_POLISH_LOG_PATH: logPath,
        };

        await expect(
          finalizeTranscriptionTextForSurface("brain layer", null, env),
        ).resolves.toBe("BrainLayer.");
        await expect(
          finalizeTranscriptionTextForSurface("brain layer", "dictation", env),
        ).resolves.toBe("Brain Layer.");
        expect(received.length).toBe(1);
        for (let i = 0; i < 50 && !existsSync(logPath); i++) {
          await new Promise((resolve) => setTimeout(resolve, 5));
        }
        expect(existsSync(logPath)).toBe(true);
        const db = new Database(join(controlLayerRoot, "fleet-journal.db"), {
          readonly: true,
        });
        try {
          const row = db
            .query(
              "select topic, type, payload_json from events where type = 'transcription.polish'",
            )
            .get() as {
            topic: string;
            type: string;
            payload_json: string;
          } | null;
          expect(row).not.toBeNull();
          expect(row?.topic).toBe("voice.transcription");
          const payload = JSON.parse(row?.payload_json ?? "{}");
          expect(payload).toMatchObject({
            mode: "on",
            status: "applied",
            surface: "dictation",
            changed: true,
          });
          expect(payload.cleaned_chars).toBe("BrainLayer.".length);
          expect(payload.final_chars).toBe("Brain Layer.".length);
        } finally {
          db.close();
        }
      } finally {
        if (savedDisable === undefined) {
          delete process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
        } else {
          process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL = savedDisable;
        }
        if (savedControlLayerBase === undefined) {
          delete process.env.VOICELAYER_CONTROL_LAYER_BASE;
        } else {
          process.env.VOICELAYER_CONTROL_LAYER_BASE = savedControlLayerBase;
        }
        server.stop(true);
        try {
          unlinkSync(socketPath);
        } catch {}
        rmSync(tempDir, { recursive: true, force: true });
      }
    });
  });

  describe("Phase 7 chunk transcription integration", () => {
    it("carries prompt context across chunks and applies rules to the merged text", async () => {
      const prompts: string[] = [];

      const result = await transcribeChunkSequence(
        [new Uint8Array([1]), new Uint8Array([2])],
        async (_chunk, prompt) => {
          prompts.push(prompt);
          return prompts.length === 1
            ? "תשתמש ב use effect"
            : "use effect בשביל on click handler";
        },
      );

      expect(prompts).toEqual(["", "תשתמש ב use effect"]);
      expect(result).toContain("useEffect");
      expect(result).toContain("onClick");
    });

    it("applies STT cleanup aliases to merged chunk text", async () => {
      const result = await transcribeChunkSequence(
        [new Uint8Array([1]), new Uint8Array([2])],
        async (_chunk, _prompt) =>
          "work claude opened voice layer in whisper flow",
      );

      expect(result).toContain("orcClaude");
      expect(result).toContain("VoiceLayer");
      expect(result).toContain("Wispr Flow");
    });

    it("returns empty text when chunk STT only produces no-input labels", async () => {
      const result = await transcribeChunkSequence(
        [new Uint8Array([1]), new Uint8Array([2])],
        async (_chunk, _prompt) => "- Oh, my God.",
      );

      expect(result).toBe("");
    });
  });
});

describe("archived transcript metadata after retranscription", () => {
  let archiveDir: string;

  const writeArchive = (metadata: Record<string, unknown>): string => {
    archiveDir = mkdtempSync(join(tmpdir(), "voicelayer-retranscribe-meta-"));
    const audioPath = join(archiveDir, "audio.wav");
    writeFileSync(audioPath, createWavBuffer(new Uint8Array([1, 2, 3, 4])));
    writeFileSync(
      join(archiveDir, "metadata.json"),
      `${JSON.stringify(metadata, null, 2)}\n`,
    );
    return audioPath;
  };

  const readMetadata = (): Record<string, unknown> =>
    JSON.parse(readFileSync(join(archiveDir, "metadata.json"), "utf8"));

  afterEach(() => {
    if (archiveDir && existsSync(archiveDir)) {
      rmSync(archiveDir, { recursive: true, force: true });
    }
  });

  it("records the trimmed duration actually handed to STT, leaving mic-on time intact", () => {
    const audioPath = writeArchive({
      id: "2026-08-18T12-14-56-912Z-ece16541",
      source: "voicebar",
      mode: "ptt",
      duration_ms: 64853,
      raw_duration_ms: 64853,
      transcribed_duration_ms: 64853,
      transcription_status: "transcribed",
    });

    updateArchivedTranscript(audioPath, "Well, I got a no from Upwind.", {
      backend: "whisper-server",
      languageMode: "auto",
      transcribedDurationMs: 17000,
    });

    const metadata = readMetadata();
    // The portion whisper actually saw.
    expect(metadata.transcribed_duration_ms).toBe(17000);
    // Mic-on time is a separate fact and must survive untouched.
    expect(metadata.duration_ms).toBe(64853);
    expect(metadata.raw_duration_ms).toBe(64853);
  });

  it("leaves the recorded duration alone when nothing was trimmed", () => {
    const audioPath = writeArchive({
      id: "2026-08-18T12-14-56-912Z-ece16541",
      source: "voicebar",
      mode: "vad",
      duration_ms: 4200,
      raw_duration_ms: 4200,
      transcribed_duration_ms: 4200,
      transcription_status: "transcribed",
    });

    updateArchivedTranscript(audioPath, "Short one.", {
      backend: "whisper-server",
      languageMode: "auto",
      transcribedDurationMs: 4200,
    });

    expect(readMetadata().transcribed_duration_ms).toBe(4200);
  });

  it("does not invent a duration when the caller supplies none", () => {
    const audioPath = writeArchive({
      id: "2026-08-18T12-14-56-912Z-ece16541",
      source: "voicebar",
      mode: "ptt",
      duration_ms: 64853,
      raw_duration_ms: 64853,
      transcribed_duration_ms: 64853,
      transcription_status: "transcribed",
    });

    updateArchivedTranscript(audioPath, "No duration passed.", {
      backend: "whisper-server",
      languageMode: "auto",
    });

    expect(readMetadata().transcribed_duration_ms).toBe(64853);
  });
});

describe("recorder stderr watcher", () => {
  const PROBE_OUTPUT = "Channels : 2\nSample Rate : 48000\n";
  const encode = (s: string) => new TextEncoder().encode(s);

  beforeEach(() => {
    resetNativeInputFormatCache();
    __setNativeInputFormatProbesForTests({
      sync: () => ({ stderr: PROBE_OUTPUT, stdout: "" }),
    });
  });

  afterEach(() => {
    __resetNativeInputFormatProbesForTests();
    resetNativeInputFormatCache();
  });

  // The round-1 HIGH: the old reader only fed the cache at EOF, while finish()
  // resolves the recording without awaiting either the recorder's exit or this
  // reader. The next press could therefore spawn rec with the stale format.
  it("corrects the format cache mid-stream, before the recorder exits", () => {
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 48000,
      channels: 2,
    });

    const watcher = createRecorderStderrWatcher("rec");
    watcher.push(
      encode(
        "/opt/homebrew/bin/rec WARN formats: can't set sample rate 48000; using 16000\n",
      ),
    );

    // No finish() — the recorder is still running and the stream is still open.
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 16000,
      channels: 2,
    });
  });

  it("corrects from a warning that never gets a trailing newline", () => {
    detectNativeInputFormat();

    const watcher = createRecorderStderrWatcher("rec");
    watcher.push(encode("rec WARN formats: can't set 2 channels; using 1"));

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 48000,
      channels: 1,
    });
  });

  it("applies a correction split across two chunks", () => {
    detectNativeInputFormat();

    const watcher = createRecorderStderrWatcher("rec");
    watcher.push(encode("rec WARN formats: can't set sample "));
    watcher.push(encode("rate 48000; using 44100\n"));

    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 44100,
      channels: 2,
    });
  });

  it("drops the cache mid-stream when rec reports a device failure", () => {
    detectNativeInputFormat();
    let probes = 0;
    __setNativeInputFormatProbesForTests({
      sync: () => {
        probes++;
        return { stderr: PROBE_OUTPUT, stdout: "" };
      },
    });

    const watcher = createRecorderStderrWatcher("rec");
    watcher.push(encode("rec FAIL formats: can't open input device\n"));

    detectNativeInputFormat();
    expect(probes).toBe(1);
  });

  it("announces a correction once, not per chunk", () => {
    detectNativeInputFormat();
    const logged: string[] = [];
    const errSpy = spyOn(console, "error").mockImplementation((...args) => {
      logged.push(args.join(" "));
    });

    try {
      const watcher = createRecorderStderrWatcher("rec");
      watcher.push(encode("rec WARN formats: can't set 2 channels; using 1\n"));
      watcher.push(encode("rec WARN formats: can't set 2 channels; using 1\n"));
      watcher.finish();
    } finally {
      errSpy.mockRestore();
    }

    expect(
      logged.filter((line) => line.includes("Device input format changed")),
    ).toHaveLength(1);
  });

  it("returns the accumulated text for the diagnostic log and stays quiet when clean", () => {
    detectNativeInputFormat();
    const watcher = createRecorderStderrWatcher("rec");
    watcher.push(encode("rec WARN alsa: over-run\n"));

    expect(watcher.finish()).toBe("rec WARN alsa: over-run");
    expect(detectNativeInputFormat()).toEqual({
      sampleRate: 48000,
      channels: 2,
    });
  });

  it("has nothing to report for a recorder that wrote no stderr", () => {
    const watcher = createRecorderStderrWatcher("rec");
    expect(watcher.finish()).toBe("");
  });
});
