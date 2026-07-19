import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { handleVoiceAsk, handleVoiceSpeak } from "../handlers";
import * as input from "../input";
import * as recordingState from "../recording-state";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as launcher from "../voice-bar-launcher";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";

describe("SoundLayer MCP compatibility regression", () => {
  let ensureBarSpy: ReturnType<typeof spyOn>;
  let speakSpy: ReturnType<typeof spyOn>;
  let awaitPlaybackSpy: ReturnType<typeof spyOn>;
  let waitForInputSpy: ReturnType<typeof spyOn>;
  let isConnectedSpy: ReturnType<typeof spyOn>;
  let recordingStateSpy: ReturnType<typeof spyOn>;
  let bookingSpy: ReturnType<typeof spyOn>;
  let bookSpy: ReturnType<typeof spyOn>;
  let clearInputSpy: ReturnType<typeof spyOn>;
  let clearStopSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    ensureBarSpy = spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(
      () => {},
    );
    speakSpy = spyOn(tts, "speak").mockResolvedValue({});
    awaitPlaybackSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(
      undefined,
    );
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("answer");
    isConnectedSpy = spyOn(socketClient, "isConnected").mockReturnValue(true);
    recordingStateSpy = spyOn(
      recordingState,
      "getEffectiveRecordingState",
    ).mockReturnValue("idle");
    bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: true,
      ownedByUs: true,
      owner: {
        pid: process.pid,
        sessionId: "test-session",
        startedAt: new Date().toISOString(),
      },
    });
    bookSpy = spyOn(sessionBooking, "bookVoiceSession").mockReturnValue({
      success: true,
      sessionId: "test-session",
      lockPath: "/tmp/test-lock",
    });
    clearInputSpy = spyOn(input, "clearInput").mockImplementation(() => {});
    clearStopSpy = spyOn(sessionBooking, "clearStopSignal").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    ensureBarSpy.mockRestore();
    speakSpy.mockRestore();
    awaitPlaybackSpy.mockRestore();
    waitForInputSpy.mockRestore();
    isConnectedSpy.mockRestore();
    recordingStateSpy.mockRestore();
    bookingSpy.mockRestore();
    bookSpy.mockRestore();
    clearInputSpy.mockRestore();
    clearStopSpy.mockRestore();
  });

  it("keeps voice_speak non-blocking by not requesting playback wait", async () => {
    const result = await handleVoiceSpeak({
      message: "ship it",
      mode: "announce",
    });

    expect(result.isError).toBeUndefined();
    expect(ensureBarSpy).toHaveBeenCalled();
    expect(speakSpy).toHaveBeenCalledWith("ship it", {
      mode: "announce",
      rate: undefined,
      voice: undefined,
    });
    expect(awaitPlaybackSpy).not.toHaveBeenCalled();
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("returns a playback id immediately and follows with interruption telemetry", async () => {
    const events: any[] = [];
    speakSpy.mockImplementation(async (_text, options: any) => {
      const outcome = {
        type: "playback_outcome" as const,
        playback_id: "playback-speak-1",
        status: "interrupted" as const,
        reason: "stopped" as const,
        stopped_at_ms: 550,
        duration_ms: 1_000,
        progress: 0.55,
        word_index: 1,
        word_count: 3,
      };
      queueMicrotask(() => options?.onPlaybackComplete?.(outcome));
      return { playbackId: outcome.playback_id } as any;
    });

    const result = await handleVoiceSpeak(
      { message: "Listen until interrupted", mode: "announce" },
      { emit: (event: unknown) => events.push(event) } as any,
    );
    await Promise.resolve();

    expect(result.content[0].text).toContain("playback-speak-1");
    expect(events).toEqual([
      {
        kind: "playback_outcome",
        outcome: expect.objectContaining({
          playback_id: "playback-speak-1",
          status: "interrupted",
          progress: 0.55,
          word_index: 1,
        }),
      },
    ]);
  });

  it("keeps voice_ask blocking through playback completion before recording", async () => {
    const calls: string[] = [];
    awaitPlaybackSpy.mockImplementation(async () => {
      calls.push("awaitCurrentPlayback");
    });
    speakSpy.mockImplementation(async () => {
      calls.push("speak");
      return {
        displayText: "What changed safely?",
        engine: "edge-tts",
        voice: "en-US-AndrewNeural",
        audioArtifact: {
          bytes: new Uint8Array([0x49, 0x44, 0x33, 1, 2, 3, 4]),
          format: "mp3",
        },
      };
    });
    waitForInputSpy.mockImplementation(async () => {
      calls.push("waitForInput");
      return "answer";
    });

    const result = await handleVoiceAsk({
      message: "What changed?",
      timeout_seconds: 45,
      silence_mode: "quick",
      press_to_talk: true,
      voice: "theo",
    });

    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("answer");
    expect(calls).toEqual(["awaitCurrentPlayback", "speak", "waitForInput"]);
    expect(speakSpy).toHaveBeenCalledWith("What changed?", {
      mode: "converse",
      waitForPlayback: true,
      voice: undefined,
      captureAudioArtifact: true,
    });
    expect(waitForInputSpy).toHaveBeenCalledWith(45_000, "quick", true, {
      archiveSource: "voice_ask",
      onCaptureEnd: expect.any(Function),
      onNoSpeech: expect.any(Function),
      onPhaseChange: expect.any(Function),
      signal: expect.any(AbortSignal),
      voiceAskArtifacts: {
        agentAudioBytes: new Uint8Array([0x49, 0x44, 0x33, 1, 2, 3, 4]),
        agentAudioFormat: "mp3",
        agentTranscript: "What changed safely?",
        agentTtsEngine: "edge-tts",
        agentTtsVoice: "en-US-AndrewNeural",
      },
    });
  });

  it("includes ask-prompt interruption telemetry in the blocking result", async () => {
    speakSpy.mockResolvedValue({
      displayText: "Stop me when you heard enough.",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 1]),
        format: "mp3",
      },
      playbackId: "playback-ask-1",
      playbackOutcome: {
        type: "playback_outcome",
        playback_id: "playback-ask-1",
        status: "interrupted",
        reason: "stopped",
        stopped_at_ms: 600,
        duration_ms: 1_000,
        progress: 0.6,
        word_index: 3,
        word_count: 7,
      },
    } as any);
    waitForInputSpy.mockResolvedValue("I heard enough");

    const result = await handleVoiceAsk({
      message: "Stop me when you heard enough.",
    });

    expect(result.content[0].text).toContain("I heard enough");
    expect(result.content[0].text).toContain("Prompt interrupted");
    expect(result.content[0].text).toContain("60%");
  });

  it("emits monotonic keepalives across a simulated long recording and transcription", async () => {
    speakSpy.mockResolvedValue({
      displayText: "Give me the long answer.",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 1]),
        format: "mp3",
      },
    });
    waitForInputSpy.mockImplementation(
      async (_timeoutMs, _silenceMode, _pressToTalk, options) => {
        await Bun.sleep(35);
        options?.onPhaseChange?.("transcribing");
        await Bun.sleep(25);
        return "Long answer";
      },
    );
    const events: any[] = [];

    const result = await handleVoiceAsk(
      { message: "Give me the long answer.", timeout_seconds: 180 },
      {
        heartbeatIntervalMs: 10,
        emit: (event: unknown) => events.push(event),
      } as any,
    );

    expect(result.content[0].text).toContain("Long answer");
    expect(events.length).toBeGreaterThanOrEqual(5);
    expect(events.map((event) => event.sequence)).toEqual(
      [...events.map((event) => event.sequence)].sort((a, b) => a - b),
    );
    expect(events.some((event) => event.stage === "recording")).toBe(true);
    expect(events.some((event) => event.stage === "transcribing")).toBe(true);
  });

  it("refuses voice_ask before recording when prompt audio cannot be retained", async () => {
    speakSpy.mockResolvedValue({});

    const result = await handleVoiceAsk({ message: "Can you hear this?" });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain(
      "could not retain synthesized prompt audio",
    );
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("refuses voice_ask before recording when actual-used TTS metadata is missing", async () => {
    speakSpy.mockResolvedValue({
      displayText: "Receipt-less question",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33]),
        format: "mp3",
      },
    });

    const result = await handleVoiceAsk({ message: "Receipt-less question" });

    expect(result.isError).toBe(true);
    expect(result.content[0].text).toContain("engine/voice");
    expect(waitForInputSpy).not.toHaveBeenCalled();
  });

  it("publishes one paired folder through the voice_ask handler archive boundary", async () => {
    const archiveRoot = mkdtempSync(join(tmpdir(), "voiceask-round-test-"));
    const savedArchiveRoot = process.env.QA_VOICE_RECORDINGS_DIR;
    process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
    const agentAudio = new Uint8Array([0x49, 0x44, 0x33, 7, 8, 9]);
    speakSpy.mockResolvedValue({
      displayText: "Paired question without markup",
      engine: "qwen3-tts",
      voice: "etan-clone",
      audioArtifact: { bytes: agentAudio, format: "mp3" },
    });
    waitForInputSpy.mockImplementation(
      async (timeoutMs, silenceMode, pressToTalk, options) => {
        input.archiveWaitForInputRecording({
          options: options!,
          audioBytes: input.createWavBuffer(new Uint8Array([1, 2, 3, 4])),
          transcript: "Paired answer",
          silenceMode: silenceMode!,
          pressToTalk: pressToTalk!,
          durationMs: timeoutMs / 10,
          backend: "fake-stt",
        });
        return "Paired answer";
      },
    );

    try {
      const result = await handleVoiceAsk({
        message: "Paired question",
        timeout_seconds: 5,
      });

      expect(result.isError).toBeUndefined();
      const dayDirs = readdirSync(archiveRoot);
      expect(dayDirs).toHaveLength(1);
      const archiveIds = readdirSync(join(archiveRoot, dayDirs[0]));
      expect(archiveIds).toHaveLength(1);
      const folder = join(archiveRoot, dayDirs[0], archiveIds[0]);
      expect(readdirSync(folder).sort()).toEqual([
        "agent-audio.mp3",
        "agent-transcript.txt",
        "audio.wav",
        "metadata.json",
        "voicelayer-transcript.txt",
      ]);
      expect(readFileSync(join(folder, "agent-audio.mp3"))).toEqual(
        Buffer.from(agentAudio),
      );
      expect(readFileSync(join(folder, "agent-transcript.txt"), "utf8")).toBe(
        "Paired question without markup",
      );
      expect(
        readFileSync(join(folder, "voicelayer-transcript.txt"), "utf8"),
      ).toBe("Paired answer");
    } finally {
      if (savedArchiveRoot === undefined) {
        delete process.env.QA_VOICE_RECORDINGS_DIR;
      } else {
        process.env.QA_VOICE_RECORDINGS_DIR = savedArchiveRoot;
      }
      rmSync(archiveRoot, { recursive: true, force: true });
    }
  });

  it("archives and returns promptly when a voice_ask capture contains no speech", async () => {
    const archiveRoot = mkdtempSync(join(tmpdir(), "voiceask-no-speech-test-"));
    const savedArchiveRoot = process.env.QA_VOICE_RECORDINGS_DIR;
    process.env.QA_VOICE_RECORDINGS_DIR = archiveRoot;
    speakSpy.mockResolvedValue({
      displayText: "Are you there?",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 2]),
        format: "mp3",
      },
    });
    waitForInputSpy.mockImplementation(
      async (_timeoutMs, silenceMode, pressToTalk, options) => {
        input.archiveVoiceAskCapture({
          options: options!,
          audioBytes: input.createWavBuffer(new Uint8Array(32_000)),
          silenceMode: silenceMode!,
          pressToTalk: pressToTalk!,
          durationMs: 1_000,
        });
        options?.onCaptureEnd?.();
        options?.onNoSpeech?.();
        return null;
      },
    );

    try {
      const startedAt = Date.now();
      const result = await handleVoiceAsk({
        message: "Are you there?",
        timeout_seconds: 180,
      });

      expect(Date.now() - startedAt).toBeLessThan(1_000);
      expect(result.content[0].text).toContain("No speech detected");
      expect(result.content[0].text).not.toContain("180s");
      const dayDirs = readdirSync(archiveRoot);
      expect(dayDirs).toHaveLength(1);
      const archiveIds = readdirSync(join(archiveRoot, dayDirs[0]));
      expect(archiveIds).toHaveLength(1);
      const metadata = JSON.parse(
        readFileSync(
          join(archiveRoot, dayDirs[0], archiveIds[0], "metadata.json"),
          "utf8",
        ),
      );
      expect(metadata).toMatchObject({
        source: "voice_ask",
        transcription_status: "captured",
      });
    } finally {
      if (savedArchiveRoot === undefined) {
        delete process.env.QA_VOICE_RECORDINGS_DIR;
      } else {
        process.env.QA_VOICE_RECORDINGS_DIR = savedArchiveRoot;
      }
      rmSync(archiveRoot, { recursive: true, force: true });
    }
  });
});
