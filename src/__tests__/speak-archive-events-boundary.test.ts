import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import * as fs from "fs";
import { join, relative, resolve } from "path";
import { createSpeakReceipt, type SpeakReceiptRequest } from "../speak-archive";
import { openSpeakEventJournal, type SpeakArchiveEvent, type SpeakEventJournal } from "../speak-archive-events";

const request: SpeakReceiptRequest = {
  input: "  synthetic שלום e\u0301 🗣️\nfu… no, full  ", request_id: "synthetic-request",
  request_source: "selection", connection: "daemon", format: "plain", blocking: false,
  requested: { mode: null, profile: null, engine: null, voice: null, rate: null },
  build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
};
const event: SpeakArchiveEvent = {
  generation_id: null, playback_id: null, chunk_id: null,
  utc: "2026-10-23T12:34:56.789Z", clock_id: null, elapsed_ms: null,
  event: "request_received", data: { request_source: "selection" },
};
const marker = "synthetic-private-error-marker";
let root: string | undefined, originalRoot: string | undefined;
let journals: SpeakEventJournal[] = [];
function receipt(request_id = request.request_id) {
  const result = createSpeakReceipt({ ...request, request_id });
  if (result.kind !== "created") throw new Error("synthetic receipt failed");
  return result.context;
}
function open(context: ReturnType<typeof receipt>) {
  const result = openSpeakEventJournal(context);
  if (result.kind !== "opened") throw new Error("synthetic journal failed");
  journals.push(result.journal);
  return result.journal;
}

describe("speak journal creation identity and open-error boundaries", () => {
  beforeEach(() => {
    const run = process.env.VOICELAYER_TEST_RUN_ROOT, archive = process.env.QA_VOICE_RECORDINGS_DIR;
    if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !run || !archive ||
      relative(resolve(run), resolve(archive)).startsWith("..") || resolve(run) === resolve(archive)) {
      throw new Error("canonical isolated preload required");
    }
    originalRoot = archive;
    root = fs.mkdtempSync(join(archive, "speak-event-boundary-"));
    process.env.QA_VOICE_RECORDINGS_DIR = root;
  });
  afterEach(() => {
    for (const journal of journals) journal.close();
    journals = [];
    if (originalRoot !== undefined) process.env.QA_VOICE_RECORDINGS_DIR = originalRoot;
    if (root !== undefined) fs.rmSync(root, { recursive: true, force: true });
    root = undefined;
    originalRoot = undefined;
  });

  for (const { name, requestId } of [
    { name: "257-character ASCII", requestId: "r".repeat(257) },
    { name: "empty", requestId: "" },
    { name: "control-containing", requestId: "\u0000\t\n\r\u001b" },
    { name: "Unicode", requestId: "שלום e\u0301 🗣️" },
    { name: "unpaired-surrogate", requestId: "\ud800" },
  ]) {
    it(`preserves a real created ${name} request ID exactly through append`, () => {
      const context = receipt(requestId);
      const input = fs.readFileSync(join(context.path, "input.txt"));
      const metadata = fs.readFileSync(join(context.path, "metadata.json"));
      expect(context.metadata.request_id).toBe(requestId);
      expect(JSON.parse(metadata.toString("utf8")).request_id).toBe(requestId);
      const journal = open(context);
      expect(journal.append(event)).toEqual({ kind: "durable", seq: 1 });
      const lines = fs.readFileSync(join(context.path, "events.ndjson"), "utf8").split("\n");
      expect(lines).toHaveLength(2);
      expect(lines[1]).toBe("");
      expect(JSON.parse(lines[0]!).request_id).toBe(requestId);
      expect(fs.readFileSync(join(context.path, "input.txt"))).toEqual(input);
      expect(fs.readFileSync(join(context.path, "metadata.json"))).toEqual(metadata);
      expect(journal.close()).toEqual({ kind: "closed" });
    });
  }

  it("keeps new optional event and clock IDs bounded independently of inherited request identity", () => {
    const context = receipt("r".repeat(257)), journal = open(context);
    const path = join(context.path, "events.ndjson");
    for (const field of ["generation_id", "playback_id", "chunk_id", "clock_id"]) {
      for (const invalid of ["r".repeat(257), "", "\n", "\ud800"]) {
        expect(journal.append({ ...event, [field]: invalid,
          elapsed_ms: field === "clock_id" ? 0 : null })).toEqual({ kind: "failed", code: "INVALID_INPUT" });
        expect(fs.readFileSync(path)).toEqual(Buffer.alloc(0));
      }
    }
    expect(journal.append({ ...event, generation_id: "g-שלום", clock_id: "fixture-clock", elapsed_ms: 0 }))
      .toEqual({ kind: "durable", seq: 1 });
  });

  for (const { name, thrown } of [
    { name: "throwing code getter", thrown: () => Object.defineProperty({}, "code", {
      get() { throw new Error(marker); },
    }) },
    { name: "throwing Proxy has trap", thrown: () => new Proxy({}, {
      has() { throw new Error(marker); },
    }) },
    { name: "throwing Proxy prototype trap", thrown: () => new Proxy({}, {
      getPrototypeOf() { throw new Error(marker); },
    }) },
  ]) {
    it(`contains a ${name} in a fixed open failure without journal writes`, () => {
      const context = receipt(), entry = context.path, exception = thrown();
      const input = fs.readFileSync(join(entry, "input.txt"));
      const metadata = fs.readFileSync(join(entry, "metadata.json"));
      Object.defineProperty(context, "metadata", { get() { throw exception; } });
      let result: ReturnType<typeof openSpeakEventJournal> | undefined;
      expect(() => { result = openSpeakEventJournal(context); }).not.toThrow();
      expect(result).toEqual({ kind: "failed", code: "IO_ERROR" });
      expect(JSON.stringify(result)).not.toContain(marker);
      expect(fs.readdirSync(entry).sort()).toEqual(["input.txt", "metadata.json"]);
      expect(fs.readFileSync(join(entry, "input.txt"))).toEqual(input);
      expect(fs.readFileSync(join(entry, "metadata.json"))).toEqual(metadata);
    });
  }

  it("preserves genuine existing-journal EXISTS classification and prior bytes", () => {
    const context = receipt(), journal = open(context);
    expect(journal.append(event)).toEqual({ kind: "durable", seq: 1 });
    const path = join(context.path, "events.ndjson"), prior = fs.readFileSync(path);
    expect(openSpeakEventJournal(context)).toEqual({ kind: "failed", code: "EXISTS" });
    expect(fs.readFileSync(path)).toEqual(prior);
    expect(journal.close()).toEqual({ kind: "closed" });
    expect(openSpeakEventJournal(context)).toEqual({ kind: "failed", code: "EXISTS" });
    expect(fs.readFileSync(path)).toEqual(prior);
  });
});
