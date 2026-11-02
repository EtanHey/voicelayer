import { test, expect, beforeEach, afterEach, spyOn } from "bun:test";
import { mkdirSync, writeFileSync, rmSync, existsSync, symlinkSync } from "fs";
import { join } from "path";
import { testTmp } from "./setup/test-tmp";
import { deleteRecognizer } from "../recognizer-management";
import { PARAKEET_FILES } from "../recognizer-assets";
import { configureRecognizerBusyProbe, noteRecognizerEngine, noteRecognizerEffective, confirmRecognizerCleanup,
  beginRecognizerRequest, finishRecognizerRequest, readRecognizerStatus, recognizerRecovery, setRecognizerRecovery } from "../recognizer-state";
import { parseCommand } from "../socket-protocol";
import { parakeetServer } from "../parakeet-server";
import { handleSocketCommand } from "../socket-handlers";
const keys = ["VOICELAYER_STATE_DIR", "VOICELAYER_PARAKEET_MODEL", "VOICELAYER_PARAKEET_PYTHON", "QA_VOICE_WHISPER_MODEL", "QA_VOICE_STT_BACKEND"] as const;
let saved: (string | undefined)[];
let prior: ReturnType<typeof readRecognizerStatus>, recovery: ReturnType<typeof recognizerRecovery>;
const root = testTmp("model-management");
beforeEach(() => {
  prior = readRecognizerStatus(); recovery = recognizerRecovery();
  saved = keys.map(k => process.env[k]); mkdirSync(root, { recursive: true });
  process.env.VOICELAYER_STATE_DIR = root; process.env.VOICELAYER_PARAKEET_MODEL = root;
  process.env.VOICELAYER_PARAKEET_PYTHON = join(root, "python"); process.env.QA_VOICE_WHISPER_MODEL = join(root, "whisper.bin"); delete process.env.QA_VOICE_STT_BACKEND;
  for (const name of [...PARAKEET_FILES, "python", "whisper.bin"]) writeFileSync(join(root, name), "fixture");
  configureRecognizerBusyProbe(() => null);
  for (const engine of ["whisper", "parakeet"] as const) { confirmRecognizerCleanup(engine); noteRecognizerEngine(engine, { phase: "sleeping", error: null }); }
  noteRecognizerEffective(null);
});
afterEach(() => { keys.forEach((k,i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; }); configureRecognizerBusyProbe(() => null);
  for (const engine of ["whisper", "parakeet"] as const) {
    confirmRecognizerCleanup(engine);
    const { phase, available, error } = prior.engines[engine]; noteRecognizerEngine(engine, { phase, available, error });
  }
  setRecognizerRecovery(recovery); noteRecognizerEffective(prior.effective, prior.fallback_reason);
  rmSync(root, { recursive: true, force: true });
});
test("delete command accepts only explicit engine names", () => {
  expect(parseCommand('{"cmd":"delete_recognizer","engine":"parakeet","id":"x"}')).toEqual({ cmd: "delete_recognizer", engine: "parakeet", id: "x" });
  expect(parseCommand('{"cmd":"delete_recognizer","engine":"auto"}')).toBeNull();
});
for (const engine of ["parakeet", "whisper"] as const) test(`loaded ${engine} is stopped before any weights are deleted`, async () => {
  noteRecognizerEngine(engine, { phase: "ready" }); noteRecognizerEffective(engine);
  const held = Promise.withResolvers<void>(), entered = Promise.withResolvers<void>();
  const paths = engine === "parakeet" ? PARAKEET_FILES.map(name => join(root, name)) : [join(root, "whisper.bin")];
  const deleting = deleteRecognizer(engine, async actual => {
    expect(actual).toBe(engine); entered.resolve(); await held.promise;
  });
  await entered.promise;
  expect(paths.every(existsSync)).toBe(true);
  expect(() => beginRecognizerRequest()).toThrow("transition active");
  held.resolve();
  expect(await deleting).toMatchObject({ outcome: "accept" });
  expect(paths.some(existsSync)).toBe(false);
  expect(readRecognizerStatus().effective).toBeNull();
});
test("unconfirmed process exit leaves weights and selection intact", async () => {
  const before = readRecognizerStatus().desired;
  expect(await deleteRecognizer("whisper", async () => { throw new Error("cleanup-unconfirmed"); })).toMatchObject({ outcome: "reject", reason: "cleanup-unconfirmed" });
  expect(existsSync(join(root, "whisper.bin"))).toBe(true);
  expect(readRecognizerStatus().desired).toBe(before);
});
test("capture beginning during unload keeps the files", async () => {
  expect(await deleteRecognizer("whisper", async () => { configureRecognizerBusyProbe(() => "capture-active"); })).toMatchObject({ outcome: "reject", reason: "capture-active" });
  expect(existsSync(join(root, "whisper.bin"))).toBe(true);
});
test("Delete socket ACK waits for the actual provider unload", async () => {
  noteRecognizerEngine("parakeet", { phase: "ready" });
  const held = Promise.withResolvers<void>(), entered = Promise.withResolvers<void>();
  const unload = spyOn(parakeetServer, "unload").mockImplementation(async () => { entered.resolve(); await held.promise; });
  try {
    const pending = handleSocketCommand({ cmd: "delete_recognizer", engine: "parakeet", id: "loaded-delete" });
    await entered.promise; expect(existsSync(join(root, "model.safetensors"))).toBe(true);
    held.resolve();
    expect(await pending).toMatchObject({ type: "ack", id: "loaded-delete", outcome: "accept" });
    expect(existsSync(join(root, "model.safetensors"))).toBe(false);
    expect(unload).toHaveBeenCalledTimes(1);
  } finally { held.resolve(); unload.mockRestore(); }
});
test("unconfirmed owned unload blocks requests and preserves all weights", async () => {
  const unload = spyOn(parakeetServer, "unload").mockRejectedValue(new Error("child-exit-unconfirmed"));
  try {
    expect(await deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "cleanup-unconfirmed" });
    expect(() => beginRecognizerRequest()).toThrow("cleanup unconfirmed");
    expect(PARAKEET_FILES.every(name => existsSync(join(root, name)))).toBe(true);
  } finally { unload.mockRestore(); }
});
test("delete rechecks external links after awaiting unload", async () => {
  const shared = join(root, "shared.bin"); writeFileSync(shared, "keep");
  expect(await deleteRecognizer("whisper", async () => {
    rmSync(join(root, "whisper.bin")); symlinkSync(shared, join(root, "whisper.bin"));
  })).toMatchObject({ outcome: "reject", reason: "external-model-link" });
  expect(existsSync(shared)).toBe(true);
});
test("last installed model cannot be deleted", async () => {
  rmSync(join(root, "whisper.bin"));
  expect(await deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "last-installed-recognizer" });
});
test("delete changes selected engine first and preserves unrelated files and runtime", async () => {
  expect((await deleteRecognizer("whisper", async () => {})).outcome).toBe("accept");
  expect(readRecognizerStatus().desired).toBe("parakeet");
  expect(readRecognizerStatus().engines.parakeet.phase).toBe("sleeping"); // Loads on next dictation.
  expect(readRecognizerStatus().engines.whisper.assets_present).toBe(false);
  expect(existsSync(join(root, "python"))).toBe(true);
  expect(existsSync(join(root, "model.safetensors"))).toBe(true);
});
for (const reason of ["capture-active", "voice-busy"]) test(`delete refuses ${reason}`, async () => {
  configureRecognizerBusyProbe(() => reason); expect(await deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason });
});
test("active transcription refuses delete", async () => {
  beginRecognizerRequest(); try { expect(await deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "request-active" }); }
  finally { finishRecognizerRequest(); }
});
test("delete refuses a model symlink into an external cache", async () => {
  rmSync(join(root, "config.json")); symlinkSync(join(root, "python"), join(root, "config.json"));
  expect(await deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "external-model-link" });
  expect(existsSync(join(root, "python"))).toBe(true);
});

test("delete refuses a symlinked model DIRECTORY and leaves the shared target untouched", async () => {
  const shared = join(root, "shared-cache"), linked = join(root, "linked-model");
  mkdirSync(shared, { recursive: true });
  for (const name of PARAKEET_FILES) writeFileSync(join(shared, name), "shared");
  symlinkSync(shared, linked);
  process.env.VOICELAYER_PARAKEET_MODEL = linked;
  expect(await deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "external-model-link" });
  for (const name of PARAKEET_FILES) expect(existsSync(join(shared, name))).toBe(true);
});

test("delete refuses a symlinked Whisper model directory", async () => {
  const shared = join(root, "shared-whisper"), linked = join(root, "linked-whisper");
  mkdirSync(shared, { recursive: true }); writeFileSync(join(shared, "ggml.bin"), "shared");
  symlinkSync(shared, linked);
  process.env.QA_VOICE_WHISPER_MODEL = join(linked, "ggml.bin");
  expect(await deleteRecognizer("whisper")).toMatchObject({ outcome: "reject", reason: "external-model-link" });
  expect(existsSync(join(shared, "ggml.bin"))).toBe(true);
});

test("deleting selected assets invalidates the cached backend before the next request", async () => {
  const stt = await import("../stt"); stt.resetBackendCache();
  const available = spyOn(stt.WhisperServerBackend.prototype, "isAvailable").mockResolvedValue(true);
  try {
    await stt.getBackend();
    expect((await deleteRecognizer("whisper", async () => {})).outcome).toBe("accept");
    expect((await stt.getBackend()).name).toBe("parakeet-resident");
  } finally { available.mockRestore(); stt.resetBackendCache(); }
});

test("both engines have explicit load and unload, with no preference change", async () => {
  const { setRecognizerResidency } = await import("../recognizer-controller");
  const { persistRecognizer } = await import("../recognizer-state"); const calls: string[] = [];
  const d = { startP: async () => { calls.push("loadP"); }, startW: async () => { calls.push("loadW"); },
    stopP: async () => { calls.push("unloadP"); }, stopW: async () => { calls.push("unloadW"); }, reset() {} };
  for (const engine of ["whisper", "parakeet"] as const) {
    persistRecognizer(engine); noteRecognizerEffective(null);
    expect((await setRecognizerResidency(engine, "load", d)).outcome).toBe("accept");
    expect((await setRecognizerResidency(engine, "unload", d)).outcome).toBe("accept");
    expect(readRecognizerStatus().desired).toBe(engine);
    expect(readRecognizerStatus().engines[engine].phase).toBe("sleeping");
  }
  expect(calls).toEqual(["loadW", "unloadW", "loadP", "unloadP"]);
});

test("Load retries the desired engine after a fallback without a circular select-first refusal", async () => {
  const { setRecognizerResidency } = await import("../recognizer-controller"), { persistRecognizer } = await import("../recognizer-state");
  persistRecognizer("parakeet"); noteRecognizerEffective("whisper");
  const calls: string[] = [], d = { stopP: async () => { calls.push("stopP"); }, stopW: async () => { calls.push("stopW"); },
    startP: async () => { calls.push("startP"); }, startW: async () => {}, reset() {} };
  expect((await setRecognizerResidency("parakeet", "load", d)).outcome).toBe("accept");
  expect(calls).toEqual(["stopP", "stopW", "startP"]); expect(readRecognizerStatus().desired).toBe("parakeet");
});
