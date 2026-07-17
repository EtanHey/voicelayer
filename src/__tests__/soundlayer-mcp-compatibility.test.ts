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
});
