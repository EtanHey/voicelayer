import { randomUUID } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, openSync, renameSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { Database } from "bun:sqlite";
import { dlopen, FFIType } from "bun:ffi";
import { z } from "zod";
import { getStateDir } from "./paths";
import { readProcessStartUs } from "./process-lock";
import { readUpdateGate } from "./update-gate";

const ownerSchema = z.strictObject({ daemonId: z.uuid(), pid: z.number().int().positive(), startUs: z.number().int().positive() });
type Owner = z.infer<typeof ownerSchema>;
type BootstrapResult = { kind: "READY"; daemonId: string } | { kind: "REFUSED"; reason: string };
const LOCK_EX_NONBLOCKING = 2 | 4;

function ownerStatus(owner: Owner): "LIVE" | "DEAD" | "UNKNOWN" {
  const startUs = readProcessStartUs(owner.pid);
  if (startUs !== null) return startUs === owner.startUs ? "LIVE" : "DEAD";
  try { process.kill(owner.pid, 0); }
  catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ESRCH") return "DEAD";
  }
  return "UNKNOWN";
}

function persistedState(db: Database) {
  const row = db.query<{ state: string }, []>("SELECT state FROM gate WHERE id=1").get();
  return readUpdateGate(row ? JSON.parse(row.state) : undefined);
}

function persistedOwner(db: Database) {
  const row = db.query<{ owner: string }, []>("SELECT owner FROM gate_owner WHERE id=1").get();
  return ownerSchema.parse(row ? JSON.parse(row.owner) : undefined);
}

export function readTrustedUpdateGate(db: Database, expectedDaemonId?: string): ReturnType<typeof readUpdateGate> {
  try {
    const state = persistedState(db);
    if (state.kind !== "OPEN") return state;
    const owner = persistedOwner(db);
    if (expectedDaemonId !== undefined && owner.daemonId !== expectedDaemonId) return { kind: "UNKNOWN" };
    return ownerStatus(owner) === "LIVE" ? state : { kind: "UNKNOWN" };
  } catch { return { kind: "UNKNOWN" }; }
}

function claimGate(path: string, startUs: number, created = false): BootstrapResult {
  let db: Database | undefined;
  try {
    db = new Database(path, { readwrite: true, create: false });
    db.exec("PRAGMA busy_timeout=0; PRAGMA synchronous=FULL");
    const store = db;
    return store.transaction((): BootstrapResult => {
      if (created) {
        store.exec("CREATE TABLE gate (id INTEGER PRIMARY KEY CHECK(id=1), state TEXT NOT NULL); CREATE TABLE gate_owner (id INTEGER PRIMARY KEY CHECK(id=1), owner TEXT NOT NULL); CREATE TABLE admissions (id TEXT PRIMARY KEY, pid INTEGER NOT NULL)");
        store.query("INSERT INTO gate VALUES (1, ?)").run(JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
      }
      const state = persistedState(store);
      if (state.kind !== "OPEN") throw new Error(`gate ${state.kind}`);
      if (!created && ownerStatus(persistedOwner(store)) !== "DEAD") throw new Error("UNKNOWN gate already owned or owner identity unavailable");
      const admissions = store.query<{ count: number }, []>("SELECT count(*) AS count FROM admissions").get();
      if (!admissions || admissions.count !== 0) throw new Error("UNKNOWN unresolved operation admissions");
      const owner: Owner = { daemonId: randomUUID(), pid: process.pid, startUs };
      store.query("INSERT OR REPLACE INTO gate_owner VALUES (1, ?)").run(JSON.stringify(owner));
      return { kind: "READY", daemonId: owner.daemonId };
    }).immediate();
  } finally { db?.close(); }
}

function publishGate(path: string, startUs: number, directoryFd: number): BootstrapResult {
  const temporary = `${path}.${randomUUID()}.tmp`;
  let fd: number | undefined;
  try {
    fd = openSync(temporary, "wx", 0o600);
    const result = claimGate(temporary, startUs, true);
    fsyncSync(fd);
    closeSync(fd);
    fd = undefined;
    renameSync(temporary, path);
    fsyncSync(directoryFd);
    return result;
  } finally {
    if (fd !== undefined) closeSync(fd);
    rmSync(temporary, { force: true });
  }
}

export function bootstrapUpdateGate(path?: string): BootstrapResult {
  try {
    path ??= join(getStateDir(), "update-admission.sqlite");
    const startUs = readProcessStartUs(process.pid);
    if (startUs === null) throw new Error("UNKNOWN daemon kernel start identity");
    const directoryFd = openSync(dirname(path), "r");
    try {
      const library = dlopen("/usr/lib/libSystem.B.dylib", { flock: { args: [FFIType.i32, FFIType.i32], returns: FFIType.i32 } });
      try {
        if (library.symbols.flock(directoryFd, LOCK_EX_NONBLOCKING) !== 0) throw new Error("UNKNOWN bootstrap already in progress; retry after the other daemon settles");
        const existing = lstatSync(path, { throwIfNoEntry: false });
        if (existing && !existing.isFile()) throw new Error("UNKNOWN gate is not a regular file");
        if (!existing || existing.size === 0) {
          if (["-journal", "-wal", "-shm"].some(suffix => existsSync(`${path}${suffix}`))) throw new Error("UNKNOWN incomplete gate has recovery sidecars");
          if (existing) closeSync(openSync(path, "r+"));
          return publishGate(path, startUs, directoryFd);
        }
        return claimGate(path, startUs);
      } finally { library.close(); }
    } finally { closeSync(directoryFd); }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return { kind: "REFUSED", reason: `Update gate UNKNOWN/refused (${detail}); recovery required: inspect ${path ?? "the configured VoiceLayer state directory"}, reconcile the pending update and unfinished archives before reopening. Preserve this state.` };
  }
}
