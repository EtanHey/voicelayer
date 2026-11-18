/**
 * Private, acknowledged Ask recovery on the caller's next voice call.
 *
 * Identity is a bridge-generated random capability (`_meta["voicelayer/caller"]`), bound to a row at
 * admission. A socket write is never delivery: only an explicit `delivery_ack` (delivery id + current
 * lease id, same caller) marks a row delivered. This is at-least-once recovery, not automatic wake.
 *
 * MCP tasks (2026-07-28, daemon only): a voice_ask whose request carries the tasks extension is answered at once (or
 * after `wait_seconds`) with a task handle bound to the same caller; `tasks/get` reads its row from this outbox and
 * `tasks/cancel` ends the Ask through the client-disconnect abort path. A task's first terminal state wins.
 * Model: formal/ask-delivery.
 */
import { Database } from "bun:sqlite";
import { createHash, randomUUID } from "node:crypto";
import { chmodSync, existsSync, lstatSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { getStateDir } from "./paths";
import type { McpRequest, McpResponse } from "./mcp-handler";
import { CLIENT_CAPABILITIES_META, MAX_WAIT_SECONDS, TASK_POLL_MS, TASKS_EXTENSION } from "./mcp-protocol";
import type { McpNotification } from "./mcp-notifications";

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
type TaskState = "working" | "completed" | "cancelled" | "failed";
type Row = { operation: string; delivery: string; scope: string; state: State; archive: string | null;
  answer: string | null; result: string | null; lease: string | null; connection: string | null; until_ms: number;
  owner_pid: number };
type TaskRow = Row & { task: string; task_state: TaskState; created_ms: number; updated_ms: number };
type Event = "connection_open" | "connection_close" | "connection_error" | "request" | "cancelled" |
  "archive_associated" | "finalized" | "write_attempted" | "delivery_acknowledged" | "ack_refused" | "recovered" |
  "scope_refused" | "store_refused" | "orphan_retained" | "task_accepted" | "task_get" | "task_cancel";
type Fields = { request_id?: string; tool?: string; operation_id?: string; delivery_id?: string; archive_id?: string;
  progress_token_present?: boolean; tasks_capability?: boolean; logging_capability?: boolean; matched?: boolean;
  state?: State; count?: number; task_id?: string; task_state?: TaskState; wait_seconds?: number };

/** Per-request client capabilities (MCP 2026-07-28): does this request accept a task answer? */
export function requestAcceptsTask(meta: unknown): boolean {
  const extensions = object(object(object(meta)[CLIENT_CAPABILITIES_META]).extensions);
  return typeof extensions[TASKS_EXTENSION] === "object" && extensions[TASKS_EXTENSION] !== null;
}
/** `wait_seconds`: a finite number, floored and clamped to 0–MAX_WAIT_SECONDS; anything else means 0. */
export function waitSeconds(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value) ? Math.min(MAX_WAIT_SECONDS, Math.max(0, Math.floor(value))) : 0;
}

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
      CREATE INDEX IF NOT EXISTS caller_deliveries ON deliveries(scope,state,sequence);
      CREATE TABLE IF NOT EXISTS tasks (
        task TEXT PRIMARY KEY, scope TEXT NOT NULL, operation TEXT UNIQUE NOT NULL, state TEXT NOT NULL,
        created_ms INTEGER NOT NULL, updated_ms INTEGER NOT NULL);`);
    this.recoverOrphans();
  }
  /** A task leaves `working` once; its first terminal state wins (a cancelled task never later completes). */
  private settleTask(operation: string, state: Exclude<TaskState, "working">): void {
    this.db.query("UPDATE tasks SET state=?,updated_ms=? WHERE operation=? AND state='working'").run(state, Date.now(), operation);
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
          this.settleTask(row.operation, "completed");
        } else {
          this.db.query("UPDATE deliveries SET state='void' WHERE operation=? AND state='pending'").run(row.operation);
          this.settleTask(row.operation, "failed");
        }
      }
      if (count) this.log(JSON.stringify({ event: "ask_delivery.orphan_retained", timestamp: new Date().toISOString(), count }));
    }).immediate();
  }
  oldest(scope: string): Row | null {
    return this.db.query<Row, [string]>(
      "SELECT * FROM deliveries WHERE scope=? AND state IN ('pending','ready') ORDER BY sequence LIMIT 1").get(scope);
  }
  /**
   * Admission: refuses (null) while this caller has any undelivered row, so no second capture opens. With a task id the
   * task row is created in the same transaction, durably, before any task answer is sent.
   */
  begin(scope: string, task?: { id: string; now: number }): Row | null {
    return this.db.transaction(() => {
      if (this.oldest(scope)) return null;
      const operation = randomUUID(), delivery = randomUUID();
      this.db.query("INSERT INTO deliveries(operation,delivery,scope,state,owner_pid) VALUES (?,?,?,'pending',?)")
        .run(operation, delivery, scope, process.pid);
      if (task) {
        this.db.query("INSERT INTO tasks(task,scope,operation,state,created_ms,updated_ms) VALUES (?,?,?,'working',?,?)")
          .run(task.id, scope, operation, task.now, task.now);
      }
      return this.db.query<Row, [string]>("SELECT * FROM deliveries WHERE operation=?").get(operation);
    }).immediate();
  }
  /** Only the caller that created a task can see it; anyone else gets nothing (reported as an unknown task). */
  task(scope: string, task: string): TaskRow | null {
    return this.db.query<TaskRow, [string, string]>(`SELECT d.*, t.task, t.state AS task_state, t.created_ms, t.updated_ms
      FROM tasks t JOIN deliveries d ON d.operation=t.operation WHERE t.task=? AND t.scope=? AND d.scope=t.scope`).get(task, scope);
  }
  /** tasks/cancel: working -> cancelled; a terminal task is left as it is. False for another caller's or unknown id. */
  cancelTask(scope: string, task: string): boolean {
    return this.db.transaction(() => {
      const row = this.task(scope, task);
      if (row) this.settleTask(row.operation, "cancelled");
      return !!row;
    }).immediate();
  }
  /** The Ask ran but its result could not be stored: the task fails instead of staying working forever. */
  failTask(operation: string): void { this.settleTask(operation, "failed"); }
  archive(operation: string, archive: string): void {
    if (!ARCHIVE.test(archive)) return;
    this.db.query("UPDATE deliveries SET archive=? WHERE operation=? AND state='pending'").run(archive, operation);
  }
  answer(operation: string, answer: string): void {
    // The exact string, fragments and retractions included. The archive stays the independent receipt.
    this.db.query("UPDATE deliveries SET answer=? WHERE operation=? AND state='pending'").run(answer, operation);
  }
  /**
   * First finalization wins. Nothing captured (no archive, no answer) means nothing to recover. A working task completes
   * in the same transaction; a cancelled one stays cancelled while its captured row is still held for recovery.
   */
  finalize(operation: string, result: Result): State | null {
    return this.db.transaction(() => {
      this.db.query(`UPDATE deliveries SET result=?,
          state=CASE WHEN archive IS NULL AND answer IS NULL THEN 'void' ELSE 'ready' END
        WHERE operation=? AND state='pending'`).run(JSON.stringify(result), operation);
      const state = this.db.query<{ state: State }, [string]>("SELECT state FROM deliveries WHERE operation=?").get(operation)?.state ?? null;
      if (state && state !== "pending") this.settleTask(operation, "completed");
      return state;
    }).immediate();
  }
  /** Lease the oldest ready row to this connection; a pending row is returned as-is (still running). */
  claim(scope: string, connection: string): Row | null {
    return this.db.transaction(() => this.lease(this.oldest(scope), connection)).immediate();
  }
  /** Lease one named ready row (a completed task's result); null unless it is this caller's and still ready. */
  claimDelivery(scope: string, delivery: string, connection: string): Row | null {
    return this.db.transaction(() => {
      const row = this.db.query<Row, [string, string]>("SELECT * FROM deliveries WHERE scope=? AND delivery=? AND state='ready'").get(scope, delivery);
      return row && this.lease(row, connection);
    }).immediate();
  }
  private lease(row: Row | null, connection: string): Row | null {
    if (!row || row.state === "pending") return row;
    const keep = row.lease && row.until_ms > Date.now();
    const lease = keep ? row.lease! : randomUUID();
    this.db.query("UPDATE deliveries SET lease=?,connection=?,until_ms=? WHERE delivery=? AND state='ready'")
      .run(lease, connection, Date.now() + LEASE_MS, row.delivery);
    return { ...row, lease, connection };
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
  /** Task mode: aborts the Ask (tasks/cancel), joined with the connection's disconnect signal. */
  signal?: AbortSignal;
  /** Task mode: false drops a notification (the call was already answered with its task). */
  notificationOpen?(notification: McpNotification): boolean;
};
type Active = { cancelled: boolean };
type Invoke = (hooks?: AskDeliveryHooks, request?: McpRequest) => Promise<McpResponse | null>;
type Reply = (content: Content[], isError?: boolean) => McpResponse;
type Flow = { handler: Promise<McpResponse | null>; finalized: Promise<void>; response(): McpResponse | null;
  handlerResult(): Result; finalizeFailed(): boolean };
const jsonText = (data: Record<string, unknown>): Content => ({ type: "text", text: JSON.stringify(data) });
const iso = (ms: number) => new Date(ms).toISOString();
const ENDED_WITHOUT_RESULT = "voice_ask ended without a result.";

/** One instance per transport connection. No identity is inferred from clientInfo, cwd, PID or archives. */
export class AskDeliverySession {
  readonly id = randomUUID();
  private scope: string | undefined;
  private readonly active = new Map<string, Active>();
  /** Task id -> abort for an Ask this process is still running (tasks/cancel). */
  private readonly running = new Map<string, AbortController>();
  private closed = false;
  private tasks = false;
  private logging = false;
  private readonly taskCapable: boolean;
  /** `tasks: true` only where MCP 2026-07-28 can be negotiated (the daemon); the SDK stdio server stays legacy. */
  constructor(private readonly store: () => AskDeliveryStore, private readonly log: (line: string) => void = console.error,
    options: { tasks?: boolean } = {}) {
    this.taskCapable = options.tasks === true;
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
  async run(request: McpRequest, invoke: Invoke): Promise<McpResponse | null> {
    if (request.method === "notifications/cancelled") { this.cancel(request.params?.requestId); return null; }
    const params = request.params ?? {};
    if (request.method === "initialize") {
      const caps = object(params.capabilities);
      this.logging = "logging" in caps;
      this.tasks = requestAcceptsTask(params._meta) || "tasks" in caps;
    }
    if (request.method === "tasks/get" || request.method === "tasks/cancel") return this.taskRequest(request);
    if (request.method !== "tools/call" || typeof params.name !== "string" || !DELIVERY_TOOLS.has(params.name)) return invoke();
    const tool = params.name;
    const id = deliveryRequestId(request.id), metadata = object(params._meta), rawScope = metadata[CALLER_META];
    const reply: Reply = (content, isError = false) =>
      ({ jsonrpc: "2.0", id: request.id!, result: { content, ...(isError ? { isError: true } : {}) } });
    const refuse = () => { this.event("scope_refused", { request_id: id });
      return reply([jsonText({ status: "scope-refused", new_action_run: false })], true); };
    if (rawScope !== undefined && (typeof rawScope !== "string" || !CAPABILITY.test(rawScope))) return refuse();
    const scope = typeof rawScope === "string" ? hash(rawScope) : undefined;
    if (this.scope && scope !== this.scope) return refuse();
    this.scope = scope;
    const acceptsTask = requestAcceptsTask(metadata);
    this.event("request", { request_id: id, tool, progress_token_present: metadata.progressToken !== undefined,
      tasks_capability: this.tasks || acceptsTask, logging_capability: this.logging });
    let args = object(params.arguments);
    // wait_seconds is VoiceLayer's own task option: it never reaches the handler, and without a task it is ignored.
    let wait = 0, stripped = false;
    if (tool === "voice_ask" && "wait_seconds" in args) {
      const { wait_seconds: rawWait, ...rest } = args;
      args = rest; wait = waitSeconds(rawWait); stripped = true;
    }
    // Legacy direct clients keep their existing behavior; no ownerless archive is ever adopted.
    if (!scope) return stripped ? invoke(undefined, { ...request, params: { ...params, arguments: args } }) : invoke();
    const { [CALLER_META]: _reserved, ...cleanMeta } = metadata;
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
        return reply(this.recovery(held)); }
      if (tool !== "voice_ask") return await invoke(undefined, forward);
      const task = this.taskCapable && acceptsTask ? { id: `voice-ask-${randomUUID()}`, now: Date.now() } : undefined;
      const row = store.begin(scope, task);
      if (!row) { const again = store.claim(scope, this.id)!; return reply(this.recovery(again)); }
      if (task) return await this.askTask(store, scope, row, task, wait, active, request, forward, invoke, reply);
      return await this.ask(store, scope, row, active, request, forward, invoke, reply);
    } catch {
      // Provider/FS errors may contain private text. Retain any pending receipt and refuse new side effects.
      this.event("store_refused", { request_id: id });
      return reply([jsonText({ status: "delivery-unavailable", new_action_run: false })], true);
    } finally {
      this.active.delete(id);
    }
  }
  /** Start the Ask with the outbox hooks; its row is finalized when the handler (or its late transcription) settles. */
  private launch(store: AskDeliveryStore, row: Row, forward: McpRequest, invoke: Invoke,
    extra: Pick<AskDeliveryHooks, "signal" | "notificationOpen"> = {}): Flow {
    const ids = { operation_id: row.operation, delivery_id: row.delivery };
    const finalized = Promise.withResolvers<void>();
    let finalizeFailed = false;
    const finalize = (result: Result) => {
      try {
        const state = store.finalize(row.operation, result);
        this.event("finalized", { ...ids, ...(state ? { state } : {}) });
      } catch (error) { finalizeFailed = true; throw error; }
      finally { finalized.resolve(); }
    };
    let timedOut = false;
    let deferred: Promise<Result> | undefined;
    const hooks: AskDeliveryHooks = {
      archive: archive => { store.archive(row.operation, archive);
        if (ARCHIVE.test(archive)) this.event("archive_associated", { operation_id: row.operation, archive_id: archive }); },
      answer: answer => store.answer(row.operation, answer),
      timedOut: () => { timedOut = true; },
      defer: promise => { deferred = promise; },
      ...extra,
    };
    let response: McpResponse | null = null;
    const handlerResult = () => (response?.result as Result | undefined) ??
      { content: [{ type: "text", text: ENDED_WITHOUT_RESULT }], isError: true };
    const handler = (async () => {
      try { response = await invoke(hooks, forward); return response; }
      finally {
        if (deferred && timedOut) {
          // Late transcription: the flow finalizes when it settles; a rejected flow keeps the bounded response.
          void deferred.then(finalize, () => finalize(handlerResult()))
            .catch(() => this.event("store_refused", { operation_id: row.operation }));
        } else {
          finalize(handlerResult());
        }
      }
    })();
    return { handler, finalized: finalized.promise, response: () => response, handlerResult, finalizeFailed: () => finalizeFailed };
  }
  private async ask(store: AskDeliveryStore, scope: string, row: Row, active: Active, request: McpRequest,
    forward: McpRequest, invoke: Invoke, reply: Reply): Promise<McpResponse | null> {
    const flow = this.launch(store, row, forward, invoke);
    await flow.handler;
    return this.plainReply(store, scope, row, active, request, flow, reply);
  }
  /**
   * A task-capable voice_ask: answered with its task at once, or after up to `wait` seconds with the plain result if the
   * Ask finished by then. The Ask keeps running after the task answer; tasks/get reads its outcome from the outbox.
   */
  private async askTask(store: AskDeliveryStore, scope: string, row: Row, task: { id: string; now: number }, wait: number,
    active: Active, request: McpRequest, forward: McpRequest, invoke: Invoke, reply: Reply): Promise<McpResponse | null> {
    const ids = { operation_id: row.operation, delivery_id: row.delivery, task_id: task.id };
    const abort = new AbortController();
    let answered = false, rejected = false;
    this.running.set(task.id, abort);
    const flow = this.launch(store, row, forward, invoke, {
      signal: abort.signal,
      notificationOpen: notification => !answered || notification.method !== "notifications/progress",
    });
    const handled = flow.handler.then(() => {}, () => { rejected = true; });
    void flow.finalized.then(() => {
      this.running.delete(task.id);
      if (!flow.finalizeFailed()) return;
      try { store.failTask(row.operation); } catch { this.event("store_refused", ids); }
    });
    if (wait > 0) {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const finished = await Promise.race([
        Promise.all([handled, flow.finalized]).then(() => true),
        new Promise<false>(resolve => { timer = setTimeout(() => resolve(false), wait * 1000); }),
      ]);
      clearTimeout(timer);
      if (finished) {
        answered = true;
        if (rejected) throw new Error("voice_ask handler failed"); // Same refusal as the blocking path.
        return this.plainReply(store, scope, row, active, request, flow, reply);
      }
    }
    answered = true;
    if (active.cancelled || this.closed) return null;
    this.event("task_accepted", { ...ids, wait_seconds: wait });
    return { jsonrpc: "2.0", id: request.id!, result: { resultType: "task", taskId: task.id, status: "working",
      createdAt: iso(task.now), lastUpdatedAt: iso(task.now), ttlMs: null, pollIntervalMs: TASK_POLL_MS } };
  }
  /** tasks/get and tasks/cancel: only the creating caller's capability resolves the id; anything else is unknown. */
  private taskRequest(request: McpRequest): McpResponse | null {
    if (request.id === undefined || request.id === null) return null;
    const params = request.params ?? {}, rawScope = object(params._meta)[CALLER_META], taskId = params.taskId;
    const requestId = deliveryRequestId(request.id), method = request.method === "tasks/get" ? "task_get" : "task_cancel";
    const unknown = (): McpResponse => { this.event(method, { request_id: requestId, matched: false });
      return { jsonrpc: "2.0", id: request.id!, error: { code: -32602, message: "Unknown task" } }; };
    if (!this.taskCapable || typeof rawScope !== "string" || !CAPABILITY.test(rawScope) || typeof taskId !== "string") return unknown();
    const scope = hash(rawScope);
    if (this.scope && scope !== this.scope) return unknown();
    this.scope = scope;
    try {
      const store = this.store();
      if (request.method === "tasks/cancel") {
        if (!store.cancelTask(scope, taskId)) return unknown();
        // The same abort path a client disconnect uses: the Ask ends, anything recorded is kept and held for recovery.
        this.running.get(taskId)?.abort(new Error("MCP task cancelled"));
        this.event(method, { request_id: requestId, matched: true, task_id: taskId, task_state: store.task(scope, taskId)?.task_state });
        return { jsonrpc: "2.0", id: request.id, result: {} };
      }
      const row = store.task(scope, taskId);
      if (!row) return unknown();
      this.event(method, { request_id: requestId, matched: true, task_id: taskId, task_state: row.task_state });
      return { jsonrpc: "2.0", id: request.id, result: this.poll(store, scope, row) };
    } catch {
      this.event("store_refused", { request_id: requestId });
      return { jsonrpc: "2.0", id: request.id, error: { code: -32603, message: "VoiceLayer task store unavailable" } };
    }
  }
  private poll(store: AskDeliveryStore, scope: string, row: TaskRow): Record<string, unknown> {
    const base = { resultType: "complete", taskId: row.task, status: row.task_state, createdAt: iso(row.created_ms),
      lastUpdatedAt: iso(row.updated_ms), ttlMs: null, pollIntervalMs: TASK_POLL_MS };
    if (row.task_state === "working") return base;
    if (row.task_state === "cancelled") return { ...base,
      statusMessage: "Cancelled. Anything already recorded is kept and returned on your next voice call." };
    if (row.task_state === "failed") return { ...base, error: { code: -32603,
      message: "voice_ask ended without a stored result (VoiceLayer restarted or could not save it); nothing captured was lost." } };
    return { ...base, result: this.completed(store, scope, row) };
  }
  /** The normal voice_ask result, as the blocking call would have returned it. */
  private completed(store: AskDeliveryStore, scope: string, row: TaskRow): Result {
    const original: Result = row.result ? JSON.parse(row.result) as Result
      : { content: [{ type: "text", text: ENDED_WITHOUT_RESULT }], isError: true };
    if (row.state === "void") return original; // Nothing captured: the handler's own result, unchanged.
    if (row.state === "acknowledged") return { content: [jsonText({ status: "acknowledged", delivery_id: row.delivery,
      new_action_run: false, message: "This Ask's result was already read and acknowledged." })] };
    const leased = store.claimDelivery(scope, row.delivery, this.id) ?? row;
    return { content: [...original.content, this.receipt(leased)], ...(original.isError ? { isError: true } : {}) };
  }
  private plainReply(store: AskDeliveryStore, scope: string, row: Row, active: Active, request: McpRequest, flow: Flow,
    reply: Reply): McpResponse | null {
    const ids = { operation_id: row.operation, delivery_id: row.delivery };
    const response = flow.response(), handlerResult = flow.handlerResult;
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
  private recovery(row: Row): Content[] {
    const status = { status: row.state === "ready" ? "ready" : "pending", operation_id: row.operation,
      delivery_id: row.delivery, archive_id: row.archive, new_action_run: false,
      message: row.state === "ready"
        ? "The newly requested action was NOT run. This is your earlier Ask's held result; acknowledge it, then retry."
        : "The newly requested action was NOT run. Your earlier Ask is still recording or transcribing; no second capture was opened." };
    if (row.state !== "ready") return [jsonText(status)];
    const original = row.result ? (JSON.parse(row.result) as Result).content : [];
    // `answer` is the raw transcript, byte for byte; the original response (boxed for display) follows unchanged.
    return [jsonText({ ...status, ...(row.answer !== null ? { answer: row.answer } : {}), lease_id: row.lease,
      acknowledge: { delivery_ack: { delivery_id: row.delivery, lease_id: row.lease } } }), ...original];
  }
}

function object(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}
