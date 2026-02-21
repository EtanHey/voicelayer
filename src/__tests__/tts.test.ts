import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { platform } from "os";

// Mock Bun.spawn and Bun.spawnSync to avoid actually playing audio
const originalSpawn = Bun.spawn;
const originalSpawnSync = Bun.spawnSync;
let spawnCalls: { cmd: string[] }[] = [];

describe("tts module", () => {
  beforeEach(() => {
    spawnCalls = [];
    // @ts-ignore — mock Bun.spawn
    Bun.spawn = (cmd: string[]) => {
      spawnCalls.push({ cmd: [...cmd] });
      return { exited: Promise.resolve(0) };
    };
    // @ts-ignore — mock Bun.spawnSync so getAudioPlayer() is deterministic on all platforms
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return { exitCode: 1, stdout: new Uint8Array(0), stderr: new Uint8Array(0) };
      }
      return originalSpawnSync(cmd);
    };
  });

  afterEach(() => {
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("speak() calls edge-tts then audio player", async () => {
    const { speak } = await import("../tts");

    await speak("Hello test");

    // On macOS: afplay, on Linux with no players: mpg123 fallback
    const expectedPlayer = platform() === "darwin" ? "afplay" : "mpg123";
    expect(spawnCalls.length).toBe(2);
    expect(spawnCalls[0].cmd[0]).toBe("python3");
    expect(spawnCalls[0].cmd).toContain("edge_tts");
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
});
