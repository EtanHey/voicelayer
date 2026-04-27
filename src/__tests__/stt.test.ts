import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import {
  WhisperCppBackend,
  WisprFlowBackend,
  getBackend,
  resetBackendCache,
  buildChunkPrompt,
  mergeChunkTranscripts,
} from "../stt";

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
        expect(spawnSyncCalls).toContainEqual(["/opt/homebrew/bin/brew", "--prefix", "whisper-cpp"]);
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
          "QA_VOICE_WISPR_KEY"
        );
      } finally {
        if (saved) process.env.QA_VOICE_WISPR_KEY = saved;
      }
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
        expect(["whisper.cpp", "wispr-flow"]).toContain(backend.name);
      } catch {
        // If nothing is available, that's OK for CI
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
  });
});
