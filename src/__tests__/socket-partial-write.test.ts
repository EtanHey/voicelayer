import { afterEach, expect, it } from "bun:test";
import { unlinkSync } from "fs";
import { dirname, join } from "path";
import { SOCKET_PATH } from "../paths";
import { broadcast, connectToBar, disconnectFromBar } from "../socket-client";
import { serializeEvent, type SocketEvent } from "../socket-protocol";
import { createMcpDaemon } from "../mcp-daemon";
import { serializeMcpFrame, parseMcpFrames } from "../mcp-framing";
import { SocketOutboundQueue } from "../socket-outbound-queue";

const TEST_SOCKET = join(dirname(SOCKET_PATH), "pw.sock");
if (process.env.VOICELAYER_TEST_ISOLATED !== "1" || !TEST_SOCKET.includes(".test-tmp")) {
  throw new Error("partial-write test requires the isolated preload");
}

let server: ReturnType<typeof Bun.listen> | undefined;
let daemon: Awaited<ReturnType<typeof createMcpDaemon>> | undefined;
afterEach(() => {
  disconnectFromBar();
  server?.stop(true);
  server = undefined;
  daemon?.stop();
  daemon = undefined;
  try { unlinkSync(TEST_SOCKET); } catch {}
  try { unlinkSync(join(dirname(SOCKET_PATH), "pm.sock")); } catch {}
});

it("resumes the exact unwritten bytes after zero and preserves queued order", () => {
  const accepted: Buffer[] = [];
  const counts = [2, 0, 1, 100, 100];
  let ended = false;
  const queue = new SocketOutboundQueue({
    write(bytes) {
      const count = Math.min(counts.shift() ?? bytes.length, bytes.length);
      accepted.push(Buffer.from(bytes.subarray(0, count)));
      return count;
    },
    end() { ended = true; },
  }, "test", 32);
  queue.enqueue("אבג\n");
  queue.enqueue("last\n");
  queue.drain();
  expect(Buffer.concat(accepted).toString("utf8")).toBe("אבג\nlast\n");
  expect(queue.queuedBytes).toBe(0);
  expect(ended).toBe(false);
});

it("closes a connection when its queued bytes exceed the cap", () => {
  let ended = false;
  const queue = new SocketOutboundQueue({
    write() { return 0; },
    end() { ended = true; },
  }, "test", 8);
  queue.enqueue("12345678");
  queue.enqueue("9");
  expect(ended).toBe(true);
  expect(queue.queuedBytes).toBe(0);
});

it("waits for queued reply bytes to drain before reporting them delivered", async () => {
  let writable = false;
  const queue = new SocketOutboundQueue({
    write(bytes) { return writable ? bytes.length : 0; },
    end() {},
  }, "test", 32);
  queue.enqueue("reply\n");
  let delivered = false;
  const completion = queue.whenEmpty().then(() => { delivered = true; });
  await Promise.resolve();
  expect(delivered).toBe(false);
  writable = true;
  queue.drain();
  await completion;
  expect(delivered).toBe(true);
});

it("returns a large MCP reply intact over a real Unix client connection", async () => {
  const mcpSocket = join(dirname(SOCKET_PATH), "pm.sock");
  const answer = "Synthetic answer. ".repeat(6_000);
  daemon = await createMcpDaemon({
    socketPath: mcpSocket,
    toolExecutor: { executeTool: async () => ({ content: [{ type: "text", text: answer }] }) },
  });
  const response = await new Promise<Record<string, unknown>>((resolve, reject) => {
    let raw = "";
    const timer = setTimeout(() => reject(new Error(`MCP reply incomplete: ${Buffer.byteLength(raw)} bytes`)), 3_000);
    Bun.connect({
      unix: mcpSocket,
      socket: {
        open(socket) {
          socket.write(serializeMcpFrame({
            jsonrpc: "2.0", id: 42, method: "tools/call",
            params: { name: "voice_ask", arguments: { message: "Synthetic question" } },
          }));
        },
        data(socket, bytes) {
          raw += bytes.toString("utf8");
          const parsed = parseMcpFrames(raw);
          if (parsed.messages.length > 0) {
            clearTimeout(timer);
            socket.end();
            resolve(parsed.messages[0] as Record<string, unknown>);
          }
        },
        close() {}, error(_socket, error) { reject(error); }, drain() {},
      },
    }).catch(reject);
  });
  const result = response.result as { content: Array<{ text: string }> };
  expect(result.content[0]?.text).toBe(answer);
});

it("delivers large daemon events byte-exact and in order through a slow Unix reader", async () => {
  const chunks: Buffer[] = [];
  let accepted!: () => void;
  const open = new Promise<void>((resolve) => { accepted = resolve; });
  let received!: (bytes: Buffer) => void;
  const complete = new Promise<Buffer>((resolve) => { received = resolve; });
  let stalled = false;
  const first: SocketEvent = { type: "transcription", text: "אבג — …".repeat(12_000) };
  const second: SocketEvent = { type: "transcription", text: "Synthetic second sentence. ".repeat(4_000) };
  const last: SocketEvent = { type: "transcription", text: "Synthetic tail" };
  const expected = Buffer.from([first, second, last].map(serializeEvent).join(""));
  expect(expected.length).toBeGreaterThan(64 * 1024);

  server = Bun.listen({
    unix: TEST_SOCKET,
    socket: {
      open() { accepted(); },
      data(_socket, raw) {
        // Hold the first read briefly so the sender faces a full Unix send buffer.
        if (!stalled) {
          stalled = true;
          Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 20);
        }
        chunks.push(Buffer.from(raw));
        const bytes = Buffer.concat(chunks);
        if (bytes.includes(Buffer.from('"text":"Synthetic tail"'))) received(bytes);
      },
      close() {}, error() {}, drain() {},
    },
  });

  connectToBar(TEST_SOCKET, { onConnected() {
    broadcast(first);
    broadcast(second);
    broadcast(last);
  } });
  await open;
  const actual = await Promise.race([
    complete,
    new Promise<Buffer>((resolve) => setTimeout(() => resolve(Buffer.concat(chunks)), 1_000)),
  ]);
  const firstNewline = actual.indexOf(0x0a);
  expect(firstNewline).toBeGreaterThan(0); // client_hello precedes events
  expect(actual.subarray(firstNewline + 1).length).toBe(expected.length);
  expect(actual.subarray(firstNewline + 1).equals(expected)).toBe(true);
});
