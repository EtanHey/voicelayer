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
