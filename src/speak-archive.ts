import { createHash } from "crypto";
import * as fs from "fs";
import { dirname, isAbsolute, join, normalize, parse } from "path";
import { archiveId, recordingsArchiveRoot } from "./recordings-archive-fs";

export interface SpeakReceiptRequest {
  input: string;
  request_id: string;
  request_source: "voice_speak" | "selection" | "clipboard" | "cli" | "preview" | "ask_prompt" | "direct";
  connection: "stdio" | "daemon" | "cli_local" | null;
  format: "plain" | "markdown" | null;
  blocking: boolean | null;
  requested: {
    mode: string | null;
    profile: string | null;
    engine: string | null;
    voice: string | null;
    rate: number | null;
  };
  build: {
    app_version: string | null;
    daemon_version: string | null;
    git_sha: string | null;
    executable_hash: string | null;
  };
}

export interface SpeakReceivedMetadata {
  schema_version: 1;
  source: "speak";
  id: string;
  created_at: string;
  updated_at: string;
  request_id: string;
  request_source: SpeakReceiptRequest["request_source"];
  connection: SpeakReceiptRequest["connection"];
  format: SpeakReceiptRequest["format"];
  blocking: SpeakReceiptRequest["blocking"];
  requested: SpeakReceiptRequest["requested"];
  build: SpeakReceiptRequest["build"];
  status: "received";
  input: { bytes: number; sha256: string };
  generation_id: null;
}

type Identity = { id: string; path: string };
type Stage = "validate" | "allocate" | "input" | "metadata";
type FailureCode = "INVALID_INPUT" | "UNSAFE_PATH" | "COLLISION" | "IO_ERROR";
export type SpeakReceiptResult =
  | { kind: "created"; context: Identity & { metadata: SpeakReceivedMetadata } }
  | { kind: "failed"; stage: Stage; code: FailureCode; partial: Identity | null };

class ReceiptFailure extends Error {
  constructor(readonly code: FailureCode) { super(code); }
}

function hasCode(error: unknown, code: string): boolean {
  return typeof error === "object" && error !== null && "code" in error && error.code === code;
}

// Unlike the shared best-effort fsyncPath, every open/sync/close error fails creation.
function syncDirectory(path: string): void {
  const fd = fs.openSync(path, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
  try { fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
}

function privateDirectory(path: string): void {
  const stat = fs.lstatSync(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || (stat.mode & 0o077) !== 0 ||
      stat.uid !== process.getuid?.()) throw new ReceiptFailure("UNSAFE_PATH");
}

// Inspect each component before descent; never canonicalize an alias into acceptance.
// Existing shared ancestor permissions are not changed. The archive root/day must be private.
function prepareRoot(root: string): void {
  if (!isAbsolute(root) || normalize(root) !== root || root === parse(root).root) {
    throw new ReceiptFailure("UNSAFE_PATH");
  }
  let current = parse(root).root;
  for (const component of root.slice(current.length).split("/")) {
    current = join(current, component);
    try {
      const stat = fs.lstatSync(current);
      if (!stat.isDirectory() || stat.isSymbolicLink()) throw new ReceiptFailure("UNSAFE_PATH");
    } catch (error) {
      if (!hasCode(error, "ENOENT")) throw error;
      fs.mkdirSync(current, { mode: 0o700 });
      syncDirectory(current);
      syncDirectory(dirname(current));
    }
  }
  privateDirectory(root);
  syncDirectory(root);
  syncDirectory(dirname(root));
}

function prepareDay(path: string): void {
  try { fs.mkdirSync(path, { mode: 0o700 }); }
  catch (error) { if (!hasCode(error, "EEXIST")) throw error; }
  privateDirectory(path);
  syncDirectory(path);
  syncDirectory(dirname(path));
}

// Shared atomicWriteFile deletes failed temporary writes and swallows directory sync
// failures. Creation instead keeps its exclusively owned temp evidence for later recovery.
// The final directory is exclusive and these fixed filenames have no other writer.
function writeReceiptFile(entry: string, name: string, data: Uint8Array): void {
  privateDirectory(entry);
  const temporary = join(entry, `.${name}.received-partial`);
  const fd = fs.openSync(temporary,
    fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
  try {
    fs.writeFileSync(fd, data);
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  fs.renameSync(temporary, join(entry, name));
  syncDirectory(entry);
}

/** Creation only: no synthesis policy, artifacts, lifecycle updates or restart recovery.
 * Success means every requested sync returned, not unconditional power-loss proof.
 * Identity on failure names only our allocated final entry; never a collided entry.
 */
export function createSpeakReceipt(
  request: SpeakReceiptRequest,
  seams: { now?: () => Date; id?: (at: Date) => string } = {},
): SpeakReceiptResult {
  let stage: Stage = "validate";
  let partial: Identity | null = null;
  try {
    const at = (seams.now ?? (() => new Date()))();
    const timestamp = at.toISOString();
    const id = (seams.id ?? archiveId)(at);
    // Match the shared allocator shape; request identity/text never constructs a path.
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/.test(id)) {
      throw new ReceiptFailure("UNSAFE_PATH");
    }
    const input = Buffer.from(request.input, "utf8");
    if (input.toString("utf8") !== request.input) throw new ReceiptFailure("INVALID_INPUT");
    const metadata: SpeakReceivedMetadata = {
      schema_version: 1, source: "speak", id, created_at: timestamp, updated_at: timestamp,
      request_id: request.request_id, request_source: request.request_source,
      connection: request.connection, format: request.format, blocking: request.blocking,
      requested: {
        mode: request.requested.mode, profile: request.requested.profile,
        engine: request.requested.engine, voice: request.requested.voice, rate: request.requested.rate,
      },
      build: {
        app_version: request.build.app_version, daemon_version: request.build.daemon_version,
        git_sha: request.build.git_sha, executable_hash: request.build.executable_hash,
      },
      status: "received", generation_id: null,
      input: { bytes: input.byteLength, sha256: createHash("sha256").update(input).digest("hex") },
    };
    // Serialize the allowlisted context before allocating any directory.
    const encoded = Buffer.from(JSON.stringify(metadata, null, 2) + "\n", "utf8");
    stage = "allocate";
    const root = recordingsArchiveRoot(); // Call-time isolation checks remain authoritative.
    prepareRoot(root);
    const day = join(root, timestamp.slice(0, 10));
    prepareDay(day);
    const path = join(day, id);
    try { fs.mkdirSync(path, { mode: 0o700 }); }
    catch (error) {
      if (hasCode(error, "EEXIST")) throw new ReceiptFailure("COLLISION");
      throw error;
    }
    partial = { id, path };
    privateDirectory(path);
    syncDirectory(path);
    syncDirectory(day); // Persist final entry identity before file publication.
    stage = "input";
    writeReceiptFile(path, "input.txt", input);
    stage = "metadata"; // A received receipt is published only after the exact input syncs.
    writeReceiptFile(path, "metadata.json", encoded);
    return { kind: "created", context: { ...partial, metadata } };
  } catch (error) {
    // Never return/log the raw filesystem exception, request text or transport object.
    return { kind: "failed", stage,
      code: error instanceof ReceiptFailure ? error.code : "IO_ERROR", partial };
  }
}
