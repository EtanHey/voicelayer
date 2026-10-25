import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { createHash } from "crypto";
import * as fs from "fs";
import { isAbsolute, join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest } from "../speak-archive";
import { openSpeakEventJournal } from "../speak-archive-events";
import { recoverSpeakArchive, saveSpeakArtifact, saveSpeakProjection, updateSpeakLifecycle,
  type SpeakLifecycle, type SpeakStoreResult } from "../speak-archive-store";

const at = new Date("2026-10-23T12:34:56.789Z"), id = "2026-10-23T12-34-56-789Z-1234abcd";
const request: SpeakReceiptRequest = { input: "synthetic recovery input שלום 🗣️\n", request_id: "synthetic-request",
  request_source: "selection", connection: "daemon", format: "plain", blocking: false,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null } };
const projection: Parameters<typeof saveSpeakProjection>[1] = {
  display: "synthetic display", spoken: "synthetic spoken", normalization: {
    version: null, pronunciation_hash: null, settings_hash: null, stages: [] },
  chunks: [{ chunk_id: "c0", index: 0, source_range_utf16: null, display_range_utf16: null,
    spoken_range_utf16: null, display_text: "synthetic display", spoken_text: "synthetic spoken",
    state: "planned", attempts: [] }] };
const stopped: SpeakLifecycle = { status: "stopped", generation_id: null,
  timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
  summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code: null }, played_spans: [] };
const artifact: Parameters<typeof saveSpeakArtifact>[1] = { bytes: Buffer.from("synthetic MP3 bytes"),
  role: "playback_ready", mime: "audio/mpeg", duration_ms: null, sample_rate: null, channels: null };
const hash = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
let root: string | undefined, previous: string | undefined;
let restores: (() => void)[] = [];
function receipt(request_id = request.request_id) {
  const result = createSpeakReceipt({ ...request, request_id }, { now: () => at, id: () => id });
  if (result.kind !== "created") throw new Error("synthetic receipt failed");
  return result.context;
}
function stored(result: SpeakStoreResult) {
  if (result.kind !== "stored") throw new Error(`synthetic store failed: ${result.code}`);
  return result.metadata;
}
function write(entry: string, name: string, bytes: string) {
  fs.writeFileSync(join(entry, name), bytes, { mode: 0o600 });
}
function evidence(entry: string) {
  return fs.readdirSync(entry).sort().filter(name => fs.lstatSync(join(entry, name)).isFile()).map(name => ({
    name, bytes: fs.readFileSync(join(entry, name)), inode: fs.lstatSync(join(entry, name)).ino,
  }));
}
function journal(context: ReturnType<typeof receipt>) {
  const opened = openSpeakEventJournal(context);
  if (opened.kind !== "opened") throw new Error("synthetic journal failed");
  try {
    for (let seq = 1; seq <= 2; seq++) expect(opened.journal.append({ generation_id: null,
      playback_id: null, chunk_id: null, utc: at.toISOString(), clock_id: null, elapsed_ms: null,
      event: "request_received", data: { request_source: "selection" } })).toEqual({ kind: "durable", seq });
  } finally { expect(opened.journal.close()).toEqual({ kind: "closed" }); }
}

describe("speak store recovery regressions (preload-owned synthetic filesystem)", () => {
  beforeEach(() => {
    root = undefined; previous = process.env.QA_VOICE_RECORDINGS_DIR;
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, base = resolve(".test-tmp");
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run) throw new Error("canonical isolated preload required");
    const child = relative(base, resolve(run));
    if (!child || child === ".." || child.startsWith("../") || isAbsolute(child) ||
      fs.realpathSync(run) !== resolve(run)) throw new Error("owned preload root required");
    root = fs.mkdtempSync(join(run, "store-recovery-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    for (const restore of restores.reverse()) restore(); restores = [];
    if (previous === undefined) delete process.env.QA_VOICE_RECORDINGS_DIR;
    else process.env.QA_VOICE_RECORDINGS_DIR = previous;
    if (root) fs.rmSync(root, { recursive: true, force: true });
    root = undefined;
  });

  it("4369225230 reports mkdir parent-sync uncertainty and retries it before publishing audio", () => {
    const c = receipt(), before = evidence(c.path), entry = fs.statSync(c.path), audio = join(c.path, "audio");
    const originalSync = fs.fsyncSync; let fault = true, entrySyncs = 0;
    const spy = spyOn(fs, "fsyncSync").mockImplementation(fd => {
      const stat = fs.fstatSync(fd);
      if (stat.isDirectory() && stat.dev === entry.dev && stat.ino === entry.ino) {
        entrySyncs++; if (fault) throw new Error("synthetic entry sync failure");
      }
      originalSync(fd);
    });
    restores.push(() => spy.mockRestore());
    expect(saveSpeakArtifact(c, artifact)).toEqual({ kind: "failed", code: "SYNC_UNCERTAIN" });
    const created = fs.statSync(audio);
    expect(created.mode & 0o777).toBe(0o700); expect(entrySyncs).toBe(1);
    expect(fs.readdirSync(audio)).toEqual([]); expect(evidence(c.path)).toEqual(before);
    expect(saveSpeakArtifact(c, artifact)).toEqual({ kind: "failed", code: "SYNC_UNCERTAIN" });
    expect(entrySyncs).toBe(2); expect(fs.readdirSync(audio)).toEqual([]);
    expect(fs.statSync(audio).ino).toBe(created.ino); expect(evidence(c.path)).toEqual(before);
    fault = false;
    const m = stored(saveSpeakArtifact(c, artifact));
    expect(entrySyncs).toBe(4); expect(m.artifacts).toHaveLength(1);
    expect(fs.readFileSync(join(audio, hash(artifact.bytes) + ".mp3"))).toEqual(artifact.bytes);
    expect(fs.statSync(audio).ino).toBe(created.ino);
    expect(fs.readFileSync(join(c.path, "input.txt"), "utf8")).toBe(request.input);
  });
  for (const unsafe of ["file", "symlink", "mode"]) {
    it(`4369225230 preserves EEXIST ${unsafe} refusal`, () => {
      const c = receipt(), audio = join(c.path, "audio");
      if (unsafe === "file") write(c.path, "audio", "synthetic occupied path");
      else if (unsafe === "symlink") fs.symlinkSync(c.path, audio);
      else { fs.mkdirSync(audio, { mode: 0o700 }); fs.chmodSync(audio, 0o755); }
      const before = evidence(c.path), stat = fs.lstatSync(audio);
      expect(saveSpeakArtifact(c, artifact)).toEqual({ kind: "failed", code: "UNSAFE_PATH" });
      expect(evidence(c.path)).toEqual(before); expect(fs.lstatSync(audio).ino).toBe(stat.ino);
      expect(fs.lstatSync(audio).mode).toBe(stat.mode);
      if (unsafe === "symlink") expect(fs.readlinkSync(audio)).toBe(c.path);
    });
  }

  for (const { label, requestId } of [{ label: "ordinary", requestId: "synthetic-journal-id" },
    { label: "long Unicode", requestId: "  שלום/🗣️".repeat(80) + "  " },
    { label: "empty", requestId: "" }, { label: "unrestricted", requestId: "\ud800\u0000../synthetic" }]) {
    it(`4369225234 rebuilds missing metadata from genuine ${label} journal identity and retains torn bytes`, () => {
      const c = receipt(requestId); journal(c);
      const path = join(c.path, "events.ndjson"), tail = Buffer.from('{"seq":3,"synthetic":"שלום');
      fs.appendFileSync(path, tail); fs.unlinkSync(join(c.path, "metadata.json"));
      const original = fs.readFileSync(path), input = fs.readFileSync(join(c.path, "input.txt"));
      expect(stored(recoverSpeakArchive(id))).toMatchObject({ request_id: requestId, status: "interrupted_unknown",
        recovery: { metadata_missing: true, journal_complete_lines: 2, torn_tail_bytes: tail.length } });
      expect(fs.readFileSync(path)).toEqual(original); expect(fs.readFileSync(join(c.path, "input.txt"))).toEqual(input);
      const recovered = evidence(c.path); stored(recoverSpeakArchive(id)); expect(evidence(c.path)).toEqual(recovered);
    });
  }
  for (const mode of ["absent", "empty", "torn only"]) {
    it(`4369225234 keeps explicit unknown identity for ${mode} journal`, () => {
      const c = receipt(); fs.unlinkSync(join(c.path, "metadata.json"));
      if (mode !== "absent") write(c.path, "events.ndjson", mode === "empty" ? "" : '{"seq":1');
      const before = evidence(c.path);
      expect(stored(recoverSpeakArchive(id))).toMatchObject({ request_id: null,
        recovery: { metadata_missing: true, journal_complete_lines: 0, torn_tail_bytes: mode === "torn only" ? 8 : 0 } });
      expect(evidence(c.path).filter(f => f.name !== "metadata.json")).toEqual(before);
    });
  }
  const invalidJournals = ["not-json\n", '{"seq":2,"request_id":"synthetic-request"}\n',
    '{"seq":1,"request_id":null}\n', '{"seq":1,"request_id":7}\n', '{"seq":1}\n',
    '{"seq":1,"request_id":"synthetic-request"}\n{"seq":3,"request_id":"synthetic-request"}\n',
    '{"seq":1,"request_id":"synthetic-request"}\n{"seq":2,"request_id":"foreign"}\n',
    '{"seq":1,"request_id":"synthetic-request"}\nnot-json\n',
    '{"seq":1,"request_id":"synthetic-request"}\n{"seq":2,"request_id":null}\n'];
  for (const missing of [true, false]) for (const [index, bytes] of invalidJournals.entries()) {
    it(`4369225234 refuses journal boundary ${index} with metadata missing=${missing} without replacing evidence`, () => {
      const c = receipt(); write(c.path, "events.ndjson", bytes + '{"torn":');
      if (missing) fs.unlinkSync(join(c.path, "metadata.json"));
      const before = evidence(c.path);
      expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "CORRUPT_METADATA" });
      expect(evidence(c.path)).toEqual(before);
    });
  }
  it("4369225234 refuses a valid journal whose identity conflicts with retained metadata", () => {
    const c = receipt(); journal(c);
    write(c.path, "metadata.json", JSON.stringify({ ...c.metadata, request_id: "foreign" }));
    const before = evidence(c.path);
    expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "CORRUPT_METADATA" });
    expect(evidence(c.path)).toEqual(before);
  });

  for (const { label, bytes } of [{ label: "JSON syntax", bytes: "{" }, { label: "non-array schema", bytes: "{}" },
    { label: "incomplete chunk schema", bytes: "[{}]" },
    { label: "invalid state", bytes: JSON.stringify(projection.chunks.map(chunk => ({ ...chunk, state: "foreign" }))) }]) {
    it(`4369225239 classifies corrupt chunks ${label} without changing any original file`, () => {
      const c = receipt(); stored(saveSpeakProjection(c, projection)); write(c.path, "chunks.json", bytes);
      const before = evidence(c.path);
      expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "CORRUPT_METADATA" });
      expect(evidence(c.path)).toEqual(before);
    });
  }
  it("4369225239 retains IO_ERROR for a chunks open failure", () => {
    const c = receipt(); stored(saveSpeakProjection(c, projection)); const before = evidence(c.path);
    const originalOpen = fs.openSync; let faults = 0;
    const spy = spyOn(fs, "openSync").mockImplementation((path, flags, mode) => {
      if (String(path) === join(c.path, "chunks.json")) { faults++; throw new Error("synthetic open failure"); }
      return originalOpen(path, flags, mode);
    });
    restores.push(() => spy.mockRestore());
    expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "IO_ERROR" });
    expect(faults).toBe(1); spy.mockRestore(); expect(evidence(c.path)).toEqual(before);
  });
  it("4369225239 retains UNSAFE_PATH for a nonprivate chunks file", () => {
    const c = receipt(); stored(saveSpeakProjection(c, projection)); fs.chmodSync(join(c.path, "chunks.json"), 0o644);
    const before = evidence(c.path);
    expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "UNSAFE_PATH" });
    expect(evidence(c.path)).toEqual(before); expect(fs.statSync(join(c.path, "chunks.json")).mode & 0o777).toBe(0o644);
  });
  for (const name of ["display.txt", "spoken.txt"]) {
    it(`4369225243 refuses altered immutable ${name} without rewriting the ledger`, () => {
      const c = receipt(); stored(saveSpeakProjection(c, projection)); write(c.path, name, "synthetic corruption");
      const before = evidence(c.path);
      expect(recoverSpeakArchive(id)).toEqual({ kind: "failed", code: "CORRUPT_METADATA" });
      expect(evidence(c.path)).toEqual(before);
    });
  }
  it("4369225243 recovers projections published before metadata publication failed", () => {
    const c = receipt(), originalRename = fs.renameSync;
    const spy = spyOn(fs, "renameSync").mockImplementation((from, to) => {
      if (String(to) === join(c.path, "metadata.json")) throw new Error("synthetic metadata publication failure");
      originalRename(from, to);
    });
    restores.push(() => spy.mockRestore());
    expect(saveSpeakProjection(c, projection)).toEqual({ kind: "failed", code: "WRITE_UNCERTAIN" });
    spy.mockRestore(); const before = evidence(c.path), m = stored(recoverSpeakArchive(id));
    expect(m.projections).toHaveLength(3); expect(m.totals.chunk_count).toBe(1);
    for (const p of m.projections) expect(p.sha256).toBe(hash(fs.readFileSync(join(c.path, p.name))));
    expect(evidence(c.path).filter(f => f.name !== "metadata.json")).toEqual(before.filter(f => f.name !== "metadata.json"));
  });
  it("4369225243 accepts matching immutable hashes and reconciles stale chunks after Stop", () => {
    const c = receipt(), published = stored(saveSpeakProjection(c, projection)); stored(updateSpeakLifecycle(c, stopped));
    const chunks = JSON.stringify(projection.chunks.flatMap(chunk => [chunk, { ...chunk, chunk_id: "c1", index: 1, state: "generated" }]));
    expect(published.projections.find(p => p.name === "chunks.json")?.sha256).not.toBe(hash(Buffer.from(chunks)));
    write(c.path, "chunks.json", chunks); const before = evidence(c.path), m = stored(recoverSpeakArchive(id));
    expect(m.status).toBe("stopped"); expect(m.totals.chunk_count).toBe(2);
    expect(m.projections.find(p => p.name === "chunks.json")?.sha256).toBe(hash(Buffer.from(chunks)));
    expect(evidence(c.path).filter(f => f.name !== "metadata.json")).toEqual(before.filter(f => f.name !== "metadata.json"));
    const recovered = evidence(c.path); stored(recoverSpeakArchive(id)); expect(evidence(c.path)).toEqual(recovered);
  });
});
