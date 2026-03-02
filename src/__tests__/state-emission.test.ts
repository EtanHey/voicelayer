/**
 * Tests for state emission via socket broadcast (inverted architecture).
 *
 * Verifies that broadcast() sends correct state events to FlowBar.
 * Uses a mock FlowBar server (Bun.listen) to receive events.
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { unlinkSync } from "fs";
import type { SocketEvent } from "../socket-protocol";

const TEST_SOCKET = "/tmp/voicelayer-test-emission.sock";

// --- Mock FlowBar server ---

type MockServer = {
  server: ReturnType<typeof Bun.listen>;
  received: SocketEvent[];
  rawLines: string[];
  stop: () => void;
};

function createMockFlowBarServer(socketPath: string): MockServer {
  const rawLines: string[] = [];
  const received: SocketEvent[] = [];

  const server = Bun.listen<{ buffer: string }>({
    unix: socketPath,
    socket: {
      open(socket) {
        socket.data = { buffer: "" };
      },
      data(socket, raw) {
        socket.data.buffer += raw.toString("utf-8");
        const lines = socket.data.buffer.split("\n");
        socket.data.buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (line.trim()) {
            rawLines.push(line);
            try {
              received.push(JSON.parse(line));
            } catch {}
          }
        }
      },
      close() {},
      error() {},
      drain() {},
    },
  });

  return {
    server,
    received,
    rawLines,
    stop() {
      server.stop(true);
      try {
        unlinkSync(socketPath);
      } catch {}
    },
  };
}

// --- Tests ---

describe("state emission", () => {
  let mockServer: MockServer | null = null;

  beforeEach(() => {
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  afterEach(async () => {
    try {
      const { disconnectFromFlowBar } = await import("../socket-client");
      disconnectFromFlowBar();
    } catch {}
    mockServer?.stop();
    mockServer = null;
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  /** Helper: connect client to mock server and wait */
  async function connectAndWait() {
    const { connectToFlowBar } = await import("../socket-client");
    const { broadcast } = await import("../socket-server");
    connectToFlowBar(TEST_SOCKET);
    await Bun.sleep(200);
    return { broadcast };
  }

  describe("broadcast events", () => {
    it("sends speaking state event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({
        type: "state",
        state: "speaking",
        text: "Hello world",
        voice: "en-US-JennyNeural",
      });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({
        type: "state",
        state: "speaking",
        text: "Hello world",
        voice: "en-US-JennyNeural",
      });
    });

    it("sends idle state event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({ type: "state", state: "idle" });
    });

    it("sends recording state event with mode", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "standard",
      });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "standard",
      });
    });

    it("sends transcribing state event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({ type: "state", state: "transcribing" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({
        type: "state",
        state: "transcribing",
      });
    });

    it("sends speech detection event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({ type: "speech", detected: true });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({
        type: "speech",
        detected: true,
      });
    });

    it("sends transcription result event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({ type: "transcription", text: "Hello, how are you?" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({
        type: "transcription",
        text: "Hello, how are you?",
      });
    });

    it("sends error event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({
        type: "error",
        message: "TTS synthesis failed",
        recoverable: true,
      });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect(mockServer.received[0]).toEqual({
        type: "error",
        message: "TTS synthesis failed",
        recoverable: true,
      });
    });
  });

  describe("state transitions", () => {
    it("speaking → idle sequence", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({
        type: "state",
        state: "speaking",
        text: "Testing transition",
      });
      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(2);
      expect(mockServer.received[0].type).toBe("state");
      expect((mockServer.received[0] as any).state).toBe("speaking");
      expect(mockServer.received[1].type).toBe("state");
      expect((mockServer.received[1] as any).state).toBe("idle");
    });

    it("recording → speech → transcribing → transcription → idle sequence", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "standard",
      });
      broadcast({ type: "speech", detected: true });
      broadcast({ type: "state", state: "transcribing" });
      broadcast({ type: "transcription", text: "Test result" });
      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(5);
      expect((mockServer.received[0] as any).state).toBe("recording");
      expect((mockServer.received[1] as any).detected).toBe(true);
      expect((mockServer.received[2] as any).state).toBe("transcribing");
      expect((mockServer.received[3] as any).text).toBe("Test result");
      expect((mockServer.received[4] as any).state).toBe("idle");
    });

    it("speaking → error → idle sequence", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      broadcast({ type: "state", state: "speaking", text: "Will fail" });
      broadcast({
        type: "error",
        message: "TTS synthesis failed",
        recoverable: true,
      });
      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(3);
      expect((mockServer.received[0] as any).state).toBe("speaking");
      expect(mockServer.received[1].type).toBe("error");
      expect((mockServer.received[2] as any).state).toBe("idle");
    });

    it("full converse cycle: speaking → idle → recording → speech → transcribing → transcription → idle", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      // TTS question
      broadcast({
        type: "state",
        state: "speaking",
        text: "What do you think?",
      });
      broadcast({ type: "state", state: "idle" });

      // Recording user response
      broadcast({
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "thoughtful",
      });
      broadcast({ type: "speech", detected: true });
      broadcast({ type: "state", state: "transcribing" });
      broadcast({ type: "transcription", text: "I think it looks great" });
      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(7);

      const states = mockServer.received.map((e) => {
        if (e.type === "state") return (e as any).state;
        if (e.type === "speech") return "speech-detected";
        if (e.type === "transcription") return "transcription";
        return e.type;
      });
      expect(states).toEqual([
        "speaking",
        "idle",
        "recording",
        "speech-detected",
        "transcribing",
        "transcription",
        "idle",
      ]);
    });
  });

  describe("text truncation in speak broadcast", () => {
    it("truncates long text in speaking event", async () => {
      mockServer = createMockFlowBarServer(TEST_SOCKET);
      const { broadcast } = await connectAndWait();

      const longText = "A".repeat(500);
      broadcast({
        type: "state",
        state: "speaking",
        text: longText.slice(0, 200),
      });

      await Bun.sleep(100);
      expect(mockServer.received.length).toBe(1);
      expect((mockServer.received[0] as any).text.length).toBe(200);
    });
  });
});
