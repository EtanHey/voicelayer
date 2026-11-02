import { test, expect, afterEach } from "bun:test";
import { mkdirSync, writeFileSync, rmSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { readRecognizerAssets, PARAKEET_FILES } from "../recognizer-assets";
const root = testTmp("asset-status");
afterEach(() => rmSync(root, { recursive: true, force: true }));
test("absent and partial Parakeet assets are false; complete never-loaded assets are present", () => {
  mkdirSync(root, { recursive: true });
  const env = { VOICELAYER_PARAKEET_MODEL: root, VOICELAYER_PARAKEET_PYTHON: join(root, "python") };
  expect(readRecognizerAssets("parakeet", env).assets_present).toBe(false);
  for (const name of PARAKEET_FILES) writeFileSync(join(root, name), "fixture");
  expect(readRecognizerAssets("parakeet", env)).toEqual({ assets_present: false, disk_bytes: 21 });
  writeFileSync(env.VOICELAYER_PARAKEET_PYTHON, "fixture");
  expect(readRecognizerAssets("parakeet", env)).toEqual({ assets_present: true, disk_bytes: 21 });
});
test("Whisper presence and size come only from file metadata", () => {
  mkdirSync(root, { recursive: true }); const path = join(root, "fixture.bin");
  const env = { QA_VOICE_WHISPER_MODEL: path };
  expect(readRecognizerAssets("whisper", env)).toEqual({ assets_present: false, disk_bytes: 0 });
  writeFileSync(path, "fixture");
  expect(readRecognizerAssets("whisper", env)).toEqual({ assets_present: true, disk_bytes: 7 });
});
