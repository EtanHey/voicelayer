import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "crypto";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest, type SpeakReceiptResult } from "../speak-archive";

const at = new Date("2026-10-23T12:34:56.789Z");
const id = "2026-10-23T12-34-56-789Z-1234abcd";
const seams = { now: () => at, id: () => id };
const request: SpeakReceiptRequest = {
  input: " \tשלום e\u0301 🗣️\nfu… no, full\r\n  ", request_id: "../caller-is-not-a-path",
  request_source: "selection", connection: "daemon", format: "markdown", blocking: false,
  requested: { mode: "read", profile: "synthetic", engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
};
let root: string;
let originalRoot: string | undefined;
let restoreSpy: (() => void) | undefined;
function created(result: SpeakReceiptResult) {
  if (result.kind !== "created") throw new Error(`unexpected receipt failure: ${result.code}`);
  return result.context;
}

describe("private speak receipt creation", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT;
    const redirected = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !redirected ||
        relative(resolve(run), resolve(redirected)).startsWith("..") ||
        resolve(run) === resolve(redirected)) throw new Error("canonical isolated preload required");
    originalRoot = redirected;
    root = fs.mkdtempSync(join(redirected, "speak-receipt-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    restoreSpy?.();
    restoreSpy = undefined;
    if (originalRoot !== undefined) process.env.QA_VOICE_RECORDINGS_DIR = originalRoot;
    if (root) fs.rmSync(root, { recursive: true, force: true });
  });

  it("publishes exact Unicode whitespace input, hash and received metadata in the final private entry", () => {
    const context = created(createSpeakReceipt(request, seams));
    expect(context.path).toBe(join(root, "2026-10-23", id));
    expect(fs.readFileSync(join(context.path, "input.txt"), "utf8")).toBe(request.input);
    expect(context.metadata.input).toEqual({ bytes: Buffer.byteLength(request.input),
      sha256: createHash("sha256").update(request.input).digest("hex") });
    expect(context.metadata).toMatchObject({ source: "speak", request_source: "selection",
      schema_version: 1, status: "received", request_id: request.request_id,
      created_at: at.toISOString(), updated_at: at.toISOString(), generation_id: null,
      requested: request.requested, build: request.build });
    expect(JSON.parse(fs.readFileSync(join(context.path, "metadata.json"), "utf8"))).toEqual(context.metadata);
    expect(fs.readdirSync(context.path).sort()).toEqual(["input.txt", "metadata.json"]);
    expect(fs.existsSync(join(context.path, "audio.wav"))).toBe(false);
    expect(fs.existsSync(join(context.path, "voicelayer-transcript.txt"))).toBe(false);
    for (const path of [root, join(root, "2026-10-23"), context.path]) {
      expect(fs.statSync(path).mode & 0o777).toBe(0o700);
    }
    for (const name of ["input.txt", "metadata.json"]) {
      expect(fs.statSync(join(context.path, name)).mode & 0o777).toBe(0o600);
    }
    expect(context.metadata).not.toHaveProperty("backup");
    expect(context.metadata).not.toHaveProperty("effective");
  });

  it("allowlists context and never copies transport extras or reference audio", () => {
    const enriched = { ...request, token: "synthetic-secret",
      build: { ...request.build, reference_audio: "synthetic-private-bytes" } };
    const context = created(createSpeakReceipt(enriched, seams));
    const metadata = fs.readFileSync(join(context.path, "metadata.json"), "utf8");
    expect(metadata).not.toContain("synthetic-secret");
    expect(metadata).not.toContain("synthetic-private-bytes");
  });

  it("creates multiple entries and refuses a collision without overwriting prior bytes", () => {
    const first = created(createSpeakReceipt(request, seams));
    const before = fs.readFileSync(join(first.path, "metadata.json"));
    const collision = createSpeakReceipt({ ...request, input: "different" }, seams);
    expect(collision).toEqual({ kind: "failed", stage: "allocate", code: "COLLISION", partial: null });
    expect(fs.readFileSync(join(first.path, "metadata.json"))).toEqual(before);
    const next = created(createSpeakReceipt(request, { ...seams, id: () => id.replace("1234abcd", "abcd1234") }));
    expect(next.id).not.toBe(first.id);
    expect(fs.readdirSync(join(root, "2026-10-23"))).toHaveLength(2);
  });

  it("rejects traversal IDs and root aliases before allocating an entry", () => {
    expect(createSpeakReceipt(request, { ...seams, id: () => "../escape" })).toMatchObject({
      kind: "failed", code: "UNSAFE_PATH", partial: null });
    process.env.QA_VOICE_RECORDINGS_DIR = `${root}/../alias`;
    expect(createSpeakReceipt(request, seams)).toMatchObject({ kind: "failed", code: "UNSAFE_PATH" });
    expect(fs.readdirSync(root)).toEqual([]);
  });

  it("refuses symlink roots, ancestors, days and collided entries without touching targets", () => {
    const target = join(root, "target");
    fs.mkdirSync(target, { mode: 0o700 });
    fs.writeFileSync(join(target, "keep"), "untouched", { mode: 0o600 });
    fs.symlinkSync(target, join(root, "alias"));
    for (const override of [join(root, "alias"), join(root, "alias", "nested")]) {
      process.env.QA_VOICE_RECORDINGS_DIR = override;
      expect(createSpeakReceipt(request, seams)).toMatchObject({ kind: "failed", code: "UNSAFE_PATH" });
    }
    process.env.QA_VOICE_RECORDINGS_DIR = root;
    fs.symlinkSync(target, join(root, "2026-10-23"));
    expect(createSpeakReceipt(request, seams)).toMatchObject({ kind: "failed", code: "UNSAFE_PATH" });
    fs.unlinkSync(join(root, "2026-10-23"));
    fs.mkdirSync(join(root, "2026-10-23"), { mode: 0o700 });
    fs.symlinkSync(target, join(root, "2026-10-23", id));
    expect(createSpeakReceipt(request, seams)).toMatchObject({ kind: "failed", code: "COLLISION", partial: null });
    expect(fs.readdirSync(target)).toEqual(["keep"]);
    expect(fs.readFileSync(join(target, "keep"), "utf8")).toBe("untouched");
  });

  it("leaves existing Dictation and Ask data and permissions untouched", () => {
    const day = join(root, "2026-10-23");
    fs.mkdirSync(day, { mode: 0o700 });
    for (const source of ["voicebar", "voice_ask"]) {
      const path = join(day, source);
      fs.mkdirSync(path, { mode: 0o750 });
      fs.writeFileSync(join(path, "metadata.json"), JSON.stringify({ source }), { mode: 0o640 });
      fs.chmodSync(path, 0o750);
      fs.chmodSync(join(path, "metadata.json"), 0o640);
    }
    created(createSpeakReceipt(request, seams));
    for (const source of ["voicebar", "voice_ask"]) {
      const path = join(day, source);
      expect(fs.statSync(path).mode & 0o777).toBe(0o750);
      expect(fs.statSync(join(path, "metadata.json")).mode & 0o777).toBe(0o640);
      expect(fs.readFileSync(join(path, "metadata.json"), "utf8")).toBe(JSON.stringify({ source }));
    }
  });

  it("refuses an existing non-private day without changing its permissions", () => {
    const day = join(root, "2026-10-23");
    fs.mkdirSync(day, { mode: 0o755 });
    fs.chmodSync(day, 0o755);
    expect(createSpeakReceipt(request, seams)).toMatchObject({ kind: "failed", code: "UNSAFE_PATH", partial: null });
    expect(fs.statSync(day).mode & 0o777).toBe(0o755);
    expect(fs.readdirSync(day)).toEqual([]);
  });

  for (const operation of ["writeFileSync", "fsyncSync", "renameSync"] as const) {
    it(`returns an honest ${operation} failure and retains allocated partial evidence`, () => {
      const previous = created(createSpeakReceipt(request, { ...seams, id: () => id.replace("1234abcd", "abcd1234") }));
      const prior = fs.readFileSync(join(previous.path, "input.txt"));
      const fail = () => { throw new Error(`private failure ${request.input}`); };
      const originalSync = fs.fsyncSync;
      const spy = operation === "fsyncSync"
        ? spyOn(fs, "fsyncSync").mockImplementation((fd) => {
          if (fs.fstatSync(fd).isFile()) fail();
          originalSync(fd);
        })
        : operation === "writeFileSync"
          ? spyOn(fs, "writeFileSync").mockImplementation(fail)
          : spyOn(fs, "renameSync").mockImplementation(fail);
      restoreSpy = () => spy.mockRestore();
      const result = createSpeakReceipt(request, seams);
      expect(result).toEqual({ kind: "failed", stage: "input", code: "IO_ERROR",
        partial: { id, path: join(root, "2026-10-23", id) } });
      expect(JSON.stringify(result)).not.toContain(request.input);
      expect(fs.readdirSync(join(root, "2026-10-23", id))).toEqual([".input.txt.received-partial"]);
      expect(fs.readFileSync(join(previous.path, "input.txt"))).toEqual(prior);
    });
  }

  it("retains input and metadata partial evidence when the metadata write fails", () => {
    const original = fs.writeFileSync;
    let writes = 0;
    const spy = spyOn(fs, "writeFileSync").mockImplementation((file, data, options) => {
      if (++writes === 2) throw new Error("synthetic metadata disk failure");
      original(file, data, options);
    });
    restoreSpy = () => spy.mockRestore();
    expect(createSpeakReceipt(request, seams)).toEqual({ kind: "failed", stage: "metadata", code: "IO_ERROR",
      partial: { id, path: join(root, "2026-10-23", id) } });
    const path = join(root, "2026-10-23", id);
    expect(fs.readFileSync(join(path, "input.txt"), "utf8")).toBe(request.input);
    expect(fs.readdirSync(path).sort()).toEqual([".metadata.json.received-partial", "input.txt"]);
    expect(fs.statSync(join(path, ".metadata.json.received-partial")).mode & 0o777).toBe(0o600);
  });

  it("does not report success when directory fsync fails after metadata publication", () => {
    const path = join(root, "2026-10-23", id);
    const original = fs.fsyncSync;
    const spy = spyOn(fs, "fsyncSync").mockImplementation((fd) => {
      if (fs.fstatSync(fd).isDirectory() && fs.existsSync(join(path, "metadata.json"))) {
        throw new Error("synthetic directory sync failure");
      }
      original(fd);
    });
    restoreSpy = () => spy.mockRestore();
    expect(createSpeakReceipt(request, seams)).toEqual({ kind: "failed", stage: "metadata", code: "IO_ERROR",
      partial: { id, path } });
    expect(fs.readdirSync(path).sort()).toEqual(["input.txt", "metadata.json"]);
    expect(fs.readFileSync(join(path, "input.txt"), "utf8")).toBe(request.input);
  });

  it("fails closed on missing call-time isolation and rejects non-UTF8 string fragments", () => {
    process.env.QA_VOICE_RECORDINGS_DIR = " ";
    expect(createSpeakReceipt(request, seams)).toMatchObject({ kind: "failed", partial: null });
    process.env.QA_VOICE_RECORDINGS_DIR = root;
    expect(createSpeakReceipt({ ...request, input: "\ud800" }, seams)).toMatchObject({
      kind: "failed", stage: "validate", code: "INVALID_INPUT", partial: null });
    expect(fs.readdirSync(root)).toEqual([]);
  });
});
