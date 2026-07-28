import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { Database } from "bun:sqlite";
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
  let savedAllowPushToEnd: string | undefined;
  let savedControlLayerDisable: string | undefined;
  let savedControlLayerBase: string | undefined;

  beforeEach(() => {
    savedAllowPushToEnd = process.env.VOICELAYER_ALLOW_PUSH_TO_END;
    savedControlLayerDisable =
      process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
    savedControlLayerBase = process.env.VOICELAYER_CONTROL_LAYER_BASE;
    delete process.env.VOICELAYER_ALLOW_PUSH_TO_END;
    process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL = "1";
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
    if (savedAllowPushToEnd === undefined) {
      delete process.env.VOICELAYER_ALLOW_PUSH_TO_END;
    } else {
      process.env.VOICELAYER_ALLOW_PUSH_TO_END = savedAllowPushToEnd;
    }
    if (savedControlLayerDisable === undefined) {
      delete process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL;
    } else {
      process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL =
        savedControlLayerDisable;
    }
    if (savedControlLayerBase === undefined) {
      delete process.env.VOICELAYER_CONTROL_LAYER_BASE;
    } else {
      process.env.VOICELAYER_CONTROL_LAYER_BASE = savedControlLayerBase;
    }
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

  it("uses manual-stop capture when push_to_end is requested and the gate is satisfied", async () => {
    process.env.VOICELAYER_ALLOW_PUSH_TO_END = "1";
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
      push_to_end: true,
      voice: "theo",
    });

    expect(result.isError).toBeUndefined();
    expect(result.content[0].text).toContain("answer");
    expect(calls).toEqual(["awaitCurrentPlayback", "speak", "waitForInput"]);
    expect(speakSpy).toHaveBeenCalledWith("What changed?", {
      mode: "converse",
      waitForPlayback: true,
      voice: "theo",
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

  it("uses VAD capture when push_to_end is absent", async () => {
    speakSpy.mockResolvedValue({
      displayText: "What changed safely?",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 1]),
        format: "mp3",
      },
    });

    await handleVoiceAsk({
      message: "What changed?",
      silence_mode: "thoughtful",
    });

    expect(waitForInputSpy).toHaveBeenCalledWith(
      30_000,
      "thoughtful",
      false,
      expect.any(Object),
    );
  });

  it("accepts a voice_ask message at the 1,200-character boundary", async () => {
    const boundaryMessage = "A".repeat(1_200);
    speakSpy.mockResolvedValue({
      displayText: boundaryMessage,
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 1]),
        format: "mp3",
      },
    });

    const result = await handleVoiceAsk({ message: boundaryMessage });

    expect(result.isError).toBeUndefined();
    expect(speakSpy).toHaveBeenCalledWith(
      boundaryMessage,
      expect.objectContaining({
        mode: "converse",
        waitForPlayback: true,
      }),
    );
    expect(waitForInputSpy).toHaveBeenCalled();
  });

  it("refuses and journals a voice_ask message above 1,200 characters", async () => {
    const journalRoot = mkdtempSync(join(tmpdir(), "voiceask-length-guard-"));
    process.env.VOICELAYER_DISABLE_CONTROL_LAYER_JOURNAL = "0";
    process.env.VOICELAYER_CONTROL_LAYER_BASE = journalRoot;

    try {
      const result = await handleVoiceAsk({ message: "A".repeat(1_201) });
      const text = result.content[0].text;

      expect(result.isError).toBe(true);
      expect(text).toContain("1,201");
      expect(text).toContain("1,200");
      expect(text).toContain("approximately 94 seconds");
      expect(text).toContain("two or more sequential voice_ask calls");
      expect(text).toContain("checkpoint");
      expect(text).toContain("confirms");
      expect(speakSpy).not.toHaveBeenCalled();
      expect(awaitPlaybackSpy).not.toHaveBeenCalled();
      expect(waitForInputSpy).not.toHaveBeenCalled();

      const database = new Database(
        join(journalRoot, "fleet-journal.db"),
        { readonly: true },
      );
      const row = database
        .query(
          "SELECT payload_json FROM events WHERE type = ? ORDER BY seq DESC LIMIT 1",
        )
        .get("voice_ask.message_too_long") as
        | { payload_json: string }
        | null;
      database.close();

      expect(row).not.toBeNull();
      expect(JSON.parse(row!.payload_json)).toMatchObject({
        caller: "mcp.voice_ask",
        message_length: 1_201,
        threshold: 1_200,
        approximate_speech_seconds: 94,
      });
    } finally {
      rmSync(journalRoot, { recursive: true, force: true });
    }
  });

  it("ignores legacy press_to_talk, keeps VAD, and emits a deprecation warning", async () => {
    process.env.VOICELAYER_ALLOW_PUSH_TO_END = "1";
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    speakSpy.mockResolvedValue({
      displayText: "What changed safely?",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 1]),
        format: "mp3",
      },
    });

    try {
      await handleVoiceAsk({
        message: "What changed?",
        press_to_talk: true,
      });

      expect(waitForInputSpy).toHaveBeenCalledWith(
        30_000,
        "thoughtful",
        false,
        expect.any(Object),
      );
      expect(errorSpy).toHaveBeenCalledWith(
        expect.stringContaining(
          "Deprecated press_to_talk ignored; use push_to_end",
        ),
      );
    } finally {
      errorSpy.mockRestore();
    }
  });

  it("ignores push_to_end when the gate is not satisfied, keeps VAD, and warns", async () => {
    const errorSpy = spyOn(console, "error").mockImplementation(() => {});
    speakSpy.mockResolvedValue({
      displayText: "What changed safely?",
      engine: "edge-tts",
      voice: "en-US-AndrewNeural",
      audioArtifact: {
        bytes: new Uint8Array([0x49, 0x44, 0x33, 1]),
        format: "mp3",
      },
    });

    try {
      await handleVoiceAsk({
        message: "What changed?",
        push_to_end: true,
      });

      expect(waitForInputSpy).toHaveBeenCalledWith(
        30_000,
        "thoughtful",
        false,
        expect.any(Object),
      );
      expect(errorSpy).toHaveBeenCalledWith(
        expect.stringContaining(
          "push_to_end ignored: VOICELAYER_ALLOW_PUSH_TO_END=1 is required",
        ),
      );
    } finally {
      errorSpy.mockRestore();
    }
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
      async (_timeoutMs, _silenceMode, _pushToEnd, options) => {
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
      async (timeoutMs, silenceMode, pushToEnd, options) => {
        input.archiveWaitForInputRecording({
          options: options!,
          audioBytes: input.createWavBuffer(new Uint8Array([1, 2, 3, 4])),
          transcript: "Paired answer",
          silenceMode: silenceMode!,
          pushToEnd: pushToEnd!,
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
      async (_timeoutMs, silenceMode, pushToEnd, options) => {
        input.archiveVoiceAskCapture({
          options: options!,
          audioBytes: input.createWavBuffer(new Uint8Array(32_000)),
          silenceMode: silenceMode!,
          pushToEnd: pushToEnd!,
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
