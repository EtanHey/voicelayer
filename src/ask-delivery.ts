/** Private, acknowledged Ask recovery. A socket write is never delivery. */
import { Database } from "bun:sqlite";
import { createHash, randomUUID } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { getStateDir } from "./paths";
import type { McpRequest, McpResponse } from "./mcp-handler";

export const CALLER_META = "voicelayer/caller";
const CAPABILITY = /^[a-f0-9]{64}$/;
const UUID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
const ARCHIVE = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z-[a-f0-9]{8}$/;
const tools = new Set(["voice_ask", "voice_speak", "voice_ask_results"]);
const hash = (text: string) => createHash("sha256").update(text).digest("hex");
type Result = { content: { type: string; text: string }[]; isError?: boolean };
type Row = { operation: string; delivery: string; scope: string; state: string; archive: string | null;
  answer: string | null; result: string | null; lease: string | null; connection: string | null; until_ms: number };
type Event = "connection_open" | "connection_close" | "connection_error" | "request" | "cancelled" |
  "archive_associated" | "finalized" | "write_attempted" | "delivery_acknowledged" | "scope_refused" | "store_refused";
type Fields = { request_id?: string; tool?: string; caller_scope?: string; operation_id?: string;
  delivery_id?: string; archive_id?: string; progress_token_present?: boolean; tasks_capability?: boolean;
  logging_capability?: boolean; matched?: boolean };

/** Hash arbitrary client request ids; never log capabilities, arguments or text. */
export function deliveryRequestId(id: unknown): string {
  return hash(JSON.stringify([typeof id, id ?? null]));
}

/** One SQLite transaction serializes all claims/acks, including overlapping connections. */
export class AskDeliveryStore {
  private readonly db: Database;
  constructor() {
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
        archive TEXT, answer TEXT, result TEXT, lease TEXT, connection TEXT, until_ms INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS caller_deliveries ON deliveries(scope,state,sequence);`);
  }
  close(): void { this.db.close(); }
  oldest(scope: string): Row | null {
    return this.db.query<Row, [string]>("SELECT * FROM deliveries WHERE scope=? AND state!='acknowledged' ORDER BY sequence LIMIT 1").get(scope);
  }
  begin(scope: string): Row | null {
    return this.db.transaction(() => {
      if (this.oldest(scope)) return null;
      const operation = randomUUID(), delivery = randomUUID();
      this.db.query("INSERT INTO deliveries(operation,delivery,scope,state) VALUES (?,?,?,'pending')").run(operation, delivery, scope);
      return this.db.query<Row, [string]>("SELECT * FROM deliveries WHERE operation=?").get(operation);
    }).immediate();
  }
  archive(operation: string, archive: string): void {
    if (!ARCHIVE.test(archive)) return;
    this.db.query("UPDATE deliveries SET archive=? WHERE operation=?").run(archive, operation);
  }
  answer(operation: string, answer: string): void {
    // Preserve the exact string. The archive remains the independent audio receipt.
    this.db.query("UPDATE deliveries SET answer=? WHERE operation=? AND state!='acknowledged'").run(answer, operation);
  }
  finalize(operation: string, result: Result): void {
    this.db.query("UPDATE deliveries SET state='ready',result=? WHERE operation=? AND state='pending'").run(JSON.stringify(result), operation);
  }
  claim(scope: string, connection: string): Row | null {
    return this.db.transaction(() => {
      const row = this.oldest(scope);
      if (!row || row.state === "pending") return row;
      if (row.lease && row.until_ms > Date.now() && row.connection !== connection) return { ...row, state: "leased" };
      const lease = row.lease && row.connection === connection && row.until_ms > Date.now() ? row.lease : randomUUID();
      this.db.query("UPDATE deliveries SET lease=?,connection=?,until_ms=? WHERE delivery=? AND state='ready'")
        .run(lease, connection, Date.now() + 30_000, row.delivery);
      return { ...row, lease, connection };
    }).immediate();
  }
  ack(scope: string, connection: string, delivery: string, lease: string): boolean {
    return this.db.transaction(() => {
      const row = this.db.query<Row, [string, string]>("SELECT * FROM deliveries WHERE scope=? AND delivery=?").get(scope, delivery);
      if (!row || row.lease !== lease || row.connection !== connection || row.state === "pending") return false;
      if (row.state === "acknowledged") return true;
      if (row.until_ms < Date.now()) return false;
      this.db.query("UPDATE deliveries SET state='acknowledged' WHERE delivery=?").run(delivery);
      return true;
    }).immediate();
  }
  disconnect(connection: string): void {
    this.db.query("UPDATE deliveries SET lease=NULL,connection=NULL,until_ms=0 WHERE connection=? AND state!='acknowledged'").run(connection);
  }
}

export type AskDeliveryHooks = { archive(id: string): void; answer(text: string): void; defer(result: Promise<Result>): void };
type Active = { row: Row; cancelled: boolean };
const jsonResult = (data: Record<string, unknown>, isError = false): Result => ({
  content: [{ type: "text", text: JSON.stringify(data) }], ...(isError ? { isError: true } : {}),
});

/** One instance per transport connection. No identity is inferred from clientInfo. */
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
    this.log(JSON.stringify({ event: `ask_delivery.${event}`, timestamp: new Date().toISOString(),
      connection_id: this.id, ...(this.scope ? { caller_scope: this.scope } : {}), ...fields }));
  }
  writeAttempt(id: unknown): void { this.event("write_attempted", { request_id: deliveryRequestId(id) }); }
  disconnect(error = false): void {
    if (this.closed) return;
    this.closed = true;
    for (const item of this.active.values()) item.cancelled = true;
    if (this.scope) { try { this.store().disconnect(this.id); } catch { this.event("store_refused"); } }
    this.event(error ? "connection_error" : "connection_close");
  }
  cancel(requestId: unknown): void {
    const id = deliveryRequestId(requestId), active = this.active.get(id);
    if (active) active.cancelled = true;
    this.event("cancelled", { request_id: id, matched: !!active });
  }
  async run(request: McpRequest, invoke: (hooks?: AskDeliveryHooks) => Promise<McpResponse | null>): Promise<McpResponse | null> {
    if (request.method === "notifications/cancelled") {
      this.cancel(request.params?.requestId); return null;
    }
    const params = request.params ?? {};
    if (request.method === "initialize") {
      const caps = params.capabilities;
      this.logging = !!caps && typeof caps === "object" && "logging" in caps;
      const extensions = object(object(object(params._meta)["io.modelcontextprotocol/clientCapabilities"]).extensions);
      this.tasks = typeof extensions["io.modelcontextprotocol/tasks"] === "object";
    }
    if (request.method !== "tools/call" || typeof params.name !== "string" || !tools.has(params.name)) return invoke();
    const id = deliveryRequestId(request.id), metadata = object(params._meta), rawScope = metadata[CALLER_META];
    const reply = (result: Result): McpResponse => ({ jsonrpc: "2.0", id: request.id!, result });
    if (rawScope !== undefined && (typeof rawScope !== "string" || !CAPABILITY.test(rawScope))) {
      this.event("scope_refused", { request_id: id });
      return reply(jsonResult({ status: "scope-refused", new_action_run: false }, true));
    }
    const scope = typeof rawScope === "string" ? hash(rawScope) : undefined;
    if (this.scope && scope !== this.scope) {
      this.event("scope_refused", { request_id: id });
      return reply(jsonResult({ status: "scope-refused", new_action_run: false }, true));
    }
    this.scope = scope;
    this.event("request", { request_id: id, tool: params.name, progress_token_present: metadata.progressToken !== undefined,
      tasks_capability: this.tasks, logging_capability: this.logging });
    // Legacy direct clients keep their existing behavior; no ownerless archive is adopted.
    if (!scope) return invoke();
    let active: Active | undefined;
    try {
      const store = this.store(), args = object(params.arguments), ack = object(args.delivery_ack);
      if ("delivery_ack" in args) {
        const accepted = Object.keys(args).length === 1 && Object.keys(ack).length === 2 && params.name === "voice_ask_results" && typeof ack.delivery_id === "string" && UUID.test(ack.delivery_id) &&
          typeof ack.lease_id === "string" && UUID.test(ack.lease_id) && store.ack(scope, this.id, ack.delivery_id, ack.lease_id);
        if (accepted) this.event("delivery_acknowledged", { request_id: id, delivery_id: ack.delivery_id as string });
        return reply(jsonResult({ status: accepted ? "acknowledged" : "ack-refused", new_action_run: false,
          ...(accepted ? { delivery_id: ack.delivery_id } : {}) }, !accepted));
      }
      const held = store.claim(scope, this.id);
      if (held) return reply(this.envelope(held, false));
      if (params.name !== "voice_ask") return invoke();
      const row = store.begin(scope);
      if (!row) return reply(this.envelope(store.claim(scope, this.id)!, false));
      active = { row, cancelled: false }; this.active.set(id, active);
      let deferred = false;
      const finalize = (result: Result) => {
        store.finalize(row.operation, result);
        this.event("finalized", { operation_id: row.operation, delivery_id: row.delivery });
      };
      const hooks: AskDeliveryHooks = {
        archive: archive => { store.archive(row.operation, archive); if (ARCHIVE.test(archive)) this.event("archive_associated", { operation_id: row.operation, archive_id: archive }); },
        answer: answer => { store.answer(row.operation, answer); },
        defer: promise => {
          deferred = true;
          void promise.then(finalize, () => finalize(jsonResult({ status: "answer-retained", archive_id: row.archive }, true)))
            .catch(() => this.event("store_refused", { operation_id: row.operation }));
        },
      };
      const response = await invoke(hooks);
      if (!deferred) finalize(response?.result ? response.result as Result : jsonResult({ status: "ended-without-result" }, true));
      if (active.cancelled || this.closed) return null;
      return reply(this.envelope(store.claim(scope, this.id)!, true));
    } catch {
      // Provider/FS errors may contain private text. Retain the pending receipt and refuse new side effects.
      this.event("store_refused", { request_id: id });
      return reply(jsonResult({ status: "delivery-unavailable", new_action_run: false }, true));
    } finally {
      if (active) this.active.delete(id);
    }
  }
  private envelope(row: Row, original: boolean): Result {
    return jsonResult({ status: row.state === "ready" ? "ready" : "pending", operation_id: row.operation,
      delivery_id: row.delivery, archive_id: row.archive, new_action_run: original,
      message: original ? "Acknowledge this delivery after reading it with voice_ask_results delivery_ack." :
        "The newly requested action was NOT run. This is the older Ask; do not ask the user to repeat.",
      ...(row.state === "ready" ? { answer: row.answer, result: row.result ? JSON.parse(row.result) : null,
        lease_id: row.lease, acknowledgement: { tool: "voice_ask_results", arguments: { delivery_ack: { delivery_id: row.delivery, lease_id: row.lease } } } } : {}) });
  }
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
