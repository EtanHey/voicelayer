import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest } from "../speak-archive";
import { openSpeakEventJournal, type SpeakArchiveEvent, type SpeakEventJournal } from "../speak-archive-events";

const at = new Date("2026-10-23T12:34:56.789Z");
const request: SpeakReceiptRequest = {
  input: "  שלום 🗣️ fu… no, full\n", request_id: "fixture-request-שלום",
  request_source: "selection", connection: "daemon", format: "plain", blocking: false,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
};
const event: SpeakArchiveEvent = { generation_id: null, playback_id: null, chunk_id: null,
  utc: at.toISOString(), clock_id: null, elapsed_ms: null,
  event: "request_received", data: { request_source: "selection" } };
let root: string, previous: string;
let journals: SpeakEventJournal[] = [];
let restores: (() => void)[] = [];
function receipt(tail = "1234abcd") {
  const result = createSpeakReceipt(request, { now: () => at,
    id: () => `2026-10-23T12-34-56-789Z-${tail}` });
  if (result.kind !== "created") throw new Error("synthetic receipt failed");
  return result.context;
}
function open(context: ReturnType<typeof receipt>) {
  const result = openSpeakEventJournal(context);
  if (result.kind !== "opened") throw new Error("synthetic journal failed");
  journals.push(result.journal);
  return result.journal;
}
const bytes = (entry: string) => fs.readFileSync(join(entry, "events.ndjson"));

describe("fresh private speak event journals", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, archive = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !archive ||
      relative(resolve(run), resolve(archive)).startsWith("..") || resolve(run) === resolve(archive)) {
      throw new Error("canonical isolated preload required");
    }
    previous = archive;
    root = fs.mkdtempSync(join(archive, "speak-events-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    for (const restore of restores.reverse()) restore();
    restores = [];
    for (const journal of journals) journal.close();
    journals = [];
    if (previous) process.env.QA_VOICE_RECORDINGS_DIR = previous;
    if (root) fs.rmSync(root, { recursive: true, force: true });
  });

  it("durably orders explicit envelopes, preserves receipt bytes and journal prefixes, and closes its FD", () => {
    const context = receipt(), journal = open(context);
    const input = fs.readFileSync(join(context.path, "input.txt"));
    const metadata = fs.readFileSync(join(context.path, "metadata.json"));
    expect(journal.append(event)).toEqual({ kind: "durable", seq: 1 });
    const prefix = bytes(context.path);
    expect(journal.append({ ...event, utc: "2026-10-22T12:34:56.789Z", clock_id: "fixture-clock",
      elapsed_ms: 17, generation_id: "g1", playback_id: "p1", chunk_id: "c1",
      event: "stop_requested", data: { reason: "user" } })).toEqual({ kind: "durable", seq: 2 });
    const saved = bytes(context.path);
    expect(saved.subarray(0, prefix.length)).toEqual(prefix);
    expect(saved.toString("utf8").endsWith("\n")).toBe(true);
    const records = saved.toString("utf8").trimEnd().split("\n").map(line => JSON.parse(line));
    expect(records[0]).toEqual({ seq: 1, request_id: request.request_id, ...event });
    expect(records[1]).toMatchObject({ seq: 2, elapsed_ms: 17, clock_id: "fixture-clock", event: "stop_requested" });
    expect(fs.statSync(join(context.path, "events.ndjson")).mode & 0o777).toBe(0o600);
    expect(fs.statSync(context.path).mode & 0o777).toBe(0o700);
    expect(fs.readFileSync(join(context.path, "input.txt"))).toEqual(input);
    expect(fs.readFileSync(join(context.path, "metadata.json"))).toEqual(metadata);
    let fd = -1;
    const original = fs.closeSync;
    const spy = spyOn(fs, "closeSync").mockImplementation(value => { fd = value; original(value); });
    restores.push(() => spy.mockRestore());
    expect(journal.close()).toEqual({ kind: "closed" });
    expect(() => fs.fstatSync(fd)).toThrow();
    expect(journal.append(event)).toEqual({ kind: "failed", code: "CLOSED" });
    expect(journal.close()).toEqual({ kind: "failed", code: "CLOSED" });
    expect(bytes(context.path)).toEqual(saved);
  });

  it("keeps independent sequences and refuses both active and closed existing journals without adoption", () => {
    const a = receipt(), b = receipt("abcd1234"), one = open(a), two = open(b);
    expect(one.append(event)).toEqual({ kind: "durable", seq: 1 });
    expect(two.append(event)).toEqual({ kind: "durable", seq: 1 });
    const saved = bytes(a.path);
    expect(openSpeakEventJournal(a)).toEqual({ kind: "failed", code: "EXISTS" });
    one.close();
    expect(openSpeakEventJournal(a)).toEqual({ kind: "failed", code: "EXISTS" });
    expect(bytes(a.path)).toEqual(saved);
  });

  it("validates serialization and clock inputs before consuming a sequence and ignores transport extras", () => {
    const context = receipt(), journal = open(context);
    for (const changed of [{ generation_id: 4 }, { playback_id: undefined }, { elapsed_ms: NaN },
      { clock_id: "clock", elapsed_ms: null }, { clock_id: "clock", elapsed_ms: -1 },
      { utc: "2026-02-30T00:00:00.000Z" }, { chunk_id: "\ud800" }, { event: "unknown" },
      { data: { request_source: "secret-text" } }]) {
      const external = JSON.parse(JSON.stringify(event));
      Object.assign(external, changed);
      expect(journal.append(external)).toEqual({ kind: "failed", code: "INVALID_INPUT" });
    }
    const data = { request_source: "selection", secret: request.input, toJSON() { throw new Error("must not serialize transport"); } };
    expect(journal.append({ ...event, data: { ...data, request_source: "selection" } })).toEqual({ kind: "durable", seq: 1 });
    expect(bytes(context.path).toString("utf8")).not.toContain(request.input);
  });

  it("rejects forged identities, outside-root paths, aliases and lost isolation before creating a journal", () => {
    const context = receipt();
    for (const forged of [{ ...context, path: previous }, { ...context, id: "../escape" },
      { ...context, metadata: { ...context.metadata, request_id: "foreign" } }]) {
      expect(openSpeakEventJournal(forged).kind).toBe("failed");
    }
    process.env.QA_VOICE_RECORDINGS_DIR = root + "/../alias";
    expect(openSpeakEventJournal(context).kind).toBe("failed");
    process.env.QA_VOICE_RECORDINGS_DIR = " ";
    expect(openSpeakEventJournal(context).kind).toBe("failed");
    expect(fs.readdirSync(context.path).sort()).toEqual(["input.txt", "metadata.json"]);
  });

  for (const component of ["root", "day", "entry", "metadata.json", "input.txt", "events.ndjson"]) {
    it(`refuses a symlink ${component} without touching its target`, () => {
      const context = receipt();
      const target = join(root, "target");
      fs.writeFileSync(target, "keep", { mode: 0o600 });
      if (component === "root") {
        const alias = join(root, "alias"); fs.symlinkSync(root, alias);
        process.env.QA_VOICE_RECORDINGS_DIR = alias;
        expect(openSpeakEventJournal({ ...context, path: join(alias, "2026-10-23", context.id) }).kind).toBe("failed");
      } else {
        const path = component === "day" ? join(root, "2026-10-23") : component === "entry" ? context.path : join(context.path, component);
        if (fs.existsSync(path)) fs.renameSync(path, path + ".owned-old");
        fs.symlinkSync(target, path);
        expect(openSpeakEventJournal(context).kind).toBe("failed");
      }
      expect(fs.readFileSync(target, "utf8")).toBe("keep");
    });
  }

  it("refuses unsafe modes and a changed entry inode without repair or further appends", () => {
    const context = receipt();
    fs.chmodSync(context.path, 0o750);
    expect(openSpeakEventJournal(context).kind).toBe("failed");
    expect(fs.statSync(context.path).mode & 0o777).toBe(0o750);
    fs.chmodSync(context.path, 0o700);
    const journal = open(context);
    fs.renameSync(context.path, context.path + ".owned-old");
    fs.mkdirSync(context.path, { mode: 0o700 });
    expect(journal.append(event)).toEqual({ kind: "failed", code: "UNSAFE_PATH" });
    expect(journal.append(event)).toEqual({ kind: "failed", code: "POISONED" });
    expect(bytes(context.path + ".owned-old")).toEqual(Buffer.alloc(0));
    expect(fs.readdirSync(context.path)).toEqual([]);
  });

  it("refuses hardlinked receipt files and preserves a failed fresh-open journal while closing its FD", () => {
    const context = receipt(), input = join(context.path, "input.txt");
    fs.linkSync(input, join(root, "owned-link"));
    expect(openSpeakEventJournal(context).kind).toBe("failed");
    expect(fs.readFileSync(input, "utf8")).toBe(request.input);
    fs.unlinkSync(join(root, "owned-link"));
    let fd = -1;
    const spy = spyOn(fs, "fsyncSync").mockImplementation(value => { fd = value; throw new Error(request.input); });
    restores.push(() => spy.mockRestore());
    expect(openSpeakEventJournal(context)).toEqual({ kind: "failed", code: "IO_ERROR" });
    expect(() => fs.fstatSync(fd)).toThrow();
    expect(bytes(context.path)).toEqual(Buffer.alloc(0));
    expect(openSpeakEventJournal(context)).toEqual({ kind: "failed", code: "EXISTS" });
  });

  it("fails closed when call-time isolation disappears after open", () => {
    const context = receipt(), journal = open(context);
    process.env.QA_VOICE_RECORDINGS_DIR = " ";
    expect(journal.append(event)).toEqual({ kind: "failed", code: "UNSAFE_PATH" });
    expect(journal.append(event)).toEqual({ kind: "failed", code: "POISONED" });
    expect(bytes(context.path)).toEqual(Buffer.alloc(0));
    expect(journal.close()).toEqual({ kind: "closed" });
  });

  it("reports an uncertain close safely and never retries the consumed descriptor", () => {
    const journal = open(receipt()), original = fs.closeSync;
    let calls = 0;
    const spy = spyOn(fs, "closeSync").mockImplementation(fd => { calls++; original(fd); throw new Error(request.input); });
    restores.push(() => spy.mockRestore());
    expect(journal.close()).toEqual({ kind: "failed", code: "CLOSE_UNCERTAIN" });
    expect(journal.close()).toEqual({ kind: "failed", code: "CLOSED" });
    expect(calls).toBe(1);
  });

  for (const fault of ["short", "partial", "zero", "sync"]) {
    it(`handles ${fault} writes with exact retained bytes and honest durability`, () => {
      const context = receipt(), journal = open(context);
      journal.append(event);
      const prefix = bytes(context.path), write = fs.writeSync;
      let calls = 0, writtenFD = -1, attempted = Buffer.alloc(0);
      const spy = fault === "sync" ? spyOn(fs, "fsyncSync").mockImplementation(fd => { writtenFD = fd; throw new Error(request.input); }) :
        spyOn(fs, "writeSync").mockImplementation((fd, data, offset, length, position) => {
          writtenFD = fd;
          if (typeof data === "string" || typeof offset !== "number" || typeof length !== "number") throw new Error("unexpected write form");
          if (calls++ === 0) attempted = Buffer.from(data.buffer, data.byteOffset, data.byteLength);
          if (fault === "partial" && calls > 1) throw new Error(request.input);
          return fault === "zero" ? 0 : write(fd, data, offset, Math.min(7, length), position);
        });
      restores.push(() => spy.mockRestore());
      const result = journal.append(event), saved = bytes(context.path);
      if (fault === "short") {
        expect(result).toEqual({ kind: "durable", seq: 2 });
        expect(saved).toEqual(Buffer.concat([prefix, attempted]));
      } else {
        expect(result).toEqual({ kind: "failed", code: fault === "sync" ? "SYNC_UNCERTAIN" : "WRITE_UNCERTAIN" });
        expect(journal.append(event)).toEqual({ kind: "failed", code: "POISONED" });
        expect(bytes(context.path)).toEqual(saved);
        if (fault !== "sync") expect(saved).toEqual(Buffer.concat([prefix, attempted.subarray(0, fault === "zero" ? 0 : 7)]));
        else expect(saved.toString("utf8").trimEnd().split("\n")).toHaveLength(2);
        expect(JSON.stringify(result)).not.toContain(request.input);
        expect(journal.close()).toEqual({ kind: "closed" });
        expect(() => fs.fstatSync(writtenFD)).toThrow();
      }
      expect(saved.subarray(0, prefix.length)).toEqual(prefix);
    });
  }
});
