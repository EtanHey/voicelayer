import * as fs from "fs";
import { isAbsolute, join, normalize, parse } from "path";
import type { SpeakReceiptResult, SpeakReceiptRequest } from "./speak-archive";
import { recordingsArchiveRoot } from "./recordings-archive-fs";

type Created = Extract<SpeakReceiptResult, { kind: "created" }>["context"];
type Lifecycle =
  | { event: "request_received"; data: { request_source: SpeakReceiptRequest["request_source"] } }
  | { event: "stop_requested"; data: { reason: "user" | "replacement" | "disconnect" } };
export type SpeakArchiveEvent = Lifecycle & {
  generation_id: string | null; playback_id: string | null; chunk_id: string | null;
  utc: string; clock_id: string | null; elapsed_ms: number | null;
};
export type SpeakArchiveEventRecord = SpeakArchiveEvent & { seq: number; request_id: string };
type Code = "INVALID_INPUT" | "UNSAFE_PATH" | "EXISTS" | "IO_ERROR" |
  "WRITE_UNCERTAIN" | "SYNC_UNCERTAIN" | "POISONED" | "CLOSED" | "BUSY" | "CLOSE_UNCERTAIN";
type Failure = { kind: "failed"; code: Code };
export interface SpeakEventJournal {
  append(event: SpeakArchiveEvent): { kind: "durable"; seq: number } | Failure;
  close(): { kind: "closed" } | Failure;
}
class Invalid extends Error { constructor(readonly code: Code) { super(code); } }
const failed = (code: Code): Failure => ({ kind: "failed", code });
function check(ok: boolean, code: Code = "INVALID_INPUT"): asserts ok {
  if (!ok) throw new Invalid(code);
}
function boundedId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= 256 &&
    Buffer.from(value, "utf8").toString("utf8") === value && !/[\u0000-\u001f]/.test(value);
}
function utc(value: unknown): value is string {
  return typeof value === "string" && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/.test(value) &&
    new Date(value).toISOString() === value;
}
function same(a: fs.Stats, b: fs.Stats): boolean { return a.dev === b.dev && a.ino === b.ino; }
function privateStat(s: fs.Stats, directory: boolean): void {
  check((directory ? s.isDirectory() : s.isFile()) && !s.isSymbolicLink() &&
    s.uid === process.getuid?.() && (s.mode & 0o7777) === (directory ? 0o700 : 0o600) &&
    (directory || s.nlink === 1), "UNSAFE_PATH");
}
function directories(root: string, entry: string) {
  check(isAbsolute(root) && normalize(root) === root && !root.endsWith("/"), "UNSAFE_PATH");
  let path = parse(entry).root;
  return entry.slice(path.length).split("/").map(component => {
    path = join(path, component);
    const stat = fs.lstatSync(path);
    check(stat.isDirectory() && !stat.isSymbolicLink(), "UNSAFE_PATH");
    if (path === root || path.startsWith(root + "/")) privateStat(stat, true);
    return { path, stat };
  });
}
function readPrivate(path: string): Buffer {
  const before = fs.lstatSync(path);
  privateStat(before, false);
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try {
    check(same(before, fs.fstatSync(fd)), "UNSAFE_PATH");
    return fs.readFileSync(fd);
  } finally { fs.closeSync(fd); }
}
function envelope(input: SpeakArchiveEvent, request_id: string, seq: number) {
  const { generation_id, playback_id, chunk_id, utc: at, clock_id, elapsed_ms, event, data } = input;
  check([generation_id, playback_id, chunk_id].every(id => id === null || boundedId(id)) && utc(at));
  check((clock_id === null && elapsed_ms === null) || (boundedId(clock_id) &&
    typeof elapsed_ms === "number" && Number.isFinite(elapsed_ms) &&
    elapsed_ms >= 0 && elapsed_ms <= Number.MAX_SAFE_INTEGER));
  let payload: Lifecycle;
  if (event === "request_received") {
    const request_source = data.request_source;
    check(["voice_speak", "selection", "clipboard", "cli", "preview", "ask_prompt", "direct"].includes(request_source));
    payload = { event, data: { request_source } };
  } else {
    check(event === "stop_requested");
    const reason = data.reason;
    check(reason === "user" || reason === "replacement" || reason === "disconnect");
    payload = { event, data: { reason } };
  }
  const record: SpeakArchiveEventRecord = { seq, request_id, generation_id, playback_id, chunk_id,
    utc: at, clock_id, elapsed_ms, ...payload };
  return Buffer.from(JSON.stringify(record) + "\n", "utf8");
}

/** Fresh journals only. No adoption, recovery, metadata publication or unconditional crash atomicity. */
export function openSpeakEventJournal(context: Created):
  { kind: "opened"; journal: SpeakEventJournal } | Failure {
  let fd: number | undefined;
  try {
    const { id, path: entry, metadata } = context;
    const { request_id, created_at } = metadata;
    // Creation owns request_id's unrestricted string domain; preserve it verbatim.
    check(typeof request_id === "string" && utc(created_at) &&
      /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/.test(id));
    const root = recordingsArchiveRoot(); // Resolve again for every append; isolation cannot be lost.
    check(entry === join(root, created_at.slice(0, 10), id) &&
      id.slice(0, 24) === created_at.replace(/[:.]/g, "-"), "UNSAFE_PATH");
    const pinned = directories(root, entry);
    const raw = readPrivate(join(entry, "metadata.json"));
    const disk: unknown = JSON.parse(raw.toString("utf8"));
    check(typeof disk === "object" && disk !== null && "source" in disk && disk.source === "speak" &&
      "schema_version" in disk && disk.schema_version === 1 && "status" in disk && disk.status === "received" &&
      "id" in disk && disk.id === id && "request_id" in disk && disk.request_id === request_id &&
      "created_at" in disk && disk.created_at === created_at, "UNSAFE_PATH");
    check(raw.equals(Buffer.from(JSON.stringify(metadata, null, 2) + "\n")), "UNSAFE_PATH");
    privateStat(fs.lstatSync(join(entry, "input.txt")), false);
    for (const name of ["audio.wav", "voicelayer-transcript.txt"]) {
      try { fs.lstatSync(join(entry, name)); throw new Invalid("UNSAFE_PATH"); }
      catch (error) { if (!(typeof error === "object" && error !== null && "code" in error && error.code === "ENOENT")) throw error; }
    }
    const path = join(entry, "events.ndjson");
    const validate = () => {
      check(recordingsArchiveRoot() === root, "UNSAFE_PATH");
      const current = directories(root, entry);
      check(current.every((item, i) => same(item.stat, pinned[i]!.stat)), "UNSAFE_PATH");
    };
    validate();
    fd = fs.openSync(path, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL |
      fs.constants.O_NOFOLLOW | fs.constants.O_APPEND, 0o600);
    const owned = fs.fstatSync(fd);
    privateStat(owned, false);
    check(owned.size === 0 && same(owned, fs.lstatSync(path)), "UNSAFE_PATH");
    fs.fsyncSync(fd);
    const dir = fs.openSync(entry, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_DIRECTORY);
    try {
      check(same(fs.fstatSync(dir), pinned[pinned.length - 1]!.stat), "UNSAFE_PATH");
      fs.fsyncSync(dir);
    } finally { fs.closeSync(dir); }
    validate();
    const journalFD = fd;
    let state: "open" | "busy" | "poisoned" | "closed" = "open";
    let seq = 0, bytes = 0;
    const journal: SpeakEventJournal = Object.freeze({
      append(input: SpeakArchiveEvent): ReturnType<SpeakEventJournal["append"]> {
        if (state !== "open") return failed(state === "closed" ? "CLOSED" : state === "busy" ? "BUSY" : "POISONED");
        state = "busy";
        let encoded: Buffer;
        try { check(Number.isSafeInteger(seq + 1)); encoded = envelope(input, request_id, seq + 1); }
        catch { state = "open"; return failed("INVALID_INPUT"); }
        let code: Code = "UNSAFE_PATH";
        try {
          validate();
          const current = fs.fstatSync(journalFD), named = fs.lstatSync(path);
          privateStat(current, false); privateStat(named, false);
          check(same(current, owned) && same(current, named) && current.size === bytes, "UNSAFE_PATH");
          code = "WRITE_UNCERTAIN";
          for (let offset = 0; offset < encoded.length;) {
            const n = fs.writeSync(journalFD, encoded, offset, encoded.length - offset, null);
            check(Number.isInteger(n) && n > 0 && n <= encoded.length - offset, "WRITE_UNCERTAIN");
            offset += n;
          }
          code = "SYNC_UNCERTAIN";
          fs.fsyncSync(journalFD);
          seq++; bytes += encoded.length; state = "open";
          return { kind: "durable", seq };
        } catch { state = "poisoned"; return failed(code); }
      },
      close(): ReturnType<SpeakEventJournal["close"]> {
        if (state === "busy") return failed("BUSY");
        if (state === "closed") return failed("CLOSED");
        state = "closed"; // Consume once even on an ambiguous close; never retry a recycled FD.
        try { fs.closeSync(journalFD); return { kind: "closed" }; }
        catch { return failed("CLOSE_UNCERTAIN"); }
      },
    });
    fd = undefined; // Ownership transfers only after all open-time validation/syncs succeed.
    return { kind: "opened", journal };
  } catch (error) {
    if (fd !== undefined) {
      try { fs.closeSync(fd); } catch { return failed("CLOSE_UNCERTAIN"); }
    }
    try {
      return failed(error instanceof Invalid ? error.code :
        typeof error === "object" && error !== null && "code" in error && error.code === "EEXIST" ? "EXISTS" : "IO_ERROR");
    } catch {
      return failed("IO_ERROR");
    }
  }
}
