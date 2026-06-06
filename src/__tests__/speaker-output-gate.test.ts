import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  spyOn,
} from "bun:test";
import { existsSync, unlinkSync, writeFileSync } from "fs";
import * as handlers from "../handlers";
import * as input from "../input";
import * as sessionBooking from "../session-booking";
import * as socketClient from "../socket-client";
import * as tts from "../tts";
import * as launcher from "../voice-bar-launcher";

const TEST_RECORDING_STATE_FILE = `/tmp/voicelayer-speaker-gate-${process.pid}.json`;
const TEST_REPLAY_FILE = `/tmp/voicelayer-speaker-gate-replay-${process.pid}.mp3`;
const SPEAKER_REFUSED = "user is recording — speaker output refused";

function writeRecordingState(state: "idle" | "recording" | "transcribing") {
  writeFileSync(
    TEST_RECORDING_STATE_FILE,
    JSON.stringify({
      state,
      pid: process.pid,
      updated_at: new Date().toISOString(),
    }),
  );
}

function cleanupFiles() {
  for (const file of [TEST_RECORDING_STATE_FILE, TEST_REPLAY_FILE]) {
    try {
      if (existsSync(file)) unlinkSync(file);
    } catch {}
  }
}

describe("speaker output recording gate", () => {
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;
  const originalRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
  let spawnCalls: string[][];

  beforeEach(() => {
    cleanupFiles();
    process.env.QA_VOICE_RECORDING_STATE_PATH = TEST_RECORDING_STATE_FILE;
    spawnCalls = [];

    // @ts-ignore — test seam for external audio commands.
    Bun.spawn = (cmd: string[], _opts?: unknown) => {
      spawnCalls.push([...(Array.isArray(cmd) ? cmd : [String(cmd)])]);
      const mediaIdx = cmd.indexOf("--write-media");
      if (mediaIdx >= 0 && cmd[mediaIdx + 1]) {
        writeFileSync(cmd[mediaIdx + 1], "fake mp3");
      }
      const metadataIdx = cmd.indexOf("--write-metadata");
      if (metadataIdx >= 0 && cmd[metadataIdx + 1]) {
        writeFileSync(cmd[metadataIdx + 1], "");
      }
      return { exited: Promise.resolve(0), pid: 99999, kill: () => {} };
    };

    // @ts-ignore — make audio player selection deterministic.
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };
  });

  afterEach(async () => {
    try {
      tts.stopPlayback();
      await tts.awaitCurrentPlayback();
    } catch {}
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
    if (originalRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = originalRecordingStatePath;
    }
    cleanupFiles();
  });

  it("refuses voice_speak during active recording without synthesis or playback", async () => {
    writeRecordingState("recording");

    await expect(tts.speak("this must not leak")).rejects.toThrow(
      SPEAKER_REFUSED,
    );

    expect(spawnCalls).toHaveLength(0);
  });

  it("refuses voice_ask before calling TTS when recording is active", async () => {
    writeRecordingState("recording");
    const broadcasts: unknown[] = [];
    const speakSpy = spyOn(tts, "speak").mockResolvedValue({});
    const waitForInputSpy = spyOn(input, "waitForInput").mockResolvedValue(
      "answer",
    );
    const awaitPlaybackSpy = spyOn(tts, "awaitCurrentPlayback").mockResolvedValue(
      undefined,
    );
    const ensureBarSpy = spyOn(launcher, "ensureVoiceBarRunning").mockImplementation(
      () => {},
    );
    const isConnectedSpy = spyOn(socketClient, "isConnected").mockReturnValue(
      true,
    );
    const broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(JSON.parse(JSON.stringify(event)));
      },
    );
    const bookingSpy = spyOn(sessionBooking, "isVoiceBooked").mockReturnValue({
      booked: true,
      ownedByUs: true,
      owner: {
        pid: process.pid,
        sessionId: "speaker-gate-test",
        startedAt: new Date().toISOString(),
      },
    });
    const clearInputSpy = spyOn(input, "clearInput").mockImplementation(
      () => {},
    );
    const clearStopSpy = spyOn(sessionBooking, "clearStopSignal").mockImplementation(
      () => {},
    );

    try {
      const result = await handlers.handleVoiceAsk({
        message: "Are you there?",
        timeout_seconds: 30,
      });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain(SPEAKER_REFUSED);
      expect(speakSpy).not.toHaveBeenCalled();
      expect(awaitPlaybackSpy).not.toHaveBeenCalled();
      expect(waitForInputSpy).not.toHaveBeenCalled();
      expect(
        broadcasts.filter(
          (event: any) => event.type === "state" && event.state === "idle",
        ),
      ).toHaveLength(0);
    } finally {
      speakSpy.mockRestore();
      waitForInputSpy.mockRestore();
      awaitPlaybackSpy.mockRestore();
      ensureBarSpy.mockRestore();
      isConnectedSpy.mockRestore();
      broadcastSpy.mockRestore();
      bookingSpy.mockRestore();
      clearInputSpy.mockRestore();
      clearStopSpy.mockRestore();
    }
  });

  it("refuses replay during active recording without spawning playback", async () => {
    writeRecordingState("recording");
    writeFileSync(TEST_REPLAY_FILE, "fake mp3");
    const historySpy = spyOn(tts, "getHistoryEntry").mockReturnValue({
      id: 0,
      file: TEST_REPLAY_FILE,
      text: "latest replay",
      voice: "jenny",
      timestamp: Date.now(),
    });

    try {
      const result = await handlers.handleReplay({ index: 0 });

      expect(result.isError).toBe(true);
      expect(result.content[0].text).toContain(SPEAKER_REFUSED);
      expect(spawnCalls).toHaveLength(0);
    } finally {
      historySpy.mockRestore();
    }
  });

  it("deletes synthesized TTS when recording starts after synthesis but before playback", async () => {
    writeRecordingState("idle");
    let synthesizedFile: string | null = null;

    // @ts-ignore — flip recording state after synthesis writes the file.
    Bun.spawn = (cmd: string[], _opts?: unknown) => {
      spawnCalls.push([...(Array.isArray(cmd) ? cmd : [String(cmd)])]);
      const mediaIdx = cmd.indexOf("--write-media");
      if (mediaIdx >= 0 && cmd[mediaIdx + 1]) {
        synthesizedFile = cmd[mediaIdx + 1];
        writeFileSync(synthesizedFile, "fake mp3");
        writeRecordingState("recording");
      }
      const metadataIdx = cmd.indexOf("--write-metadata");
      if (metadataIdx >= 0 && cmd[metadataIdx + 1]) {
        writeFileSync(cmd[metadataIdx + 1], "");
      }
      return { exited: Promise.resolve(0), pid: 99999, kill: () => {} };
    };

    try {
      await expect(tts.speak("recording starts after synthesis")).rejects.toThrow(
        SPEAKER_REFUSED,
      );

      expect(synthesizedFile).not.toBeNull();
      expect(existsSync(synthesizedFile!)).toBe(false);
      expect(spawnCalls).toHaveLength(1);
      expect(spawnCalls[0][0]).toContain("python3");
    } finally {
      if (synthesizedFile) {
        try {
          unlinkSync(synthesizedFile);
        } catch {}
      }
    }
  });

  it("keeps normal voice_speak playback unchanged while idle", async () => {
    writeRecordingState("idle");

    await tts.speak("idle path still speaks");

    expect(spawnCalls.length).toBe(2);
    expect(spawnCalls[0][0]).toContain("python3");
    expect(spawnCalls[1]).toContain(
      process.platform === "darwin" ? "afplay" : "mpg123",
    );
  });
});
