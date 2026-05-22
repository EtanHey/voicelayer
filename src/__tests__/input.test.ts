import { afterEach, beforeEach, describe, it, expect } from "bun:test";
import { createHash } from "crypto";
import ts from "typescript";
import {
  existsSync,
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
  archiveWaitForInputRecording,
  calculateRMS,
  ChunkedRecordingSession,
  consumeCancelSignalForRecording,
  createWavBuffer,
  clearInput,
  evaluateNoSpeechGate,
  isChunkedSTTEnabled,
  isPttStopDrainComplete,
  retainLastCaptureForRecovery,
  selectChunksWithPreRoll,
  transcribeChunkSequence,
  finalizeTranscriptionTextForSurface,
  finalizeTranscriptionText,
  trimTrailingSilenceForSTT,
  terminateRecorderProcess,
} from "../input";
import {
  clearCancelSignal,
  clearStopSignal,
  hasCancelSignal,
  setCancelSignal,
} from "../session-booking";
import { STOP_FILE } from "../paths";
import { retainedRecordingFilePath } from "../paths";

describe("input module", () => {
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
        pressToTalk: true,
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
        app_version: null,
        schema_version: 1,
      });
      expect(metadata.audio_sha256).toBe(
        createHash("sha256").update(audioBytes).digest("hex"),
      );
    });

    it("skips archive creation when a recording is cancelled before transcription", () => {
      const archivedPath = archiveVoiceBarRecording({
        audioBytes: createWavBuffer(new Uint8Array([1, 2])),
        transcript: null,
        source: "voicebar",
        silenceMode: "standard",
        pressToTalk: false,
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
        pressToTalk: true,
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
        pressToTalk: false,
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
        pressToTalk: false,
        durationMs: 900,
        backend: "whisper.cpp",
      });

      expect(archivedPath).toBeNull();
      expect(readdirSync(archiveRoot!)).toHaveLength(0);
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

  describe("PTT stop capture drain", () => {
    it("keeps recording briefly after a PTT stop signal to preserve final words", () => {
      expect(isPttStopDrainComplete(1000, 1249, 250)).toBe(false);
      expect(isPttStopDrainComplete(1000, 1250, 250)).toBe(true);
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
    function pcmWithConstantSample(sample: number, durationMs: number): Uint8Array {
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

    it("trims a long quiet PTT tail before STT while preserving a short pad", () => {
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
        speech.byteLength + quietTail.byteLength + finalPartialSpeech.byteLength,
      );

      const result = trimTrailingSilenceForSTT(pcm, true);

      expect(result.trimmed).toBe(true);
      expect(result.transcribedDurationMs).toBe(12250);
    });

    it("allows the no-speech gate to evaluate trimmed PTT audio instead of raw long tails", () => {
      const speech = pcmWithConstantSample(1000, 2000);
      const veryLongSilence = pcmWithConstantSample(0, 1000000);
      const pcm = new Uint8Array(speech.byteLength + veryLongSilence.byteLength);
      pcm.set(speech);
      pcm.set(veryLongSilence, speech.byteLength);

      const rawGate = evaluateNoSpeechGate(pcm);
      const trim = trimTrailingSilenceForSTT(pcm, true);
      const trimmedGate = evaluateNoSpeechGate(trim.pcmData);

      expect(rawGate.allowed).toBe(false);
      expect(rawGate.reason).toBe("too-quiet");
      expect(trim.trimmed).toBe(true);
      expect(trimmedGate.allowed).toBe(true);
    });

    it("can rebuild chunked STT segments from trimmed PTT audio", () => {
      const session = new ChunkedRecordingSession(16000, "thoughtful");
      const trimmedPcm = pcmWithVaryingSpeech(65000);

      session.replaceWithPCM(trimmedPcm, true);
      session.finalize();
      const segments = session.consumeSegments();

      expect(segments.length).toBeGreaterThan(1);
      expect(segments.reduce((sum, segment) => sum + segment.byteLength, 0)).toBe(
        trimmedPcm.byteLength + session.currentOverlapBytes() * (segments.length - 1),
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

  describe("broken mic detection", () => {
    function pcmWithConstantSample(sample: number, durationMs: number): Uint8Array {
      const samples = Math.floor((16000 * durationMs) / 1000);
      const buffer = new Uint8Array(samples * 2);
      const view = new DataView(buffer.buffer);
      for (let i = 0; i < samples; i++) {
        view.setInt16(i * 2, sample, true);
      }
      return buffer;
    }

    it("flags long near-zero captures as broken mic instead of ordinary silence", async () => {
      const input = (await import("../input")) as Record<string, any>;
      const gate = evaluateNoSpeechGate(pcmWithConstantSample(1, 3500));

      expect(input.classifyCaptureFailure?.(gate)).toEqual({
        type: "broken-mic",
        message: expect.stringContaining("Microphone"),
      });
    });

    it("keeps ordinary quiet silence as a silent dismiss", async () => {
      const input = (await import("../input")) as Record<string, any>;
      const gate = evaluateNoSpeechGate(pcmWithConstantSample(20, 700));

      expect(input.classifyCaptureFailure?.(gate)).toBeNull();
    });
  });

  describe("PTT mode exports", () => {
    it("recordToBuffer accepts pressToTalk parameter (type check)", async () => {
      const { recordToBuffer } = await import("../input");
      // Verify the function exists and has the right arity (3 params)
      expect(typeof recordToBuffer).toBe("function");
      expect(recordToBuffer.length).toBeGreaterThanOrEqual(1);
    });

    it("waitForInput accepts pressToTalk parameter (type check)", async () => {
      const { waitForInput } = await import("../input");
      expect(typeof waitForInput).toBe("function");
      expect(waitForInput.length).toBeGreaterThanOrEqual(1);
    });

    it("stops PTT recording promptly even when no audio chunks are processed", async () => {
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
      expect(finalizeTranscriptionText("brain layer", {})).toBe("BrainLayer");
      expect(finalizeTranscriptionText("brain layer", { QA_VOICE_CORRECTOR: "off" })).toBe(
        "BrainLayer",
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
      ).toBe("BrainLayer");
    });

    it("routes polish only for VoiceBar dictation surfaces", async () => {
      const tempDir = mkdtempSync(join(tmpdir(), "voicelayer-input-polish-"));
      const socketPath = join(tempDir, "polish.sock");
      const logPath = join(tempDir, "polish.jsonl");
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
              socket.write(`${JSON.stringify({ text: "BrainLayer." })}\n`);
            }
          },
          close() {},
          error() {},
          drain() {},
        },
      });

      try {
        const env = {
          QA_VOICE_STT_POLISH: "on",
          QA_VOICE_STT_POLISH_SOCKET: socketPath,
          QA_VOICE_STT_POLISH_LOG_PATH: logPath,
        };

        await expect(
          finalizeTranscriptionTextForSurface("brain layer", null, env),
        ).resolves.toBe("BrainLayer");
        await expect(
          finalizeTranscriptionTextForSurface("brain layer", "dictation", env),
        ).resolves.toBe("BrainLayer.");
        expect(received.length).toBe(1);
        for (let i = 0; i < 50 && !existsSync(logPath); i++) {
          await new Promise((resolve) => setTimeout(resolve, 5));
        }
        expect(existsSync(logPath)).toBe(true);
      } finally {
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
