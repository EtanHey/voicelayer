/**
 * Private, acknowledged Ask recovery on the caller's next voice call.
 *
 * Identity is a bridge-generated random capability (`_meta["voicelayer/caller"]`), bound to a row at
 * admission. A socket write is never delivery: only an explicit `delivery_ack` (delivery id + current
 * lease id, same caller) marks a row delivered. This is at-least-once recovery, not automatic wake.
 * Model: formal/ask-delivery.
 */
import { Database } from "bun:sqlite";
import { createHash, randomUUID } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { getStateDir } from "./paths";
import type { McpRequest, McpResponse } from "./mcp-handler";

export const CALLER_META = "voicelayer/caller";
export const DELIVERY_TOOLS: ReadonlySet<string> = new Set(["voice_ask", "voice_speak", "voice_ask_results"]);
const CAPABILITY = /^[a-f0-9]{64}$/;
const UUID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const ARCHIVE = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/;
const LEASE_MS = 30_000;
const hash = (text: string) => createHash("sha256").update(text).digest("hex");
type Content = { type: string; text: string };
type Result = { content: Content[]; isError?: boolean };
type State = "pending" | "ready" | "void" | "acknowledged";
type Row = { operation: string; delivery: string; scope: string; state: State; archive: string | null;
  answer: string | null; result: string | null; lease: string | null; connection: string | null; until_ms: number;
  owner_pid: number };
type Event = "connection_open" | "connection_close" | "connection_error" | "request" | "cancelled" |
  "archive_associated" | "finalized" | "write_attempted" | "delivery_acknowledged" | "ack_refused" | "recovered" |
  "scope_refused" | "store_refused" | "orphan_retained";
type Fields = { request_id?: string; tool?: string; operation_id?: string; delivery_id?: string; archive_id?: string;
  progress_token_present?: boolean; tasks_capability?: boolean; logging_capability?: boolean; matched?: boolean;
  state?: State; count?: number };

/** Hash arbitrary client request ids; never log capabilities, arguments or text. */
export function deliveryRequestId(id: unknown): string {
  return hash(JSON.stringify([typeof id, id ?? null]));
}

const DAEMON_RESTART_TEXT = (archive: string) =>
  `The VoiceLayer daemon restarted before this Ask finished. Its recording was kept (archive ${archive}). ` +
  "Read it with voice_ask_results archive_id; do not ask the user to repeat.";

function alive(pid: number): boolean {
  if (pid === process.pid) return true;
  try { process.kill(pid, 0); return true; } catch (error) { return (error as { code?: string }).code === "EPERM"; }
}

/** One SQLite transaction serializes all claims/acks, including overlapping connections and processes. */
export class AskDeliveryStore {
  private readonly db: Database;
  constructor(private readonly log: (line: string) => void = console.error) {
    const directory = join(getStateDir(), "ask-delivery");
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    if (!lstatSync(directory).isDirectory() || lstatSync(directory).isSymbolicLink()) throw new Error("unsafe outbox");
    chmodSync(directory, 0o700);
    const path = join(directory, "outbox.sqlite");
    if (existsSync(path) && (!lstatSync(path).isFile() || lstatSync(path).isSymbolicLink())) throw new Error("unsafe outbox");
    this.db = new Database(path, { create: true });
    chmodSync(path, 0o600);
    this.db.exec(`PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS deliveries (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, operation TEXT UNIQUE NOT NULL,
        delivery TEXT UNIQUE NOT NULL, scope TEXT NOT NULL, state TEXT NOT NULL,
        archive TEXT, answer TEXT, result TEXT, lease TEXT, connection TEXT, until_ms INTEGER NOT NULL DEFAULT 0,
        owner_pid INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS caller_deliveries ON deliveries(scope,state,sequence);`);
    this.recoverOrphans();
  }
  close(): void { this.db.close(); }

  /**
   * Crash actor: a pending row whose owning process is gone can never be finalized by its flow. With an
   * archive it becomes a ready pointer to the kept recording (no loss before ack); without one, nothing
   * was captured and it is voided so it cannot block the caller forever.
   */
  private recoverOrphans(): void {
    this.db.transaction(() => {
      const rows = this.db.query<Row, []>("SELECT * FROM deliveries WHERE state='pending'").all();
      let count = 0;
      for (const row of rows) {
        if (alive(row.owner_pid)) continue;
        count++;
        if (row.archive) {
          const result: Result = { content: [{ type: "text", text: DAEMON_RESTART_TEXT(row.archive) }], isError: true };
          this.db.query("UPDATE deliveries SET state='ready',result=? WHERE operation=? AND state='pending'")
            .run(JSON.stringify(result), row.operation);
        } else {
          this.db.query("UPDATE deliveries SET state='void' WHERE operation=? AND state='pending'").run(row.operation);
        }
      }
      if (count) this.log(JSON.stringify({ event: "ask_delivery.orphan_retained", timestamp: new Date().toISOString(), count }));
    }).immediate();
  }
  oldest(scope: string): Row | null {
    return this.db.query<Row, [string]>(
      "SELECT * FROM deliveries WHERE scope=? AND state IN ('pending','ready') ORDER BY sequence LIMIT 1").get(scope);
  }
  /** Admission: refuses (null) while this caller has any undelivered row, so no second capture opens. */
  begin(scope: string): Row | null {
    return this.db.transaction(() => {
      if (this.oldest(scope)) return null;
      const operation = randomUUID(), delivery = randomUUID();
      this.db.query("INSERT INTO deliveries(operation,delivery,scope,state,owner_pid) VALUES (?,?,?,'pending',?)")
        .run(operation, delivery, scope, process.pid);
      return this.db.query<Row, [string]>("SELECT * FROM deliveries WHERE operation=?").get(operation);
    }).immediate();
  }
  archive(operation: string, archive: string): void {
    if (!ARCHIVE.test(archive)) return;
    this.db.query("UPDATE deliveries SET archive=? WHERE operation=? AND state='pending'").run(archive, operation);
  }
  answer(operation: string, answer: string): void {
    // The exact string, fragments and retractions included. The archive stays the independent receipt.
    this.db.query("UPDATE deliveries SET answer=? WHERE operation=? AND state='pending'").run(answer, operation);
  }
  /** First finalization wins. Nothing captured (no archive, no answer) means nothing to recover. */
  finalize(operation: string, result: Result): State | null {
    return this.db.transaction(() => {
      this.db.query(`UPDATE deliveries SET result=?,
          state=CASE WHEN archive IS NULL AND answer IS NULL THEN 'void' ELSE 'ready' END
        WHERE operation=? AND state='pending'`).run(JSON.stringify(result), operation);
      return this.db.query<{ state: State }, [string]>("SELECT state FROM deliveries WHERE operation=?").get(operation)?.state ?? null;
    }).immediate();
  }
  /** Lease the oldest ready row to this connection; a pending row is returned as-is (still running). */
  claim(scope: string, connection: string): Row | null {
    return this.db.transaction(() => {
      const row = this.oldest(scope);
      if (!row || row.state === "pending") return row;
      const keep = row.lease && row.until_ms > Date.now();
      const lease = keep ? row.lease! : randomUUID();
      this.db.query("UPDATE deliveries SET lease=?,connection=?,until_ms=? WHERE delivery=? AND state='ready'")
        .run(lease, connection, Date.now() + LEASE_MS, row.delivery);
      return { ...row, lease, connection };
    }).immediate();
  }
  /** Same caller, same delivery, the current lease. Acknowledged rows drop their private text. */
  ack(scope: string, delivery: string, lease: string): boolean {
    return this.db.transaction(() => {
      const row = this.db.query<Row, [string, string]>("SELECT * FROM deliveries WHERE scope=? AND delivery=?").get(scope, delivery);
      if (!row || row.state === "pending" || row.state === "void") return false;
      if (row.state === "acknowledged") return true;
      if (row.lease !== lease) return false;
      this.db.query("UPDATE deliveries SET state='acknowledged',answer=NULL,result=NULL WHERE delivery=?").run(delivery);
      return true;
    }).immediate();
  }
  /** A disconnect before the ack keeps the row retryable under a fresh lease. Never deletes. */
  disconnect(connection: string): void {
    this.db.query("UPDATE deliveries SET lease=NULL,connection=NULL,until_ms=0 WHERE connection=? AND state='ready'").run(connection);
  }
}

export type AskDeliveryHooks = {
  archive(id: string): void;
  answer(text: string): void;
  /** The handler's bounded timeout won: its response is not the flow's final result. */
  timedOut(): void;
  /** The flow's eventual result (late transcription). Registered before the handler returns. */
  defer(result: Promise<Result>): void;
};
type Active = { cancelled: boolean };
const jsonText = (data: Record<string, unknown>): Content => ({ type: "text", text: JSON.stringify(data) });

/** One instance per transport connection. No identity is inferred from clientInfo, cwd, PID or archives. */
export class AskDeliverySession {
  readonly id = randomUUID();
  private scope: string | undefined;
  private readonly active = new Map<string, Active>();
  private closed = false;
  private tasks = false;
  private logging = false;
  constructor(private readonly store: () => AskDeliveryStore, private readonly log: (line: string) => void = console.error) {
    this.event("connection_open");
  }
  private event(event: Event, fields: Fields = {}): void {
    this.log(JSON.stringify({ event: `ask_delivery.${event}`, timestamp: new Date().toISOString(), connection_id: this.id,
      ...(this.scope ? { caller_scope: hash(`log:${this.scope}`).slice(0, 16) } : {}), ...fields }));
  }
  writeAttempt(id: unknown): void { this.event("write_attempted", { request_id: deliveryRequestId(id) }); }
  disconnect(error = false): void {
    if (this.closed) return;
    this.closed = true;
    for (const item of this.active.values()) item.cancelled = true;
    if (this.scope) { try { this.store().disconnect(this.id); } catch { this.event("store_refused"); } }
    this.event(error ? "connection_error" : "connection_close");
  }
  /** Bound by connection AND request id: another client's identical id never matches here. */
  cancel(requestId: unknown): void {
    const id = deliveryRequestId(requestId), active = this.active.get(id);
    if (active) active.cancelled = true;
    this.event("cancelled", { request_id: id, matched: !!active });
  }
  async run(request: McpRequest,
    invoke: (hooks?: AskDeliveryHooks, request?: McpRequest) => Promise<McpResponse | null>): Promise<McpResponse | null> {
    if (request.method === "notifications/cancelled") { this.cancel(request.params?.requestId); return null; }
    const params = request.params ?? {};
    if (request.method === "initialize") {
      const caps = object(params.capabilities);
      this.logging = "logging" in caps;
      const extensions = object(object(object(params._meta)["io.modelcontextprotocol/clientCapabilities"]).extensions);
      this.tasks = typeof extensions["io.modelcontextprotocol/tasks"] === "object" || "tasks" in caps;
    }
    if (request.method !== "tools/call" || typeof params.name !== "string" || !DELIVERY_TOOLS.has(params.name)) return invoke();
    const tool = params.name;
    const id = deliveryRequestId(request.id), metadata = object(params._meta), rawScope = metadata[CALLER_META];
    const reply = (content: Content[], isError = false): McpResponse =>
      ({ jsonrpc: "2.0", id: request.id!, result: { content, ...(isError ? { isError: true } : {}) } });
    const recover = (row: Row): McpResponse => {
      const result = this.recovery(row);
      return reply(result.content, result.isError);
    };
    const refuse = () => { this.event("scope_refused", { request_id: id });
      return reply([jsonText({ status: "scope-refused", new_action_run: false })], true); };
    if (rawScope !== undefined && (typeof rawScope !== "string" || !CAPABILITY.test(rawScope))) return refuse();
    const scope = typeof rawScope === "string" ? hash(rawScope) : undefined;
    if (this.scope && scope !== this.scope) return refuse();
    this.scope = scope;
    this.event("request", { request_id: id, tool, progress_token_present: metadata.progressToken !== undefined,
      tasks_capability: this.tasks, logging_capability: this.logging });
    // Legacy direct clients keep their existing behavior; no ownerless archive is ever adopted.
    if (!scope) return invoke();
    const { [CALLER_META]: _reserved, ...cleanMeta } = metadata;
    let args = object(params.arguments);
    const active: Active = { cancelled: false };
    this.active.set(id, active);
    try {
      const store = this.store();
      if ("delivery_ack" in args) {
        const { delivery_ack: raw, ...rest } = args, ack = object(raw);
        const accepted = Object.keys(ack).length === 2 && typeof ack.delivery_id === "string" && UUID.test(ack.delivery_id) &&
          typeof ack.lease_id === "string" && UUID.test(ack.lease_id) && store.ack(scope, ack.delivery_id, ack.lease_id);
        this.event(accepted ? "delivery_acknowledged" : "ack_refused",
          { request_id: id, ...(typeof ack.delivery_id === "string" && UUID.test(ack.delivery_id) ? { delivery_id: ack.delivery_id } : {}) });
        if (tool === "voice_ask_results" && Object.keys(rest).length === 0) {
          return reply([jsonText({ status: accepted ? "acknowledged" : "ack-refused", new_action_run: false,
            ...(accepted ? { delivery_id: ack.delivery_id } : {}) })], !accepted);
        }
        args = rest; // A piggybacked ack is consumed; the call continues as if it carried none.
      }
      const forward: McpRequest = { ...request, params: { ...params, arguments: args, _meta: cleanMeta } };
      // Recovery precedes every new voice side effect, including reads and speech.
      const held = store.claim(scope, this.id);
      if (held) { this.event("recovered", { request_id: id, delivery_id: held.delivery, state: held.state });
        return recover(held); }
      if (tool !== "voice_ask") return await invoke(undefined, forward);
      const row = store.begin(scope);
      if (!row) { const again = store.claim(scope, this.id)!; return recover(again); }
      return await this.ask(store, scope, row, active, request, forward, invoke, reply);
    } catch {
      // Provider/FS errors may contain private text. Retain any pending receipt and refuse new side effects.
      this.event("store_refused", { request_id: id });
      return reply([jsonText({ status: "delivery-unavailable", new_action_run: false })], true);
    } finally {
      this.active.delete(id);
    }
  }
  private async ask(store: AskDeliveryStore, scope: string, row: Row, active: Active, request: McpRequest,
    forward: McpRequest, invoke: (hooks?: AskDeliveryHooks, request?: McpRequest) => Promise<McpResponse | null>,
    reply: (content: Content[], isError?: boolean) => McpResponse): Promise<McpResponse | null> {
    const ids = { operation_id: row.operation, delivery_id: row.delivery };
    const finalize = (result: Result) => {
      const state = store.finalize(row.operation, result);
      this.event("finalized", { ...ids, ...(state ? { state } : {}) });
    };
    let timedOut = false;
    let deferred: Promise<Result> | undefined;
    const hooks: AskDeliveryHooks = {
      archive: archive => { store.archive(row.operation, archive);
        if (ARCHIVE.test(archive)) this.event("archive_associated", { operation_id: row.operation, archive_id: archive }); },
      answer: answer => store.answer(row.operation, answer),
      timedOut: () => { timedOut = true; },
      defer: promise => { deferred = promise; },
    };
    let response: McpResponse | null = null;
    const handlerResult = () => (response?.result as Result | undefined) ??
      { content: [{ type: "text", text: "voice_ask ended without a result." }], isError: true };
    try { response = await invoke(hooks, forward); }
    finally {
      if (deferred && timedOut) {
        // Late transcription: the flow finalizes when it settles; a rejected flow keeps the bounded response.
        void deferred.then(finalize, () => finalize(handlerResult()))
          .catch(() => this.event("store_refused", { operation_id: row.operation }));
      } else {
        finalize(handlerResult());
      }
    }
    if (active.cancelled || this.closed) return null;
    const current = store.claim(scope, this.id);
    if (!current || current.delivery !== row.delivery) return response && { ...response, id: request.id! };
    if (current.state === "pending") return reply([...handlerResult().content, jsonText({ status: "pending", ...ids,
      message: "The answer is still being transcribed; your next voice call returns it before any new action." })],
      handlerResult().isError);
    return reply([...handlerResult().content, this.receipt(current)], handlerResult().isError);
  }
  private receipt(row: Row): Content {
    return jsonText({ delivery_id: row.delivery, lease_id: row.lease,
      acknowledge: "After reading, pass delivery_ack {delivery_id, lease_id} on your next voice call (or alone to voice_ask_results)." });
  }
  private recovery(row: Row): Result {
    const status = { status: row.state === "ready" ? "ready" : "pending", operation_id: row.operation,
      delivery_id: row.delivery, archive_id: row.archive, new_action_run: false,
      message: row.state === "ready"
        ? "The newly requested action was NOT run. This is your earlier Ask's held result; acknowledge it, then retry."
        : "The newly requested action was NOT run. Your earlier Ask is still recording or transcribing; no second capture was opened." };
    if (row.state !== "ready") return { content: [jsonText(status)] };
    const original: Result = row.result ? JSON.parse(row.result) as Result : { content: [] };
    // `answer` is the raw transcript, byte for byte; the original response (boxed for display) follows unchanged.
    return { content: [jsonText({ ...status, ...(row.answer !== null ? { answer: row.answer } : {}), lease_id: row.lease,
      acknowledge: { delivery_ack: { delivery_id: row.delivery, lease_id: row.lease } } }), ...original.content],
      isError: original.isError };
  }
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
