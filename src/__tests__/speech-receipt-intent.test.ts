import { expect, test, spyOn } from "bun:test";
import * as fs from "fs";
import { dirname, join, relative } from "path";
import { createSpeakReceipt } from "../speak-archive";
import * as index from "../speech-open-index";
import { recoverSpeakArchive, transitionSpeakArchive } from "../speak-archive-store";

const request = { input: "synthetic durable input", request_id: "fixture", request_source: "direct",
  connection: "stdio", format: "plain", blocking: true,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } } as const;

test("a preloaded child retains its parent's isolated archive redirect", () => {
  const child = Bun.spawnSync([process.execPath, "--preload", "./src/__tests__/setup/preload.ts", "-e",
    `import { createSpeakReceipt } from './src/speak-archive';
     console.log(createSpeakReceipt(${JSON.stringify(request)}).kind);`],
    { env: process.env, stdout: "pipe", stderr: "pipe" });
  expect(child.exitCode).toBe(0);
  expect(child.stdout.toString().trim()).toBe("created");
});

test("open index stays outside records and inside the isolated run", () => {
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  const result = createSpeakReceipt(request);
  expect(result.kind).toBe("created");
  const path = index.speechOpenIndex();
  expect(relative(root, path).startsWith("..")).toBe(true);
  expect(relative(process.env.VOICELAYER_TEST_RUN_ROOT!, path).startsWith("..")).toBe(false);
  expect(fs.statSync(path).mode & 0o777).toBe(0o700);
  if (result.kind !== "created") throw Error("expected receipt");
  expect(fs.existsSync(join(index.speechPendingIndex(), result.context.id, String(process.pid)))).toBe(false);
});

test("index isolation refuses missing redirects and paths outside the run", () => {
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  try {
    process.env.QA_VOICE_RECORDINGS_DIR = " ";
    expect(() => index.speechOpenIndex()).toThrow();
    process.env.QA_VOICE_RECORDINGS_DIR = dirname(process.env.VOICELAYER_TEST_RUN_ROOT!);
    expect(() => index.speechOpenIndex()).toThrow();
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = root; }
});

test("metadata failure leaves recoverable pending intent and no published index entry", () => {
  const original = fs.writeFileSync;
  let writes = 0;
  const spy = spyOn(fs, "writeFileSync").mockImplementation((file, data, options) => {
    if (++writes === 2) throw Error("synthetic metadata failure");
    original(file, data, options);
  });
  let result;
  try { result = createSpeakReceipt(request); } finally { spy.mockRestore(); }
  expect(result).toMatchObject({ kind: "failed", stage: "metadata" });
  if (result.kind !== "failed" || !result.partial) throw Error("expected allocated receipt");
  expect(fs.existsSync(join(index.speechOpenIndex(), result.partial.id))).toBe(false);
  expect(fs.existsSync(join(index.speechPendingIndex(), result.partial.id, String(process.pid)))).toBe(true);
});

test("durable pending intent precedes metadata and survives failed index publication", () => {
  let pending = false, published = false;
  const spy = spyOn(index, "indexOpenSpeech").mockImplementation(id => {
    const root = process.env.QA_VOICE_RECORDINGS_DIR!;
    pending = fs.existsSync(join(index.speechPendingIndex(), id, String(process.pid)));
    published = JSON.parse(fs.readFileSync(join(root, id.slice(0, 10), id, "metadata.json"), "utf8")).id === id;
    throw Error("synthetic index failure");
  });
  try { expect(createSpeakReceipt(request)).toMatchObject({ kind: "failed", stage: "metadata" }); }
  finally { spy.mockRestore(); }
  expect(pending).toBe(true);
  expect(published).toBe(true);
});

test("index refuses a symlink ancestor and a nonprivate directory", () => {
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  const base = fs.mkdtempSync(join(dirname(root), "index-safety-"));
  const target = join(base, "target"); fs.mkdirSync(target, { mode: 0o700 });
  const alias = join(base, "alias"); fs.symlinkSync(target, alias);
  try {
    process.env.QA_VOICE_RECORDINGS_DIR = join(alias, "records");
    expect(() => index.indexOpenSpeech("fixture")).toThrow();
    expect(fs.readdirSync(target)).toEqual([]);
    process.env.QA_VOICE_RECORDINGS_DIR = join(base, "records");
    fs.mkdirSync(index.speechOpenIndex(), { mode: 0o755 });
    fs.chmodSync(index.speechOpenIndex(), 0o755);
    expect(() => index.indexOpenSpeech("fixture")).toThrow();
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = root; fs.rmSync(base, { recursive: true }); }
});


test("trailing separators keep indexes outside records and receipts transitionable", () => {
  const root = process.env.QA_VOICE_RECORDINGS_DIR!;
  try {
    process.env.QA_VOICE_RECORDINGS_DIR = root + "///";
    const result = createSpeakReceipt(request);
    expect(result.kind).toBe("created");
    expect(relative(root, index.speechOpenIndex()).startsWith("..")).toBe(true);
    expect(relative(root, index.speechPendingIndex()).startsWith("..")).toBe(true);
    if (result.kind !== "created") throw Error("expected receipt");
    expect(transitionSpeakArchive(result.context, "preparing").kind).toBe("stored");
    expect(transitionSpeakArchive(result.context, "failed", "SYNTH_FAILED").kind).toBe("stored");
  } finally { process.env.QA_VOICE_RECORDINGS_DIR = root; }
});

for (const fault of ["index", "metadata"] as const) {
  test(`recovery removes pending receipt after ${fault} publication failure`, () => {
    const original = fs.writeFileSync;
    let writes = 0;
    const spy = fault === "index"
      ? spyOn(index, "indexOpenSpeech").mockImplementation(() => { throw Error("synthetic index failure"); })
      : spyOn(fs, "writeFileSync").mockImplementation((file, data, options) => {
        if (++writes === 2) throw Error("synthetic metadata failure");
        original(file, data, options);
      });
    let result;
    try { result = createSpeakReceipt(request); } finally { spy.mockRestore(); }
    if (result.kind !== "failed" || !result.partial) throw Error("expected partial receipt");
    const id = result.partial.id;
    expect(fs.existsSync(join(index.speechPendingIndex(), id))).toBe(true);
    expect(recoverSpeakArchive(id)).toMatchObject({ kind: "stored", metadata: { status: "interrupted_unknown" } });
    expect(fs.existsSync(join(index.speechPendingIndex(), id))).toBe(false);
    expect(fs.existsSync(join(index.speechOpenIndex(), id))).toBe(false);
  });
}

test("durable terminal transition removes pending as well as published index", () => {
  const result = createSpeakReceipt(request);
  if (result.kind !== "created") throw Error("expected receipt");
  index.beginSpeechReceipt(result.context.id);
  expect(transitionSpeakArchive(result.context, "failed", "SYNTH_FAILED").kind).toBe("stored");
  expect(fs.existsSync(join(index.speechPendingIndex(), result.context.id))).toBe(false);
  expect(fs.existsSync(join(index.speechOpenIndex(), result.context.id))).toBe(false);
});

test("recovery retries terminal cleanup after unsafe index permissions are restored", () => {
  const result = createSpeakReceipt(request);
  if (result.kind !== "created") throw Error("expected receipt");
  fs.chmodSync(index.speechOpenIndex(), 0o755);
  try { expect(transitionSpeakArchive(result.context, "failed", "SYNTH_FAILED")).toEqual({ kind: "failed", code: "UNSAFE_PATH" }); }
  finally { fs.chmodSync(index.speechOpenIndex(), 0o700); }
  expect(recoverSpeakArchive(result.context.id).kind).toBe("stored");
  // Repeat after recreating a stale index to exercise byte-identical terminal recovery.
  index.indexOpenSpeech(result.context.id);
  expect(recoverSpeakArchive(result.context.id).kind).toBe("stored");
  expect(fs.existsSync(join(index.speechOpenIndex(), result.context.id))).toBe(false);
});
