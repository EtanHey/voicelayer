import { afterEach, expect, test, spyOn } from "bun:test";
import { randomBytes } from "node:crypto";
import { join, relative } from "node:path";
import { createConnection } from "node:net";
import { createMcpDaemon } from "../mcp-daemon";
import { parseMcpFrames, serializeMcpFrame } from "../mcp-framing";
import type { VoiceToolContext } from "../mcp-notifications";

const cleanups: (() => void)[] = [];
afterEach(() => { for (const cleanup of cleanups.splice(0).reverse()) cleanup(); });
type Rpc = { id?: number; result?: { content: { text: string }[] }; error?: unknown };
const caller = () => randomBytes(32).toString("hex");
const meta = (scope: unknown) => ({ "voicelayer/caller": scope });
const answer = "  fu… no, full truth.\nAgain again. שלום 👋  ";
const archive = "2026-11-17T12-00-00-000Z-1234abcd";
function isolatedSocket(name: string) {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!root || process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("preload required");
  // Relative AF_UNIX names also fit deep official T3 worktrees; the parent is
  // still the preload's exclusive per-run directory, never a live socket.
  return relative(process.cwd(), join(root, name));
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
    call: (id: number, scope: unknown, name = "voice_ask", args = {}) => rpc(id, "tools/call", { name, arguments: args, _meta: meta(scope) }),
  };
}
function delivery(response: Rpc) { return JSON.parse(response.result!.content[0]!.text); }

for (const framed of [false, true]) {
  const transport = framed ? "Content-Length" : "NDJSON";
  test(`${transport}: pending retry, cancelled response recovery, lease and explicit ack`, async () => {
    const logs: string[] = [];
    const log = spyOn(console, "error").mockImplementation((...args) => { logs.push(args.join(" ")); });
    cleanups.push(() => log.mockRestore());
    const path = isolatedSocket(framed ? "f.sock" : "n.sock");
    const started = Promise.withResolvers<void>(), finish = Promise.withResolvers<void>();
    let executions = 0;
    const daemon = await createMcpDaemon({ socketPath: path, toolExecutor: {
      async executeTool(_name, _args, context) {
        executions++;
        if (executions > 1) return { content: [{ type: "text", text: JSON.stringify({ status: "new-side-effect-ran" }) }] };
        started.resolve(); await finish.promise;
        const hooks = context as VoiceToolContext & { askDelivery?: { archive(id: string): void; answer(text: string): void } };
        hooks.askDelivery?.archive(archive); hooks.askDelivery?.answer(answer);
        return { content: [{ type: "text", text: answer }] };
      },
    } });
    cleanups.push(() => daemon.stop()); cleanups.push(() => finish.resolve());
    const a = await client(path, framed), scope = caller();
    void a.call(1, scope); await started.promise;
    a.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1, reason: "SYNTHETIC_PRIVATE_REASON" } });
    const pending = delivery(await a.call(2, scope));
    expect(pending).toMatchObject({ status: "pending", new_action_run: false });
    expect(executions).toBe(1);
    finish.resolve();
    // Latch finalization via the original execution's completed promise below
    // is supplied by a benign tools/list round trip after the executor settles.
    await finish.promise; await a.rpc(90, "tools/list", {});
    const held = delivery(await a.call(3, scope, "voice_speak"));
    expect(held).toMatchObject({ status: "ready", new_action_run: false, answer, archive_id: archive });
    expect(held.delivery_id).toBeString(); expect(held.operation_id).toBeString(); expect(held.lease_id).toBeString();
    expect(executions).toBe(1);
    // No automatic acknowledgement on a response write. Same caller must ack.
    const again = delivery(await a.call(4, scope));
    expect(again.delivery_id).toBe(held.delivery_id);
    const ack = delivery(await a.call(5, scope, "voice_ask_results", { delivery_ack: { delivery_id: again.delivery_id, lease_id: again.lease_id } }));
    expect(ack).toMatchObject({ status: "acknowledged", delivery_id: held.delivery_id });
    expect(executions).toBe(1);
    const trace = logs.join("\n");
    expect(trace.includes(answer)).toBe(false); expect(trace.includes(scope)).toBe(false);
    expect(trace.includes("SYNTHETIC_PRIVATE_REASON")).toBe(false);
    for (const event of ["cancelled", "archive_associated", "finalized", "write_attempted", "delivery_acknowledged"]) expect(trace.includes(`ask_delivery.${event}`)).toBe(true);
  }, 5000);

  test(`${transport}: identical client info/request ids cannot recover another caller`, async () => {
    const path = isolatedSocket(framed ? "i.sock" : "j.sock");
    let executions = 0;
    const daemon = await createMcpDaemon({ socketPath: path, toolExecutor: {
      async executeTool() { executions++; return { content: [{ type: "text", text: "synthetic result" }] }; },
    } });
    cleanups.push(() => daemon.stop());
    const a = await client(path, framed), b = await client(path, framed);
    const init = { clientInfo: { name: "same", version: "same" }, capabilities: {} };
    await a.rpc(0, "initialize", init); await b.rpc(0, "initialize", init);
    const scopeA = caller(), scopeB = caller();
    const aFirst = delivery(await a.call(1, scopeA));
    const bFirst = delivery(await b.call(1, scopeB));
    expect(bFirst.delivery_id).not.toBe(aFirst.delivery_id); expect(executions).toBe(2);
    const foreign = delivery(await b.call(2, scopeB, "voice_ask_results", { delivery_ack: { delivery_id: aFirst.delivery_id, lease_id: aFirst.lease_id } }));
    expect(foreign.status).toBe("ack-refused");
    const heldA = delivery(await a.call(2, scopeA, "voice_speak"));
    expect(heldA.delivery_id).toBe(aFirst.delivery_id); expect(executions).toBe(2);
    const malformed = await b.call(3, "../../not-a-capability", "voice_speak");
    expect(malformed.result).toMatchObject({ isError: true }); expect(executions).toBe(2);
  }, 5000);

  test(`${transport}: disconnect before ack retries the same delivery, new identity cannot adopt it`, async () => {
    const path = isolatedSocket(framed ? "r.sock" : "s.sock");
    let executions = 0;
    const daemon = await createMcpDaemon({ socketPath: path, toolExecutor: { async executeTool(_name, _args, context) {
      executions++; context.askDelivery?.archive(archive); context.askDelivery?.answer(answer);
      return { content: [{ type: "text", text: answer }] };
    } } });
    cleanups.push(() => daemon.stop());
    const scope = caller(), a = await client(path, framed);
    const first = delivery(await a.call(1, scope));
    const closed = Promise.withResolvers<void>();
    const log = spyOn(console, "error").mockImplementation((line: unknown) => {
      if (typeof line === "string" && line.includes("ask_delivery.connection_close")) closed.resolve();
    });
    cleanups.push(() => log.mockRestore());
    a.socket.destroy(); await closed.promise;
    const reconnect = await client(path, framed);
    const retry = delivery(await reconnect.call(1, scope, "voice_speak"));
    expect(retry.delivery_id).toBe(first.delivery_id); expect(retry.answer).toBe(answer);
    expect(retry.lease_id).not.toBe(first.lease_id); expect(executions).toBe(1);
    const stale = delivery(await reconnect.call(2, scope, "voice_ask_results", { delivery_ack: { delivery_id: first.delivery_id, lease_id: first.lease_id } }));
    expect(stale.status).toBe("ack-refused");
    const restarted = await client(path, framed);
    const fresh = await restarted.call(1, caller(), "voice_speak");
    expect(fresh.result!.content[0]!.text).toBe(answer); expect(executions).toBe(2);
    // The new identity ran its own executor; it received no old envelope/id.
    expect(fresh.result!.content[0]!.text.includes(first.delivery_id)).toBe(false);
  }, 5000);
}

test("late pipeline settlement remains pending after bounded handler return", async () => {
  const path = isolatedSocket("l.sock"), done = Promise.withResolvers<{ content: { type: string; text: string }[] }>();
  let executions = 0;
  let hooks: VoiceToolContext["askDelivery"];
  const daemon = await createMcpDaemon({ socketPath: path, toolExecutor: { async executeTool(_name, _args, context) {
    executions++; hooks = context.askDelivery; hooks?.defer(done.promise);
    return { content: [{ type: "text", text: "synthetic early timeout" }] };
  } } });
  cleanups.push(() => daemon.stop());
  const a = await client(path, false), scope = caller();
  expect(delivery(await a.call(1, scope)).status).toBe("pending");
  expect(delivery(await a.call(2, scope)).status).toBe("pending"); expect(executions).toBe(1);
  hooks!.archive(archive); hooks!.answer(answer); done.resolve({ content: [{ type: "text", text: answer }] });
  await done.promise; await a.rpc(90, "tools/list", {});
  expect(delivery(await a.call(3, scope))).toMatchObject({ status: "ready", answer, archive_id: archive, new_action_run: false });
});

test("a foreign cancellation with the same request id never cancels the owner", async () => {
  const path = isolatedSocket("c.sock"), started = Promise.withResolvers<void>(), finish = Promise.withResolvers<void>();
  const daemon = await createMcpDaemon({ socketPath: path, toolExecutor: { async executeTool() {
    started.resolve(); await finish.promise; return { content: [{ type: "text", text: "synthetic" }] };
  } } });
  cleanups.push(() => daemon.stop()); cleanups.push(() => finish.resolve());
  const a = await client(path, false), b = await client(path, false);
  const original = a.call(1, caller()); await started.promise;
  b.send({ jsonrpc: "2.0", method: "notifications/cancelled", params: { requestId: 1 } });
  await b.rpc(90, "tools/list", {}); finish.resolve();
  expect(delivery(await original)).toMatchObject({ status: "ready", new_action_run: true });
});
