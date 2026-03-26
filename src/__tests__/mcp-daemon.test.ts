/**
 * Integration tests for the MCP daemon — a Bun Unix socket server
 * that accepts both MCP (Content-Length) and NDJSON clients on the same socket.
 *
 * Tests connect to a real Unix socket, send MCP frames, and verify responses.
 * Includes daemon resilience tests: orphan socket detection, health ping/pong,
 * socket permissions, connection tracking, startup validation.
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { unlinkSync, existsSync, statSync, writeFileSync } from "fs";
import { serializeMcpFrame, parseMcpFrames } from "../mcp-framing";

const TEST_SOCKET = "/tmp/voicelayer-test-daemon.sock";
const TEST_SOCKET_2 = "/tmp/voicelayer-test-daemon-2.sock";

// Helper: connect to socket and do MCP request-response
async function mcpRequest(
  socketPath: string,
  request: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("MCP request timeout")),
      5000,
    );
    let buffer = "";

    Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          const frame = serializeMcpFrame(request);
          socket.write(frame);
        },
        data(_socket, raw) {
          buffer += raw.toString("utf-8");
          const { messages } = parseMcpFrames(buffer);
          if (messages.length > 0) {
            clearTimeout(timeout);
            resolve(messages[0] as Record<string, unknown>);
          }
        },
        close() {
          clearTimeout(timeout);
          reject(new Error("Socket closed before response"));
        },
        error(_socket, err) {
          clearTimeout(timeout);
          reject(err);
        },
        connectError(_socket, err) {
          clearTimeout(timeout);
          reject(err);
        },
        drain() {},
      },
    }).catch(reject);
  });
}

// Helper: connect as NDJSON client and exchange messages
async function ndjsonExchange(
  socketPath: string,
  json: string,
): Promise<string[]> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error("NDJSON exchange timeout")),
      3000,
    );
    let buffer = "";
    const received: string[] = [];

    Bun.connect({
      unix: socketPath,
      socket: {
        open(socket) {
          socket.write(json + "\n");
        },
        data(_socket, raw) {
          buffer += raw.toString("utf-8");
          const lines = buffer.split("\n");
          buffer = lines.pop() ?? "";
          for (const line of lines) {
            if (line.trim()) received.push(line);
          }
          // Give a bit of time for more data, then resolve
          setTimeout(() => {
            clearTimeout(timeout);
            resolve(received);
          }, 200);
        },
        close() {
          clearTimeout(timeout);
          resolve(received);
        },
        error(_socket, err) {
          clearTimeout(timeout);
          reject(err);
        },
        connectError(_socket, err) {
          clearTimeout(timeout);
          reject(err);
        },
        drain() {},
      },
    }).catch(reject);
  });
}

function cleanup(...paths: string[]) {
  for (const p of paths) {
    try {
      unlinkSync(p);
    } catch {}
  }
}

describe("mcp-daemon", () => {
  let daemon: { stop: () => void } | null = null;

  beforeEach(() => {
    cleanup(TEST_SOCKET, TEST_SOCKET_2);
  });

  afterEach(() => {
    daemon?.stop();
    daemon = null;
    cleanup(TEST_SOCKET, TEST_SOCKET_2);
  });

  it("starts and listens on a Unix socket", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Should be able to connect
    const response = await mcpRequest(TEST_SOCKET, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test", version: "1.0" },
      },
    });

    expect(response.jsonrpc).toBe("2.0");
    expect(response.id).toBe(1);
    expect(
      (response.result as Record<string, unknown>).serverInfo,
    ).toBeDefined();
  });

  it("handles MCP initialize request", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    const response = await mcpRequest(TEST_SOCKET, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test", version: "1.0" },
      },
    });

    const result = response.result as Record<string, unknown>;
    expect(result.protocolVersion).toBe("2024-11-05");
    expect(result.capabilities).toEqual({ tools: {} });
    const serverInfo = result.serverInfo as Record<string, unknown>;
    expect(serverInfo.name).toBe("voicelayer");
  });

  it("handles MCP tools/list request", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    const response = await mcpRequest(TEST_SOCKET, {
      jsonrpc: "2.0",
      id: 2,
      method: "tools/list",
    });

    const result = response.result as Record<string, unknown>;
    const tools = result.tools as Array<{ name: string }>;
    expect(Array.isArray(tools)).toBe(true);
    expect(tools.length).toBeGreaterThan(0);

    const names = tools.map((t) => t.name);
    expect(names).toContain("voice_speak");
    expect(names).toContain("voice_ask");
  });

  it("handles MCP tools/call with mock executor", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({
      socketPath: TEST_SOCKET,
      toolExecutor: {
        executeTool: async (name: string) => ({
          content: [{ type: "text", text: `Mock: ${name} executed` }],
        }),
      },
    });

    const response = await mcpRequest(TEST_SOCKET, {
      jsonrpc: "2.0",
      id: 3,
      method: "tools/call",
      params: {
        name: "voice_speak",
        arguments: { message: "hello", mode: "think" },
      },
    });

    const result = response.result as Record<string, unknown>;
    const content = result.content as Array<{ text: string }>;
    expect(content[0].text).toBe("Mock: voice_speak executed");
  });

  it("handles multiple concurrent MCP clients", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Two clients in parallel
    const [r1, r2] = await Promise.all([
      mcpRequest(TEST_SOCKET, {
        jsonrpc: "2.0",
        id: 10,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "client-1", version: "1.0" },
        },
      }),
      mcpRequest(TEST_SOCKET, {
        jsonrpc: "2.0",
        id: 20,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "client-2", version: "1.0" },
        },
      }),
    ]);

    expect(r1.id).toBe(10);
    expect(r2.id).toBe(20);
    expect((r1.result as Record<string, unknown>).protocolVersion).toBe(
      "2024-11-05",
    );
    expect((r2.result as Record<string, unknown>).protocolVersion).toBe(
      "2024-11-05",
    );
  });

  it("handles sequential requests on same connection", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Send initialize + tools/list in sequence on same connection
    const responses = await new Promise<Record<string, unknown>[]>(
      (resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error("timeout")), 5000);
        let buffer = "";
        const results: Record<string, unknown>[] = [];

        Bun.connect({
          unix: TEST_SOCKET,
          socket: {
            open(socket) {
              // Send both requests
              const frame1 = serializeMcpFrame({
                jsonrpc: "2.0",
                id: 1,
                method: "initialize",
                params: {
                  protocolVersion: "2024-11-05",
                  capabilities: {},
                  clientInfo: { name: "test", version: "1.0" },
                },
              });
              const frame2 = serializeMcpFrame({
                jsonrpc: "2.0",
                id: 2,
                method: "tools/list",
              });
              socket.write(frame1 + frame2);
            },
            data(_socket, raw) {
              buffer += raw.toString("utf-8");
              const { messages, remainder } = parseMcpFrames(buffer);
              buffer = remainder;
              results.push(...(messages as Record<string, unknown>[]));
              if (results.length >= 2) {
                clearTimeout(timeout);
                resolve(results);
              }
            },
            close() {
              clearTimeout(timeout);
              resolve(results);
            },
            error(_s, err) {
              clearTimeout(timeout);
              reject(err);
            },
            connectError(_s, err) {
              clearTimeout(timeout);
              reject(err);
            },
            drain() {},
          },
        }).catch(reject);
      },
    );

    expect(responses).toHaveLength(2);
    expect(responses[0].id).toBe(1);
    expect(responses[1].id).toBe(2);
  });

  it("detects NDJSON protocol and passes through", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    let ndjsonReceived: string[] = [];
    daemon = await createMcpDaemon({
      socketPath: TEST_SOCKET,
      onNdjsonMessage: (msg: Record<string, unknown>) => {
        ndjsonReceived.push(JSON.stringify(msg));
      },
    });

    // Connect and send NDJSON (starts with '{')
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => resolve(), 500);
      Bun.connect({
        unix: TEST_SOCKET,
        socket: {
          open(socket) {
            socket.write('{"type":"state","state":"idle"}\n');
            // Give it time to process
            setTimeout(() => {
              clearTimeout(timeout);
              socket.end();
              resolve();
            }, 200);
          },
          data() {},
          close() {},
          error(_s, err) {
            clearTimeout(timeout);
            reject(err);
          },
          connectError(_s, err) {
            clearTimeout(timeout);
            reject(err);
          },
          drain() {},
        },
      }).catch(reject);
    });

    expect(ndjsonReceived.length).toBe(1);
    const parsed = JSON.parse(ndjsonReceived[0]);
    expect(parsed.type).toBe("state");
    expect(parsed.state).toBe("idle");
  });

  it("handles MCP-over-NDJSON without reclassifying protocol", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({
      socketPath: TEST_SOCKET,
      toolExecutor: {
        executeTool: async (name: string) => ({
          content: [{ type: "text", text: `Mock: ${name}` }],
        }),
      },
    });

    // Send MCP initialize WITHOUT Content-Length framing (raw JSON, like socat sometimes does)
    const responses = await ndjsonExchange(
      TEST_SOCKET,
      JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2024-11-05",
          capabilities: {},
          clientInfo: { name: "socat-client", version: "1.0" },
        },
      }),
    );

    // Should get a response back (not silently dropped)
    expect(responses.length).toBeGreaterThan(0);
    const response = JSON.parse(responses[0]);
    expect(response.jsonrpc).toBe("2.0");
    expect(response.id).toBe(1);
    expect(
      (response.result as Record<string, unknown>).serverInfo,
    ).toBeDefined();
  });

  it("survives malformed Content-Length frame without killing connection", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Send a malformed frame followed by a valid one
    const responses = await new Promise<Record<string, unknown>[]>(
      (resolve, reject) => {
        const timeout = setTimeout(() => reject(new Error("timeout")), 5000);
        let buffer = "";
        const results: Record<string, unknown>[] = [];

        Bun.connect({
          unix: TEST_SOCKET,
          socket: {
            open(socket) {
              // Malformed: Content-Length header with no number
              const bad = "Content-Length: \r\n\r\n";
              // Valid frame after the bad one
              const good = serializeMcpFrame({
                jsonrpc: "2.0",
                id: 99,
                method: "initialize",
                params: {
                  protocolVersion: "2024-11-05",
                  capabilities: {},
                  clientInfo: { name: "test", version: "1.0" },
                },
              });
              socket.write(bad + good);
            },
            data(_socket, raw) {
              buffer += raw.toString("utf-8");
              const { messages, remainder } = parseMcpFrames(buffer);
              buffer = remainder;
              results.push(...(messages as Record<string, unknown>[]));
              if (results.length >= 1) {
                clearTimeout(timeout);
                resolve(results);
              }
            },
            close() {
              clearTimeout(timeout);
              resolve(results);
            },
            error(_s, err) {
              clearTimeout(timeout);
              reject(err);
            },
            connectError(_s, err) {
              clearTimeout(timeout);
              reject(err);
            },
            drain() {},
          },
        }).catch(reject);
      },
    );

    // The valid frame should still be processed despite the bad one before it
    expect(responses.length).toBeGreaterThanOrEqual(1);
    const valid = responses.find((r) => r.id === 99);
    expect(valid).toBeDefined();
    expect(valid!.jsonrpc).toBe("2.0");
  });

  it("cleans up socket file on stop", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Socket file should exist
    expect(existsSync(TEST_SOCKET)).toBe(true);

    daemon.stop();
    daemon = null;

    // Socket file should be cleaned up
    expect(existsSync(TEST_SOCKET)).toBe(false);
  });
});

describe("mcp-daemon resilience", () => {
  let daemon: { stop: () => void } | null = null;

  beforeEach(() => {
    cleanup(TEST_SOCKET, TEST_SOCKET_2);
  });

  afterEach(() => {
    daemon?.stop();
    daemon = null;
    cleanup(TEST_SOCKET, TEST_SOCKET_2);
  });

  it("removes orphan socket file on startup", async () => {
    // Create a fake orphan socket file (regular file, not a real socket)
    writeFileSync(TEST_SOCKET, "orphan");
    expect(existsSync(TEST_SOCKET)).toBe(true);

    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Should have started successfully despite orphan file
    const response = await mcpRequest(TEST_SOCKET, {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: "2024-11-05",
        capabilities: {},
        clientInfo: { name: "test", version: "1.0" },
      },
    });
    expect(response.jsonrpc).toBe("2.0");
  });

  it("sets socket permissions to 600", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    const stat = statSync(TEST_SOCKET);
    // Socket permissions: mask with 0o777 to get rwx bits
    const perms = stat.mode & 0o777;
    expect(perms).toBe(0o600);
  });

  it("responds to health ping with pong", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    const responses = await ndjsonExchange(
      TEST_SOCKET,
      JSON.stringify({ type: "ping" }),
    );

    expect(responses.length).toBeGreaterThan(0);
    const pong = JSON.parse(responses[0]);
    expect(pong.type).toBe("pong");
    expect(typeof pong.uptime_seconds).toBe("number");
    expect(pong.uptime_seconds).toBeGreaterThanOrEqual(0);
    expect(typeof pong.connections).toBe("number");
    expect(pong.connections).toBeGreaterThanOrEqual(1); // At least this connection
  });

  it("refuses to start if another instance holds socket", async () => {
    const { createMcpDaemon } = await import("../mcp-daemon");

    // Start first daemon
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    // Try to start second daemon on same socket
    try {
      const daemon2 = await createMcpDaemon({ socketPath: TEST_SOCKET });
      daemon2.stop();
      // Should not reach here
      expect(true).toBe(false);
    } catch (err) {
      expect((err as Error).message).toContain("already listening");
    }
  });

  it("isSocketLive returns false for non-existent socket", async () => {
    const { isSocketLive } = await import("../mcp-daemon");
    const live = await isSocketLive("/tmp/voicelayer-test-nonexistent.sock");
    expect(live).toBe(false);
  });

  it("isSocketLive returns true for active socket", async () => {
    const { createMcpDaemon, isSocketLive } = await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    const live = await isSocketLive(TEST_SOCKET);
    expect(live).toBe(true);
  });

  it("isSocketLive returns false for orphan socket file", async () => {
    // Create a regular file (not a real socket)
    writeFileSync(TEST_SOCKET_2, "not-a-socket");

    const { isSocketLive } = await import("../mcp-daemon");
    const live = await isSocketLive(TEST_SOCKET_2);
    expect(live).toBe(false);
  });

  it("cleanOrphanSocket removes stale socket file", async () => {
    writeFileSync(TEST_SOCKET_2, "stale");

    const { cleanOrphanSocket } = await import("../mcp-daemon");
    const removed = await cleanOrphanSocket(TEST_SOCKET_2);
    expect(removed).toBe(true);
    expect(existsSync(TEST_SOCKET_2)).toBe(false);
  });

  it("cleanOrphanSocket preserves live socket", async () => {
    const { createMcpDaemon, cleanOrphanSocket } =
      await import("../mcp-daemon");
    daemon = await createMcpDaemon({ socketPath: TEST_SOCKET });

    const removed = await cleanOrphanSocket(TEST_SOCKET);
    expect(removed).toBe(false);
    expect(existsSync(TEST_SOCKET)).toBe(true);
  });
});
