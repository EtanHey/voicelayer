import { afterEach, expect, test } from "bun:test";
import { createServer, type Socket } from "node:net";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { mkdirSync, writeFileSync, readFileSync, statSync, symlinkSync, rmSync } from "node:fs";
import { z } from "zod";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { testSocket, testTmp } from "./setup/test-tmp";
import { withChildFixtureEnv } from "./setup/child-env";

const rpc = z.looseObject({ id: z.union([z.string(), z.number(), z.null()]).optional(), method: z.string().optional() });
const cleanups: (() => void | Promise<void>)[] = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });
const pause = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
async function until(check: () => boolean) {
  for (let n = 0; n < 300; n++) { if (check()) return; await pause(10); }
  throw new Error("Bridge fixture timed out");
}
function launch(path: string, preload: string[] = []) {
  const child = withChildFixtureEnv({ VOICELAYER_MCP_SOCKET_PATH: path }, () => Bun.spawn([process.execPath, ...preload, "src/mcp-bridge.ts"], {
    env: process.env, stdin: "pipe", stdout: "pipe", stderr: "pipe",
  }));
  const messages: z.infer<typeof rpc>[] = [];
  const retries: number[] = [];
  const parseDiagnostic = (line: string) => {
    try {
      const event = z.object({ delayMs: z.number() }).safeParse(JSON.parse(line));
      if (event.success) retries.push(event.data.delayMs);
    } catch {}
  };
  const diagnostics = createInterface({ input: Readable.fromWeb(child.stderr) });
  diagnostics.on("line", parseDiagnostic);
  parseDiagnostic("non-JSON Bun diagnostic");
  const lines = createInterface({ input: Readable.fromWeb(child.stdout) });
  const output: string[] = [];
  lines.on("line", line => { output.push(line); const value = JSON.parse(line); messages.push(...(Array.isArray(value) ? value : [value]).map(item => rpc.parse(item))); });
  cleanups.push(async () => { child.kill(); await child.exited; lines.close(); diagnostics.close(); });
  return { child, messages, retries, output, send: (value: unknown) => { child.stdin.write(JSON.stringify(value) + "\n"); child.stdin.flush(); } };
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
  await pause(900); expect(bridge.child.exitCode).toBeNull();
  expect(performance.now() - started).toBeGreaterThanOrEqual(650);
  expect(bridge.retries).toEqual([100]);
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
test("malformed lines and batches preserve the connection and track every batch request", async () => {
  const path = testSocket("bad.sock"); const server = await daemon(path); const bridge = launch(path);
  bridge.send(init); await until(() => bridge.messages.length === 1);
  for (const socket of server.sockets) socket.removeAllListeners("data");
  const received: string[] = [];
  for (const socket of server.sockets) createInterface({ input: socket }).on("line", line => received.push(line));
  const batch = [{ jsonrpc: "2.0", id: "a", method: "hold" }, { jsonrpc: "2.0", id: "b", method: "hold" }];
  bridge.child.stdin.write("not JSON\n"); bridge.child.stdin.flush(); bridge.send(batch);
  await until(() => received.length === 2 || bridge.child.exitCode !== null);
  expect(bridge.child.exitCode).toBeNull(); expect(received).toEqual(["not JSON", JSON.stringify(batch)]);
  for (const socket of server.sockets) socket.write(JSON.stringify([{ jsonrpc: "2.0", id: "a", result: {} }]) + "\n");
  await until(() => bridge.messages.length === 2); await server.stop();
  await until(() => bridge.messages.length === 3);
  expect(bridge.messages[2]).toMatchObject({ id: "b", error: { code: -32000 } });
  bridge.send({ jsonrpc: "2.0", id: "after", method: "tools/call" }); await daemon(path);
  await until(() => bridge.messages.length === 4); expect(bridge.messages[3].id).toBe("after");
});
test("healthy writes above the queue budget drain and oversize input resynchronizes", async () => {
  const path = testSocket("large.sock"); const server = await daemon(path); const bridge = launch(path);
  bridge.send(init); await until(() => bridge.messages.length === 1);
  bridge.send({ jsonrpc: "2.0", id: "large", method: "tools/call", params: { text: "x".repeat(2 * 1024 * 1024) } });
  bridge.send({ jsonrpc: "2.0", id: "tail", method: "tools/call" });
  await until(() => bridge.messages.length === 3 || bridge.child.exitCode !== null);
  expect(bridge.messages.map(message => message.id)).toEqual([0, "large", "tail"]);
  bridge.send({ jsonrpc: "2.0", id: "pending", method: "hold" }); await until(() => server.messages.length === 4);
  bridge.child.stdin.write("x".repeat(16 * 1024 * 1024 + 1) + "\n"); bridge.child.stdin.flush();
  bridge.send({ jsonrpc: "2.0", id: "after", method: "tools/call" });
  await until(() => bridge.messages.length >= 5 || bridge.child.exitCode !== null);
  expect(bridge.child.exitCode).toBeNull(); expect(bridge.messages.at(-1)?.id).toBe("after");
  await server.stop(); await until(() => bridge.messages.length === 6);
  expect(bridge.messages.at(-1)).toMatchObject({ id: "pending", error: { code: -32000 } });
});
test("offline batches retain each ID and bad input does not discard the queue", async () => {
  const bridge = launch(testSocket("batch.sock"));
  bridge.send([{ jsonrpc: "2.0", id: "a", method: "hold" }, { jsonrpc: "2.0", id: "b", method: "hold" }]);
  bridge.child.stdin.write("bad JSON\n"); bridge.child.stdin.flush(); bridge.child.stdin.end();
  await until(() => bridge.child.exitCode !== null);
  expect(bridge.child.exitCode).toBe(0);
  expect(bridge.messages.filter(message => message.id !== null).map(message => message.id)).toEqual(["a", "b"]);
});
test("oversize input preserves queued calls and accepts the following frame", async () => {
  const path = testSocket("over.sock"); const bridge = launch(path);
  bridge.send({ jsonrpc: "2.0", id: "queued", method: "tools/call" });
  try { bridge.child.stdin.write("x".repeat(16 * 1024 * 1024 + 1) + "\n"); await bridge.child.stdin.flush(); } catch {}
  await pause(50); expect(bridge.child.exitCode).toBeNull();
  bridge.send({ jsonrpc: "2.0", id: "after", method: "tools/call" }); await daemon(path);
  await until(() => bridge.messages.length === 3);
  expect(bridge.messages).toMatchObject([{ id: null, error: { code: -32600 } }, { id: "queued" }, { id: "after" }]);
});
test("malformed daemon lines do not interrupt a large response or its pending request", async () => {
  const path = testSocket("reply.sock"); const server = await daemon(path); const bridge = launch(path);
  bridge.send({ jsonrpc: "2.0", id: "held", method: "hold" }); await until(() => server.messages.length === 1);
  const response = JSON.stringify({ jsonrpc: "2.0", id: "held", result: { text: "ש".repeat(1024 * 1024) } });
  for (const socket of server.sockets) socket.write("bad JSON\n" + response + "\r\n");
  await until(() => bridge.messages.length > 0 || bridge.child.exitCode !== null);
  expect(bridge.output).toEqual([response]); expect(bridge.messages[0]).toMatchObject({ id: "held", result: { text: "ש".repeat(1024 * 1024) } });
  expect(bridge.child.exitCode).toBeNull();
});
test("write completion flushes a queued frame when no drain event fires", async () => {
  const fixture = testTmp("bridge-no-drain.ts");
  writeFileSync(fixture, `import { Socket } from "node:net";
const original = Socket.prototype.write;
let first = true;
Socket.prototype.write = function(data, ...args) {
  if (!first) return original.call(this, data, ...args);
  first = false;
  let queued = 1;
  Object.defineProperty(this, "writableLength", { get: () => queued, configurable: true });
  original.call(this, data);
  let bytes = 0;
  const complete = chunk => {
    bytes += chunk.length;
    if (bytes < 1024 * 1024) return;
    process.stdin.off("data", complete);
    setImmediate(() => { queued = 0; args.find(arg => typeof arg === "function")?.(); });
  };
  process.stdin.on("data", complete);
  return true;
};\n`);
  const path = testSocket("drain.sock"); const server = await daemon(path); const bridge = launch(path, ["--preload", fixture]);
  const request = { jsonrpc: "2.0", id: "queued", method: "tools/call", params: { text: "" } };
  request.params.text = "x".repeat(1024 * 1024 - JSON.stringify(request).length - 1);
  bridge.send({ jsonrpc: "2.0", id: "first", method: "hold" }); await until(() => server.messages.length === 1); bridge.send(request);
  await until(() => bridge.messages.length === 1);
  expect(server.messages.map(message => message.id)).toEqual(["first", "queued"]);
  expect(bridge.messages[0]).toMatchObject({ id: "queued", result: { version: "old" } });
});
test("accept-close connections back off and retry diagnostics stay bounded", async () => {
  const path = testSocket("close.sock"); let attempts = 0;
  const server = createServer(socket => { attempts++; socket.destroy(); });
  await new Promise<void>(resolve => server.listen(path, resolve)); cleanups.push(() => { server.close(); });
  const bridge = launch(path); await pause(1200);
  expect(attempts).toBeGreaterThanOrEqual(3); expect(attempts).toBeLessThanOrEqual(5);
  expect(bridge.retries).toEqual([100]); expect(bridge.child.exitCode).toBeNull();
});
test("logging restores only acknowledged levels before calls and swallows replay responses", async () => {
  const path = testSocket("log.sock"); const old = await daemon(path); const bridge = launch(path);
  const level = { jsonrpc: "2.0", id: "level", method: "logging/setLevel", params: { level: "error" } };
  bridge.send(init); await until(() => bridge.messages.length === 1); bridge.send(initialized); bridge.send(level);
  await until(() => old.messages.length === 3);
  for (const socket of old.sockets) socket.write('{"jsonrpc":"2.0","id":"level","result":{}}\n');
  await until(() => bridge.messages.length === 2);
  bridge.send({ ...level, id: "unacknowledged", params: { level: "debug" } });
  await until(() => old.messages.length === 4); await old.stop(); await until(() => bridge.messages.length === 3);
  bridge.send({ jsonrpc: "2.0", id: "queued", method: "tools/call" });
  const next = await daemon(path); await until(() => next.messages.length >= 3);
  expect(next.messages).toEqual([init, initialized, level]); await pause(50); expect(next.messages.length).toBe(3);
  for (const socket of next.sockets) socket.write('{"jsonrpc":"2.0","id":"level","result":{}}\n');
  await until(() => bridge.messages.length === 4); expect(bridge.messages.at(-1)?.id).toBe("queued");
});
test("repeated rejected replays fail queued calls but keep reconnecting in background", async () => {
  const path = testSocket("reject.sock"); const old = await daemon(path); const bridge = launch(path);
  bridge.send(init); await until(() => bridge.messages.length === 1); await old.stop(); await until(() => bridge.retries.length > 0);
  bridge.send({ jsonrpc: "2.0", id: "queued", method: "tools/call" }); let attempts = 0;
  const sockets = new Set<Socket>();
  const server = createServer(socket => {
    sockets.add(socket); socket.on("close", () => sockets.delete(socket));
    createInterface({ input: socket }).on("line", () => { attempts++; socket.write('{"jsonrpc":"2.0","id":0,"error":{"code":-32602,"message":"unsupported"}}\n'); });
    cleanups.push(() => { socket.destroy(); });
  });
  await new Promise<void>(resolve => server.listen(path, resolve)); cleanups.push(() => { server.close(); });
  await until(() => bridge.messages.length === 2); expect(attempts).toBe(3);
  expect(bridge.messages[1]).toMatchObject({ id: "queued", error: { code: -32000 } });
  bridge.send({ jsonrpc: "2.0", id: "later", method: "tools/call" }); await until(() => bridge.messages.length === 3);
  expect(bridge.messages[2]).toMatchObject({ id: "later", error: { code: -32000 } });
  await pause(900); expect(attempts).toBe(4); expect(bridge.child.exitCode).toBeNull();
  for (const socket of sockets) socket.destroy(); await new Promise<void>(resolve => server.close(() => resolve()));
  const recovered = await daemon(path); await until(() => recovered.messages.length === 2);
  bridge.send({ jsonrpc: "2.0", id: "recovered", method: "tools/call" }); await until(() => bridge.messages.length === 4);
  expect(bridge.messages[3]).toMatchObject({ id: "recovered", result: { initialized: true } });
});
async function migrationFixture() {
  const root = testTmp("migration-" + Math.random().toString(16).slice(2)); const bin = `${root}/bin`; const repos = `${root}/repos`;
  const tools = `${root}/tools`;
  mkdirSync(tools, { recursive: true }); mkdirSync(bin, { recursive: true }); mkdirSync(`${repos}/example`, { recursive: true });
  writeFileSync(`${tools}/python3`, '#!/usr/bin/python3\nimport os, sys\nsys.argv.pop(1)\noriginal = os.path.isfile\nos.path.isfile = lambda p: False if str(p).startswith("/opt/homebrew/") else original(p)\nexec(compile(sys.stdin.read(), "migration", "exec"))\n', { mode: 0o755 });
  const config = `${repos}/example/.mcp.json`; const other = { command: "other", env: { TEXT: "שלום 👋" } };
  writeFileSync(config, JSON.stringify({ mcpServers: { voice: { command: "socat", args: ["STDIO", "UNIX-CONNECT:/tmp/voicelayer-mcp.sock"], env: { CUSTOM: "kept" } }, other } }));
  const run = async (thin = false, dry = false) => {
    const child = Bun.spawn(["/bin/bash", "scripts/migrate-to-daemon.sh", "--root", repos, ...(dry ? ["--dry-run"] : [])], {
      env: { ...process.env, HOME: root, PATH: thin ? `${tools}:/usr/bin:/bin` : `${bin}:${tools}:/usr/bin:/bin` }, stdout: "pipe", stderr: "pipe",
    });
    const [code, stdout, stderr] = await Promise.all([child.exited, new Response(child.stdout).text(), new Response(child.stderr).text()]);
    return { code, stdout, stderr };
  };
  return { root, bin, repos, config, other, run };
}
test("migration pins bun and stable bridge symlink, includes root, preserves Unicode/backup, and is idempotent", async () => {
  const { root, bin, repos, config, other, run } = await migrationFixture();
  const script = `${root}/mcp-bridge.ts`; writeFileSync(script, "#!/usr/bin/env bun\n", { mode: 0o755 });
  symlinkSync(script, `${bin}/voicelayer-mcp-bridge`); symlinkSync(process.execPath, `${bin}/bun`);
  const original = readFileSync(config, "utf8"); writeFileSync(`${repos}/.mcp.json`, original);
  const inode = statSync(config).ino;
  expect(await run(false, true)).toMatchObject({ code: 0 }); expect(readFileSync(config, "utf8")).toBe(original);
  expect(await run()).toMatchObject({ code: 0 });
  expect(statSync(config).ino).not.toBe(inode);
  for (const file of [config, `${repos}/.mcp.json`]) {
    const text = readFileSync(file, "utf8"); const data = JSON.parse(text);
    expect(data.mcpServers.voice).toEqual({ command: `${bin}/bun`, args: [`${bin}/voicelayer-mcp-bridge`], env: { CUSTOM: "kept" } });
    expect(JSON.stringify(data.mcpServers.other)).toBe(JSON.stringify(other)); expect(text).toContain("שלום 👋");
    expect(readFileSync(`${file}.bak`, "utf8")).toBe(original);
  }
  const mtime = statSync(config).mtimeMs; expect(await run()).toMatchObject({ code: 0 }); expect(statSync(config).mtimeMs).toBe(mtime);
});
test("migration never downgrades bridge seats on thin PATH and refuses missing transports", async () => {
  const { bin, config, run } = await migrationFixture();
  const original = readFileSync(config, "utf8");
  expect((await run(true)).code).toBe(1); expect(readFileSync(config, "utf8")).toBe(original);
  writeFileSync(`${bin}/socat`, "#!/bin/sh\nexit 0\n", { mode: 0o755 });
  const bridge = { command: "/missing/voicelayer-mcp-bridge", args: [], env: { KEPT: "yes" } };
  const canonical = { command: "/missing/bun", args: ["/missing/mcp-bridge.ts"] };
  const seats = { mcpServers: { voice: bridge, canonical } }; const before = JSON.stringify(seats);
  writeFileSync(config, before);
  expect(await run()).toMatchObject({ code: 0 }); expect(readFileSync(config, "utf8")).toBe(before);
});
test("migration resolves bridge and bun from home bun bin without PATH", async () => {
  const { root, config, run } = await migrationFixture(); const bin = `${root}/.bun/bin`; mkdirSync(bin, { recursive: true });
  writeFileSync(`${bin}/voicelayer-mcp-bridge`, "#!/usr/bin/env bun\n", { mode: 0o755 }); symlinkSync(process.execPath, `${bin}/bun`);
  expect(await run(true)).toMatchObject({ code: 0 });
  expect(JSON.parse(readFileSync(config, "utf8")).mcpServers.voice).toMatchObject({ command: `${bin}/bun`, args: [`${bin}/voicelayer-mcp-bridge`] });
});

test("migration argv survives Homebrew keg replacement", async () => {
  const { root, bin, config, run } = await migrationFixture();
  const opt = `${root}/opt`; mkdirSync(opt);
  for (const version of ["1", "2"]) {
    const keg = `${root}/Cellar/voicelayer/${version}`; mkdirSync(`${keg}/src`, { recursive: true });
    writeFileSync(`${keg}/src/mcp-bridge.ts`, `console.log("bridge-${version}");`, { mode: 0o755 });
    mkdirSync(`${root}/Cellar/bun/${version}`, { recursive: true });
    symlinkSync(process.execPath, `${root}/Cellar/bun/${version}/bun`);
  }
  symlinkSync(`${root}/Cellar/voicelayer/1`, `${opt}/voicelayer`);
  symlinkSync(`${root}/Cellar/bun/1`, `${opt}/bun`);
  symlinkSync(`${opt}/voicelayer/src/mcp-bridge.ts`, `${bin}/voicelayer-mcp-bridge`);
  symlinkSync(`${opt}/bun/bun`, `${bin}/bun`);
  expect(await run()).toMatchObject({ code: 0 });
  const server = JSON.parse(readFileSync(config, "utf8")).mcpServers.voice;
  expect(JSON.stringify(server)).not.toContain("/Cellar/");
  for (const pkg of ["voicelayer", "bun"]) {
    rmSync(`${opt}/${pkg}`); symlinkSync(`${root}/Cellar/${pkg}/2`, `${opt}/${pkg}`);
    rmSync(`${root}/Cellar/${pkg}/1`, { recursive: true });
  }
  const child = Bun.spawn([server.command, ...server.args], { env: process.env, stdout: "pipe", stderr: "pipe" });
  expect(await child.exited).toBe(0);
  expect(await new Response(child.stdout).text()).toBe("bridge-2\n");
});
