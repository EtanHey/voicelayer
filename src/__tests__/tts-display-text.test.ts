import { afterEach, beforeEach, expect, it, mock, spyOn } from "bun:test";
import { TEST_TMP } from "./setup/test-tmp";
// AIDEV-NOTE: R-014 — this file can reach the microphone, the recorder
// device probe, or files the resident VoiceBar reads. `describe` is the
// live-host guard, so the suite skips loudly rather than racing the live app.
import { describeMicTouching as describe } from "./setup/live-host-guard";
import { existsSync, unlinkSync, writeFileSync } from "fs";
import * as actualPaths from "../paths";
import * as socketClient from "../socket-client";
import * as qwen3 from "../tts/qwen3";

const TEST_DISABLED_FILE = `${TEST_TMP}/voicelayer-display-text-${process.pid}-disabled`;
const TEST_RECORDING_STATE_FILE = `${TEST_TMP}/voicelayer-display-text-${process.pid}-recording.json`;
const TEST_PRONUNCIATION_FILE = `${TEST_TMP}/voicelayer-display-text-${process.pid}-pronunciation.yaml`;

const pronunciations: Record<string, string> = {
  Etan: "Eh tahn",
  supabase: "Soopa base",
  golems: "Go lems",
  BrainLayer: "Brain Layer",
};

mock.module("../paths", () => ({
  ...actualPaths,
  TTS_DISABLED_FILE: TEST_DISABLED_FILE,
}));

interface SpawnCall {
  cmd: string[];
}

async function waitFor(
  predicate: () => boolean,
  description: string,
  timeoutMs = 1_000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) {
      throw new Error(`Timed out waiting for ${description}`);
    }
    await Bun.sleep(1);
  }
}

describe("TTS display text stays separate from pronunciation text", () => {
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;
  let originalRecordingStatePath: string | undefined;
  let originalPronunciationPath: string | undefined;
  let spawnCalls: SpawnCall[];
  let broadcasts: any[];
  let broadcastSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    originalRecordingStatePath = process.env.QA_VOICE_RECORDING_STATE_PATH;
    originalPronunciationPath = process.env.QA_VOICE_PRONUNCIATION_PATH;
    process.env.QA_VOICE_RECORDING_STATE_PATH = TEST_RECORDING_STATE_FILE;
    process.env.QA_VOICE_PRONUNCIATION_PATH = TEST_PRONUNCIATION_FILE;
    writeFileSync(
      process.env.QA_VOICE_PRONUNCIATION_PATH,
      `tech:\n${Object.entries(pronunciations).map(([term, replacement]) => `  ${term}: "${replacement}"`).join("\n")}\n`,
    );
    writeFileSync(
      TEST_RECORDING_STATE_FILE,
      JSON.stringify({
        state: "idle",
        pid: process.pid,
        updated_at: new Date().toISOString(),
      }),
    );

    spawnCalls = [];
    broadcasts = [];
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(structuredClone(event));
      },
    );

    // @ts-ignore — deterministic edge-tts and audio-player fixture.
    Bun.spawn = (cmd: string[]) => {
      const command = [...cmd];
      spawnCalls.push({ cmd: command });

      if (command[0].includes("python3")) {
        const argValue = (flag: string): string | undefined => {
          const hit = command.find((arg) => arg.startsWith(`${flag}=`));
          return hit?.slice(flag.length + 1);
        };
        const mediaPath = argValue("--write-media");
        if (mediaPath) writeFileSync(mediaPath, "fake mp3");

        const spokenText = argValue("--text") ?? "";
        const metadataPath = argValue("--write-metadata");
        if (metadataPath) {
          const lines = spokenText.split(/\s+/u).map((word, index) =>
            JSON.stringify({
              offset: index * 1200000,
              duration: 1000000,
              text: word,
            }),
          );
          writeFileSync(metadataPath, `${lines.join("\n")}\n`);
        }
      }

      return {
        exited: Promise.resolve(0),
        pid: 81000,
        stdout:
          command[0] === "ffmpeg"
            ? new Blob([new Uint8Array([0, 0])]).stream()
            : undefined,
        kill: () => {},
      };
    };

    // @ts-ignore — avoid invoking platform probes in this unit fixture.
    Bun.spawnSync = (cmd: string[]) => {
      if (cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      if (cmd[0] === "ffprobe") {
        return {
          exitCode: 0,
          stdout: Buffer.from("1.0\n"),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };
  });

  afterEach(async () => {
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcastSpy?.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
    for (const path of [
      TEST_DISABLED_FILE,
      TEST_RECORDING_STATE_FILE,
      TEST_PRONUNCIATION_FILE,
      actualPaths.TTS_HISTORY_FILE,
    ]) {
      try {
        if (existsSync(path)) unlinkSync(path);
      } catch {}
    }
    if (originalRecordingStatePath === undefined) {
      delete process.env.QA_VOICE_RECORDING_STATE_PATH;
    } else {
      process.env.QA_VOICE_RECORDING_STATE_PATH = originalRecordingStatePath;
    }
    if (originalPronunciationPath === undefined) {
      delete process.env.QA_VOICE_PRONUNCIATION_PATH;
    } else {
      process.env.QA_VOICE_PRONUNCIATION_PATH = originalPronunciationPath;
    }
  });

  for (const [displayText, spokenText] of Object.entries(pronunciations)) {
    it(`shows ${displayText} while handing ${spokenText} to the TTS engine`, async () => {
      const { speak } = await import("../tts");

      await speak(displayText);
      await waitFor(
        () => broadcasts.some(
          (event) => event.type === "state" &&
            event.state === "speaking" &&
            event.text === displayText,
        ),
        `speaking event for ${displayText}`,
      );

      const synthesis = spawnCalls.find((call) =>
        call.cmd[0].includes("python3"),
      );
      expect(synthesis?.cmd).toContain(`--text=${spokenText}`);

      const speaking = broadcasts.find(
        (event) => event.type === "state" && event.state === "speaking",
      );
      expect(speaking?.text).toBe(displayText);
    });
  }

  it("passes cmuxlayer through unchanged as a negative control", async () => {
    const { speak } = await import("../tts");

    await speak("cmuxlayer");
    await waitFor(
      () => broadcasts.some(
        (event) => event.type === "state" &&
          event.state === "speaking" &&
          event.text === "cmuxlayer",
      ),
      "negative-control speaking event",
    );

    const synthesis = spawnCalls.find((call) =>
      call.cmd[0].includes("python3"),
    );
    expect(synthesis?.cmd).toContain("--text=cmuxlayer");
    const speaking = broadcasts.find(
      (event) => event.type === "state" && event.state === "speaking",
    );
    expect(speaking?.text).toBe("cmuxlayer");
  });

  it("maps a substituted token to the full spoken timing span", async () => {
    const { speak } = await import("../tts");

    await speak("Etan");
    await waitFor(
      () => broadcasts.some((event) => event.type === "subtitle"),
      "substituted subtitle event",
    );

    const subtitle = broadcasts.find((event) => event.type === "subtitle");
    expect(subtitle?.words).toEqual([
      { offset_ms: 0, duration_ms: 220, text: "Etan" },
    ]);
  });

  it("broadcasts original tokens on the real subtitle render surface", async () => {
    const { speak } = await import("../tts");

    await speak("Etan runs supabase cmuxlayer golems and BrainLayer");
    await waitFor(
      () => broadcasts.some(
        (event) => event.type === "state" &&
          event.state === "speaking" &&
          event.text === "Etan runs supabase cmuxlayer golems and BrainLayer",
      ),
      "full display-text speaking event",
    );

    const synthesis = spawnCalls.find((call) => call.cmd[0].includes("python3"));
    expect(synthesis?.cmd).toContain(
      "--text=Eh tahn runs Soopa base cmuxlayer Go lems and Brain Layer",
    );
    const subtitle = broadcasts.find((event) => event.type === "subtitle");
    expect(subtitle?.words.map((word: { text: string }) => word.text)).toEqual([
      "Etan",
      "runs",
      "supabase",
      "cmuxlayer",
      "golems",
      "and",
      "BrainLayer",
    ]);
    const speaking = broadcasts.find(
      (event) => event.type === "state" && event.state === "speaking",
    );
    expect(speaking?.text).toBe(
      "Etan runs supabase cmuxlayer golems and BrainLayer",
    );
  });

  it("broadcasts all 2,300 display characters through edge TTS", async () => {
    const { speak } = await import("../tts");
    const displayText = "A".repeat(2_300);

    await speak(displayText);
    await waitFor(
      () => broadcasts.some(
        (event) =>
          event.type === "state" &&
          event.state === "speaking",
      ),
      "long edge-TTS speaking event",
    );

    const speaking = broadcasts.find(
      (event) => event.type === "state" && event.state === "speaking",
    );
    expect(speaking?.text).toBe(displayText);
  });

  it("broadcasts all 2,300 display characters through cloned TTS", async () => {
    const profileSpy = spyOn(qwen3, "loadProfile").mockReturnValue({
      profile_id: "long-display-clone",
      name: "long-display-clone",
      engine: "qwen3-tts",
      model_path: `${TEST_TMP}/long-display-clone-model`,
      reference_clips: [],
      reference_clip: "",
      fallback: "jenny",
      created: "2026-07-28",
    });
    const synthesizeSpy = spyOn(qwen3, "synthesizeCloned").mockResolvedValue(
      Buffer.from("fake cloned mp3"),
    );

    try {
      const { speak } = await import("../tts");
      const displayText = "B".repeat(2_300);

      const result = await speak(displayText, {
        voice: "long-display-clone",
      });
      expect(synthesizeSpy).toHaveBeenCalledTimes(1);
      expect(result.engine).toBe("qwen3-tts");
      await waitFor(
        () => broadcasts.some(
          (event) =>
            event.type === "state" &&
            event.state === "speaking",
        ),
        "long cloned-TTS speaking event",
      );

      const speaking = broadcasts.find(
        (event) => event.type === "state" && event.state === "speaking",
      );
      expect(speaking?.text).toBe(displayText);
    } finally {
      profileSpy.mockRestore();
      synthesizeSpy.mockRestore();
    }
  });

  it("falls back to the original text when engine boundaries cannot map cleanly", async () => {
    const { alignWordBoundariesToDisplayText } = await import("../tts");

    expect(
      alignWordBoundariesToDisplayText("Etan", "Eh tahn", [
        { offset_ms: 40, duration_ms: 160, text: "Eh" },
      ]),
    ).toEqual([{ offset_ms: 40, duration_ms: 160, text: "Etan" }]);
  });
});
