import { test, expect } from "bun:test";
import { mkdirSync, writeFileSync, rmSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";

test("missing configured Whisper model never substitutes cached weights", () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const home = testTmp("missing-model-home");
  const cache = join(home, ".cache/whisper");
  mkdirSync(cache, { recursive: true });
  for (const name of ["ggml-base.bin", "ggml-small.bin", "ggml-ivrit-large-v3-turbo.bin"]) {
    writeFileSync(join(cache, name), "other weights");
  }
  try {
    for (const override of ["", join(cache, "explicit-missing.bin")]) {
      const child = Bun.spawnSync([process.execPath, "-e", `
        import { whisperAssetPath, readRecognizerAssets } from './src/recognizer-assets';
        import { resolveWhisperCliModelPath } from './src/stt';
        import { resolveWhisperModelPath } from './src/whisper-server';
        console.log(JSON.stringify([whisperAssetPath(), readRecognizerAssets('whisper'), resolveWhisperCliModelPath(), resolveWhisperModelPath()]));
      `], { env: { ...process.env, HOME: home, QA_VOICE_WHISPER_MODEL: override }, stdout: "pipe", stderr: "pipe" });
      expect(child.exitCode).toBe(0);
      expect(JSON.parse(child.stdout.toString())).toEqual([
        override || join(cache, "ggml-large-v3-turbo.bin"),
        { assets_present: false, disk_bytes: 0 }, null, null,
      ]);
    }
  } finally { rmSync(home, { recursive: true, force: true }); }
});

test("weight identity hashes bytes and invalidates after replacement", async () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const { hashWhisperWeights, executedWhisperHash } = await import("../whisper-model-identity");
  const { createHash } = await import("crypto");
  const path = testTmp("identity.bin");
  try {
    writeFileSync(path, "first weights");
    expect(await hashWhisperWeights(path)).toBe(createHash("sha256").update("first weights").digest("hex"));
    writeFileSync(path, "replacement weights");
    const expected = createHash("sha256").update("replacement weights").digest("hex");
    expect(await hashWhisperWeights(path)).toBe(expected);
    expect(executedWhisperHash(path)).toBe(expected);
  } finally { rmSync(path, { force: true }); }
});

test("missing weights leave availability boolean and auto cloud fallback usable", async () => {
  const { WhisperCppBackend, WhisperServerBackend, getBackend, resetBackendCache } = await import("../stt");
  const { ParakeetBackend } = await import("../parakeet-backend");
  const saved = { ...process.env };
  try {
    process.env.QA_VOICE_WHISPER_MODEL = testTmp("absent-review.bin");
    process.env.QA_VOICE_STT_BACKEND = "auto";
    process.env.QA_VOICE_WISPR_KEY = "fixture-key-never-sent";
    resetBackendCache();
    expect((await getBackend()).name).toBe("wispr-flow");
    expect(await new WhisperCppBackend().isAvailable()).toBe(false);
    expect(await new WhisperServerBackend().isAvailable()).toBe(false);
    expect(await new ParakeetBackend({ isAvailable: () => false, fallbackBackend: new WhisperCppBackend() }).isAvailable()).toBe(false);
  } finally { process.env = saved; resetBackendCache(); }
});

test("selected Parakeet succeeds without Whisper; a true failure preserves archived audio and names missing weights", async () => {
  const { getBackend, resetBackendCache } = await import("../stt");
  const { createWavBuffer, archiveVoiceBarUntranscribedRecording, retranscribeRecordingCapture } = await import("../input");
  const { readFileSync } = await import("fs");
  const { dirname } = await import("path");
  const saved = { ...process.env };
  try {
    process.env.QA_VOICE_WHISPER_MODEL = testTmp("absent-review.bin");
    process.env.QA_VOICE_STT_BACKEND = "parakeet";
    resetBackendCache();
    const backend = await getBackend();
    expect(backend.name).toBe("parakeet-resident");
    const deps = (backend as any).deps;
    let fallbackCalls = 0;
    const originalFallback = deps.fallbackBackend.transcribe.bind(deps.fallbackBackend);
    deps.fallbackBackend.transcribe = (...args: any[]) => { fallbackCalls++; return originalFallback(...args); };
    deps.unload = async () => {};
    deps.transcribe = async () => ({ text: "Keep every word and the final tail.", complete: true,
      input_frames: 16000, covered_frames: 16000, sample_rate: 16000, last_token_end_s: 1, inference_s: .1, language: null });
    const pcm = Buffer.alloc(32000); for (let i = 0; i < pcm.length; i += 2) pcm.writeInt16LE(1000, i);
    const bytes = createWavBuffer(pcm);
    const archive = archiveVoiceBarUntranscribedRecording({ audioBytes: bytes, source: "voicebar", silenceMode: "quick",
      pushToEnd: false, durationMs: 1000, backend: "parakeet-resident", reason: "cancelled" });
    const path = join(archive, "audio.wav");
    const result = await backend.transcribe(path);
    expect(result.backend).toBe("parakeet-resident");
    expect(result.text).toBe("Keep every word and the final tail.");
    expect(fallbackCalls).toBe(0);
    deps.transcribe = async () => { throw new Error("Parakeet really failed"); };
    await expect(retranscribeRecordingCapture(path)).rejects.toThrow(`Whisper model is missing: ${process.env.QA_VOICE_WHISPER_MODEL}`);
    expect(fallbackCalls).toBe(1);
    expect(readFileSync(path)).toEqual(Buffer.from(bytes));
    const metadata = JSON.parse(readFileSync(join(dirname(path), "metadata.json"), "utf8"));
    expect(metadata.not_transcribed_reason).toBe("transcription-failed");
    expect(metadata.not_transcribed_detail).toContain(`Whisper model is missing: ${process.env.QA_VOICE_WHISPER_MODEL}`);
  } finally { process.env = saved; resetBackendCache(); }
});
