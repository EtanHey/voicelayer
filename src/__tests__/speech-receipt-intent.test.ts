import { expect, test, spyOn } from "bun:test";
import * as fs from "fs";
import { dirname, join, relative } from "path";
import { createSpeakReceipt } from "../speak-archive";
import * as index from "../speech-open-index";

const request = { input: "synthetic durable input", request_id: "fixture", request_source: "direct",
  connection: "stdio", format: "plain", blocking: true,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } } as const;

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
