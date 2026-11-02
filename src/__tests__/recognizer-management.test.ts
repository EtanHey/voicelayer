import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, writeFileSync, rmSync, existsSync, symlinkSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { deleteRecognizer } from "../recognizer-management";
import { PARAKEET_FILES } from "../recognizer-assets";
import { configureRecognizerBusyProbe, noteRecognizerEngine, noteRecognizerEffective, confirmRecognizerCleanup,
  beginRecognizerRequest, finishRecognizerRequest, readRecognizerStatus } from "../recognizer-state";
import { parseCommand } from "../socket-protocol";
const keys = ["VOICELAYER_STATE_DIR", "VOICELAYER_PARAKEET_MODEL", "VOICELAYER_PARAKEET_PYTHON", "QA_VOICE_WHISPER_MODEL", "QA_VOICE_STT_BACKEND"] as const;
let saved: (string | undefined)[];
const root = testTmp("model-management");
beforeEach(() => {
  saved = keys.map(k => process.env[k]); mkdirSync(root, { recursive: true });
  process.env.VOICELAYER_STATE_DIR = root; process.env.VOICELAYER_PARAKEET_MODEL = root;
  process.env.VOICELAYER_PARAKEET_PYTHON = join(root, "python"); process.env.QA_VOICE_WHISPER_MODEL = join(root, "whisper.bin"); delete process.env.QA_VOICE_STT_BACKEND;
  for (const name of [...PARAKEET_FILES, "python", "whisper.bin"]) writeFileSync(join(root, name), "fixture");
  configureRecognizerBusyProbe(() => null);
  for (const engine of ["whisper", "parakeet"] as const) { confirmRecognizerCleanup(engine); noteRecognizerEngine(engine, { phase: "sleeping", error: null }); }
  noteRecognizerEffective(null);
});
afterEach(() => { keys.forEach((k,i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; }); configureRecognizerBusyProbe(() => null); rmSync(root, { recursive: true, force: true }); });
test("delete command accepts only explicit engine names", () => {
  expect(parseCommand('{"cmd":"delete_recognizer","engine":"parakeet","id":"x"}')).toEqual({ cmd: "delete_recognizer", engine: "parakeet", id: "x" });
  expect(parseCommand('{"cmd":"delete_recognizer","engine":"auto"}')).toBeNull();
});
test("loaded model cannot be deleted", () => {
  noteRecognizerEngine("parakeet", { phase: "ready" });
  expect(deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "recognizer-loaded" });
  expect(existsSync(join(root, "model.safetensors"))).toBe(true);
});
test("last installed model cannot be deleted", () => {
  rmSync(join(root, "whisper.bin"));
  expect(deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "last-installed-recognizer" });
});
test("delete changes selected engine first and preserves unrelated files and runtime", () => {
  expect(deleteRecognizer("whisper").outcome).toBe("accept");
  expect(readRecognizerStatus().desired).toBe("parakeet");
  expect(readRecognizerStatus().engines.whisper.assets_present).toBe(false);
  expect(existsSync(join(root, "python"))).toBe(true);
  expect(existsSync(join(root, "model.safetensors"))).toBe(true);
});
for (const reason of ["capture-active", "voice-busy"]) test(`delete refuses ${reason}`, () => {
  configureRecognizerBusyProbe(() => reason); expect(deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason });
});
test("active transcription refuses delete", () => {
  beginRecognizerRequest(); try { expect(deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "request-active" }); }
  finally { finishRecognizerRequest(); }
});
test("delete refuses a model symlink into an external cache", () => {
  rmSync(join(root, "config.json")); symlinkSync(join(root, "python"), join(root, "config.json"));
  expect(deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "external-model-link" });
  expect(existsSync(join(root, "python"))).toBe(true);
});
