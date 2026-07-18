import { describe, it, expect, beforeEach, afterEach, mock } from "bun:test";
import { platform } from "os";
import { existsSync, unlinkSync, readFileSync, writeFileSync } from "fs";
import * as actualPaths from "../paths";

// Mock Bun.spawn and Bun.spawnSync to avoid actually playing audio
const originalSpawn = Bun.spawn;
const originalSpawnSync = Bun.spawnSync;
let spawnCalls: { cmd: string[] }[] = [];

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

const TEST_TTS_DISABLED_FILE = `/tmp/voicelayer-tts-${process.pid}-disabled`;

mock.module("../paths", () => ({
  ...actualPaths,
  TTS_DISABLED_FILE: TEST_TTS_DISABLED_FILE,
}));

describe("tts module", () => {
  beforeEach(() => {
    spawnCalls = [];
    // @ts-ignore — mock Bun.spawn
    Bun.spawn = (cmd: string[], opts?: unknown) => {
      spawnCalls.push({ cmd: [...cmd] });
      if (Array.isArray(cmd) && cmd[0].includes("python3")) {
        // edge-tts args use the `--flag=value` form (see buildEdgeTTSArgs),
        // so extract values by prefix rather than the two-token indexOf shape.
        const argValue = (flag: string): string | undefined => {
          const hit = cmd.find((c) => c.startsWith(`${flag}=`));
          return hit ? hit.slice(flag.length + 1) : undefined;
        };
        const mediaPath = argValue("--write-media");
        if (mediaPath) {
          writeFileSync(mediaPath, "fake mp3");
        }
        const metadataPath = argValue("--write-metadata");
        if (metadataPath) {
          writeFileSync(
            metadataPath,
            [
              '{"offset":0,"duration":1000000,"text":"Hello"}',
              '{"offset":1200000,"duration":900000,"text":"world"}',
            ].join("\n") + "\n",
          );
        }
      }
      return {
        exited: Promise.resolve(0),
        pid: 99999,
        stdout:
          cmd[0] === "ffmpeg"
            ? new Blob([new Uint8Array([0, 0])]).stream()
            : undefined,
        kill: () => {},
      };
    };
    // @ts-ignore — mock Bun.spawnSync so getAudioPlayer() is deterministic on all platforms
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

    // Clean up history file before each test
    try {
      unlinkSync("/tmp/voicelayer-history.json");
    } catch {}
    // Clean up TTS disabled flag
    try {
      unlinkSync(TEST_TTS_DISABLED_FILE);
    } catch {}
  });

  afterEach(async () => {
    const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
    stopPlayback();
    await awaitCurrentPlayback();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
    try {
      unlinkSync("/tmp/voicelayer-history.json");
    } catch {}
    try {
      unlinkSync(TEST_TTS_DISABLED_FILE);
    } catch {}
  });

  it("speak() calls edge-tts then audio player (non-blocking)", async () => {
    const { speak } = await import("../tts");

    const result = await speak("Hello test", { captureAudioArtifact: true });
    await waitFor(() => spawnCalls.length === 3, "audio player spawn");

    // On macOS: afplay, on Linux with no players: mpg123 fallback
    const expectedPlayer = platform() === "darwin" ? "afplay" : "mpg123";
    expect(spawnCalls.length).toBe(3);
    // python3 may be resolved to full path (e.g., /Library/Frameworks/.../python3)
    expect(spawnCalls[0].cmd[0]).toContain("python3");
    // Uses edge-tts-words.py script for word boundary metadata
    expect(
      spawnCalls[0].cmd.some((c: string) => c.includes("edge-tts-words")),
    ).toBe(true);
    // Text is passed in =-bound form (--text=<value>) so a dash-leading
    // utterance can't be misparsed by argparse (exit-2 regression guard).
    expect(spawnCalls[0].cmd).toContain("--text=Hello test");
    expect(spawnCalls[1].cmd[0]).toBe("ffmpeg");
    expect(spawnCalls[2].cmd[0]).toBe(expectedPlayer);
    expect(result.audioArtifact?.format).toBe("mp3");
    expect(Buffer.from(result.audioArtifact!.bytes)).toEqual(
      Buffer.from("fake mp3"),
    );
    const actualVoice = spawnCalls[0].cmd
      .find((arg: string) => arg.startsWith("--voice="))!
      .slice("--voice=".length);
    expect(result.engine).toBe("edge-tts");
    expect(result.voice).toBe(actualVoice);
  });

  it("returns the sanitized display transcript paired with synthesized audio", async () => {
    const { speak } = await import("../tts");

    const result = await speak("<speak>Hello\u0000 archive</speak>", {
      captureAudioArtifact: true,
    });

    expect(result.displayText).toBe("Hello archive");
    expect(spawnCalls[0].cmd).toContain("--text=Hello archive");
    expect(result.audioArtifact?.format).toBe("mp3");
  });

  it("speak() uses configured voice and rate", async () => {
    const { speak } = await import("../tts");

    await speak("Voice test");

    const edgeTtsCmd = spawnCalls[0].cmd;
    // Voice is passed in =-bound form (--voice=<value>); no bare --voice token.
    expect(edgeTtsCmd).not.toContain("--voice");
    const voiceArg = edgeTtsCmd.find((arg: string) =>
      arg.startsWith("--voice="),
    );
    expect(voiceArg).toBeDefined();
    // Default voice should be JennyNeural
    expect(voiceArg).toContain("Jenny");
  });

  it("speak() passes negative long-text rates as a single --rate= argv token", async () => {
    const { speak } = await import("../tts");

    await speak("This is a long sentence. ".repeat(40), { mode: "brief" });

    const synthCalls = spawnCalls.filter((c: { cmd: string[] }) =>
      c.cmd[0].includes("python3"),
    );
    expect(synthCalls.length).toBeGreaterThan(1);
    for (const call of synthCalls) {
      // Regression guard: a negative rate (e.g. "-25%") MUST be passed as a
      // single `--rate=-25%` token. The two-token form ("--rate", "-25%") makes
      // Python argparse treat the value as a stray option and reject it.
      expect(call.cmd).not.toContain("--rate");
      const rateArg = call.cmd.find((arg) => arg.startsWith("--rate="));
      expect(rateArg).toBeDefined();
      expect(rateArg).toMatch(/^--rate=-\d+%$/);
    }
  });

  it("speak() only calls edge-tts and afplay", async () => {
    const { speak } = await import("../tts");

    await speak("No F5 test");

    const osascriptCall = spawnCalls.find((c) => c.cmd[0] === "osascript");
    expect(osascriptCall).toBeUndefined();
  });

  it("speak() tolerates missing ffprobe", async () => {
    // @ts-ignore — simulate ffprobe missing from PATH
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "ffprobe") {
        throw new Error('Executable not found in $PATH: "ffprobe"');
      }
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    const { speak } = await import("../tts");

    await speak("ffprobe is optional");
    await waitFor(() => spawnCalls.length === 3, "fallback audio player spawn");

    expect(spawnCalls.length).toBe(3);
    expect(spawnCalls[0].cmd[0]).toContain("python3");
    expect(spawnCalls[1].cmd[0]).toBe("ffmpeg");
  });

  it("speak() skips when TTS is disabled via flag file", async () => {
    writeFileSync(TEST_TTS_DISABLED_FILE, "test");
    const { speak } = await import("../tts");

    await speak("Should not speak");

    // No spawn calls should have been made
    expect(spawnCalls.length).toBe(0);
  });
});

describe("tts ring buffer", () => {
  beforeEach(() => {
    try {
      unlinkSync("/tmp/voicelayer-history.json");
    } catch {}
  });

  afterEach(() => {
    try {
      unlinkSync("/tmp/voicelayer-history.json");
    } catch {}
    // Clean up history audio files
    for (let i = 0; i < 20; i++) {
      try {
        unlinkSync(`/tmp/voicelayer-history-${i}.mp3`);
      } catch {}
    }
  });

  it("loadHistory returns empty array when no file", async () => {
    const { loadHistory } = await import("../tts");
    expect(loadHistory()).toEqual([]);
  });

  it("loadHistory returns empty array for corrupt JSON", async () => {
    writeFileSync("/tmp/voicelayer-history.json", "not json{{{");
    const { loadHistory } = await import("../tts");
    expect(loadHistory()).toEqual([]);
  });

  it("getHistoryEntry returns null when empty", async () => {
    const { getHistoryEntry } = await import("../tts");
    expect(getHistoryEntry(0)).toBeNull();
  });

  it("getHistoryEntry returns null for out-of-range index", async () => {
    const { getHistoryEntry } = await import("../tts");
    expect(getHistoryEntry(5)).toBeNull();
    expect(getHistoryEntry(-1)).toBeNull();
  });
});

describe("tts MODE_RATES", () => {
  it("has rates for all modes", async () => {
    const { MODE_RATES } = await import("../tts");
    expect(MODE_RATES.announce).toBe("+10%");
    expect(MODE_RATES.brief).toBe("-10%");
    expect(MODE_RATES.consult).toBe("+5%");
    expect(MODE_RATES.converse).toBe("+0%");
  });
});

describe("mergeWordBoundaryChunks", () => {
  it("offsets later chunks by accumulated chunk duration", async () => {
    const { mergeWordBoundaryChunks } = await import("../tts");

    const merged = mergeWordBoundaryChunks([
      {
        audioFile: "/tmp/chunk-1.mp3",
        durationMs: 420,
        wordBoundaries: [
          { offset_ms: 0, duration_ms: 90, text: "chunk" },
          { offset_ms: 110, duration_ms: 120, text: "one" },
        ],
      },
      {
        audioFile: "/tmp/chunk-2.mp3",
        durationMs: 380,
        wordBoundaries: [
          { offset_ms: 0, duration_ms: 80, text: "chunk" },
          { offset_ms: 95, duration_ms: 100, text: "two" },
        ],
      },
    ]);

    expect(merged).toEqual([
      { offset_ms: 0, duration_ms: 90, text: "chunk" },
      { offset_ms: 110, duration_ms: 120, text: "one" },
      { offset_ms: 420, duration_ms: 80, text: "chunk" },
      { offset_ms: 515, duration_ms: 100, text: "two" },
    ]);
  });
});
