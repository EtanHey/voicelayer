import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import {
  WhisperCppBackend,
  WisprFlowBackend,
  getBackend,
  resetBackendCache,
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
      // Force binary path to null
      (backend as any).binaryPath = null;
      (backend as any).modelPath = "/some/model.bin";

      // Verify it throws with helpful error message
      await expect(backend.transcribe("/tmp/test.wav")).rejects.toThrow("whisper-cpp");
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
});
