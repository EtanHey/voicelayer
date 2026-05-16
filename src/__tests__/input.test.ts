import { afterEach, beforeEach, describe, it, expect } from "bun:test";
import { createHash } from "crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  archiveVoiceBarRecording,
  archiveWaitForInputRecording,
  calculateRMS,
  consumeCancelSignalForRecording,
  createWavBuffer,
  clearInput,
  evaluateNoSpeechGate,
  isChunkedSTTEnabled,
  selectChunksWithPreRoll,
  transcribeChunkSequence,
  finalizeTranscriptionText,
} from "../input";
import {
  clearCancelSignal,
  hasCancelSignal,
  setCancelSignal,
} from "../session-booking";

describe("input module", () => {
  describe("VoiceBar recording archive", () => {
    let archiveRoot: string | undefined;
    let savedRecordingsDir: string | undefined;
    let savedLanguage: string | undefined;

    beforeEach(() => {
      savedRecordingsDir = process.env.QA_VOICE_RECORDINGS_DIR;
      savedLanguage = process.env.QA_VOICE_WHISPER_LANG;
      archiveRoot = mkdtempSync(join(tmpdir(), "voicelayer-recordings-test-"));
      process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
      process.env.QA_VOICE_WHISPER_LANG = "hebrew";
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
        sample_rate: 16000,
        channels: 1,
        backend: "whisper.cpp",
        language_mode: "hebrew",
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

    it("retains the last wav before honoring a late cancel during transcription", () => {
      const source = readFileSync(join(import.meta.dir, "../input.ts"), "utf8");
      const retainIndex = source.indexOf(
        "writeFileSync(retainedRecordingFilePath(), retainedWavData);",
      );
      const lateCancelIndex = source.indexOf(
        '"[voicelayer] Recording cancelled during transcription — discarding transcript"',
      );

      expect(retainIndex).toBeGreaterThan(-1);
      expect(lateCancelIndex).toBeGreaterThan(-1);
      expect(retainIndex).toBeLessThan(lateCancelIndex);
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
