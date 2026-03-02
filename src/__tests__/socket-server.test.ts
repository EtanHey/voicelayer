/**
 * Tests for socket-server.ts facade — verifies the re-export aliases work
 * correctly after architecture inversion.
 *
 * The facade maps old names to new socket-client.ts implementation:
 *   startSocketServer  → connectToFlowBar
 *   stopSocketServer   → disconnectFromFlowBar
 *   isServerRunning    → isConnected
 *   broadcast          → broadcast
 *   onCommand          → onCommand
 *   getClientCount     → 0 or 1 based on isConnected
 *
 * Each test spins up a mock FlowBar server (Bun.listen) and tests through
 * the facade aliases.
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { unlinkSync } from "fs";
import type { SocketEvent, SocketCommand } from "../socket-protocol";

// Use a unique test socket path
const TEST_SOCKET = "/tmp/voicelayer-test-facade.sock";

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

describe("socket-server (facade)", () => {
  let mockServer: MockServer | null = null;

  beforeEach(() => {
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  afterEach(async () => {
    try {
      const { stopSocketServer } = await import("../socket-server");
      stopSocketServer();
    } catch {}
    mockServer?.stop();
    mockServer = null;
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  describe("lifecycle", () => {
    it("startSocketServer connects via facade", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { isServerRunning } = await import("../socket-server");

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);
      expect(isServerRunning()).toBe(true);
    });

    it("stopSocketServer disconnects via facade", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { stopSocketServer, isServerRunning } =
        await import("../socket-server");

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);
      expect(isServerRunning()).toBe(true);

      stopSocketServer();
      await Bun.sleep(100);
      expect(isServerRunning()).toBe(false);
    });

    it("isServerRunning returns false when not connected", async () => {
      const { isServerRunning } = await import("../socket-server");
      expect(isServerRunning()).toBe(false);
    });

    it("getClientCount returns 1 when connected, 0 when not", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar, disconnectFromFlowBar } =
        await import("../socket-client");
      const { getClientCount } = await import("../socket-server");

      expect(getClientCount()).toBe(0);

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);
      expect(getClientCount()).toBe(1);

      disconnectFromFlowBar();
      await Bun.sleep(100);
      expect(getClientCount()).toBe(0);
    });
  });

  describe("broadcast via facade", () => {
    it("sends event to FlowBar server", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { broadcast } = await import("../socket-server");

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      const event: SocketEvent = { type: "state", state: "idle" };
      broadcast(event);

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      const parsed = JSON.parse(mockServer.received[0]);
      expect(parsed.type).toBe("state");
      expect(parsed.state).toBe("idle");
    });

    it("sends event to ALL connected — no-op concept: only one server", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { broadcast } = await import("../socket-server");

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      broadcast({ type: "state", state: "speaking", text: "hello" });
      await Bun.sleep(100);

      expect(mockServer.received.length).toBe(1);
      expect(JSON.parse(mockServer.received[0]).text).toBe("hello");
    });

    it("sends multiple events in sequence", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { broadcast } = await import("../socket-server");

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      broadcast({ type: "state", state: "speaking", text: "question" });
      broadcast({ type: "state", state: "recording", mode: "vad" });
      broadcast({ type: "speech", detected: true });
      await Bun.sleep(100);

      expect(mockServer.received.length).toBe(3);
      expect(JSON.parse(mockServer.received[0]).state).toBe("speaking");
      expect(JSON.parse(mockServer.received[1]).state).toBe("recording");
      expect(JSON.parse(mockServer.received[2]).detected).toBe(true);
    });

    it("is no-op when not connected", async () => {
      const { broadcast } = await import("../socket-server");
      expect(() => {
        broadcast({ type: "state", state: "idle" });
      }).not.toThrow();
    });
  });

  describe("command handling via facade", () => {
    it("receives stop command from FlowBar", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { onCommand } = await import("../socket-server");

      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      mockServer.sendToAll('{"cmd":"stop"}\n');
      await Bun.sleep(100);

      expect(commands.length).toBe(1);
      expect(commands[0].cmd).toBe("stop");
    });

    it("receives replay command from FlowBar", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { onCommand } = await import("../socket-server");

      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      mockServer.sendToAll('{"cmd":"replay"}\n');
      await Bun.sleep(100);

      expect(commands.length).toBe(1);
      expect(commands[0].cmd).toBe("replay");
    });

    it("receives toggle command from FlowBar", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { onCommand } = await import("../socket-server");

      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      mockServer.sendToAll('{"cmd":"toggle","scope":"tts","enabled":false}\n');
      await Bun.sleep(100);

      expect(commands.length).toBe(1);
      expect(commands[0]).toEqual({
        cmd: "toggle",
        scope: "tts",
        enabled: false,
      });
    });

    it("ignores invalid JSON from FlowBar", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { onCommand } = await import("../socket-server");

      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      mockServer.sendToAll("not json\n");
      await Bun.sleep(100);

      expect(commands.length).toBe(0);
    });

    it("handles multiple commands in one TCP chunk", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { onCommand } = await import("../socket-server");

      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      mockServer.sendToAll('{"cmd":"stop"}\n{"cmd":"replay"}\n');
      await Bun.sleep(100);

      expect(commands.length).toBe(2);
      expect(commands[0].cmd).toBe("stop");
      expect(commands[1].cmd).toBe("replay");
    });
  });

  describe("bidirectional via facade", () => {
    it("client sends broadcast AND receives command", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { connectToFlowBar } = await import("../socket-client");
      const { broadcast, onCommand } = await import("../socket-server");

      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      connectToFlowBar(TEST_SOCKET);
      await Bun.sleep(200);

      // Client broadcasts to server
      broadcast({ type: "state", state: "speaking", text: "hi" });
      await Bun.sleep(50);
      expect(mockServer.received.length).toBe(1);

      // Server sends command to client
      mockServer.sendToAll('{"cmd":"stop"}\n');
      await Bun.sleep(50);
      expect(commands.length).toBe(1);
    });
  });
});
