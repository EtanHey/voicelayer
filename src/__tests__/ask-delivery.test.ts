/**
 * Interrupted voice_ask reaches its caller on the next call (lane c7). Real daemon transport (NDJSON and
 * Content-Length), latch-driven, preload-isolated, no microphone. Synthetic text only.
 */
import { afterEach, beforeEach, expect, spyOn, test } from "bun:test";
import { createHash, randomBytes } from "node:crypto";
import { mkdtempSync } from "node:fs";
import { join, relative } from "node:path";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { createMcpDaemon } from "../mcp-daemon";
import { parseMcpFrames, serializeMcpFrame } from "../mcp-framing";
import type { VoiceToolContext } from "../mcp-notifications";
import * as tts from "../tts";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import { handleVoiceAsk } from "../handlers";

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
type Rpc = { id?: number; result?: { content: { text: string }[]; isError?: boolean }; error?: unknown };
type Executor = (name: string, args: Record<string, unknown>, context: VoiceToolContext) => Promise<unknown>;
const caller = () => randomBytes(32).toString("hex");
const answer = "  fu… no, full truth.\nAgain again. שלום 👋  ";
const archive = "2026-11-17T12-00-00-000Z-1234abcd";
const text = (value: string) => ({ content: [{ type: "text", text: value }] });
function isolatedSocket(name: string) {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!root || process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("preload required");
  // Relative AF_UNIX names also fit deep official T3 worktrees; the parent is
  // still the preload's exclusive per-run directory, never a live socket.
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
  socket.on("data", chunk => {
    buffer += chunk.toString();
    let messages: Rpc[];
    if (framed) { const parsed = parseMcpFrames(buffer); buffer = parsed.remainder; messages = parsed.messages as Rpc[]; }
    else { const lines = buffer.split("\n"); buffer = lines.pop()!; messages = lines.filter(Boolean).map(line => JSON.parse(line)); }
    for (const message of messages) if (message.id !== undefined) { waiting.get(message.id)?.(message); waiting.delete(message.id); }
  });
  const send = (value: unknown) => socket.write(framed ? serializeMcpFrame(value as Record<string, unknown>) : JSON.stringify(value) + "\n");
  const rpc = (id: number, method: string, params: Record<string, unknown>) => {
    const result = new Promise<Rpc>(resolve => waiting.set(id, resolve));
    send({ jsonrpc: "2.0", id, method, params });
    return result;
  };
  return { socket, send, rpc,
    call: (id: number, scope: unknown, name = "voice_ask", args: Record<string, unknown> = { message: "Synthetic question?" }) =>
      rpc(id, "tools/call", { name, arguments: args, _meta: { "voicelayer/caller": scope } }),
  };
}
const items = (response: Rpc) => response.result!.content.map(item => item.text);
const json = (value: string) => JSON.parse(value);
/** Status line of a recovery result, or the receipt appended to an original result. */
const head = (response: Rpc) => json(items(response)[0]!);
const tail = (response: Rpc) => json(items(response).at(-1)!);
const ack = (delivery: { delivery_id: string; lease_id: string }) =>
  ({ delivery_ack: { delivery_id: delivery.delivery_id, lease_id: delivery.lease_id } });

for (const framed of [false, true]) {
  const transport = framed ? "Content-Length" : "NDJSON";
  test(`${transport}: ready recovery preserves a retained STT error without running the requested action`, async () => {
    let executions = 0;
    const path = await daemon(framed ? "ef.sock" : "en.sock", async (_name, _args, context) => {
      executions++; context.askDelivery?.archive(archive);
      return { ...text("Synthetic STT failure; recording kept"), isError: true };
    });
    const a = await client(path, framed), scope = caller();
    expect((await a.call(1, scope)).result?.isError).toBe(true);
    const held = await a.call(2, scope, "voice_speak", { message: "Synthetic speech" });
    expect(head(held)).toMatchObject({ status: "ready", new_action_run: false, archive_id: archive });
    expect(items(held)[1]).toBe("Synthetic STT failure; recording kept");
    expect(executions).toBe(1);
    expect(held.result?.isError).toBe(true);
  });

  test(`${transport}: a cancelled Ask is pending, then recovered with exact bytes before any new action, until acked`, async () => {
    const started = Promise.withResolvers<void>(), finish = Promise.withResolvers<void>();
    const ran: { name: string; args: Record<string, unknown> }[] = [];
    const path = await daemon(framed ? "f.sock" : "n.sock", async (name, args, context) => {
      ran.push({ name, args });
      if (ran.length > 1) return text("new side effect ran");
      started.resolve(); await finish.promise;
      context.askDelivery?.archive(archive); context.askDelivery?.answer(answer);
      return text(answer);
    });
    cleanups.push(() => finish.resolve());
    const a = await client(path, framed), scope = caller();
    let originalAnswered = false;
    void a.call(1, scope).then(() => { originalAnswered = true; });
    await started.promise;
    a.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1, reason: "SYNTHETIC_PRIVATE_REASON" } });
    await logged('"matched":true');
    // The older Ask is still running: pending status, no second capture.
    expect(head(await a.call(2, scope))).toMatchObject({ status: "pending", new_action_run: false });
    expect(ran).toHaveLength(1);
    finish.resolve(); await logged("ask_delivery.finalized");
    const held = await a.call(3, scope, "voice_speak", { message: "Synthetic speech" });
    expect(head(held)).toMatchObject({ status: "ready", new_action_run: false, archive_id: archive });
    expect(head(held).answer).toBe(answer); // Exact bytes: fragment, retraction, repeat, whitespace, Unicode.
    expect(items(held)[1]).toBe(answer); // The original response, unchanged.
    expect(ran).toHaveLength(1);
    // A response write is not delivery: without an ack the same delivery comes back.
    const again = head(await a.call(4, scope));
    expect(again.delivery_id).toBe(head(held).delivery_id); expect(again.lease_id).toBe(head(held).lease_id);
    // A piggybacked ack is consumed and the new call then runs, without the ack in its arguments.
    expect(items(await a.call(5, scope, "voice_speak", { message: "Synthetic speech", ...ack(again) }))).toEqual(["new side effect ran"]);
    expect(ran).toHaveLength(2); expect(ran[1]).toEqual({ name: "voice_speak", args: { message: "Synthetic speech" } });
    expect(originalAnswered).toBe(false); // The cancelled request never got a response.
    const trace = logs.filter(line => line.includes("ask_delivery.")).join("\n");
    for (const secret of [answer.trim(), "full truth", scope, "SYNTHETIC_PRIVATE_REASON", "Synthetic"]) expect(trace.includes(secret)).toBe(false);
    for (const event of ["connection_open", "request", "cancelled", "archive_associated", "finalized", "recovered", "write_attempted", "delivery_acknowledged"]) {
      expect(trace.includes(`ask_delivery.${event}`)).toBe(true);
    }
    expect(trace.includes('"progress_token_present":false')).toBe(true);
  }, 5000);

  test(`${transport}: identical clientInfo, cwd and request ids never cross callers; malformed scope runs nothing`, async () => {
    let executions = 0;
    const path = await daemon(framed ? "i.sock" : "j.sock", async (_name, _args, context) => {
      executions++; context.askDelivery?.archive(archive); context.askDelivery?.answer(answer); return text(answer);
    });
    const a = await client(path, framed), b = await client(path, framed);
    const init = { clientInfo: { name: "same", version: "same" }, capabilities: {}, _meta: { cwd: "/same/seat" } };
    await a.rpc(0, "initialize", init); await b.rpc(0, "initialize", init);
    const scopeA = caller(), scopeB = caller();
    const aFirst = await a.call(1, scopeA), bFirst = await b.call(1, scopeB);
    expect(items(aFirst)[0]).toBe(answer); expect(items(bFirst)[0]).toBe(answer);
    expect(tail(bFirst).delivery_id).not.toBe(tail(aFirst).delivery_id); expect(executions).toBe(2);
    expect(head(await b.call(2, scopeB, "voice_ask_results", ack(tail(aFirst))))).toMatchObject({ status: "ack-refused" });
    const heldA = head(await a.call(2, scopeA, "voice_speak", { message: "x" }));
    expect(heldA.delivery_id).toBe(tail(aFirst).delivery_id); expect(executions).toBe(2);
    expect(head(await b.call(3, scopeB, "voice_ask_results", ack(tail(bFirst))))).toMatchObject({ status: "acknowledged" });
    expect(items(await b.call(4, scopeB, "voice_speak", { message: "x" }))).toEqual([answer]); // B is free; A's item never reached B.
    expect(executions).toBe(3);
    expect(head(await b.call(5, scopeA, "voice_speak", { message: "x" }))).toMatchObject({ status: "scope-refused" });
    const c = await client(path, framed);
    for (const [n, bad] of [[1, "../../not-a-capability"], [2, 42], [3, "A".repeat(64)]] as const) {
      expect((await c.call(n, bad, "voice_speak", { message: "x" })).result).toMatchObject({ isError: true });
    }
    expect(executions).toBe(3);
  }, 5000);

  test(`${transport}: disconnect before ack retries the same delivery; a restarted bridge cannot adopt it`, async () => {
    let executions = 0;
    const path = await daemon(framed ? "r.sock" : "s.sock", async (_name, _args, context) => {
      executions++; context.askDelivery?.archive(archive); context.askDelivery?.answer(answer); return text(answer);
    });
    const scope = caller(), a = await client(path, framed);
    const first = tail(await a.call(1, scope));
    a.socket.destroy(); await logged("ask_delivery.connection_close");
    // Bridge reconnect: same capability, new daemon connection.
    const reconnect = await client(path, framed);
    const retry = await reconnect.call(1, scope, "voice_speak", { message: "x" });
    expect(head(retry).delivery_id).toBe(first.delivery_id); expect(items(retry)[1]).toBe(answer);
    expect(head(retry).lease_id).not.toBe(first.lease_id); expect(executions).toBe(1);
    expect(head(await reconnect.call(2, scope, "voice_ask_results", ack(first)))).toMatchObject({ status: "ack-refused" });
    // Restarted bridge: a fresh capability has no verified binding and gets nothing old (no newest-archive adoption).
    const restarted = await client(path, framed);
    const fresh = await restarted.call(1, caller(), "voice_speak", { message: "x" });
    expect(items(fresh)).toEqual([answer]); expect(executions).toBe(2);
    expect(JSON.stringify(fresh).includes(first.delivery_id)).toBe(false);
    // The original item stays retained for its own caller.
    expect(head(await reconnect.call(3, scope, "voice_speak", { message: "x" })).delivery_id).toBe(first.delivery_id);
  }, 5000);
}

test("a refusal with nothing captured leaves nothing to recover, so the next call runs", async () => {
  let executions = 0;
  const path = await daemon("v.sock", async () => { executions++; return { ...text("[converse] Another Ask owns capture admission"), isError: true }; });
  const a = await client(path, false), scope = caller();
  expect(items(await a.call(1, scope))).toEqual(["[converse] Another Ask owns capture admission"]);
  expect(items(await a.call(2, scope))).toEqual(["[converse] Another Ask owns capture admission"]);
  expect(executions).toBe(2);
});

test("late transcription: a bounded timeout response is pending, and the flow's later answer is recovered", async () => {
  const done = Promise.withResolvers<{ content: { type: string; text: string }[] }>();
  let executions = 0;
  let hooks: VoiceToolContext["askDelivery"];
  const path = await daemon("l.sock", async (_name, _args, context) => {
    executions++; hooks = context.askDelivery; hooks?.archive(archive); hooks?.defer(done.promise); hooks?.timedOut();
    return text("synthetic bounded timeout; recording kept");
  });
  const a = await client(path, false), scope = caller();
  const bounded = await a.call(1, scope);
  expect(items(bounded)[0]).toBe("synthetic bounded timeout; recording kept");
  expect(tail(bounded)).toMatchObject({ status: "pending" });
  expect(head(await a.call(2, scope))).toMatchObject({ status: "pending", new_action_run: false }); expect(executions).toBe(1);
  hooks!.answer(answer); done.resolve(text(answer)); await logged('"state":"ready"');
  const held = await a.call(3, scope);
  expect(head(held)).toMatchObject({ status: "ready", archive_id: archive, new_action_run: false }); expect(items(held)[1]).toBe(answer);
  expect(executions).toBe(1);
});

test("a foreign cancellation with the same request id never cancels the owner", async () => {
  const started = Promise.withResolvers<void>(), finish = Promise.withResolvers<void>();
  const path = await daemon("c.sock", async () => { started.resolve(); await finish.promise; return text("synthetic"); });
  cleanups.push(() => finish.resolve());
  const a = await client(path, false), b = await client(path, false);
  const original = a.call(1, caller()); await started.promise;
  b.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1 } });
  await logged('"matched":false'); finish.resolve();
  expect(items(await original)).toEqual(["synthetic"]); // Nothing captured: a plain result, no receipt.
});

test("crash: a dead daemon's pending Ask with an archive becomes a ready pointer; without one it is voided", async () => {
  const kept = caller(), empty = caller();
  const script = `
    import { createHash } from "node:crypto";
    import { AskDeliveryStore } from ${JSON.stringify(join(process.cwd(), "src/ask-delivery.ts"))};
    const store = new AskDeliveryStore(() => {}), h = (v) => createHash("sha256").update(v).digest("hex");
    const row = store.begin(h(process.argv.at(-2))); store.archive(row.operation, ${JSON.stringify(archive)});
    store.begin(h(process.argv.at(-1))); store.close();`;
  const child = Bun.spawn([process.execPath, "--eval", script, kept, empty], { env: process.env, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(0);
  let executions = 0;
  const path = await daemon("o.sock", async () => { executions++; return text("new side effect ran"); });
  const a = await client(path, false);
  const recovered = await a.call(1, kept, "voice_speak", { message: "x" });
  expect(head(recovered)).toMatchObject({ status: "ready", archive_id: archive, new_action_run: false });
  expect(recovered.result?.isError).toBe(true);
  expect(items(recovered)[1]).toContain(`archive ${archive}`); expect(executions).toBe(0);
  const b = await client(path, false);
  expect(items(await b.call(1, empty, "voice_speak", { message: "x" }))).toEqual(["new side effect ran"]);
  expect(logs.some(line => line.includes("ask_delivery.orphan_retained"))).toBe(true);
});

test("real handleVoiceAsk: a steered (cancelled) Ask is returned on the next call without speaking or recording again", async () => {
  const stateRoot = mkdtempSync(join(tmpdir(), "voicelayer-ask-delivery-"));
  const saved = process.env.QA_VOICE_RECORDING_STATE_PATH;
  process.env.QA_VOICE_RECORDING_STATE_PATH = join(stateRoot, "recording-state.json");
  cleanups.push(() => { if (saved === undefined) delete process.env.QA_VOICE_RECORDING_STATE_PATH; else process.env.QA_VOICE_RECORDING_STATE_PATH = saved; });
  const spies = [
    spyOn(socketClient, "broadcast").mockImplementation(() => {}),
    spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({ booked: true, ownedByUs: true,
      owner: { pid: process.pid, sessionId: "test", startedAt: new Date().toISOString() } }),
    spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(undefined),
    spyOn(input, "clearInput").mockImplementation(() => {}),
    spyOn(sessionBooking, "clearStopSignal").mockImplementation(() => {}),
  ];
  const speak = spyOn(tts, "speak").mockResolvedValue({ displayText: "q", engine: "edge-tts", voice: "en-US-JennyNeural",
    audioArtifact: { bytes: new Uint8Array([0x49, 0x44, 0x33]), format: "mp3" as const } } as never);
  const captured = Promise.withResolvers<void>(), decoded = Promise.withResolvers<string>();
  const wait = spyOn(input, "waitForInput").mockImplementation(async (_t, _s, _p, options) => {
    options?.onCaptureStart?.(); options?.onSpeechStart?.();
    options?.onArchiveCreated?.(join(stateRoot, archive)); captured.resolve();
    const value = await decoded.promise; options?.onCaptureEnd?.(); return value;
  });
  cleanups.push(() => { decoded.resolve(answer); for (const spy of [...spies, speak, wait]) spy.mockRestore(); });
  const path = await daemon("h.sock", (name, args, context) => name === "voice_ask"
    ? handleVoiceAsk(args, context) : Promise.resolve(text("new side effect ran")));
  const a = await client(path, false), scope = caller();
  void a.call(1, scope); await captured.promise;
  a.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1 } });
  await logged('"matched":true');
  decoded.resolve(answer); await logged('"state":"ready"');
  const held = await a.call(2, scope);
  expect(head(held)).toMatchObject({ status: "ready", archive_id: archive, new_action_run: false });
  expect(head(held).answer).toBe(answer); // Raw bytes; the boxed original response follows unchanged.
  expect(items(held)[1]).toContain("Archive: " + archive);
  expect(speak).toHaveBeenCalledTimes(1); expect(wait).toHaveBeenCalledTimes(1);
});
