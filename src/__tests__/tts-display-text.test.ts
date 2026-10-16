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
import { projectSpeakableText } from "../speakable-text";

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
      if (cmd[0] === "which" && cmd[1] === "ffmpeg") return {pid: 89990, exited: Promise.resolve(0), stdout: new Blob(["ffmpeg\n"]).stream(), kill() {}};
      if (cmd[1] === "-version") return {pid: 89991, exited: Promise.resolve(cmd[0] === "ffmpeg" ? 0 : 1), kill() {}};
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
      if (cmd[0] === "which" && ["ffmpeg", "ffprobe"].includes(cmd[1])) return {exitCode: 0, stdout: Buffer.from(`${cmd[1]}\n`), stderr: Buffer.alloc(0)};
      if (cmd[1] === "-version") return {exitCode: ["ffmpeg", "ffprobe"].includes(cmd[0]) ? 0 : 1, stdout: Buffer.alloc(0), stderr: Buffer.alloc(0)};
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

  it("normalizes developer text for Edge while timings still name the original words", async () => {
    const { speak } = await import("../tts");
    const display = "Play MP3 from INCIDENT-INVENTORY.md at 3 PM.";
    await speak(display);
    await waitFor(() => broadcasts.some(e => e.type === "subtitle"), "mapped subtitles");
    expect(spawnCalls.find(c => c.cmd[0].includes("python3"))?.cmd)
      .toContain("--text=Play MP3 from incident inventory dot M D at 3 PM.");
    expect(broadcasts.find(e => e.type === "subtitle").words.map((w: any) => w.text))
      .toEqual(display.split(" "));
    expect(broadcasts.find(e => e.state === "speaking").text).toBe(display);
  });

  it("maps measured speech spans through contractions, expansion, repeats and omitted markdown", async () => {
    const { alignWordBoundariesToDisplayText: align } = await import("../tts");
    const speech = "Play M P three then S three M P three.";
    const timings = speech.split(" ").map((text, i) => ({text, offset_ms: i * 100, duration_ms: 50}));
    expect(align("Play MP3 then S3 MP3.", speech, timings, projectSpeakableText("Play MP3 then S3 MP3.").ranges)).toEqual([
      {text: "Play", offset_ms: 0, duration_ms: 50}, {text: "MP3", offset_ms: 100, duration_ms: 250},
      {text: "then", offset_ms: 400, duration_ms: 50}, {text: "S3", offset_ms: 500, duration_ms: 150},
      {text: "MP3.", offset_ms: 700, duration_ms: 250},
    ]);
    expect(align("Open /app/src/foo_bar.ts now", "Open foo bar dot T S now", ["Open", "foo", "bar", "dot", "T", "S", "now"].map((text, i) => ({text, offset_ms: i * 100, duration_ms: 50}))))
      .toEqual([{text: "Open", offset_ms: 0, duration_ms: 50}, {text: "/app/src/foo_bar.ts", offset_ms: 100, duration_ms: 450}, {text: "now", offset_ms: 600, duration_ms: 50}]);
    const markdown = align("- MP3", "M P three.", ["M", "P", "three", "."].map((text, i) => ({text, offset_ms: i * 100, duration_ms: 50})), projectSpeakableText("- MP3").ranges);
    expect(markdown.map(w => w.text)).toEqual(["-", "MP3"]);
    expect(markdown[0].duration_ms).toBe(0);
    expect(markdown[1]).toEqual({text: "MP3", offset_ms: 0, duration_ms: 250});
    expect(align("Unrelated words", "wrong text", timings)).toEqual([]);
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

  for (const [displayText, route] of [["B".repeat(2_300), "clone"], ["Export MP3 from INCIDENT-INVENTORY.md.", "clone"], ["Is that OK? MP3 API at 3 PM on 2026.10.15.", "fallback"], ["MP3 API", "announce"]] as const) it("keeps original cloned display text while normalizing synthesis input", async () => {
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
      route === "fallback" ? null : Buffer.from("fake cloned mp3"),
    );

    try {
      const { speak } = await import("../tts");
      const result = await speak(displayText, {
        voice: "long-display-clone", mode: route === "announce" ? "announce" : undefined,
      });
      expect(synthesizeSpy).toHaveBeenCalledTimes(route === "announce" ? 0 : 1);
      if (displayText.startsWith("Export")) expect(synthesizeSpy).toHaveBeenCalledWith(
        "Export M P three from incident inventory dot M D.", "long-display-clone",
      );
      expect(result.engine).toBe(route === "clone" ? "qwen3-tts" : "edge-tts");
      if (route === "announce") expect(spawnCalls.find(c => c.cmd[0].includes("python3"))?.cmd).toContain("--text=MP3 API");
      if (route === "fallback") {
        expect(synthesizeSpy).toHaveBeenCalledWith("Is that OK? M P three A P I at 3 PM on 2026.10.15.", "long-display-clone");
        expect(spawnCalls.find(c => c.cmd[0].includes("python3"))?.cmd).toContain(`--text=${displayText}`);
      }
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
