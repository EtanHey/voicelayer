import { randomUUID } from "node:crypto";
import { closeSync, lstatSync, openSync } from "node:fs";
import { join } from "node:path";
import { Database } from "bun:sqlite";
import { z } from "zod";
import { getStateDir } from "./paths";
import { readProcessStartUs } from "./process-lock";
import { readUpdateGate } from "./update-gate";

const ownerSchema = z.strictObject({ daemonId: z.uuid(), pid: z.number().int().positive(), startUs: z.number().int().positive() });
type Owner = z.infer<typeof ownerSchema>;
type BootstrapResult = { kind: "READY"; daemonId: string } | { kind: "REFUSED"; reason: string };

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

export function bootstrapUpdateGate(path = join(getStateDir(), "update-admission.sqlite")): BootstrapResult {
  let db: Database | undefined;
  try {
    const startUs = readProcessStartUs(process.pid);
    if (startUs === null) throw new Error("UNKNOWN daemon kernel start identity");
    let created = false;
    try {
      closeSync(openSync(path, "wx", 0o600));
      created = true;
    } catch (error) {
      if (!(error instanceof Error && "code" in error && error.code === "EEXIST")) throw error;
    }
    if (!lstatSync(path).isFile()) throw new Error("UNKNOWN gate is not a regular file");
    db = new Database(path, { readwrite: true, create: false });
    db.exec("PRAGMA busy_timeout=1000; PRAGMA synchronous=FULL");
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
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return { kind: "REFUSED", reason: `Update gate UNKNOWN/refused (${detail}); recovery required: inspect ${path}, reconcile the pending update and unfinished archives before reopening. Preserve this state.` };
  } finally { db?.close(); }
}
