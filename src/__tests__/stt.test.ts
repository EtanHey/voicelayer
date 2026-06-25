import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import {
  WhisperCppBackend,
  WhisperServerBackend,
  WisprFlowBackend,
  getBackend,
  resetBackendCache,
  buildChunkPrompt,
  mergeChunkTranscripts,
  buildWhisperServerOptions,
} from "../stt";

function makePcm16Wav(durationSeconds: number): Uint8Array {
  const sampleRate = 16000;
  const channels = 1;
  const bitsPerSample = 16;
  const dataBytes = durationSeconds * sampleRate * channels * 2;
  const wav = new Uint8Array(44 + dataBytes);
  const view = new DataView(wav.buffer);
  const writeAscii = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i++) {
      wav[offset + i] = value.charCodeAt(i);
    }
  };

  writeAscii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  writeAscii(8, "WAVE");
  writeAscii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * channels * 2, true);
  view.setUint16(32, channels * 2, true);
  view.setUint16(34, bitsPerSample, true);
  writeAscii(36, "data");
  view.setUint32(40, dataBytes, true);

  return wav;
}

describe("STT backends", () => {
  beforeEach(() => {
    resetBackendCache();
  });

  afterEach(() => {
    resetBackendCache();
  });

  describe("WhisperCppBackend", () => {
    it("has correct name", () => {
      const backend = new WhisperCppBackend();
      expect(backend.name).toBe("whisper.cpp");
    });

    it("isAvailable checks for binary and model", async () => {
      const backend = new WhisperCppBackend();
      // This may return true or false depending on the machine
      const available = await backend.isAvailable();
      expect(typeof available).toBe("boolean");
    });

    it("getModelInfo returns binary and model paths", () => {
      const backend = new WhisperCppBackend();
      const info = backend.getModelInfo();
      expect(info).toHaveProperty("binary");
      expect(info).toHaveProperty("model");
    });

    it("transcribe throws when binary not found", async () => {
      const backend = new WhisperCppBackend();

      // Prevent transcribe() from re-detecting a real local install.
      Object.defineProperty(backend, "binaryPath", {
        configurable: true,
        get: () => null,
        set: () => {},
      });
      Object.defineProperty(backend, "modelPath", {
        configurable: true,
        get: () => "/some/model.bin",
        set: () => {},
      });

      // Verify it throws with helpful error message
      await expect(backend.transcribe("/tmp/test.wav")).rejects.toThrow(
        "whisper-cpp",
      );
    });

    it("transcribe resolves brew by absolute path for launchd-style PATHs", async () => {
      const backend = new WhisperCppBackend();
      const originalSpawn = Bun.spawn;
      const originalSpawnSync = Bun.spawnSync;
      const spawnSyncCalls: string[][] = [];
      let whisperEnv: Record<string, string> | undefined;

      Object.defineProperty(backend, "binaryPath", {
        configurable: true,
        get: () => "/opt/homebrew/bin/whisper-cli",
        set: () => {},
      });
      Object.defineProperty(backend, "modelPath", {
        configurable: true,
        get: () => "/tmp/test-model.bin",
        set: () => {},
      });

      // @ts-ignore - test double
      Bun.spawnSync = (cmd: string[]) => {
        spawnSyncCalls.push([...cmd]);

        if (cmd[0] === "which" && cmd[1] === "brew") {
          return {
            exitCode: 1,
            stdout: new Uint8Array(0),
            stderr: new Uint8Array(0),
          };
        }

        if (cmd[0] === "/opt/homebrew/bin/brew" && cmd[1] === "--version") {
          return {
            exitCode: 0,
            stdout: Buffer.from("Homebrew 4.0.0\n"),
            stderr: new Uint8Array(0),
          };
        }

        if (
          cmd[0] === "/opt/homebrew/bin/brew" &&
          cmd[1] === "--prefix" &&
          cmd[2] === "whisper-cpp"
        ) {
          return {
            exitCode: 0,
            stdout: Buffer.from("/opt/homebrew/opt/whisper-cpp\n"),
            stderr: new Uint8Array(0),
          };
        }

        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      };

      // @ts-ignore - test double
      Bun.spawn = (cmd: string[], opts?: { env?: Record<string, string> }) => {
        whisperEnv = opts?.env;
        const stdout = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("transcribed text\n"));
            controller.close();
          },
        });
        const stderr = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.close();
          },
        });
        return {
          stdout,
          stderr,
          exited: Promise.resolve(0),
          pid: 12345,
          kill: () => {},
        };
      };

      try {
        const result = await backend.transcribe("/tmp/test.wav");
        expect(result.text).toBe("transcribed text");
        expect(whisperEnv?.GGML_METAL_PATH_RESOURCES).toBe(
          "/opt/homebrew/opt/whisper-cpp/share/whisper-cpp",
        );
        expect(spawnSyncCalls).toContainEqual([
          "/opt/homebrew/bin/brew",
          "--prefix",
          "whisper-cpp",
        ]);
      } finally {
        Bun.spawn = originalSpawn;
        Bun.spawnSync = originalSpawnSync;
      }
    });

    it("transcribe uses the whisper-cli prompt flag for explicit language modes", async () => {
      const backend = new WhisperCppBackend();
      const originalSpawn = Bun.spawn;
      const originalSpawnSync = Bun.spawnSync;
      let whisperCmd: string[] | undefined;
      const savedLang = process.env.QA_VOICE_WHISPER_LANG;
      process.env.QA_VOICE_WHISPER_LANG = "english";

      Object.defineProperty(backend, "binaryPath", {
        configurable: true,
        get: () => "/opt/homebrew/bin/whisper-cli",
        set: () => {},
      });
      Object.defineProperty(backend, "modelPath", {
        configurable: true,
        get: () => "/tmp/test-model.bin",
        set: () => {},
      });

      // @ts-ignore - test double
      Bun.spawnSync = (_cmd: string[]) => ({
        exitCode: 1,
        stdout: new Uint8Array(0),
        stderr: new Uint8Array(0),
      });

      // @ts-ignore - test double
      Bun.spawn = (cmd: string[]) => {
        whisperCmd = [...cmd];
        const stdout = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("transcribed text\n"));
            controller.close();
          },
        });
        const stderr = new ReadableStream<Uint8Array>({
          start(controller) {
            controller.close();
          },
        });
        return {
          stdout,
          stderr,
          exited: Promise.resolve(0),
          pid: 12345,
          kill: () => {},
        };
      };

      try {
        const result = await backend.transcribe("/tmp/test.wav");
        expect(result.text).toBe("transcribed text");
        expect(whisperCmd).toContain("--prompt");
        expect(whisperCmd).not.toContain("--initial-prompt");
        const promptIndex = whisperCmd!.indexOf("--prompt");
        expect(promptIndex).toBeGreaterThan(-1);
        expect(whisperCmd![promptIndex + 1]).toContain("Wispr Flow");
        expect(whisperCmd![promptIndex + 1]).toContain("VoiceLayer");
      } finally {
        if (savedLang) process.env.QA_VOICE_WHISPER_LANG = savedLang;
        else delete process.env.QA_VOICE_WHISPER_LANG;
        Bun.spawn = originalSpawn;
        Bun.spawnSync = originalSpawnSync;
      }
    });
  });

  describe("WisprFlowBackend", () => {
    it("has correct name", () => {
      const backend = new WisprFlowBackend();
      expect(backend.name).toBe("wispr-flow");
    });

    it("isAvailable returns true when WISPR_KEY is set", async () => {
      const saved = process.env.QA_VOICE_WISPR_KEY;
      process.env.QA_VOICE_WISPR_KEY = "test-key";
      try {
        const backend = new WisprFlowBackend();
        expect(await backend.isAvailable()).toBe(true);
      } finally {
        if (saved) process.env.QA_VOICE_WISPR_KEY = saved;
        else delete process.env.QA_VOICE_WISPR_KEY;
      }
    });

    it("isAvailable returns false when WISPR_KEY is not set", async () => {
      const saved = process.env.QA_VOICE_WISPR_KEY;
      delete process.env.QA_VOICE_WISPR_KEY;
      try {
        const backend = new WisprFlowBackend();
        expect(await backend.isAvailable()).toBe(false);
      } finally {
        if (saved) process.env.QA_VOICE_WISPR_KEY = saved;
      }
    });

    it("transcribe throws when WISPR_KEY is not set", async () => {
      const saved = process.env.QA_VOICE_WISPR_KEY;
      delete process.env.QA_VOICE_WISPR_KEY;
      try {
        const backend = new WisprFlowBackend();
        await expect(backend.transcribe("/tmp/test.wav")).rejects.toThrow(
          "QA_VOICE_WISPR_KEY",
        );
      } finally {
        if (saved) process.env.QA_VOICE_WISPR_KEY = saved;
      }
    });
  });

  describe("WhisperServerBackend", () => {
    it("has correct name", () => {
      const backend = new WhisperServerBackend();
      expect(backend.name).toBe("whisper-server");
    });

    it("transcribes an existing WAV file through the resident server", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-backend-test.wav";
      await Bun.write(wavPath, new Uint8Array([1, 2, 3, 4]));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (wavData) => {
          expect(Array.from(wavData)).toEqual([1, 2, 3, 4]);
          return "resident text";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("resident text");
      expect(result.backend).toBe("whisper-server");
      expect(result.durationMs).toBeGreaterThanOrEqual(0);
    });

    it("verifies long recordings with a tail decode and merges recovered final words", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-verify-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      const requestSizes: number[] = [];
      const prompts: Array<string | undefined> = [];
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (wavData, options) => {
          requestSizes.push(wavData.byteLength);
          prompts.push(options?.prompt);
          return requestSizes.length === 1
            ? "Let's plan the backfill migration"
            : "backfill migration. And lastly, how long do you think it'll take to do the backfill? Okay.";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(requestSizes).toHaveLength(2);
      expect(requestSizes[1]).toBeLessThan(requestSizes[0]);
      expect(prompts[1]).toContain("Let's plan the backfill migration");
      expect(result.text).toBe(
        "Let's plan the backfill migration. And lastly, how long do you think it'll take to do the backfill?",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("keeps full-window text when tail verification has no overlap", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-no-overlap-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, _options) =>
          _options?.prompt
            ? "unrelated prompt-biased hallucination"
            : "the original complete transcript",
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("the original complete transcript");
      expect(result.backend).toBe("whisper-server");
    });

    it("keeps full-window text when tail verification only overlaps one word", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-one-word-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "we should keep the"
            : "the unrelated hallucinated ending";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("we should keep the");
      expect(result.backend).toBe("whisper-server");
    });

    it("rejects prompted tail verification when it replays an earlier phrase instead of extending the transcript", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-replay-test.wav";
      await Bun.write(wavPath, makePcm16Wav(71));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "use the collab file smart with monitors, because I don't want to leave anything for Anthropic, I mean I don't"
            : "I don't want to leave anything for Anthropic, I don't want to leave anything for Anthropic";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "use the collab file smart with monitors, because I don't want to leave anything for Anthropic, I mean I don't",
      );
      expect(result.backend).toBe("whisper-server");
    });

    it("preserves a real tail extension that intentionally repeats an earlier phrase", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-repeat-extension-test.wav";
      await Bun.write(wavPath, makePcm16Wav(71));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "intro alpha beta gamma delta prior thought and then alpha beta"
            : "alpha beta gamma delta new words";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "intro alpha beta gamma delta prior thought and then alpha beta gamma delta new words",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("preserves a one-word tail extension after an intentionally repeated phrase", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-tail-one-word-extension-test.wav";
      await Bun.write(wavPath, makePcm16Wav(71));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "intro alpha beta gamma delta prior thought and then alpha beta"
            : "alpha beta gamma delta finale";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "intro alpha beta gamma delta prior thought and then alpha beta gamma delta finale",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("repairs a leading punctuation-only resident decode when retry preserves the start", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-leading-punctuation-test.wav";
      await Bun.write(wavPath, makePcm16Wav(8));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? ", the cmux thing is another skill"
            : "I mean, the cmux thing is another skill";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("I mean, the cmux thing is another skill");
      expect(result.backend).toBe("whisper-server+head");
    });

    it("keeps leading punctuation retry text when the retry does not preserve the start", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-leading-punctuation-no-overlap-test.wav";
      await Bun.write(wavPath, makePcm16Wav(8));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? ", the cmux thing is another skill"
            : "unrelated retry hallucination";
        },
        fallbackBackend: {
          name: "whisper-cpp",
          isAvailable: async () => true,
          transcribe: async () => ({
            text: "also unrelated fallback text",
            backend: "whisper-cpp",
            durationMs: 1,
          }),
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(", the cmux thing is another skill");
      expect(result.backend).toBe("whisper-server");
    });

    it("falls back to whisper-cli when resident head retry keeps leading punctuation", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-leading-punctuation-cli-fallback-test.wav";
      await Bun.write(wavPath, makePcm16Wav(8));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () =>
          ", it's still a little ambiguous, but it is much",
        fallbackBackend: {
          name: "whisper-cpp",
          isAvailable: async () => true,
          transcribe: async () => ({
            text: "I mean, it's still a little ambiguous, but it is much",
            backend: "whisper-cpp",
            durationMs: 1,
          }),
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "I mean, it's still a little ambiguous, but it is much",
      );
      expect(result.backend).toBe("whisper-server+head-cli");
    });

    it("trims a short echoed phrase from the end of medium resident decodes", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-echo-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) =>
          options?.prompt
            ? "unrelated tail text"
            : "what we were supposed to. For fuck's sake, this is getting sickening. For fuck's sake.",
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "what we were supposed to. For fuck's sake, this is getting sickening.",
      );
      expect(result.backend).toBe("whisper-server+clean");
    });

    it("repairs a compressed final sentence when prompted tail decode has no overlap", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-tail-compressed-sentence-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) => {
          calls++;
          if (calls === 1) {
            return "Are these two separate or parallel tracks or are they sequenced? I'm confused about those tracks. Tracks.";
          }
          if (options?.prompt) {
            return "I like that Comfy UI feeds both tracks.";
          }
          return "or are they like sequenced? I'm confused about those tracks. I like that Comfy UI feeds both tracks.";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(3);
      expect(result.text).toBe(
        "Are these two separate or parallel tracks or are they sequenced? I'm confused about those tracks. I like that Comfy UI feeds both tracks.",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("repairs a prompted tail after dropping a repeated non-short orphan", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-tail-prompted-orphan-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "I'm confused about those tracks. Tracks."
            : "I'm confused about those tracks. I like that Comfy UI feeds both tracks.";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(2);
      expect(result.text).toBe(
        "I'm confused about those tracks. I like that Comfy UI feeds both tracks.",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("verifies medium recordings so live dictation does not lose the final phrase", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-medium-tail-test.wav";
      await Bun.write(wavPath, makePcm16Wav(17));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "can you just do this and then tell me when you have the next goal for the next brain layer codex do you"
            : "and then tell me when you have the next goal for the next brain layer codex do you have the next goal for the next brain layer codex";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(2);
      expect(result.text).toBe(
        "can you just do this and then tell me when you have the next goal for the next brain layer codex do you have the next goal for the next brain layer codex",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("skips unprompted tail retry when prompted tail confirms the current ending", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-confirmed-test.wav";
      await Bun.write(wavPath, makePcm16Wav(17));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) => {
          calls++;
          if (calls === 1) return "we should keep this current ending";
          if (options?.prompt) return "this current ending";
          return "this current ending hallucinated continuation";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(2);
      expect(result.text).toBe("we should keep this current ending");
      expect(result.backend).toBe("whisper-server");
    });

    it("still retries unprompted tail when the confirmed ending is a dangling cue", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-dangling-confirmed-tail-test.wav";
      await Bun.write(wavPath, makePcm16Wav(17));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) => {
          calls++;
          if (calls === 1) return "we should talk about it do you";
          if (options?.prompt) return "talk about it do you";
          return "talk about it do you want the next goal";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(3);
      expect(result.text).toBe(
        "we should talk about it do you want the next goal",
      );
      expect(result.backend).toBe("whisper-server+tail");
    });

    it("refuses to drop a repeated short common word as a tail orphan", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-short-orphan-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "I can do it. It."
            : "I can do it. Then it should continue.";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("I can do it. It.");
      expect(result.backend).toBe("whisper-server");
    });

    it("preserves adjacent repeated phrases in long resident decodes when they appear only twice", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-adjacent-tail-echo-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) =>
          options?.prompt
            ? "unrelated tail text"
            : "we should keep working through the night please repeat after me please repeat after me",
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "we should keep working through the night please repeat after me please repeat after me",
      );
      expect(result.backend).toBe("whisper-server");
    });

    it("preserves intentional adjacent repeated phrases in short resident decodes", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-short-intentional-repeat-test.wav";
      await Bun.write(wavPath, makePcm16Wav(8));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () =>
          "please repeat after me please repeat after me",
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "please repeat after me please repeat after me",
      );
      expect(result.backend).toBe("whisper-server");
    });

    it("preserves adjacent repeated phrases in medium resident decodes", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-medium-intentional-repeat-test.wav";
      await Bun.write(wavPath, makePcm16Wav(17));
      const repeated = "please repeat after me";
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) =>
          options?.prompt
            ? "repeat after me"
            : `${repeated} ${repeated} ${repeated}`,
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(`${repeated} ${repeated} ${repeated}`);
      expect(result.backend).toBe("whisper-server");
    });

    it("still trims separated echoed phrases in medium resident decodes", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-medium-separated-echo-test.wav";
      await Bun.write(wavPath, makePcm16Wav(17));
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) =>
          options?.prompt
            ? "unrelated tail text"
            : "what we were supposed to. For fuck's sake, this is getting sickening. For fuck's sake.",
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "what we were supposed to. For fuck's sake, this is getting sickening.",
      );
      expect(result.backend).toBe("whisper-server+clean");
    });

    it("trims repeated adjacent echoed phrases until only the first dictated phrase remains", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-multi-adjacent-tail-echo-test.wav";
      await Bun.write(wavPath, makePcm16Wav(71));
      const repeated = "I don't want to leave anything for Anthropic";
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) =>
          options?.prompt
            ? "unrelated tail text"
            : `we should keep working through the night, ${repeated}, ${repeated}, ${repeated}`,
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "we should keep working through the night, I don't want to leave anything for Anthropic,",
      );
      expect(result.backend).toBe("whisper-server+clean");
    });

    it("preserves real tail filler when it was already in the full-window decode", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-tail-real-filler-test.wav";
      await Bun.write(wavPath, makePcm16Wav(31));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return calls === 1
            ? "we are shipping? okay"
            : "are shipping? okay";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("we are shipping? okay");
      expect(result.backend).toBe("whisper-server");
    });

    it("does not strip dictated filler from chunked long recordings", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-chunked-filler-test.wav";
      await Bun.write(wavPath, makePcm16Wav(95));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          if (calls === 1) return "first chunk asks are we shipping";
          if (calls === 2) return "are we shipping? okay";
          return "okay and done";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("first chunk asks are we shipping? okay and done");
      expect(result.backend).toBe("whisper-server+chunks");
    });

    it("repairs leading punctuation in chunked long recordings with a clean head decode", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-chunked-leading-punctuation-test.wav";
      await Bun.write(wavPath, makePcm16Wav(95));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          if (calls === 1) return ", what? Slide six. I don't think she said";
          if (calls === 2) return "she said anything was too long";
          if (calls === 3) return "too long and we should fix the handoff";
          if (calls === 4) return "the handoff before sending it";
          return "uh what slide six i don't think she said";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "uh what? Slide six. I don't think she said anything was too long and we should fix the handoff before sending it",
      );
      expect(result.backend).toBe("whisper-server+chunks+head");
    });

    it("falls back from chunked mode when a chunk decodes empty", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-chunk-empty-test.wav";
      await Bun.write(wavPath, makePcm16Wav(95));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          if (calls === 1) return "first chunk";
          if (calls === 2) return "";
          return "full-window fallback text";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("full-window fallback text");
      expect(result.backend).toBe("whisper-server");
    });

    it("uses overlapping chunk decode for very long recordings instead of a single compressed window", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-chunked-test.wav";
      await Bun.write(wavPath, makePcm16Wav(95));
      const requestSizes: number[] = [];
      const prompts: Array<string | undefined> = [];
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (wavData, options) => {
          requestSizes.push(wavData.byteLength);
          prompts.push(options?.prompt);
          if (requestSizes.length === 1) return "first chunk has setup";
          if (requestSizes.length === 2) return "setup and middle chunk continues";
          return "chunk continues with final decision";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(requestSizes).toHaveLength(4);
      expect(requestSizes.every((size) => size < 95 * 16000 * 2)).toBe(true);
      expect(prompts[0]).toBeUndefined();
      expect(prompts[1]).toContain("first chunk has setup");
      expect(prompts[2]).toContain("setup and middle chunk continues");
      expect(result.text).toBe(
        "first chunk has setup and middle chunk continues with final decision",
      );
      expect(result.backend).toBe("whisper-server+chunks");
    });

    it("trims repeated tail loops after chunked long recordings are merged", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-chunked-tail-loop-test.wav";
      await Bun.write(wavPath, makePcm16Wav(95));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          if (calls === 1) return "first chunk";
          if (calls === 2) return "chunk middle";
          if (calls === 3) return "middle near final";
          return "near final leave for anthropic leave for anthropic leave for anthropic";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe(
        "first chunk middle near final leave for anthropic",
      );
      expect(result.backend).toBe("whisper-server+chunks+clean");
    });

    it("ignores non-overlapping hallucinations from a very short final chunk", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-chunked-short-final-hallucination-test.wav";
      await Bun.write(wavPath, makePcm16Wav(108));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          if (calls === 1) return "intro setup";
          if (calls === 2) return "setup middle";
          if (calls === 3) return "middle plan";
          if (calls === 4) return "plan look at ponytail skill";
          if (calls === 5)
            return "so I am going to put it in the middle of the ponytail";
          return "thank you";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(6);
      expect(result.text).toBe("intro setup middle plan look at ponytail skill");
      expect(result.backend).toBe("whisper-server+chunks");
    });

    it("keeps non-overlapping speech from a very short final chunk when unprompted decode agrees", async () => {
      const wavPath =
        "/tmp/voicelayer-whisper-server-chunked-short-final-real-tail-test.wav";
      await Bun.write(wavPath, makePcm16Wav(108));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          if (calls === 1) return "intro setup";
          if (calls === 2) return "setup middle";
          if (calls === 3) return "middle plan";
          if (calls === 4) return "plan look at ponytail skill";
          return "please restart voicebar now";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(6);
      expect(result.text).toBe(
        "intro setup middle plan look at ponytail skill please restart voicebar now",
      );
      expect(result.backend).toBe("whisper-server+chunks");
    });

    it("keeps short resident recordings on a single decode", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-short-test.wav";
      await Bun.write(wavPath, makePcm16Wav(8));
      let calls = 0;
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          calls++;
          return "short text";
        },
      });

      const result = await backend.transcribe(wavPath);

      expect(calls).toBe(1);
      expect(result.text).toBe("short text");
      expect(result.backend).toBe("whisper-server");
    });

    it("passes explicit language and prompt context to the resident server", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-language-test.wav";
      await Bun.write(wavPath, new Uint8Array([1, 2, 3, 4]));
      const savedLang = process.env.QA_VOICE_WHISPER_LANG;
      process.env.QA_VOICE_WHISPER_LANG = "hebrew";
      let capturedOptions: { language?: string; prompt?: string } | undefined;

      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wavData, options) => {
          capturedOptions = options;
          return "resident text";
        },
      });

      try {
        const result = await backend.transcribe(wavPath, {
          promptOverride: "previous chunk context",
        });

        expect(result.text).toBe("resident text");
        expect(capturedOptions?.language).toBe("he");
        expect(capturedOptions?.prompt).toContain("פוש ברנץ");
        expect(capturedOptions?.prompt).toContain("previous chunk context");
      } finally {
        if (savedLang) process.env.QA_VOICE_WHISPER_LANG = savedLang;
        else delete process.env.QA_VOICE_WHISPER_LANG;
      }
    });

    it("falls back to whisper-cli when resident inference fails", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-fallback-test.wav";
      await Bun.write(wavPath, new Uint8Array([5, 6]));
      const fallback = {
        name: "whisper.cpp",
        isAvailable: async () => true,
        transcribe: async (_audioPath: string) => ({
          text: "fallback text",
          backend: "whisper.cpp",
          durationMs: 12,
        }),
      };
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          throw new Error("server crashed");
        },
        fallbackBackend: fallback,
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("fallback text");
      expect(result.backend).toBe("whisper-server->whisper.cpp");
    });

    it("falls back to whisper-cli when resident inference returns empty text", async () => {
      const wavPath = "/tmp/voicelayer-whisper-server-empty-fallback-test.wav";
      await Bun.write(wavPath, new Uint8Array([7, 8]));
      const fallback = {
        name: "whisper.cpp",
        isAvailable: async () => true,
        transcribe: async (_audioPath: string) => ({
          text: "fallback from empty",
          backend: "whisper.cpp",
          durationMs: 15,
        }),
      };
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => "",
        fallbackBackend: fallback,
      });

      const result = await backend.transcribe(wavPath);

      expect(result.text).toBe("fallback from empty");
      expect(result.backend).toBe("whisper-server->whisper.cpp");
    });
  });

  describe("getBackend", () => {
    it("caches the backend on repeated calls", async () => {
      try {
        const b1 = await getBackend();
        const b2 = await getBackend();
        expect(b1).toBe(b2); // Same instance
      } catch {
        // If no backend is available on this machine, that's OK for CI
      }
    });

    it("throws clear error when wispr explicitly requested but key missing", async () => {
      const savedBackend = process.env.QA_VOICE_STT_BACKEND;
      const savedKey = process.env.QA_VOICE_WISPR_KEY;
      process.env.QA_VOICE_STT_BACKEND = "wispr";
      delete process.env.QA_VOICE_WISPR_KEY;
      try {
        await expect(getBackend()).rejects.toThrow("QA_VOICE_WISPR_KEY");
      } finally {
        if (savedBackend) process.env.QA_VOICE_STT_BACKEND = savedBackend;
        else delete process.env.QA_VOICE_STT_BACKEND;
        if (savedKey) process.env.QA_VOICE_WISPR_KEY = savedKey;
      }
    });

    it("handles whisper explicitly requested with nonexistent model", async () => {
      const savedBackend = process.env.QA_VOICE_STT_BACKEND;
      const savedModel = process.env.QA_VOICE_WHISPER_MODEL;
      process.env.QA_VOICE_STT_BACKEND = "whisper";
      process.env.QA_VOICE_WHISPER_MODEL = "/nonexistent/model.bin";
      try {
        // May throw if whisper-cpp binary isn't installed,
        // or succeed if binary exists and finds a different model
        const backend = await getBackend();
        expect(backend.name).toBe("whisper.cpp");
      } catch (err: any) {
        // Expected when whisper-cpp is not available
        expect(err.message).toContain("whisper");
      } finally {
        if (savedBackend) process.env.QA_VOICE_STT_BACKEND = savedBackend;
        else delete process.env.QA_VOICE_STT_BACKEND;
        if (savedModel) process.env.QA_VOICE_WHISPER_MODEL = savedModel;
        else delete process.env.QA_VOICE_WHISPER_MODEL;
      }
    });

    it("respects QA_VOICE_STT_BACKEND=auto", async () => {
      const saved = process.env.QA_VOICE_STT_BACKEND;
      process.env.QA_VOICE_STT_BACKEND = "auto";
      try {
        // Should not throw — picks whatever is available
        const backend = await getBackend();
        expect(["whisper-server", "whisper.cpp", "wispr-flow"]).toContain(
          backend.name,
        );
      } catch {
        // If nothing is available, that's OK for CI
      } finally {
        if (saved) process.env.QA_VOICE_STT_BACKEND = saved;
        else delete process.env.QA_VOICE_STT_BACKEND;
      }
    });

    it("supports explicit QA_VOICE_STT_BACKEND=whisper-server", async () => {
      const saved = process.env.QA_VOICE_STT_BACKEND;
      process.env.QA_VOICE_STT_BACKEND = "whisper-server";
      try {
        const backend = await getBackend();
        expect(backend.name).toBe("whisper-server");
      } catch (err: any) {
        expect(err.message).toContain("whisper-server");
      } finally {
        if (saved) process.env.QA_VOICE_STT_BACKEND = saved;
        else delete process.env.QA_VOICE_STT_BACKEND;
      }
    });
  });

  describe("Phase 7 chunk assembly", () => {
    it("buildChunkPrompt carries recent tokens for continuity", () => {
      expect(
        buildChunkPrompt(
          "console log the result in TypeScript and then switch to עברית בבקשה",
          6,
        ),
      ).toBe("TypeScript and then switch to עברית בבקשה");
    });

    it("deduplicates overlap text at the application layer", () => {
      expect(
        mergeChunkTranscripts([
          "hello world from voice layer",
          "world from voice layer and beyond",
        ]),
      ).toBe("hello world from voice layer and beyond");
    });

    it("deduplicates mixed Hebrew-English overlap on the same pipeline", () => {
      expect(
        mergeChunkTranscripts([
          "אני בודק TypeScript היום",
          "TypeScript היום עם עוד טקסט",
        ]),
      ).toBe("אני בודק TypeScript היום עם עוד טקסט");
    });

    it("deduplicates chunk overlap when punctuation differs at the boundary", () => {
      expect(
        mergeChunkTranscripts(["hello world,", "world and then continue"]),
      ).toBe("hello world, and then continue");
    });

    it("deduplicates quoted chunk overlap when quote spacing differs at the boundary", () => {
      expect(
        mergeChunkTranscripts([
          'Would"distill whisper"work if it is English only',
          '"distill whisper" work if it is English only, though',
        ]),
      ).toBe('Would "distill whisper" work if it is English only, though');
    });

    it("does not collapse distinct operator-only tokens at chunk boundaries", () => {
      // Regression: `normalizeChunkWordForOverlap` previously stripped all
      // non-alphanumeric chars, so punctuation-only tokens like `==` and
      // `!=` both became `""` and falsely overlapped, dropping the second
      // chunk's operator in code dictation.
      expect(mergeChunkTranscripts(["if value ==", "!= null"])).toBe(
        "if value == != null",
      );
      expect(
        mergeChunkTranscripts(["totalCount +", "- delta then continue"]),
      ).toBe("totalCount + - delta then continue");
    });

    it("still deduplicates when identical operator-only tokens overlap", () => {
      // Sanity check: same operator on both sides should still merge as a
      // single overlap.
      expect(mergeChunkTranscripts(["if value ==", "== check"])).toBe(
        "if value == check",
      );
    });

    it("preserves symbol-bearing code tokens during overlap (regression: C++ / C#)", () => {
      // Blanket non-alphanumeric stripping collapsed `C++` and `C#` (both ->
      // `c`), falsely overlapping and dropping the second chunk's token.
      // Strip only natural-language sentence punctuation from token edges
      // so trailing operator/symbol chars (++, #, --, .) survive as
      // identifying suffixes.
      expect(mergeChunkTranscripts(["write in C++", "C# is different"])).toBe(
        "write in C++ C# is different",
      );
      expect(mergeChunkTranscripts(["counter is i++", "x-- elsewhere"])).toBe(
        "counter is i++ x-- elsewhere",
      );
    });

    it("still deduplicates trailing sentence punctuation (regression guard)", () => {
      // Comma-tagged token should still match the bare word so natural-
      // language chunk overlap still de-dupes after the operator-aware fix.
      expect(
        mergeChunkTranscripts(["hello world,", "world and then continue"]),
      ).toBe("hello world, and then continue");
    });

    it("preserves leading `!` operator while still stripping sentence-ending `!`", () => {
      // Regression (Cursor Bugbot Low on 94d85d8): `!` was in the leading
      // strip set, so `!flag` collapsed to `flag` and `!=` collapsed to `=`.
      // That made distinct operator tokens at chunk boundaries falsely
      // overlap. Strip `!` only from the trailing edge (sentence-ending
      // exclamation) so leading-`!` operator tokens keep their identity.
      expect(mergeChunkTranscripts(["set flag", "!flag elsewhere"])).toBe(
        "set flag !flag elsewhere",
      );
      expect(mergeChunkTranscripts(["if value =", "!= null"])).toBe(
        "if value = != null",
      );
      // Sentence-ending `!` still strips so natural-language overlap works.
      expect(mergeChunkTranscripts(["hello world!", "world is great"])).toBe(
        "hello world! is great",
      );
    });

    it("deduplicates tail verification overlap after a short filler prefix", () => {
      expect(
        mergeChunkTranscripts([
          "I wonder if it should also test different type of agents. Or like with the routing agents, agents routing skill,?",
          "Yeah, I wonder if it should also test different type of agents. Or like with the routing agents, agents routing skill, you know?",
        ]),
      ).toBe(
        "I wonder if it should also test different type of agents. Or like with the routing agents, agents routing skill, you know?",
      );
    });

    it("preserves dictated filler after a question in generic chunk merging", () => {
      expect(mergeChunkTranscripts(["Are we shipping? okay"])).toBe(
        "Are we shipping? okay",
      );
    });
  });

  describe("buildWhisperServerOptions", () => {
    let savedLang: string | undefined;

    beforeEach(() => {
      savedLang = process.env.QA_VOICE_WHISPER_LANG;
    });

    afterEach(() => {
      if (savedLang === undefined) {
        delete process.env.QA_VOICE_WHISPER_LANG;
      } else {
        process.env.QA_VOICE_WHISPER_LANG = savedLang;
      }
    });

    it("includes promptOverride even when language mode is auto (default)", () => {
      // Regression: previously the auto-mode early-return dropped
      // options.promptOverride, breaking transcribeChunkSequence's
      // previous-chunk continuity prompt for chunked dictation in the
      // default (unset/auto) configuration.
      delete process.env.QA_VOICE_WHISPER_LANG;
      const result = buildWhisperServerOptions({
        promptOverride: "previous chunk transcript here",
      });
      expect(result).toBeDefined();
      expect(result?.language).toBeUndefined();
      expect(result?.prompt).toContain("previous chunk transcript here");
    });

    it("includes language and prompt when an explicit language is configured", () => {
      process.env.QA_VOICE_WHISPER_LANG = "hebrew";
      const result = buildWhisperServerOptions({
        promptOverride: "extra context",
      });
      expect(result?.language).toBe("he");
      expect(result?.prompt).toContain("extra context");
    });

    it("omits prompt in auto mode when no promptOverride is present", () => {
      delete process.env.QA_VOICE_WHISPER_LANG;
      const result = buildWhisperServerOptions();
      // Keep parity with language-config: auto mode avoids prompt priming on
      // one-shot audio so borderline silence/noise cannot decode into
      // prompt-biased dev phrases. promptOverride is still forwarded by the
      // previous test for chunk-continuity.
      expect(result).toBeUndefined();
    });
  });
});
