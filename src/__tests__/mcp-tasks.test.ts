/**
 * voice_ask as an MCP task (lane c7, T4). Real daemon handler and transport (NDJSON and Content-Length),
 * latch-driven, preload-isolated, no microphone. Synthetic text only.
 *
 * Wire contract (Claude Code docs, "MCP tasks for server authors"; MCP 2026-07-28):
 * - `server/discover` with `_meta["io.modelcontextprotocol/protocolVersion"] = "2026-07-28"` returns a DiscoverResult
 *   advertising the `io.modelcontextprotocol/tasks` extension. `initialize` keeps 2024-11-05 byte-for-byte.
 * - a voice_ask `tools/call` whose `_meta["io.modelcontextprotocol/clientCapabilities"].extensions` carries the tasks
 *   extension is answered with `{resultType:"task", taskId, status:"working", ...}`; `tasks/get` serves
 *   working -> completed (top-level `result` = the normal voice_ask result) from the caller-bound outbox.
 * - without the extension the call blocks exactly as before and `wait_seconds` is ignored (and never reaches the
 *   handler).
 */
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { randomBytes } from "node:crypto";
import { join, relative } from "node:path";
import { createConnection } from "node:net";
import { createMcpDaemon } from "../mcp-daemon";
import { parseMcpFrames, serializeMcpFrame } from "../mcp-framing";
import type { VoiceToolContext } from "../mcp-notifications";
import { handleVoiceAsk } from "../handlers";
import * as tts from "../tts";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";

const cleanups: (() => void)[] = [];
let logs: string[] = [];
let waiters: { pattern: string; resolve: () => void }[] = [];
beforeEach(() => {
  logs = []; waiters = [];
  const log = spyOn(console, "error").mockImplementation((...args: unknown[]) => {
    const line = args.map(String).join(" ");
    logs.push(line);
    waiters = waiters.filter(waiter => { if (!line.includes(waiter.pattern)) return true; waiter.resolve(); return false; });
  });
  cleanups.push(() => log.mockRestore());
});
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });
/** Latch on a structured delivery event; never sleeps. */
function logged(pattern: string): Promise<void> {
  if (logs.some(line => line.includes(pattern))) return Promise.resolve();
  return new Promise(resolve => waiters.push({ pattern, resolve }));
}
async function loggedTimes(pattern: string, times: number): Promise<void> {
  while (logs.filter(line => line.includes(pattern)).length < times) {
    await new Promise<void>(resolve => waiters.push({ pattern, resolve }));
  }
}
type Content = { type: string; text: string };
type Rpc = { id?: number; method?: string; params?: Record<string, unknown>;
  result?: Record<string, unknown> & { content?: Content[]; isError?: boolean }; error?: { code: number; message: string } };
type Executor = (name: string, args: Record<string, unknown>, context: VoiceToolContext) => Promise<unknown>;
const caller = () => randomBytes(32).toString("hex");
const answer = "  fu… no, full truth.\nAgain again. שלום 👋  ";
const archive = "2026-11-18T03-00-00-000Z-1234abcd";
const text = (value: string) => ({ content: [{ type: "text", text: value }] });
const MODERN = "2026-07-28";
const TASKS = "io.modelcontextprotocol/tasks";
/** What Claude Code puts in every 2026-07-28 request that may become a task. */
const modernMeta = (tasks: boolean) => ({
  "io.modelcontextprotocol/protocolVersion": MODERN,
  "io.modelcontextprotocol/clientCapabilities": tasks ? { extensions: { [TASKS]: {} } } : {},
});

function isolatedSocket(name: string) {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!root || process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("preload required");
  // Relative AF_UNIX names fit deep official T3 worktrees; the parent is the preload's exclusive per-run directory.
  return relative(process.cwd(), join(root, name));
}
async function daemon(name: string, executeTool: Executor) {
  const path = isolatedSocket(name);
  const instance = await createMcpDaemon({ socketPath: path, toolExecutor: { executeTool: executeTool as never } });
  cleanups.push(() => instance.stop());
  return path;
}
async function client(path: string, framed: boolean) {
  const socket = createConnection(path);
  cleanups.push(() => socket.destroy());
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  let buffer = "";
  const waiting = new Map<number, (value: Rpc) => void>();
  const raw = new Map<number, string>();
  const notifications: Rpc[] = [];
  socket.on("data", chunk => {
    buffer += chunk.toString();
    let messages: { message: Rpc; wire: string }[];
    if (framed) {
      const parsed = parseMcpFrames(buffer); buffer = parsed.remainder;
      // JSON.parse keeps key order, so re-stringifying the body is the body's compact bytes.
      messages = (parsed.messages as Rpc[]).map(message => ({ message, wire: JSON.stringify(message) }));
    } else {
      const lines = buffer.split("\n"); buffer = lines.pop()!;
      messages = lines.filter(Boolean).map(wire => ({ message: JSON.parse(wire) as Rpc, wire }));
    }
    for (const { message, wire } of messages) {
      if (message.method) { notifications.push(message); continue; }
      if (message.id !== undefined) { raw.set(message.id, wire); waiting.get(message.id)?.(message); waiting.delete(message.id); }
    }
  });
  const send = (value: unknown) => socket.write(framed ? serializeMcpFrame(value as Record<string, unknown>) : JSON.stringify(value) + "\n");
  const rpc = (id: number, method: string, params: Record<string, unknown>) => {
    const result = new Promise<Rpc>(resolve => waiting.set(id, resolve));
    send({ jsonrpc: "2.0", id, method, params });
    return result;
  };
  return { socket, send, rpc, raw, notifications,
    /** A voice call as the bridge forwards it (caller capability bound in `_meta`). */
    call: (id: number, scope: string, args: Record<string, unknown>, options: { tasks?: boolean; progressToken?: number } = {}) =>
      rpc(id, "tools/call", { name: "voice_ask", arguments: args, _meta: {
        ...(options.tasks === undefined ? {} : modernMeta(options.tasks)),
        ...(options.progressToken === undefined ? {} : { progressToken: options.progressToken }),
        "voicelayer/caller": scope } }),
    get: (id: number, scope: string, taskId: unknown) =>
      rpc(id, "tasks/get", { taskId, _meta: { ...modernMeta(true), "voicelayer/caller": scope } }),
    cancel: (id: number, scope: string, taskId: unknown) =>
      rpc(id, "tasks/cancel", { taskId, _meta: { ...modernMeta(true), "voicelayer/caller": scope } }),
  };
}
const items = (response: Rpc) => response.result!.content!.map(item => item.text);
const json = (value: string) => JSON.parse(value);
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
function expectTask(response: Rpc, status: string) {
  expect(response.error).toBeUndefined();
  const task = response.result!;
  expect(task.resultType).toBe("task");
  expect(task.status).toBe(status);
  expect(typeof task.taskId).toBe("string");
  expect(task.taskId as string).toMatch(/^[\x21-\x7e]{1,128}$/);
  expect(task.createdAt as string).toMatch(ISO); expect(task.lastUpdatedAt as string).toMatch(ISO);
  expect("ttlMs" in task).toBe(true);
  expect(task.pollIntervalMs).toBe(2000);
  expect("content" in task).toBe(false);
  return task.taskId as string;
}
function expectPoll(response: Rpc, taskId: string, status: string) {
  expect(response.error).toBeUndefined();
  const poll = response.result!;
  expect(poll).toMatchObject({ resultType: "complete", taskId, status });
  expect(poll.createdAt as string).toMatch(ISO); expect(poll.lastUpdatedAt as string).toMatch(ISO);
  expect("ttlMs" in poll).toBe(true);
  return poll;
}
/** A latched fake Ask: `release()` lets it capture (archive + answer) and return. */
function latchedAsk() {
  const started = Promise.withResolvers<VoiceToolContext>(), finish = Promise.withResolvers<void>();
  const calls: Record<string, unknown>[] = [];
  const executor: Executor = async (_name, args, context) => {
    calls.push(args); started.resolve(context);
    await finish.promise;
    context.askDelivery?.archive(archive); context.askDelivery?.answer(answer);
    return text(answer);
  };
  cleanups.push(() => finish.resolve());
  return { executor, started: started.promise, release: () => finish.resolve(), calls };
}

for (const framed of [false, true]) {
  const transport = framed ? "Content-Length" : "NDJSON";

  for (const stage of ["speaking", "recording"] as const) {
    test(`${transport}: another authorized connection cancels the executing Ask during ${stage}`, async () => {
      const entered = Promise.withResolvers<void>(), stopped = Promise.withResolvers<void>();
      let context: VoiceToolContext | undefined, stageSignal: AbortSignal | undefined;
      const speech = { displayText: "q", engine: "edge-tts", voice: "en-US-JennyNeural",
        audioArtifact: { bytes: new Uint8Array([0x49, 0x44, 0x33]), format: "mp3" as const } };
      const latch = async (signal: AbortSignal | undefined) => {
        stageSignal = signal;
        signal?.addEventListener("abort", () => stopped.resolve(), { once: true });
        entered.resolve();
        await stopped.promise;
      };
      const spies = [
        spyOn(socketClient, "broadcast").mockImplementation(() => {}),
        spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true,
          owner: { pid: process.pid, sessionId: "test", startedAt: new Date().toISOString() } }),
        spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
        spyOn(input, "clearInput").mockImplementation(() => {}),
        spyOn(sessionBooking, "clearStopSignal").mockImplementation(() => {}),
      ];
      const speak = spyOn(tts, "speak").mockImplementation(async (_message, options) => {
        if (stage === "speaking") await latch(options?.textOnlyOnSynthesisFailure);
        return speech as never;
      });
      const capture = spyOn(input, "waitForInput").mockImplementation(async (_t, _s, _p, options) => {
        options?.onCaptureStart?.();
        await latch(options?.signal);
        options?.onCaptureEnd?.();
        return null;
      });
      cleanups.push(() => { stopped.resolve(); for (const spy of [...spies, speak, capture]) spy.mockRestore(); });
      const path = await daemon(`${framed ? "f" : "n"}-${stage}.sock`, (_name, args, current) => {
        context = current;
        return handleVoiceAsk(args, current);
      });
      const a = await client(path, framed), b = await client(path, framed), scope = caller();
      const taskId = expectTask(await a.call(1, scope, { message: "Synthetic question?" }, { tasks: true }), "working");
      await entered.promise;
      expectPoll(await b.get(1, scope, taskId), taskId, "working");
      const foreign = await client(path, framed);
      expect((await foreign.cancel(1, caller(), taskId)).error).toMatchObject({ code: -32602 });
      expect(context?.disconnectSignal?.aborted).toBe(false);
      expect(stageSignal?.aborted).toBe(false);
      expect((await b.cancel(2, scope, taskId)).error).toBeUndefined();
      expect(context?.disconnectSignal?.aborted).toBe(true);
      expect(stageSignal?.aborted).toBe(true);
      await stopped.promise;
      await logged("ask_delivery.finalized");
      expectPoll(await a.get(2, scope, taskId), taskId, "cancelled");
      expect(speak).toHaveBeenCalledTimes(1);
      expect(capture).toHaveBeenCalledTimes(stage === "recording" ? 1 : 0);
    }, 5000);
  }

  test(`${transport}: server/discover on 2026-07-28 advertises tasks; initialize keeps 2024-11-05 byte-for-byte`, async () => {
    const path = await daemon(framed ? "da.sock" : "db.sock", async () => text("unused"));
    const a = await client(path, framed);
    const discovered = await a.rpc(1, "server/discover", { _meta: modernMeta(false) });
    expect(discovered.error).toBeUndefined();
    expect(discovered.result).toMatchObject({ resultType: "complete", capabilities: { tools: {}, extensions: { [TASKS]: {} } } });
    expect(discovered.result!.supportedVersions).toContain(MODERN);
    expect((discovered.result!._meta as Record<string, { name: string }>)["io.modelcontextprotocol/serverInfo"].name).toBe("voicelayer");
    // A modern request for a version we do not speak gets the modern error, never a silent downgrade.
    const future = await a.rpc(2, "server/discover", { _meta: { "io.modelcontextprotocol/protocolVersion": "2099-01-01" } });
    expect(future.error).toMatchObject({ code: -32022 });
    const legacy = await client(path, framed);
    await legacy.rpc(3, "initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "old", version: "1" } });
    expect(legacy.raw.get(3)).toMatch(/^\{"jsonrpc":"2\.0","id":3,"result":\{"protocolVersion":"2024-11-05","capabilities":\{"tools":\{\},"logging":\{\}\},"serverInfo":\{"name":"voicelayer","version":"[^"]+"\}\}\}$/);
  }, 5000);

  test(`${transport}: with the tasks extension voice_ask returns a task at once; tasks/get goes working -> completed with the original result`, async () => {
    const ask = latchedAsk();
    const path = await daemon(framed ? "ta.sock" : "tb.sock", ask.executor);
    const a = await client(path, framed), scope = caller();
    const accepted = await a.call(1, scope, { message: "Synthetic question?" }, { tasks: true, progressToken: 41 });
    const taskId = expectTask(accepted, "working");
    const context = await ask.started;
    // The Ask keeps running after the answer: polling shows it working.
    expectPoll(await a.get(2, scope, taskId), taskId, "working");
    // The call is already answered: its progress token is dead and must not be used again.
    context.emit({ kind: "voice_ask_progress", sequence: 1, stage: "recording", elapsedMs: 15_000 });
    ask.release(); await logged("ask_delivery.finalized");
    const done = expectPoll(await a.get(3, scope, taskId), taskId, "completed");
    const result = done.result as { content: Content[]; isError?: boolean };
    // The normal voice_ask result: the handler's content unchanged, then the caller-bound delivery receipt.
    expect(result.content[0]).toEqual({ type: "text", text: answer });
    expect(result.content).toHaveLength(2);
    expect(Object.keys(json(result.content[1]!.text)).sort()).toEqual(["acknowledge", "delivery_id", "lease_id"]);
    expect(result.isError).toBeUndefined();
    expect(a.notifications.some(n => n.method === "notifications/progress")).toBe(false);
    // Polling again is idempotent (a lost response can be re-read).
    expect(expectPoll(await a.get(4, scope, taskId), taskId, "completed").result).toEqual(result);
    expect(ask.calls).toEqual([{ message: "Synthetic question?" }]);
    const trace = logs.filter(line => line.includes("ask_delivery.")).join("\n");
    for (const event of ["task_accepted", "task_get"]) expect(trace.includes(`ask_delivery.${event}`)).toBe(true);
    for (const secret of [answer.trim(), "full truth", scope, "Synthetic"]) expect(trace.includes(secret)).toBe(false);
  }, 5000);

  test(`${transport}: without the extension the result is today's, byte-for-byte, and wait_seconds is ignored`, async () => {
    const seen: Record<string, unknown>[] = [];
    const path = await daemon(framed ? "pa.sock" : "pb.sock", async (_name, args) => { seen.push(args); return text("plain result"); });
    const a = await client(path, framed), scope = caller();
    // Nothing captured: the bare handler result, exactly as before (legacy, and modern without the extension).
    await a.call(1, scope, { message: "q" });
    await a.call(2, scope, { message: "q", wait_seconds: 30 });
    await a.call(3, scope, { message: "q", wait_seconds: 30 }, { tasks: false });
    for (const id of [1, 2, 3]) {
      expect(a.raw.get(id)).toBe(`{"jsonrpc":"2.0","id":${id},"result":{"content":[{"type":"text","text":"plain result"}]}}`);
    }
    expect(seen).toEqual([{ message: "q" }, { message: "q" }, { message: "q" }]);
  }, 5000);

  test(`${transport}: wait_seconds answered in time returns the plain result; expired returns the task`, async () => {
    let quick = true;
    const slow = latchedAsk();
    const path = await daemon(framed ? "wa.sock" : "wb.sock", async (name, args, context) => {
      if (!quick) return slow.executor(name, args, context);
      context.askDelivery?.archive(archive); context.askDelivery?.answer(answer); return text(answer);
    });
    const a = await client(path, framed), scope = caller();
    const plain = await a.call(1, scope, { message: "q", wait_seconds: 5 }, { tasks: true });
    expect(plain.result!.resultType).toBeUndefined();
    expect(items(plain)[0]).toBe(answer);
    const receipt = json(items(plain).at(-1)!);
    // Acknowledge the first Ask so the second can run.
    await a.rpc(2, "tools/call", { name: "voice_ask_results", arguments: { delivery_ack: { delivery_id: receipt.delivery_id, lease_id: receipt.lease_id } },
      _meta: { "voicelayer/caller": scope } });
    quick = false;
    const startedAt = performance.now();
    const expired = await a.call(3, scope, { message: "q", wait_seconds: 1 }, { tasks: true });
    expect(performance.now() - startedAt).toBeGreaterThanOrEqual(900);
    const taskId = expectTask(expired, "working");
    expect(slow.calls).toEqual([{ message: "q" }]); // wait_seconds never reaches the handler.
    slow.release(); await logged('"state":"ready"');
    expect(expectPoll(await a.get(4, scope, taskId), taskId, "completed").result).toMatchObject({ content: [{ type: "text", text: answer }, {}] });
  }, 5000);

  test(`${transport}: tasks/cancel ends the Ask; the task never later completes; the recording is kept`, async () => {
    const ask = latchedAsk();
    const path = await daemon(framed ? "ca.sock" : "cb.sock", ask.executor);
    const a = await client(path, framed), scope = caller();
    const taskId = expectTask(await a.call(1, scope, { message: "q" }, { tasks: true }), "working");
    const context = await ask.started;
    const ended = Promise.withResolvers<void>();
    context.disconnectSignal?.addEventListener("abort", () => ended.resolve(), { once: true });
    const cancelled = await a.cancel(2, scope, taskId);
    expect(cancelled.error).toBeUndefined();
    await ended.promise; // The Ask's own abort path ran, the same one a client disconnect uses.
    expect(expectPoll(await a.get(3, scope, taskId), taskId, "cancelled").result).toBeUndefined();
    ask.release(); await logged("ask_delivery.finalized");
    expectPoll(await a.get(4, scope, taskId), taskId, "cancelled");
    // The captured answer is retained for this caller and comes back before any new action.
    const recovered = await a.call(5, scope, { message: "next" });
    expect(json(items(recovered)[0]!)).toMatchObject({ status: "ready", archive_id: archive, answer, new_action_run: false });
  }, 5000);

  test(`${transport}: identical clientInfo, cwd and request ids never read each other's tasks; unknown ids are -32602`, async () => {
    const asks = [latchedAsk(), latchedAsk()];
    let n = 0;
    const path = await daemon(framed ? "xa.sock" : "xb.sock", (name, args, context) => asks[n++]!.executor(name, args, context));
    const a = await client(path, framed), b = await client(path, framed);
    for (const peer of [a, b]) await peer.rpc(0, "server/discover", { _meta: { ...modernMeta(false), cwd: "/same/seat",
      "io.modelcontextprotocol/clientInfo": { name: "same", version: "same" } } });
    const scopeA = caller(), scopeB = caller();
    const taskA = expectTask(await a.call(1, scopeA, { message: "q" }, { tasks: true }), "working");
    const taskB = expectTask(await b.call(1, scopeB, { message: "q" }, { tasks: true }), "working");
    expect(taskB).not.toBe(taskA);
    for (const response of [await b.get(2, scopeB, taskA), await b.cancel(3, scopeB, taskA), await a.get(2, scopeA, taskB)]) {
      expect(response.error).toMatchObject({ code: -32602 });
    }
    for (const bad of ["no-such-task", 42, undefined]) expect((await a.get(9, scopeA, bad)).error).toMatchObject({ code: -32602 });
    expectPoll(await a.get(3, scopeA, taskA), taskA, "working"); // B's cancel attempt changed nothing.
    for (const ask of asks) ask.release();
    await loggedTimes("ask_delivery.finalized", 2);
    const pollA = expectPoll(await a.get(4, scopeA, taskA), taskA, "completed");
    const pollB = expectPoll(await b.get(4, scopeB, taskB), taskB, "completed");
    const receipt = (poll: Record<string, unknown>) => json((poll.result as { content: Content[] }).content[1]!.text);
    expect(receipt(pollA).delivery_id).not.toBe(receipt(pollB).delivery_id);
  }, 5000);

  test(`${transport}: after a reconnect the task stays readable by its own caller only`, async () => {
    const ask = latchedAsk();
    const path = await daemon(framed ? "ra.sock" : "rb.sock", ask.executor);
    const scope = caller(), a = await client(path, framed);
    const taskId = expectTask(await a.call(1, scope, { message: "q" }, { tasks: true }), "working");
    await ask.started; ask.release(); await logged("ask_delivery.finalized");
    a.socket.destroy(); await logged("ask_delivery.connection_close");
    // Bridge reconnect: same capability, new daemon connection.
    const again = await client(path, framed);
    const poll = expectPoll(await again.get(1, scope, taskId), taskId, "completed");
    expect((poll.result as { content: Content[] }).content[0]).toEqual({ type: "text", text: answer });
    // A restarted bridge (fresh capability) cannot read it.
    const stranger = await client(path, framed);
    expect((await stranger.get(1, caller(), taskId)).error).toMatchObject({ code: -32602 });
  }, 5000);
}

test("a task for an Ask with nothing captured completes with the handler's result exactly (no receipt)", async () => {
  const path = await daemon("va.sock", async () => ({ ...text("voice_ask archive retranscription result"), isError: false }));
  const a = await client(path, false), scope = caller();
  const taskId = expectTask(await a.call(1, scope, { retranscribe_archive_id: archive }, { tasks: true }), "working");
  await logged("ask_delivery.finalized");
  expect(expectPoll(await a.get(2, scope, taskId), taskId, "completed").result)
    .toEqual({ ...text("voice_ask archive retranscription result"), isError: false });
});
