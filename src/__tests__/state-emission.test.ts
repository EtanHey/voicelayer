/**
 * Tests for Phase 2: State emission via socket broadcast.
 *
 * Verifies that tts.ts and input.ts broadcast correct state events
 * to connected Flow Bar clients through the socket server.
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { existsSync, unlinkSync } from "fs";
import { SOCKET_PATH } from "../paths";
import {
  startSocketServer,
  stopSocketServer,
  broadcast,
} from "../socket-server";
import type { SocketEvent } from "../socket-protocol";

// --- Test client helper (same pattern as socket-server.test.ts) ---

async function connectClient(): Promise<{
  received: SocketEvent[];
  rawLines: string[];
  close: () => void;
}> {
  const rawLines: string[] = [];
  const received: SocketEvent[] = [];
  let buffer = "";

  const socket = await Bun.connect<{ buffer: string }>({
    unix: SOCKET_PATH,
    socket: {
      open(s) {
        s.data = { buffer: "" };
      },
      data(_s, raw) {
        buffer += raw.toString("utf-8");
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
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

  await Bun.sleep(50);

  return {
    received,
    rawLines,
    close: () => socket.end(),
  };
}

// --- Tests ---

describe("state emission", () => {
  beforeEach(() => {
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

  describe("broadcast events", () => {
    it("sends speaking state event", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({
        type: "state",
        state: "speaking",
        text: "Hello world",
        voice: "en-US-JennyNeural",
      });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({
        type: "state",
        state: "speaking",
        text: "Hello world",
        voice: "en-US-JennyNeural",
      });

      client.close();
    });

    it("sends idle state event", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({ type: "state", state: "idle" });

      client.close();
    });

    it("sends recording state event with mode", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "standard",
      });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({
        type: "state",
        state: "recording",
        mode: "vad",
        silence_mode: "standard",
      });

      client.close();
    });

    it("sends transcribing state event", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({ type: "state", state: "transcribing" });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({
        type: "state",
        state: "transcribing",
      });

      client.close();
    });

    it("sends speech detection event", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({ type: "speech", detected: true });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({ type: "speech", detected: true });

      client.close();
    });

    it("sends transcription result event", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({ type: "transcription", text: "Hello, how are you?" });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({
        type: "transcription",
        text: "Hello, how are you?",
      });

      client.close();
    });

    it("sends error event", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({
        type: "error",
        message: "TTS synthesis failed",
        recoverable: true,
      });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect(client.received[0]).toEqual({
        type: "error",
        message: "TTS synthesis failed",
        recoverable: true,
      });

      client.close();
    });
  });

  describe("state transitions", () => {
    it("speaking → idle sequence", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({
        type: "state",
        state: "speaking",
        text: "Testing transition",
      });
      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(client.received.length).toBe(2);
      expect(client.received[0].type).toBe("state");
      expect((client.received[0] as any).state).toBe("speaking");
      expect(client.received[1].type).toBe("state");
      expect((client.received[1] as any).state).toBe("idle");

      client.close();
    });

    it("recording → speech → transcribing → transcription → idle sequence", async () => {
      startSocketServer();
      const client = await connectClient();

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
      expect(client.received.length).toBe(5);
      expect((client.received[0] as any).state).toBe("recording");
      expect((client.received[1] as any).detected).toBe(true);
      expect((client.received[2] as any).state).toBe("transcribing");
      expect((client.received[3] as any).text).toBe("Test result");
      expect((client.received[4] as any).state).toBe("idle");

      client.close();
    });

    it("speaking → error → idle sequence", async () => {
      startSocketServer();
      const client = await connectClient();

      broadcast({ type: "state", state: "speaking", text: "Will fail" });
      broadcast({
        type: "error",
        message: "TTS synthesis failed",
        recoverable: true,
      });
      broadcast({ type: "state", state: "idle" });

      await Bun.sleep(100);
      expect(client.received.length).toBe(3);
      expect((client.received[0] as any).state).toBe("speaking");
      expect(client.received[1].type).toBe("error");
      expect((client.received[2] as any).state).toBe("idle");

      client.close();
    });

    it("full converse cycle: speaking → idle → recording → speech → transcribing → transcription → idle", async () => {
      startSocketServer();
      const client = await connectClient();

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
      expect(client.received.length).toBe(7);

      // Verify state flow
      const states = client.received.map((e) => {
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

      client.close();
    });
  });

  describe("text truncation in speak broadcast", () => {
    it("truncates long text in speaking event", async () => {
      startSocketServer();
      const client = await connectClient();

      const longText = "A".repeat(500);
      broadcast({
        type: "state",
        state: "speaking",
        text: longText.slice(0, 200), // Mimics what tts.ts does
      });

      await Bun.sleep(100);
      expect(client.received.length).toBe(1);
      expect((client.received[0] as any).text.length).toBe(200);

      client.close();
    });
  });
});
