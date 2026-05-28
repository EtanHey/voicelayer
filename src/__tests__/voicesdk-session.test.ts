import { mkdtempSync, readFileSync, rmSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";
import { afterEach, describe, expect, it } from "bun:test";
import { createVoiceSdkSessionManager } from "../voicesdk/session";
import type { SoundLayer } from "../soundlayer";

function fakeSoundLayer(): SoundLayer {
  return {
    micCapture: {
      async recordToBuffer() {
        return null;
      },
      async waitForInput() {
        return "raw answer";
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
        return {
          name: "fake-stt",
          async isAvailable() {
            return true;
          },
          async transcribe() {
            return {
              text: "raw answer",
              backend: "fake-stt",
              durationMs: 1,
            };
          },
        };
      },
    },
  };
}

describe("VoiceSDK session manager", () => {
  let tempDir: string | null = null;

  afterEach(() => {
    if (tempDir) rmSync(tempDir, { recursive: true, force: true });
    tempDir = null;
  });

  it("emits ordered lifecycle events and appends them to a durable NDJSON log", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-session-"));
    const emitted: string[] = [];
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "session-fixed",
      now: () => new Date("2026-05-28T12:00:00.000Z"),
      onEvent: (event) => emitted.push(event.type),
    });

    const session = await manager.startSession({
      product: "VoiceReview",
      artifact_id: "artifact-1",
    });
    await manager.startSection(session.session_id, {
      section_id: "intro",
      title: "Intro",
      ordinal: 1,
    });
    await manager.speak(session.session_id, {
      text: "Hello VoiceSDK",
      voice_id: "theo",
    });
    await manager.listen(session.session_id, {
      mode: "vad",
      timeout_ms: 250,
    });
    await manager.recordDecision(session.session_id, {
      artifact_ref: "artifact-1",
      summary: "Keep this",
      status: "accepted",
    });
    await manager.endSession(session.session_id, "completed");

    expect(emitted).toEqual([
      "session.started",
      "section.started",
      "speak.started",
      "speak.chunk",
      "speak.stopped",
      "listen.started",
      "transcript.final",
      "answer.final",
      "decision.recorded",
      "session.ended",
    ]);

    const logLines = readFileSync(
      join(tempDir, "session-fixed.ndjson"),
      "utf-8",
    ).trim().split("\n").map((line) => JSON.parse(line));

    expect(logLines.map((line) => line.sequence)).toEqual([
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10,
    ]);
    expect(logLines[0]).toMatchObject({
      type: "session.started",
      session_id: "session-fixed",
      product: "VoiceReview",
      artifact_id: "artifact-1",
    });
    expect(logLines[6]).toMatchObject({
      type: "transcript.final",
      raw_text: "raw answer",
      cleaned_text: "raw answer",
      stt_backend: "soundlayer.micCapture",
    });
    expect(logLines[9]).toMatchObject({
      type: "session.ended",
      reason: "completed",
      duration_ms: 0,
    });
  });

  it("keeps durable replay separate from live subscribers", async () => {
    tempDir = mkdtempSync(join(tmpdir(), "voicesdk-session-"));
    const manager = createVoiceSdkSessionManager({
      soundLayer: fakeSoundLayer(),
      logDir: tempDir,
      idFactory: () => "session-no-subscriber",
    });

    await manager.startSession({ product: "VoiceReview" });

    expect(
      readFileSync(join(tempDir, "session-no-subscriber.ndjson"), "utf-8"),
    ).toContain('"type":"session.started"');
  });
});
