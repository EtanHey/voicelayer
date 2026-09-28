import { afterEach, expect, it, spyOn } from "bun:test";
import { unlinkSync } from "fs";
import { dirname, join } from "path";
import { SOCKET_PATH } from "../paths";
import { connectToBar, disconnectFromBar, onCommand } from "../socket-client";
import type { SocketCommand } from "../socket-protocol";
import { MAX_NDJSON_LINE_BYTES, NDJSONByteFramer } from "../ndjson-byte-framer";
import { createMcpDaemon } from "../mcp-daemon";

// The preload puts SOCKET_PATH under this worktree's .test-tmp/<pid>/.
const TEST_SOCKET = join(dirname(SOCKET_PATH), "x.sock");
if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !TEST_SOCKET.includes(".test-tmp")) {
  throw new Error("socket byte-framing tests require the isolated preload");
}

let server: ReturnType<typeof Bun.listen> | null = null;
let daemon: Awaited<ReturnType<typeof createMcpDaemon>> | null = null;

afterEach(() => {
  disconnectFromBar();
  server?.stop(true);
  server = null;
  daemon?.stop();
  daemon = null;
  try { unlinkSync(TEST_SOCKET); } catch {}
});

function within<T>(promise: Promise<T>, label: string, timeoutMs = 2_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout>;
  return Promise.race([
    promise,
    new Promise<T>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`timed out: ${label}`)), timeoutMs);
    }),
  ]).finally(() => clearTimeout(timer));
}

it("keeps a VoiceBar command intact when two socket reads split a Hebrew character", async () => {
  let accept!: (socket: { write: (bytes: Uint8Array) => number }) => void;
  const accepted = new Promise<{ write: (bytes: Uint8Array) => number }>((resolve) => { accept = resolve; });
  server = Bun.listen({
    unix: TEST_SOCKET,
    socket: {
      open(socket) { accept(socket); },
      data() {}, close() {}, error() {}, drain() {},
    },
  });

  const received: SocketCommand[] = [];
  let firstHandled!: () => void;
  let secondHandled!: (command: SocketCommand) => void;
  const first = new Promise<void>((resolve) => { firstHandled = resolve; });
  const second = new Promise<SocketCommand>((resolve) => { secondHandled = resolve; });
  onCommand((command) => {
    received.push(command);
    if (command.cmd === "stop") firstHandled();
    if (command.cmd === "vocab_add") secondHandled(command);
  });

  let connected!: () => void;
  const opened = new Promise<void>((resolve) => { connected = resolve; });
  connectToBar(TEST_SOCKET, { onConnected: connected });
  const socket = await within(accepted, "server accept");
  await within(opened, "client open");

  const line = Buffer.from(JSON.stringify({ cmd: "vocab_add", from: "אבג — …", to: "Synthetic" }) + "\n");
  const split = line.indexOf(0xD7) + 1;
  expect(split).toBeGreaterThan(1);
  socket.write(Buffer.concat([Buffer.from('{"cmd":"stop"}\n'), line.subarray(0, split)]));
  await within(first, "first data callback"); // proves the partial command was consumed before the second write
  socket.write(line.subarray(split));

  const command = await within(second, "split command");
  expect(received.map((item) => item.cmd)).toEqual(["stop", "vocab_add"]);
  expect(command.cmd).toBe("vocab_add");
  if (command.cmd === "vocab_add") {
    expect(command.from).toBe("אבג — …");
    expect(command.from).not.toContain("\uFFFD");
  }
});

it("frames mixed Hebrew, em dash and ellipsis at every byte boundary", () => {
  const line = JSON.stringify({ value: "אבג — …" });
  const bytes = Buffer.from(`${line}\n`);
  for (let split = 1; split < bytes.length; split++) {
    const framer = new NDJSONByteFramer();
    expect(framer.append(bytes.subarray(0, split))).toEqual({ lines: [], overflow: false });
    expect(framer.append(bytes.subarray(split))).toEqual({ lines: [line], overflow: false });
  }
});

it("keeps ordered lines and a partial tail, skips empty lines, and rejects an oversized line", () => {
  const framer = new NDJSONByteFramer(8);
  expect(framer.append(Buffer.from("a\n\nb\nc"))).toEqual({ lines: ["a", "b"], overflow: false });
  expect(framer.append(Buffer.from("d\n"))).toEqual({ lines: ["cd"], overflow: false });
  expect(framer.append(Buffer.from("12345678\n"))).toEqual({ lines: ["12345678"], overflow: false });
  expect(framer.append(Buffer.from("123456789"))).toEqual({ lines: [], overflow: true });
  expect(framer.append(Buffer.from("ignored\n"))).toEqual({ lines: [], overflow: false });
});

it("keeps a long line with thousands of one-byte reads intact", () => {
  const line = "a".repeat(16_384);
  const framer = new NDJSONByteFramer(line.length);
  let overflow = false;
  for (const byte of Buffer.from(line)) {
    overflow ||= framer.append(Buffer.of(byte)).overflow;
  }
  expect(overflow).toBe(false);
  expect(framer.append(Buffer.from("\n"))).toEqual({ lines: [line], overflow: false });
});

it("closes and reconnects after a no-newline command exceeds the byte limit", async () => {
  let firstSocket!: {
    write: (bytes: Uint8Array) => number;
  };
  let accepted!: () => void;
  let closed!: () => void;
  let reaccepted!: () => void;
  let drained!: () => void;
  let replied!: () => void;
  const reply = new Promise<void>((resolve) => { replied = resolve; });
  const firstAccepted = new Promise<void>((resolve) => { accepted = resolve; });
  const firstClosed = new Promise<void>((resolve) => { closed = resolve; });
  const secondAccepted = new Promise<void>((resolve) => { reaccepted = resolve; });
  let drainWaiter: Promise<void> | null = null;
  let responseBuffer = "";
  let accepts = 0;
  server = Bun.listen({
    unix: TEST_SOCKET,
    socket: {
      open(socket) {
        accepts++;
        if (accepts === 1) {
          firstSocket = socket;
          accepted();
        } else {
          reaccepted();
        }
      },
      data(_socket, raw) {
        responseBuffer += raw.toString("utf8"); // the synthetic reply is ASCII
        if (responseBuffer.includes('"id":"prior"')) replied();
      },
      close() { closed(); },
      error() {},
      drain() { drained?.(); },
    },
  });

  let connects = 0;
  let opened!: () => void;
  let reopened!: () => void;
  const firstOpened = new Promise<void>((resolve) => { opened = resolve; });
  const secondOpened = new Promise<void>((resolve) => { reopened = resolve; });
  connectToBar(TEST_SOCKET, { onConnected: () => {
    connects++;
    if (connects === 1) opened();
    if (connects === 2) reopened();
  } });
  await within(Promise.all([firstAccepted, firstOpened]), "first connection");

  let dispatched!: () => void;
  let resolveResponse!: (response: { type: "ack"; command: "stop"; outcome: "accept"; id: string }) => void;
  const handled = new Promise<void>((resolve) => { dispatched = resolve; });
  onCommand(() => new Promise((resolve) => {
    resolveResponse = resolve;
    dispatched();
  }));
  const originalError = console.error;
  const errorSpy = spyOn(console, "error").mockImplementation((...args) => {
    originalError(...args);
    if (String(args[0]).includes("NDJSON command exceeded byte limit")) {
      resolveResponse({ type: "ack", command: "stop", outcome: "accept", id: "prior" });
    }
  });
  try {
    firstSocket.write(Buffer.from('{"cmd":"stop"}\n'));
    await within(handled, "earlier command dispatch");
    const payload = Buffer.alloc(MAX_NDJSON_LINE_BYTES + 1, 0x61);
    let offset = 0;
    while (offset < payload.length) {
      const end = Math.min(offset + 64 * 1024, payload.length);
      const written = firstSocket.write(payload.subarray(offset, end));
      if (written > 0) {
        offset += written;
      } else {
        drainWaiter = new Promise<void>((resolve) => { drained = resolve; });
        await within(drainWaiter, "socket drain", 5_000);
        drainWaiter = null;
      }
    }
    await within(reply, "earlier command reply", 5_000);
    await within(firstClosed, "overlimit close", 5_000);
    await within(Promise.all([secondAccepted, secondOpened]), "reconnect", 5_000);
    expect(connects).toBe(2);
    const limitLogs = errorSpy.mock.calls
      .map(([message]) => String(message))
      .filter((message) => message.includes("NDJSON command exceeded byte limit"));
    expect(limitLogs).toHaveLength(1);
    expect(limitLogs[0]).not.toContain("aaaa");
  } finally {
    errorSpy.mockRestore();
  }
});

it("keeps a split Unicode NDJSON message intact at the MCP daemon socket", async () => {
  const received: Record<string, unknown>[] = [];
  let firstHandled!: () => void;
  let secondHandled!: (message: Record<string, unknown>) => void;
  const first = new Promise<void>((resolve) => { firstHandled = resolve; });
  const second = new Promise<Record<string, unknown>>((resolve) => { secondHandled = resolve; });
  daemon = await createMcpDaemon({
    socketPath: TEST_SOCKET,
    onNdjsonMessage(message) {
      received.push(message);
      if (message.type === "probe") firstHandled();
      if (message.type === "sample") secondHandled(message);
    },
  });

  let writer!: { write: (bytes: Uint8Array) => number; end: () => void };
  let connected!: () => void;
  const opened = new Promise<void>((resolve) => { connected = resolve; });
  const client = await Bun.connect({
    unix: TEST_SOCKET,
    socket: {
      open(socket) { writer = socket; connected(); },
      data() {}, close() {}, error() {}, connectError() {}, drain() {},
    },
  });
  try {
    await within(opened, "daemon client open");
    const line = Buffer.from(JSON.stringify({ type: "sample", text: "אבג — …" }) + "\n");
    const split = line.indexOf(0xD7) + 1;
    writer.write(Buffer.concat([Buffer.from('{"type":"probe"}\n'), line.subarray(0, split)]));
    await within(first, "daemon first data callback");
    writer.write(line.subarray(split));
    const message = await within(second, "daemon split message");
    expect(received.map((item) => item.type)).toEqual(["probe", "sample"]);
    expect(message.text).toBe("אבג — …");
  } finally {
    client.end();
  }
});

it("handles daemon messages before closing on an oversized NDJSON line", async () => {
  let handled!: () => void;
  const first = new Promise<void>((resolve) => { handled = resolve; });
  let resolveTool!: (result: { content: Array<{ type: string; text: string }> }) => void;
  let replyReceived!: () => void;
  const reply = new Promise<void>((resolve) => { replyReceived = resolve; });
  daemon = await createMcpDaemon({
    socketPath: TEST_SOCKET,
    toolExecutor: { executeTool: () => new Promise((resolve) => { resolveTool = resolve; }) },
    onNdjsonMessage(message) {
      if (message.type === "probe") handled();
    },
  });

  let closed!: () => void;
  const close = new Promise<void>((resolve) => { closed = resolve; });
  let writer!: { write: (bytes: Uint8Array) => number };
  let opened!: () => void;
  let drained!: () => void;
  let responseBuffer = "";
  const open = new Promise<void>((resolve) => { opened = resolve; });
  const client = await Bun.connect({
    unix: TEST_SOCKET,
    socket: {
      open(socket) { writer = socket; opened(); },
      data(_socket, raw) {
        responseBuffer += raw.toString("utf8"); // synthetic JSON-RPC response is ASCII
        if (responseBuffer.includes('"id":17')) replyReceived();
      },
      close() { closed(); }, error() {}, connectError() {}, drain() { drained?.(); },
    },
  });
  const originalError = console.error;
  const errorSpy = spyOn(console, "error").mockImplementation((...args) => {
    originalError(...args);
    if (String(args[0]).includes("NDJSON message exceeded byte limit")) {
      resolveTool({ content: [{ type: "text", text: "synthetic" }] });
    }
  });
  try {
    await within(open, "daemon client open");
    const payload = Buffer.concat([
      Buffer.from('{"type":"probe"}\n'),
      Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 17, method: "tools/call", params: { name: "voice_speak", arguments: {} } }) + "\n"),
      Buffer.alloc(MAX_NDJSON_LINE_BYTES + 1, 0x61),
      Buffer.from("\n"),
    ]);
    let offset = 0;
    while (offset < payload.length) {
      const written = writer.write(payload.subarray(offset, Math.min(offset + 64 * 1024, payload.length)));
      if (written > 0) {
        offset += written;
      } else {
        await within(new Promise<void>((resolve) => { drained = resolve; }), "daemon client drain", 5_000);
      }
    }
    await within(first, "earlier daemon message", 5_000);
    await within(reply, "earlier daemon MCP reply", 5_000);
    await within(close, "oversized daemon close", 5_000);
  } finally {
    errorSpy.mockRestore();
    client.end();
  }
});
