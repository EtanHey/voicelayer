import { afterEach, describe, expect, it, spyOn } from "bun:test";
import {
  createDefaultSoundLayer,
  type SoundLayer,
  type SpeechToTextBackend,
  type TranscriptEvent,
} from "../soundlayer";
import * as input from "../input";
import * as stt from "../stt";
import * as tts from "../tts";
import * as vad from "../vad";

describe("SoundLayer contracts", () => {
  afterEach(() => {
    const restore = (spy: { mockRestore?: () => void } | undefined) =>
      spy?.mockRestore?.();
    restore(speakSpy);
    restore(waitForInputSpy);
    restore(playAudioSpy);
    restore(stopPlaybackSpy);
    restore(queueDepthSpy);
    restore(vadProcessSpy);
    restore(vadResetSpy);
    restore(getBackendSpy);
  });

  let speakSpy: ReturnType<typeof spyOn> | undefined;
  let waitForInputSpy: ReturnType<typeof spyOn> | undefined;
  let playAudioSpy: ReturnType<typeof spyOn> | undefined;
  let stopPlaybackSpy: ReturnType<typeof spyOn> | undefined;
  let queueDepthSpy: ReturnType<typeof spyOn> | undefined;
  let vadProcessSpy: ReturnType<typeof spyOn> | undefined;
  let vadResetSpy: ReturnType<typeof spyOn> | undefined;
  let getBackendSpy: ReturnType<typeof spyOn> | undefined;

  it("keeps backend selection swappable behind the STT contract", async () => {
    const fakeBackend: SpeechToTextBackend = {
      name: "fake-stt",
      async isAvailable() {
        return true;
      },
      async transcribe(audioPath) {
        return {
          text: `transcribed ${audioPath}`,
          backend: this.name,
          durationMs: 12,
        };
      },
    };

    const result = await fakeBackend.transcribe("/tmp/input.wav");

    expect(result).toEqual({
      text: "transcribed /tmp/input.wav",
      backend: "fake-stt",
      durationMs: 12,
    });
  });

  it("models transcript events without depending on VoiceSDK sessions", () => {
    const event: TranscriptEvent = {
      type: "transcript.final",
      rawText: "raw",
      cleanedText: "clean",
      sttBackend: "whisper.cpp",
      cleanupBackend: "rules",
    };

    expect(event).toEqual({
      type: "transcript.final",
      rawText: "raw",
      cleanedText: "clean",
      sttBackend: "whisper.cpp",
      cleanupBackend: "rules",
    });
  });

  it("adapts existing primitives without changing caller-facing behavior", async () => {
    const layer: SoundLayer = createDefaultSoundLayer();

    speakSpy = spyOn(tts, "speak").mockResolvedValue({ warning: "fallback" });
    waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue("hello");
    playAudioSpy = spyOn(tts, "playAudioNonBlocking").mockImplementation(() => ({
      exited: Promise.resolve(),
    }));
    stopPlaybackSpy = spyOn(tts, "stopPlayback").mockReturnValue(true);
    queueDepthSpy = spyOn(tts, "getPlaybackQueueDepth").mockReturnValue(2);
    vadProcessSpy = spyOn(vad, "processVADChunk").mockResolvedValue(0.75);
    vadResetSpy = spyOn(vad, "resetVAD").mockResolvedValue(undefined);
    getBackendSpy = spyOn(stt, "getBackend").mockResolvedValue({
      name: "stub-stt",
      isAvailable: async () => true,
      transcribe: async () => ({
        text: "stub",
        backend: "stub-stt",
        durationMs: 1,
      }),
    });

    await expect(
      layer.tts.speak("question", { mode: "converse", waitForPlayback: true }),
    ).resolves.toEqual({ warning: "fallback" });
    await expect(
      layer.micCapture.waitForInput(30_000, "thoughtful", true, {
        archiveRecording: true,
        barOwned: false,
      }),
    ).resolves.toBe("hello");
    expect(layer.playback.play("/tmp/audio.mp3", { text: "hi", voice: "jenny" }))
      .toHaveProperty("exited");
    expect(layer.playback.getQueueDepth()).toBe(2);
    expect(layer.playback.stop()).toBe(true);
    await expect(layer.vad.processChunk(new Uint8Array(vad.VAD_CHUNK_BYTES)))
      .resolves.toBe(0.75);
    expect(layer.vad.isSpeech(0.75)).toBe(true);
    expect(layer.vad.silenceChunksForMode("quick")).toBe(
      vad.silenceChunksForMode("quick"),
    );
    await layer.vad.reset();
    await expect(layer.stt.getBackend()).resolves.toHaveProperty(
      "name",
      "stub-stt",
    );

    expect(speakSpy).toHaveBeenCalledWith("question", {
      mode: "converse",
      waitForPlayback: true,
    });
    expect(waitForInputSpy).toHaveBeenCalledWith(30_000, "thoughtful", true, {
      archiveSource: "voicebar",
      barOwned: false,
    });
  });
});
