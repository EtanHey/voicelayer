import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { platform } from "os";
import { existsSync, unlinkSync, readFileSync, writeFileSync } from "fs";

// Mock Bun.spawn and Bun.spawnSync to avoid actually playing audio
const originalSpawn = Bun.spawn;
const originalSpawnSync = Bun.spawnSync;
let spawnCalls: { cmd: string[] }[] = [];

describe("tts module", () => {
  beforeEach(() => {
    spawnCalls = [];
    // @ts-ignore — mock Bun.spawn
    Bun.spawn = (cmd: string[], opts?: unknown) => {
      spawnCalls.push({ cmd: [...cmd] });
      return { exited: Promise.resolve(0), pid: 99999, kill: () => {} };
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
      unlinkSync("/tmp/.claude_tts_disabled");
    } catch {}
  });

  afterEach(() => {
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
    try {
      unlinkSync("/tmp/voicelayer-history.json");
    } catch {}
    try {
      unlinkSync("/tmp/.claude_tts_disabled");
    } catch {}
  });

  it("speak() calls edge-tts then audio player (non-blocking)", async () => {
    const { speak } = await import("../tts");

    await speak("Hello test");

    // On macOS: afplay, on Linux with no players: mpg123 fallback
    const expectedPlayer = platform() === "darwin" ? "afplay" : "mpg123";
    expect(spawnCalls.length).toBe(2);
    expect(spawnCalls[0].cmd[0]).toBe("python3");
    // Uses edge-tts-words.py script for word boundary metadata
    expect(
      spawnCalls[0].cmd.some((c: string) => c.includes("edge-tts-words")),
    ).toBe(true);
    expect(spawnCalls[0].cmd).toContain("Hello test");
    expect(spawnCalls[1].cmd[0]).toBe(expectedPlayer);
  });

  it("speak() uses configured voice and rate", async () => {
    const { speak } = await import("../tts");

    await speak("Voice test");

    const edgeTtsCmd = spawnCalls[0].cmd;
    const voiceIdx = edgeTtsCmd.indexOf("--voice");
    expect(voiceIdx).toBeGreaterThan(-1);
    // Default voice should be JennyNeural
    expect(edgeTtsCmd[voiceIdx + 1]).toContain("Jenny");
  });

  it("speak() only calls edge-tts and afplay", async () => {
    const { speak } = await import("../tts");

    await speak("No F5 test");

    const osascriptCall = spawnCalls.find((c) => c.cmd[0] === "osascript");
    expect(osascriptCall).toBeUndefined();
  });

  it("speak() skips when TTS is disabled via flag file", async () => {
    writeFileSync("/tmp/.claude_tts_disabled", "test");
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
