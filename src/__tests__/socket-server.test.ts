import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync } from "fs";
import { SOCKET_PATH } from "../paths";
import {
  startSocketServer,
  stopSocketServer,
  broadcast,
  onCommand,
  getClientCount,
  isServerRunning,
} from "../socket-server";
import type { SocketEvent, SocketCommand } from "../socket-protocol";

// --- Helpers ---

/** Connect a test client to the socket and return read/write helpers. */
async function connectClient(): Promise<{
  socket: ReturnType<typeof Bun.connect> extends Promise<infer T> ? T : never;
  received: string[];
  close: () => void;
}> {
  const received: string[] = [];
  let buffer = "";

  const socket = await Bun.connect<{ buffer: string }>({
    unix: SOCKET_PATH,
    socket: {
      open(s) {
        s.data = { buffer: "" };
      },
      data(s, raw) {
        buffer += raw.toString("utf-8");
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (line.trim()) received.push(line);
        }
      },
      close() {},
      error() {},
      drain() {},
    },
  });

  // Small delay for the server to register the connection
  await Bun.sleep(50);

  return {
    socket: socket as any,
    received,
    close: () => socket.end(),
  };
}

/** Send a JSON command from a test client. */
function sendCommand(socket: any, command: SocketCommand): void {
  socket.write(JSON.stringify(command) + "\n");
}

// --- Tests ---

describe("socket-server", () => {
  beforeEach(() => {
    // Ensure clean state
    try {
      unlinkSync(SOCKET_PATH);
    } catch {}
  });

  afterEach(() => {
    stopSocketServer();
    try {
      unlinkSync(SOCKET_PATH);
    } catch {}
  });

  describe("lifecycle", () => {
    it("starts and creates socket file", () => {
      startSocketServer();
      expect(isServerRunning()).toBe(true);
      expect(existsSync(SOCKET_PATH)).toBe(true);
    });

    it("stops and removes socket file", () => {
      startSocketServer();
      stopSocketServer();
      expect(isServerRunning()).toBe(false);
      expect(existsSync(SOCKET_PATH)).toBe(false);
    });

    it("start is idempotent — second call is no-op", () => {
      startSocketServer();
      startSocketServer(); // should not throw
      expect(isServerRunning()).toBe(true);
    });

    it("stop is idempotent — second call is no-op", () => {
      startSocketServer();
      stopSocketServer();
      stopSocketServer(); // should not throw
      expect(isServerRunning()).toBe(false);
    });

    it("cleans up stale socket file from previous crash", () => {
      // Simulate stale file
      Bun.write(SOCKET_PATH, "stale");
      expect(existsSync(SOCKET_PATH)).toBe(true);
      startSocketServer();
      // Server should have replaced the stale file with a real socket
      expect(isServerRunning()).toBe(true);
    });

    it("reports 0 clients when no one is connected", () => {
      startSocketServer();
      expect(getClientCount()).toBe(0);
    });
  });

  describe("client connections", () => {
    it("accepts a client connection", async () => {
      startSocketServer();
      const client = await connectClient();
      expect(getClientCount()).toBe(1);
      client.close();
      await Bun.sleep(50);
      expect(getClientCount()).toBe(0);
    });

    it("accepts multiple clients", async () => {
      startSocketServer();
      const c1 = await connectClient();
      const c2 = await connectClient();
      expect(getClientCount()).toBe(2);
      c1.close();
      await Bun.sleep(50);
      expect(getClientCount()).toBe(1);
      c2.close();
      await Bun.sleep(50);
      expect(getClientCount()).toBe(0);
    });
  });

  describe("broadcast", () => {
    it("sends event to connected client", async () => {
      startSocketServer();
      const client = await connectClient();

      const event: SocketEvent = { type: "state", state: "idle" };
      broadcast(event);

      // Wait for the data to arrive
      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      const parsed = JSON.parse(client.received[0]);
      expect(parsed.type).toBe("state");
      expect(parsed.state).toBe("idle");

      client.close();
    });

    it("sends event to ALL connected clients", async () => {
      startSocketServer();
      const c1 = await connectClient();
      const c2 = await connectClient();

      broadcast({ type: "state", state: "speaking", text: "hello" });
      await Bun.sleep(100);

      expect(c1.received.length).toBe(1);
      expect(c2.received.length).toBe(1);
      expect(JSON.parse(c1.received[0]).text).toBe("hello");
      expect(JSON.parse(c2.received[0]).text).toBe("hello");

      c1.close();
      c2.close();
    });

    it("sends multiple events in sequence", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({ type: "state", state: "speaking", text: "question" });
      broadcast({ type: "state", state: "recording", mode: "vad" });
      broadcast({ type: "speech", detected: true });
      await Bun.sleep(100);

      expect(client.received.length).toBe(3);
      expect(JSON.parse(client.received[0]).state).toBe("speaking");
      expect(JSON.parse(client.received[1]).state).toBe("recording");
      expect(JSON.parse(client.received[2]).detected).toBe(true);

      client.close();
    });

    it("is no-op when no clients connected", () => {
      startSocketServer();
      // Should not throw
      broadcast({ type: "state", state: "idle" });
    });

    it("is no-op when server not running", () => {
      // Should not throw
      broadcast({ type: "state", state: "idle" });
    });
  });

  describe("command handling", () => {
    it("receives stop command from client", async () => {
      startSocketServer();
      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      const client = await connectClient();
      sendCommand(client.socket, { cmd: "stop" });
      await Bun.sleep(100);

      expect(commands.length).toBe(1);
      expect(commands[0].cmd).toBe("stop");

      client.close();
    });

    it("receives replay command from client", async () => {
      startSocketServer();
      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      const client = await connectClient();
      sendCommand(client.socket, { cmd: "replay" });
      await Bun.sleep(100);

      expect(commands.length).toBe(1);
      expect(commands[0].cmd).toBe("replay");

      client.close();
    });

    it("receives toggle command from client", async () => {
      startSocketServer();
      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      const client = await connectClient();
      sendCommand(client.socket, {
        cmd: "toggle",
        scope: "tts",
        enabled: false,
      });
      await Bun.sleep(100);

      expect(commands.length).toBe(1);
      expect(commands[0]).toEqual({
        cmd: "toggle",
        scope: "tts",
        enabled: false,
      });

      client.close();
    });

    it("ignores invalid JSON from client", async () => {
      startSocketServer();
      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      const client = await connectClient();
      client.socket.write("not json\n");
      await Bun.sleep(100);

      expect(commands.length).toBe(0);

      client.close();
    });

    it("handles multiple commands in one TCP chunk", async () => {
      startSocketServer();
      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      const client = await connectClient();
      // Send two commands in a single write (single TCP chunk)
      client.socket.write('{"cmd":"stop"}\n{"cmd":"replay"}\n');
      await Bun.sleep(100);

      expect(commands.length).toBe(2);
      expect(commands[0].cmd).toBe("stop");
      expect(commands[1].cmd).toBe("replay");

      client.close();
    });
  });

  describe("bidirectional", () => {
    it("client sends command AND receives broadcast", async () => {
      startSocketServer();
      const commands: SocketCommand[] = [];
      onCommand((cmd) => commands.push(cmd));

      const client = await connectClient();

      // Server broadcasts to client
      broadcast({ type: "state", state: "speaking", text: "hi" });
      await Bun.sleep(50);
      expect(client.received.length).toBe(1);

      // Client sends to server
      sendCommand(client.socket, { cmd: "stop" });
      await Bun.sleep(50);
      expect(commands.length).toBe(1);

      client.close();
    });
  });
});
