import * as fs from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { archiveId, recordingsArchiveRoot } from "./recordings-archive-fs";

type CaptureInput = {
  generation: number;
  format: { sampleRate: number; channels: number; encoding: "s16le"; provenance: "requested" | "recorder" };
};
type SpoolIO = {
  id: () => string;
  open: (path: string, flags: string | number, mode?: number) => number;
  write: (fd: number, bytes: Uint8Array, offset: number, length: number, position: number) => number;
  read: (fd: number) => Buffer;
  close: (fd: number) => void;
};
type Diagnostic = { stage: "setup" | "append" | "verify" | "close"; cause: unknown };
type ClosureStatus = "closed" | "unconfirmed";
type RawBytes =
  | { kind: "verified"; path: string; verifiedBytes: number; sha256: string }
  | { kind: "unavailable"; verifiedBytes: null };
type Terminal = CaptureInput & {
  observedBytes: number; writtenBytes: number; raw: RawBytes;
  fault: boolean; closureStatus: ClosureStatus; errors: readonly Diagnostic[];
};
type Observation = {
  observedBytes: number; writtenBytes: number; appendFault: boolean; fault: boolean;
} & (
  | { writerPhase: "owned-open"; closureStatus: "owned-open" | "unconfirmed" }
  | { writerPhase: "terminal"; closureStatus: ClosureStatus }
);
type Snapshot = CaptureInput & Extract<Observation, { writerPhase: "owned-open" }> & {
  raw: RawBytes; temporaryReaderClosureStatus: ClosureStatus | "not-opened"; errors: readonly Diagnostic[];
};
type Spool = {
  readonly path: string; appendNative: (chunk: Uint8Array) => void; close: () => Terminal;
  observe: () => Observation; checkpointEvidence: () => Snapshot;
};
type OpenResult =
  | { kind: "opened"; spool: Spool }
  | { kind: "unavailable"; closureStatus: ClosureStatus; errors: readonly Diagnostic[] };

function check(ok: boolean): asserts ok {
  if (!ok) throw new Error("conversation spool ownership or byte verification failed");
}
function privateNode(stat: fs.Stats, directory: boolean): void {
  check((directory ? stat.isDirectory() : stat.isFile()) && !stat.isSymbolicLink() &&
    stat.uid === process.getuid?.() && (stat.mode & 0o777) === (directory ? 0o700 : 0o600));
}
const sameFile = (a: fs.Stats, b: fs.Stats) => a.dev === b.dev && a.ino === b.ino;
const unchanged = (a: fs.Stats, b: fs.Stats) => sameFile(a, b) && a.size === b.size &&
  a.ctimeMs === b.ctimeMs && a.mtimeMs === b.mtimeMs && a.mode === b.mode && a.nlink === b.nlink;

/** Inert native-byte owner. Terminal facts confer no durability, capture completeness or release authority. */
export function createConversationSpool(input: CaptureInput, testIO: Partial<SpoolIO> = {}): OpenResult {
  if (Object.keys(testIO).length && process.env.VOICELAYER_TEST_ISOLATED !== "1") {
    throw new Error("conversation spool test seams require isolated preload");
  }
  const io: SpoolIO = {
    id: () => archiveId(new Date()), open: fs.openSync,
    write: (fd, bytes, offset, length, position) => fs.writeSync(fd, bytes, offset, length, position),
    read: fd => fs.readFileSync(fd), close: fs.closeSync, ...testIO,
  };
  const errors: Diagnostic[] = [];
  let closureStatus: ClosureStatus = "closed";
  function closeFd(fd: number): ClosureStatus {
    // A failed close relinquishes authority, even when the same fd/inode appears unchanged.
    try { io.close(fd); return "closed"; } catch (cause) {
      closureStatus = "unconfirmed";
      errors.push({ stage: "close", cause });
      return "unconfirmed";
    }
  }
  let writer: number | undefined;
  let path: string, directory: string, fileIdentity: fs.Stats, directoryIdentity: fs.Stats;
  const metadata = { generation: input.generation, format: { ...input.format } };
  try {
    check(Number.isSafeInteger(input.generation) && input.generation >= 0 &&
      Number.isSafeInteger(input.format.sampleRate) && input.format.sampleRate > 0 &&
      Number.isSafeInteger(input.format.channels) && input.format.channels > 0);
    const root = recordingsArchiveRoot();
    fs.mkdirSync(root, { recursive: true, mode: 0o700 });
    privateNode(fs.lstatSync(root), true);
    const parent = join(root, ".conversation-captures");
    fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
    privateNode(fs.lstatSync(parent), true);
    const id = io.id();
    check(/^[\dTZ-]+-[a-f0-9]{8}$/.test(id));
    directory = join(parent, id);
    fs.mkdirSync(directory, { mode: 0o700 });
    directoryIdentity = fs.lstatSync(directory);
    privateNode(directoryIdentity, true);
    path = join(directory, "native.pcm");
    writer = io.open(path, "wx", 0o600);
    fileIdentity = fs.fstatSync(writer);
    privateNode(fileIdentity, false);
    check(fileIdentity.nlink === 1 && fileIdentity.size === 0 && sameFile(fileIdentity, fs.lstatSync(path)));
  } catch (cause) {
    errors.push({ stage: "setup", cause });
    if (writer !== undefined) closeFd(writer);
    return { kind: "unavailable", closureStatus, errors };
  }
  const ownedWriter = writer;
  const expected = createHash("sha256");
  let observedBytes = 0, writtenBytes = 0, appendFault = false, terminal = false;
  let result: Terminal | undefined;
  function appendNative(chunk: Uint8Array): void {
    if (terminal) throw new Error("conversation spool is terminal");
    observedBytes += chunk.byteLength;
    if (appendFault || chunk.byteLength === 0) return;
    try {
      const copy = Buffer.from(chunk);
      let offset = 0;
      while (offset < copy.length) {
        const count = io.write(ownedWriter, copy, offset, copy.length - offset, writtenBytes);
        check(Number.isSafeInteger(count) && count > 0 && count <= copy.length - offset);
        expected.update(copy.subarray(offset, offset + count));
        writtenBytes += count;
        offset += count;
      }
    } catch (cause) {
      appendFault = true;
      errors.push({ stage: "append", cause });
    }
  }
  let temporaryReaderClosureStatus: Snapshot["temporaryReaderClosureStatus"] = "not-opened";
  function verify(): RawBytes {
    temporaryReaderClosureStatus = "not-opened";
    let reader: number | undefined;
    try {
      check(writtenBytes > 0 || observedBytes === 0);
      const dirBefore = fs.lstatSync(directory);
      privateNode(dirBefore, true);
      check(sameFile(dirBefore, directoryIdentity));
      const before = fs.fstatSync(ownedWriter);
      privateNode(before, false);
      check(sameFile(before, fileIdentity) && before.nlink === 1 && before.size === writtenBytes);
      check(unchanged(before, fs.lstatSync(path)));
      reader = io.open(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      check(unchanged(before, fs.fstatSync(reader)));
      const bytes = io.read(reader);
      const sha256 = createHash("sha256").update(bytes).digest("hex");
      check(bytes.length === writtenBytes && sha256 === expected.copy().digest("hex"));
      check(unchanged(before, fs.fstatSync(reader)) && unchanged(before, fs.fstatSync(ownedWriter)) &&
        unchanged(before, fs.lstatSync(path)) && sameFile(directoryIdentity, fs.lstatSync(directory)));
      return { kind: "verified", path, verifiedBytes: bytes.length, sha256 };
    } catch (cause) {
      errors.push({ stage: "verify", cause });
      return { kind: "unavailable", verifiedBytes: null };
    } finally {
      if (reader !== undefined) temporaryReaderClosureStatus = closeFd(reader);
    }
  }
  /** Constant-cost observation only: no I/O, verified pointer, completion or release authority. */
  function observe(): Observation {
    const counts = { observedBytes, writtenBytes, appendFault, fault: errors.length > 0 };
    return terminal ? { ...counts, writerPhase: "terminal", closureStatus } : {
      ...counts, writerPhase: "owned-open", closureStatus: closureStatus === "unconfirmed" ? "unconfirmed" : "owned-open",
    };
  }
  /** Independently reread the current prefix. Temporary reader closure never closes the writer. */
  function checkpointEvidence(): Snapshot {
    if (terminal) throw new Error("conversation spool is terminal");
    const raw = verify();
    const state = observe();
    check(state.writerPhase === "owned-open");
    return { ...metadata, format: { ...metadata.format }, ...state, raw,
      temporaryReaderClosureStatus, errors: errors.map(error => ({ ...error })) };
  }
  function close(): Terminal {
    if (result) return result;
    terminal = true;
    let raw: RawBytes;
    try { raw = verify(); } finally { closeFd(ownedWriter); }
    result = { ...metadata, observedBytes, writtenBytes, raw, fault: errors.length > 0, closureStatus, errors };
    return result;
  }
  return { kind: "opened", spool: { path, appendNative, close, observe, checkpointEvidence } };
}
