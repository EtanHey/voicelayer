/**
 * Tests for socket-client.ts — MCP server as client connecting to FlowBar server.
 *
 * TDD RED phase: these tests define the expected behavior of the inverted
 * architecture where FlowBar is the server and MCP instances connect as clients.
 *
 * Each test spins up a mock FlowBar server (Bun.listen on a temp Unix socket)
 * and tests the client's behavior.
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync } from "fs";
import type { SocketEvent, SocketCommand } from "../socket-protocol";

// Use a unique test socket path to avoid conflicts with real FlowBar
const TEST_SOCKET = "/tmp/voicelayer-test-client.sock";

// --- Mock FlowBar server helper ---

type MockServer = {
  server: ReturnType<typeof Bun.listen>;
  received: string[];
  clients: Set<any>;
  sendToAll: (data: string) => void;
  stop: () => void;
};

function createMockFlowBarServer(socketPath: string): MockServer {
  const received: string[] = [];
  const clients = new Set<any>();

  const server = Bun.listen<{ buffer: string }>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
        clients.add(socket);
      },
      data(socket, raw) {
        socket.data.buffer += raw.toString("utf-8");
        const lines = socket.data.buffer.split("\n");
        socket.data.buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (line.trim()) received.push(line);
        }
      },
      close(socket) {
        clients.delete(socket);
      },
      error(socket) {
        clients.delete(socket);
      },
      drain() {},
    },
  });

  return {
    server,
    received,
    clients,
    sendToAll(data: string) {
      for (const client of clients) {
        client.write(data);
      }
    },
    stop() {
      server.stop(true);
      try {
        unlinkSync(socketPath);
      } catch {}
    },
  };
}

// --- Tests ---

describe("socket-client", () => {
  let mockServer: MockServer | null = null;

  beforeEach(() => {
    // Clean up any stale socket
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  afterEach(async () => {
    // Import and disconnect client
    try {
      const { disconnectFromFlowBar } = await import("../socket-client");
      disconnectFromFlowBar();
    } catch {}
    // Stop mock server
    mockServer?.stop();
    mockServer = null;
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  it("connectToFlowBar connects to a listening Unix socket", async () => {
    mockServer = createMockFlowBarServer(TEST_SOCKET);

    const { connectToFlowBar, isConnected } = await import("../socket-client");
    connectToFlowBar(TEST_SOCKET);

    // Wait for connection
    await Bun.sleep(200);
    expect(isConnected()).toBe(true);
    expect(mockServer.clients.size).toBe(1);
  });

  it("broadcast sends NDJSON event to the server", async () => {
    mockServer = createMockFlowBarServer(TEST_SOCKET);

    const { connectToFlowBar, broadcast } = await import("../socket-client");
    connectToFlowBar(TEST_SOCKET);
    await Bun.sleep(200);

    const event: SocketEvent = {
      type: "state",
      state: "speaking",
      text: "hello",
    };
    broadcast(event);

    await Bun.sleep(100);
    expect(mockServer.received.length).toBe(1);
    const parsed = JSON.parse(mockServer.received[0]);
    expect(parsed.type).toBe("state");
    expect(parsed.state).toBe("speaking");
    expect(parsed.text).toBe("hello");
  });

  it("onCommand receives parsed commands from the server", async () => {
    mockServer = createMockFlowBarServer(TEST_SOCKET);

    const { connectToFlowBar, onCommand } = await import("../socket-client");
    const commands: SocketCommand[] = [];
    onCommand((cmd) => commands.push(cmd));

    connectToFlowBar(TEST_SOCKET);
    await Bun.sleep(200);

    // Server sends a command to the client
    mockServer.sendToAll('{"cmd":"stop"}\n');
    await Bun.sleep(100);

    expect(commands.length).toBe(1);
    expect(commands[0].cmd).toBe("stop");
  });

  it("auto-reconnects when connection drops", async () => {
    mockServer = createMockFlowBarServer(TEST_SOCKET);

    const { connectToFlowBar, isConnected } = await import("../socket-client");
    connectToFlowBar(TEST_SOCKET);
    await Bun.sleep(200);
    expect(isConnected()).toBe(true);

    // Kill the server
    mockServer.stop();
    await Bun.sleep(300);
    expect(isConnected()).toBe(false);

    // Restart the server — client should auto-reconnect
    mockServer = createMockFlowBarServer(TEST_SOCKET);
    // Wait for reconnect (first backoff is 1s)
    await Bun.sleep(1500);
    expect(isConnected()).toBe(true);
  });

  it("broadcast is no-op when disconnected", async () => {
    const { broadcast } = await import("../socket-client");
    // No server running, not connected — should not throw
    expect(() => {
      broadcast({ type: "state", state: "idle" });
    }).not.toThrow();
  });

  it("disconnectFromFlowBar stops reconnection attempts", async () => {
    mockServer = createMockFlowBarServer(TEST_SOCKET);

    const { connectToFlowBar, disconnectFromFlowBar, isConnected } =
      await import("../socket-client");
    connectToFlowBar(TEST_SOCKET);
    await Bun.sleep(200);
    expect(isConnected()).toBe(true);

    // Disconnect intentionally
    disconnectFromFlowBar();
    await Bun.sleep(100);
    expect(isConnected()).toBe(false);

    // Kill and restart server — should NOT auto-reconnect
    mockServer.stop();
    mockServer = createMockFlowBarServer(TEST_SOCKET);
    await Bun.sleep(2000);
    // Should still be disconnected
    expect(isConnected()).toBe(false);
    expect(mockServer.clients.size).toBe(0);
  });

  it("handles NDJSON framing across TCP chunks", async () => {
    mockServer = createMockFlowBarServer(TEST_SOCKET);

    const { connectToFlowBar, onCommand } = await import("../socket-client");
    const commands: SocketCommand[] = [];
    onCommand((cmd) => commands.push(cmd));

    connectToFlowBar(TEST_SOCKET);
    await Bun.sleep(200);

    // Send a partial chunk, then the rest
    mockServer.sendToAll('{"cmd":"sto');
    await Bun.sleep(50);
    mockServer.sendToAll('p"}\n{"cmd":"replay"}\n');
    await Bun.sleep(100);

    expect(commands.length).toBe(2);
    expect(commands[0].cmd).toBe("stop");
    expect(commands[1].cmd).toBe("replay");
  });
});
