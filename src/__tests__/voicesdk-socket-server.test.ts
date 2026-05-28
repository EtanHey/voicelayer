import { mkdtempSync, rmSync, unlinkSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { createVoiceSdkSessionManager } from "../voicesdk/session";
import { createVoiceSdkSocketServer } from "../voicesdk/socket-server";
import type { SoundLayer } from "../soundlayer";

const TEST_SOCKET = "/tmp/voicesdk-test.sock";

function fakeSoundLayer(): SoundLayer {
  return {
    micCapture: {
      async recordToBuffer() {
        return null;
      },
      async waitForInput() {
        return "socket answer";
      },
      clear() {},
      getState() {
        return "idle";
      },
    },
    playback: {
      play() {
        return { exited: Promise.resolve() };
      },
      async waitForIdle() {},
      stop() {
        return true;
      },
      getQueueDepth() {
        return 0;
      },
    },
    vad: {
      async processChunk() {
        return 0;
      },
      isSpeech() {
        return false;
      },
      silenceChunksForMode() {
        return 1;
      },
      async reset() {},
    },
    cancellation: {
      stopPlayback() {
        return true;
      },
      consumeRecordingCancel() {
        return false;
      },
    },
    transcriptEvents: {
      emitTranscript() {},
    },
    tts: {
      async speak() {
        return {};
      },
    },
    stt: {
      async getBackend() {
        throw new Error("unused");
      },
    },
  };
}

async function connectClient(socketPath: string): Promise<{
  lines: Record<string, unknown>[];
  write: (line: string) => void;
  end: () => void;
}> {
  const lines: Record<string, unknown>[] = [];
  const socket = await Bun.connect<{ buffer: string }>({
    unix: socketPath,
    socket: {
      open(target) {
        target.data = { buffer: "" };
      },
      data(target, raw) {
        target.data.buffer += raw.toString("utf-8");
        const chunks = target.data.buffer.split("\n");
        target.data.buffer = chunks.pop() ?? "";
        for (const chunk of chunks) {
          if (chunk.trim()) lines.push(JSON.parse(chunk));
        }
      },
      close() {},
      error() {},
      drain() {},
    },
  });

  return {
    lines,
    write(line: string) {
      socket.write(line.endsWith("\n") ? line : `${line}\n`);
    },
    end() {
      socket.end();
    },
  };
}

async function waitFor(
  predicate: () => boolean,
  timeoutMs = 3000,
): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return true;
    await Bun.sleep(25);
  }
  return predicate();
}

describe("VoiceSDK socket server", () => {
  let tempDir: string;
  let server: ReturnType<typeof createVoiceSdkSocketServer> | null = null;

  beforeEach(() => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-socket-"));
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  afterEach(() => {
    server?.stop();
    server = null;
    rmSync(tempDir, { recursive: true, force: true });
    try {
      unlinkSync(TEST_SOCKET);
    } catch {}
  });

  it("flows session commands to semantic events over NDJSON", async () => {
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "socket-session",
    });
    server = createVoiceSdkSocketServer({ socketPath: TEST_SOCKET, manager });
    const client = await connectClient(TEST_SOCKET);

    client.write(
      '{"cmd":"session.start","product":"VoiceReview","artifact_id":"a1"}',
    );
    client.write(
      '{"cmd":"speak","session_id":"socket-session","text":"Hello","voice_id":"theo"}',
    );
    client.write(
      '{"cmd":"listen","session_id":"socket-session","mode":"vad","timeout_ms":100}',
    );
    client.write(
      '{"cmd":"session.end","session_id":"socket-session","reason":"completed"}',
    );

    expect(
      await waitFor(() =>
        client.lines.some((line) => line.type === "session.ended"),
      ),
    ).toBe(true);
    expect(client.lines.map((line) => line.type)).toEqual([
      "session.started",
      "speak.started",
      "speak.chunk",
      "speak.stopped",
      "listen.started",
      "transcript.final",
      "answer.final",
      "session.ended",
    ]);
  });

  it("accepts reconnecting clients without losing the durable session log", async () => {
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "reconnect-session",
    });
    server = createVoiceSdkSocketServer({ socketPath: TEST_SOCKET, manager });
    const first = await connectClient(TEST_SOCKET);

    first.write('{"cmd":"session.start","product":"VoiceReview"}');
    expect(
      await waitFor(() =>
        first.lines.some((line) => line.type === "session.started"),
      ),
    ).toBe(true);
    first.end();

    const second = await connectClient(TEST_SOCKET);
    second.write(
      '{"cmd":"session.end","session_id":"reconnect-session","reason":"client_reconnect"}',
    );

    expect(
      await waitFor(() =>
        second.lines.some((line) => line.type === "session.ended"),
      ),
    ).toBe(true);
    expect(manager.replay("reconnect-session").map((event) => event.type))
      .toEqual(["session.started", "session.ended"]);
  });

  it("applies bounded backpressure by dropping clients that exceed buffered events", async () => {
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "backpressure-session",
    });
    server = createVoiceSdkSocketServer({
      socketPath: TEST_SOCKET,
      manager,
      maxBufferedEventsPerClient: 1,
      writerFactory: () => ({
        write() {
          return 0;
        },
        end() {},
      }),
    });
    const client = await connectClient(TEST_SOCKET);

    client.write('{"cmd":"session.start","product":"VoiceReview"}');
    client.write(
      '{"cmd":"section.start","session_id":"backpressure-session","section_id":"one","title":"One","ordinal":1}',
    );
    client.write(
      '{"cmd":"section.start","session_id":"backpressure-session","section_id":"two","title":"Two","ordinal":2}',
    );

    expect(await waitFor(() => server!.getClientCount() === 0)).toBe(true);
    expect(manager.replay("backpressure-session").map((event) => event.type))
      .toEqual(["session.started", "section.started", "section.started"]);
  });
});
