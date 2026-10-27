import { afterEach, expect, test } from "bun:test";
import { createServer, type Socket } from "node:net";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { mkdirSync, writeFileSync, readFileSync, statSync } from "node:fs";
import { z } from "zod";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { testSocket, testTmp } from "./setup/test-tmp";
import { withChildFixtureEnv } from "./setup/child-env";

const rpc = z.looseObject({ id: z.union([z.string(), z.number()]).optional(), method: z.string().optional() });
const cleanups: (() => void | Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });
const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
async function until(check: () => boolean) {
  for (let n = 0; n < 300; n++) { if (check()) return; await pause(10); }
  throw new Error("Bridge fixture timed out");
}
function launch(path: string) {
  const child = withChildFixtureEnv({ VOICELAYER_MCP_SOCKET_PATH: path }, () => Bun.spawn([process.execPath, "src/mcp-bridge.ts"], {
    env: process.env, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  }));
  const messages: z.infer<typeof rpc>[] = [];
  const retries: number[] = [];
  const diagnostics = createInterface({ input: Readable.fromWeb(child.stderr) });
  diagnostics.on("line", line => {
    const event = z.object({ delayMs: z.number() }).safeParse(JSON.parse(line));
    if (event.success) retries.push(event.data.delayMs);
  });
  const lines = createInterface({ input: Readable.fromWeb(child.stdout) });
  lines.on("line", line => messages.push(rpc.parse(JSON.parse(line))));
  cleanups.push(async () => { child.kill(); await child.exited; lines.close(); diagnostics.close(); });
  return { child, messages, retries, send: (value: unknown) => { child.stdin.write(JSON.stringify(value) + "\n"); child.stdin.flush(); } };
}
async function daemon(path: string, version = "old", respondToInitialize = true) {
  const messages: z.infer<typeof rpc>[] = [];
  const sockets = new Set<Socket>();
  let initialized = false;
  const server = createServer(socket => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    const lines = createInterface({ input: socket });
    lines.on("line", line => {
      const message = rpc.parse(JSON.parse(line)); messages.push(message);
      if (message.method === "notifications/initialized") initialized = true;
      if (message.method === "initialize" && respondToInitialize) socket.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { version, protocolVersion: "2025-11-25", capabilities: {}, serverInfo: { name: "fixture", version } } }) + "\r\n");
      if (message.method === "tools/call") socket.write(JSON.stringify({ jsonrpc: "2.0", id: message.id, result: { initialized, version, text: "שלום 👋" } }) + "\n");
    });
  });
  await new Promise<void>(resolve => server.listen(path, resolve));
  let stopped = false;
  const stop = async () => {
    if (stopped) return; stopped = true;
    for (const socket of sockets) socket.destroy();
    await new Promise<void>(resolve => server.close(() => resolve()));
  };
  cleanups.push(stop);
  return { messages, sockets, stop };
}
const init = { jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: "future", capabilities: {} } };
const initialized = { jsonrpc: "2.0", method: "notifications/initialized", params: { extension: true } };
test("restart replays handshake, fails in-flight once, and queues calls without duplication", async () => {
  const path = testSocket("br.sock"); const old = await daemon(path); const bridge = launch(path);
  bridge.send(init); await until(() => bridge.messages.length === 1); bridge.send(initialized);
  bridge.send({ jsonrpc: "2.0", id: "pending", method: "hold" });
  await until(() => old.messages.length === 3); await old.stop();
  await until(() => bridge.messages.length === 2);
  expect(bridge.messages[1]).toMatchObject({ id: "pending", error: { code: -32000 } });
  bridge.send({ jsonrpc: "2.0", id: "queued", method: "tools/call" });
  const next = await daemon(path, "new"); await until(() => bridge.messages.length === 3);
  expect(next.messages).toEqual([init, initialized, { jsonrpc: "2.0", id: "queued", method: "tools/call" }]);
  expect(bridge.messages[2]).toMatchObject({ id: "queued", result: { initialized: true, version: "new", text: "שלום 👋" } });
  await pause(100); expect(bridge.messages.length).toBe(3); expect(bridge.child.exitCode).toBeNull();
  await next.stop(); await until(() => bridge.retries.length === 2);
  const third = await daemon(path, "third"); await until(() => third.messages.length === 2);
  bridge.send({ jsonrpc: "2.0", id: 10, method: "tools/call" });
  await until(() => bridge.messages.length === 4);
  expect(bridge.messages[3]).toMatchObject({ id: 10, result: { version: "third" } });
});
test("offline queue is bounded and every excess request gets its own error", async () => {
  const path = testSocket("bq.sock"); const bridge = launch(path);
  for (let id = 1; id <= 140; id++) bridge.send({ jsonrpc: "2.0", id, method: "tools/call" });
  await until(() => bridge.messages.length >= 12);
  expect(bridge.messages.map(message => message.id)).toEqual(Array.from({ length: 12 }, (_, n) => n + 129));
  expect(bridge.messages.every(message => !!message.error)).toBe(true);
  const server = await daemon(path); await until(() => bridge.messages.length === 140);
  expect(server.messages.length).toBe(128);
});
test("fragmented Unicode NDJSON preserves string IDs and unknown fields", async () => {
  const path = testSocket("bf.sock"); const server = await daemon(path); const bridge = launch(path);
  const frame = Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: "future", method: "tools/call", params: { text: "שלום 👋", extension: [1, true] } }) + "\r\n");
  const split = frame.indexOf(Buffer.from("ש")) + 1;
  bridge.child.stdin.write(frame.subarray(0, split)); bridge.child.stdin.flush(); await pause(20);
  bridge.child.stdin.write(frame.subarray(split)); bridge.child.stdin.flush();
  await until(() => bridge.messages.length === 1);
  expect(server.messages[0]).toEqual(JSON.parse(frame.toString()));
  expect(bridge.messages[0]).toMatchObject({ id: "future", result: { text: "שלום 👋" } });
});
test("daemon absence uses backoff; stdin EOF exits without leaving a reconnect loop", async () => {
  const started = performance.now();
  const bridge = launch(testSocket("bd.sock"));
  await until(() => bridge.retries.length === 4); expect(bridge.child.exitCode).toBeNull();
  expect(performance.now() - started).toBeGreaterThanOrEqual(650);
  expect(bridge.retries).toEqual([100, 200, 400, 800]);
  bridge.child.stdin.end(); await until(() => bridge.child.exitCode !== null);
  expect(await bridge.child.exited).toBe(0);
  expect(bridge.child.resourceUsage()?.cpuTime.total ?? Infinity).toBeLessThan(400_000);
});
test("offline queue byte bound rejects a large request without losing the accepted request", async () => {
  const path = testSocket("bb.sock"); const bridge = launch(path);
  for (const id of [1, 2]) bridge.send({ jsonrpc: "2.0", id, method: "tools/call", params: { text: "x".repeat(700_000) } });
  await until(() => bridge.messages.length === 1);
  expect(bridge.messages[0]).toMatchObject({ id: 2, error: { code: -32001 } });
  const server = await daemon(path); await until(() => bridge.messages.length === 2);
  expect(server.messages.map(message => message.id)).toEqual([1]);
});
test("stdin EOF drains a request before terminating", async () => {
  const path = testSocket("be.sock"); await daemon(path); const bridge = launch(path);
  bridge.send({ jsonrpc: "2.0", id: 8, method: "tools/call" }); bridge.child.stdin.end();
  await until(() => bridge.child.exitCode !== null);
  expect(bridge.messages).toMatchObject([{ id: 8, result: { text: "שלום 👋" } }]);
});
test("real MCP SDK client keeps its stdio session across backend replacement", async () => {
  const path = testSocket("bs.sock"); const old = await daemon(path);
  const transport = new StdioClientTransport({ command: process.execPath, args: ["src/mcp-bridge.ts"], env: { ...process.env, VOICELAYER_MCP_SOCKET_PATH: path }, stderr: "pipe" });
  const client = new Client({ name: "bridge-test", version: "1" });
  cleanups.push(() => client.close());
  await withChildFixtureEnv({ VOICELAYER_MCP_SOCKET_PATH: path }, () => client.connect(transport));
  await until(() => old.messages.length === 2); await old.stop();
  const next = await daemon(path, "replacement");
  const result = await client.request({ method: "tools/call", params: { name: "test", arguments: {} } }, z.object({ initialized: z.boolean(), version: z.string() }));
  expect(result).toEqual({ initialized: true, version: "replacement" }); expect(next.messages.length).toBe(3);
});
test("queued calls wait for replay response, and a failed replay retains the queue", async () => {
  const path = testSocket("bg.sock"); const old = await daemon(path); const bridge = launch(path);
  bridge.send(init); await until(() => bridge.messages.length === 1); bridge.send(initialized);
  await until(() => old.messages.length === 2); await old.stop(); await until(() => bridge.retries.length > 0);
  bridge.send({ jsonrpc: "2.0", id: 9, method: "tools/call" });
  const blocked = await daemon(path, "blocked", false); await until(() => blocked.messages.length === 1);
  await pause(100); expect(blocked.messages).toEqual([init]);
  for (const socket of blocked.sockets) socket.write(JSON.stringify({ jsonrpc: "2.0", id: 0, error: { code: -1, message: "retry" } }) + "\n");
  await blocked.stop(); const next = await daemon(path, "next");
  await until(() => bridge.messages.length === 2);
  expect(bridge.messages[1]).toMatchObject({ id: 9, result: { initialized: true } });
  expect(next.messages.map(message => message.method)).toEqual(["initialize", "notifications/initialized", "tools/call"]);
});
test("migration prefers bridge, preserves metadata, is idempotent, and falls back to socat", async () => {
  const root = testTmp("bridge-migration"); const bin = `${root}/bin`; const repo = `${root}/repos/example`;
  mkdirSync(bin, { recursive: true }); mkdirSync(repo, { recursive: true });
  const config = `${repo}/.mcp.json`;
  writeFileSync(config, JSON.stringify({ mcpServers: { voice: { command: "socat", args: ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"], env: { CUSTOM: "kept" } }, other: { command: "other" } } }));
  writeFileSync(`${bin}/voicelayer-mcp-bridge`, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const run = async (fallback = false, dry = false) => {
    const child = Bun.spawn(["/bin/bash", "scripts/migrate-to-daemon.sh", "--root", `${root}/repos`, ...(dry ? ["--dry-run"] : [])], {
      env: { ...process.env, PATH: fallback ? "/usr/bin:/bin" : `${bin}:/usr/bin:/bin` }, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    expect({ code, stderr }).toEqual({ code: 0, stderr: "" }); return stdout;
  };
  const original = readFileSync(config, "utf8"); await run(false, true); expect(readFileSync(config, "utf8")).toBe(original);
  await run(); expect(JSON.parse(readFileSync(config, "utf8")).mcpServers.voice).toEqual({ command: `${bin}/voicelayer-mcp-bridge`, env: { CUSTOM: "kept" } });
  const mtime = statSync(config).mtimeMs; await run(); expect(statSync(config).mtimeMs).toBe(mtime);
  expect(readFileSync(`${config}.bak`, "utf8")).toBe(original);
  expect(await run(true)).toContain("socat");
  expect(JSON.parse(readFileSync(config, "utf8")).mcpServers.voice.command).toBe("socat");
});
