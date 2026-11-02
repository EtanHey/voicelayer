import { test, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, writeFileSync, rmSync, existsSync, readdirSync } from "fs";
import { join } from "path";
import { createHash } from "crypto";
import { testTmp } from "./setup/test-tmp";
import { downloadRecognizer, cancelRecognizerDownload, type DownloadDeps } from "../recognizer-download";
import { configureRecognizerBusyProbe, readRecognizerStatus, noteRecognizerEngine, beginRecognizerRequestAfterMaintenance, beginRecognizerRequest, finishRecognizerRequest } from "../recognizer-state";
import { parseCommand } from "../socket-protocol";
const root = testTmp("downloads"), keys = ["QA_VOICE_WHISPER_MODEL", "VOICELAYER_STATE_DIR", "QA_VOICE_STT_BACKEND", "VOICELAYER_PARAKEET_MODEL", "VOICELAYER_PARAKEET_PYTHON"] as const;
let saved: (string | undefined)[];
let prior: ReturnType<typeof readRecognizerStatus>;
const bytes = Buffer.from("synthetic weights"), file = { name: "fixture.bin", bytes: bytes.length,
  sha256: createHash("sha256").update(bytes).digest("hex"), url: "https://invalid.example/never-fetch" };
function deps(): DownloadDeps { return { files: () => [file], transfer: async (_, path, signal, progress) => {
  signal.throwIfAborted(); writeFileSync(path, bytes); progress(bytes.length);
}, runtime: async () => { throw new Error("unexpected-runtime"); }, freeBytes: () => 20 * 1024 ** 3 }; }
beforeEach(() => {
  prior = readRecognizerStatus();
  saved = keys.map(k => process.env[k]); mkdirSync(root, { recursive: true });
  process.env.QA_VOICE_WHISPER_MODEL = join(root, "model.bin"); process.env.VOICELAYER_STATE_DIR = join(root, "state"); delete process.env.QA_VOICE_STT_BACKEND;
  configureRecognizerBusyProbe(() => null); noteRecognizerEngine("whisper", { phase: "sleeping", error: null });
});
afterEach(() => { keys.forEach((k,i) => { if (saved[i] === undefined) delete process.env[k]; else process.env[k] = saved[i]; }); configureRecognizerBusyProbe(() => null);
  for (const engine of ["whisper", "parakeet"] as const) {
    const { phase, available, error, download } = prior.engines[engine]; noteRecognizerEngine(engine, { phase, available, error, download });
  }
  rmSync(root, { recursive: true, force: true });
});
test("download and cancel commands require an explicit valid engine", () => {
  for (const cmd of ["download_recognizer", "cancel_recognizer_download"]) {
    expect(parseCommand(JSON.stringify({ cmd, engine: "whisper", id: "x" }))).toEqual({ cmd, engine: "whisper", id: "x" });
    expect(parseCommand(JSON.stringify({ cmd, engine: "auto" }))).toBeNull();
  }
});
test("verified download publishes atomically without loading", async () => {
  const d = deps(), transfer = d.transfer; d.transfer = async (...args) => {
    expect(readRecognizerStatus().engines.whisper.assets_present).toBe(false); await transfer(...args);
    expect(existsSync(process.env.QA_VOICE_WHISPER_MODEL!)).toBe(false);
  };
  expect((await downloadRecognizer("whisper", d)).outcome).toBe("accept");
  expect(readRecognizerStatus().engines.whisper).toMatchObject({ assets_present: true, phase: "sleeping", download: { state: "complete" } });
  expect(readdirSync(root).filter(n => n.startsWith(".recognizer-download-"))).toEqual([]);
});
test("checksum mismatch never becomes present", async () => {
  const d = deps(); d.files = () => [{ ...file, sha256: "0".repeat(64) }];
  expect(await downloadRecognizer("whisper", d)).toMatchObject({ outcome: "reject", reason: "download-checksum-mismatch" });
  expect(readRecognizerStatus().engines.whisper.assets_present).toBe(false);
});
test("cancel joins transfer cleanup and permits a later retry", async () => {
  const d = deps(), started = Promise.withResolvers<void>();
  d.transfer = async (_, path, signal) => {
    writeFileSync(path, "partial"); started.resolve();
    await new Promise((_, reject) => signal.addEventListener("abort", () => reject(new Error("cancel")), { once: true }));
  };
  const task = downloadRecognizer("whisper", d); await started.promise;
  expect(cancelRecognizerDownload("parakeet")).toBe(false); expect(cancelRecognizerDownload("whisper")).toBe(true);
  expect(await task).toMatchObject({ outcome: "reject", reason: "download-cancelled" });
  expect(readRecognizerStatus().engines.whisper).toMatchObject({ assets_present: false, download: { state: "cancelled" } });
  expect((await downloadRecognizer("whisper", deps())).outcome).toBe("accept");
});
test("disk refusal happens before any transfer", async () => {
  const d = deps(); d.freeBytes = () => 0; d.transfer = async () => { throw new Error("must-not-run"); };
  expect(await downloadRecognizer("whisper", d)).toMatchObject({ outcome: "reject", reason: "insufficient-disk-space" });
});
test("download starts and publishes during recording or transcription", async () => {
  configureRecognizerBusyProbe(() => "capture-active");
  expect((await downloadRecognizer("whisper", deps())).outcome).toBe("accept");
  rmSync(process.env.QA_VOICE_WHISPER_MODEL!);
  configureRecognizerBusyProbe(() => null); beginRecognizerRequest();
  try { expect((await downloadRecognizer("whisper", deps())).outcome).toBe("accept"); }
  finally { finishRecognizerRequest(); }
});

test("Parakeet runtime failure publishes no model tree; retry records owned Python without an override", async () => {
  const model = join(root, "parakeet"); process.env.VOICELAYER_PARAKEET_MODEL = model; delete process.env.VOICELAYER_PARAKEET_PYTHON;
  noteRecognizerEngine("parakeet", { phase: "sleeping", error: null });
  const d = deps(); d.files = () => ["config.json", "model.safetensors", "tokenizer.model"].map(name => ({ ...file, name }));
  d.runtime = async () => { throw new Error("missing-python-packages"); };
  expect(await downloadRecognizer("parakeet", d)).toMatchObject({ outcome: "reject", reason: "missing-python-packages" });
  expect(existsSync(model)).toBe(false);
  d.runtime = async () => {
    const python = join(root, "owned-python"); writeFileSync(python, "fixture");
    writeFileSync(join(process.env.VOICELAYER_STATE_DIR!, "parakeet-runtime.json"), JSON.stringify({ version: 1, python }));
  };
  expect((await downloadRecognizer("parakeet", d)).outcome).toBe("accept");
  expect(readRecognizerStatus().engines.parakeet.assets_present).toBe(true);
});

test("runtime-only setup verifies existing weights read-only instead of downloading copies", async () => {
  const model = join(root, "parakeet"); mkdirSync(model); process.env.VOICELAYER_PARAKEET_MODEL = model; delete process.env.VOICELAYER_PARAKEET_PYTHON;
  noteRecognizerEngine("parakeet", { phase: "sleeping", error: null }); const d = deps();
  d.files = () => ["config.json", "model.safetensors", "tokenizer.model"].map(name => ({ ...file, name }));
  for (const f of d.files("parakeet")) writeFileSync(join(model, f.name), bytes);
  d.transfer = async () => { throw new Error("must-not-copy-weights"); }; d.runtime = async () => { const python = join(root, "python"); writeFileSync(python, "fixture"); process.env.VOICELAYER_PARAKEET_PYTHON = python; };
  expect((await downloadRecognizer("parakeet", d)).outcome).toBe("accept");
  expect(readdirSync(model).sort()).toEqual(["config.json", "model.safetensors", "tokenizer.model"]);
});

test("unmocked downloader is denied before any test mutation or network", async () => {
  const revision = readRecognizerStatus().revision;
  expect(await downloadRecognizer("whisper")).toMatchObject({ outcome: "reject", reason: "download-network-denied-in-tests" });
  expect(readRecognizerStatus().revision).toBe(revision);
});
test("partial external model tree is refused before runtime publication", async () => {
  const model = join(root, "parakeet"); mkdirSync(model); writeFileSync(join(model, "config.json"), "partial");
  process.env.VOICELAYER_PARAKEET_MODEL = model; delete process.env.VOICELAYER_PARAKEET_PYTHON;
  noteRecognizerEngine("parakeet", { phase: "sleeping", error: null }); const d = deps();
  d.files = () => ["config.json", "model.safetensors", "tokenizer.model"].map(name => ({ ...file, name }));
  d.runtime = async () => { throw new Error("must-not-publish-runtime"); };
  expect(await downloadRecognizer("parakeet", d)).toMatchObject({ outcome: "reject", reason: "assets-exist-delete-first" });
  expect(readRecognizerStatus().engines.parakeet.assets_present).toBe(false);
});

for (const pendingStage of ["transfer", "runtime"] as const) test(`admitted request completes while Parakeet ${pendingStage} is pending`, async () => {
  const model = join(root, "parakeet"); process.env.VOICELAYER_PARAKEET_MODEL = model;
  delete process.env.VOICELAYER_PARAKEET_PYTHON;
  noteRecognizerEngine("parakeet", { phase: "sleeping", error: null });
  const entered = Promise.withResolvers<void>(), release = Promise.withResolvers<void>();
  const d = deps(), transfer = d.transfer;
  d.files = () => ["config.json", "model.safetensors", "tokenizer.model"].map(name => ({ ...file, name }));
  if (pendingStage === "transfer") d.transfer = async (...args) => { entered.resolve(); await release.promise; await transfer(...args); };
  d.runtime = async () => {
    if (pendingStage === "runtime") { entered.resolve(); await release.promise; }
    const python = join(root, "python"); writeFileSync(python, "fixture"); process.env.VOICELAYER_PARAKEET_PYTHON = python;
  };
  const downloading = downloadRecognizer("parakeet", d); await entered.promise;
  try {
    const { deleteRecognizer } = await import("../recognizer-management");
    const { selectRecognizer, setRecognizerResidency } = await import("../recognizer-controller");
    expect(await downloadRecognizer("parakeet", d)).toMatchObject({ outcome: "reject", reason: "download-active" });
    expect(deleteRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "download-active" });
    expect(await setRecognizerResidency("parakeet", "load")).toMatchObject({ outcome: "reject", reason: "download-active" });
    expect(await selectRecognizer("parakeet")).toMatchObject({ outcome: "reject", reason: "download-active" });
    // A different engine retains independent download ownership and cancellation.
    expect((await downloadRecognizer("whisper", deps())).outcome).toBe("accept");
    const abort = new AbortController();
    const timeout = setTimeout(() => abort.abort(), 500);
    try {
      await beginRecognizerRequestAfterMaintenance(abort.signal);
      finishRecognizerRequest();
    } finally { clearTimeout(timeout); }
    expect(readRecognizerStatus().engines.parakeet.download.state).toBe(pendingStage === "transfer" ? "downloading" : "runtime");
    expect(existsSync(model)).toBe(false);
  } finally { release.resolve(); await downloading; }
  expect(readRecognizerStatus().engines.parakeet.download.state).toBe("complete");
});

test("publication retains verified files when dictation becomes busy during transfer", async () => {
  const d = deps(), transfer = d.transfer;
  d.transfer = async (...args) => { await transfer(...args); configureRecognizerBusyProbe(() => "capture-active"); };
  expect((await downloadRecognizer("whisper", d)).outcome).toBe("accept");
  expect(existsSync(process.env.QA_VOICE_WHISPER_MODEL!)).toBe(true);
});

test("publication succeeds while an admitted request remains active", async () => {
  const d = deps(), transfer = d.transfer;
  let admitted = false;
  d.transfer = async (...args) => {
    await transfer(...args); await beginRecognizerRequestAfterMaintenance(); admitted = true;
  };
  try {
    expect((await downloadRecognizer("whisper", d)).outcome).toBe("accept");
    expect(existsSync(process.env.QA_VOICE_WHISPER_MODEL!)).toBe(true);
    expect(readRecognizerStatus().switch_refusal_reason).toBe("request-active");
  } finally { if (admitted) finishRecognizerRequest(); }
});
