/**
 * Error recovery tests — H4, H5 from Phase 1 MCP Sweep audit.
 *
 * H4: waitForInput broadcasts idle when recordToBuffer throws
 * H5: Socket "record" command checks isVoiceBooked() to prevent concurrent recordings
 *
 * Uses spyOn for broadcast tracking (no mock.module leakage) and overrides
 * Bun.spawnSync to simulate sox-not-found without depending on system PATH.
 */

import { describe, it, expect, spyOn, beforeEach, afterEach } from "bun:test";
import { writeFileSync, unlinkSync, existsSync } from "fs";
import * as socketServer from "../socket-server";
import { LOCK_FILE } from "../paths";
import { handleSocketCommand } from "../socket-handlers";

// Override Bun.spawnSync to simulate sox not found
const realSpawnSync = Bun.spawnSync;
let blockSox = false;

// @ts-expect-error — overriding for test
Bun.spawnSync = function (...args: any[]) {
  const cmd = args[0];
  if (
    blockSox &&
    Array.isArray(cmd) &&
    cmd[0] === "which" &&
    cmd[1] === "rec"
  ) {
    return {
      exitCode: 1,
      stdout: new Uint8Array(),
      stderr: new Uint8Array(),
      success: false,
    };
  }
  return realSpawnSync.apply(Bun, args as any);
};

describe("H4: waitForInput broadcasts idle on recordToBuffer error", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    blockSox = true;
    broadcastSpy = spyOn(socketServer, "broadcast").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    blockSox = false;
    broadcastSpy.mockRestore();
  });

  it("broadcasts idle when sox is not installed", async () => {
    const { waitForInput } = await import("../input");

    let threw = false;
    try {
      await waitForInput(100, "quick", false);
    } catch (err) {
      threw = true;
      expect((err as Error).message).toContain("sox not installed");
    }

    expect(threw).toBe(true);

    const calls = broadcastSpy.mock.calls.map((c: any) => c[0]);
    const idleBroadcast = calls.find(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idleBroadcast).toBeDefined();
  });

  it("broadcasts error event with helpful message when sox is missing", async () => {
    const { waitForInput } = await import("../input");

    try {
      await waitForInput(100, "quick", false);
    } catch {
      // Expected
    }

    const calls = broadcastSpy.mock.calls.map((c: any) => c[0]);
    const errorBroadcast = calls.find(
      (b: any) => b.type === "error" && b.recoverable === true,
    );
    expect(errorBroadcast).toBeDefined();
    expect(errorBroadcast.message).toContain("sox");
  });
});

describe("M1: Socket toggle all writes individual flag files", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    broadcastSpy = spyOn(socketServer, "broadcast").mockImplementation(
      () => {},
    );
    // Clean up any flag files
    for (const f of [
      require("../paths").TTS_DISABLED_FILE,
      require("../paths").MIC_DISABLED_FILE,
      require("../paths").VOICE_DISABLED_FILE,
    ]) {
      try {
        if (existsSync(f)) unlinkSync(f);
      } catch {}
    }
  });

  afterEach(() => {
    broadcastSpy.mockRestore();
    // Clean up
    for (const f of [
      require("../paths").TTS_DISABLED_FILE,
      require("../paths").MIC_DISABLED_FILE,
      require("../paths").VOICE_DISABLED_FILE,
    ]) {
      try {
        if (existsSync(f)) unlinkSync(f);
      } catch {}
    }
  });

  it("disabling all also writes TTS and mic individual flag files", () => {
    handleSocketCommand({ cmd: "toggle", scope: "all", enabled: false });

    const {
      TTS_DISABLED_FILE: tts,
      MIC_DISABLED_FILE: mic,
      VOICE_DISABLED_FILE: voice,
    } = require("../paths");

    // Combined flag
    expect(existsSync(voice)).toBe(true);
    // M1 BUG: Individual flags should also be written
    expect(existsSync(tts)).toBe(true);
    expect(existsSync(mic)).toBe(true);
  });

  it("enabling all removes all three flag files", () => {
    // First disable all
    handleSocketCommand({ cmd: "toggle", scope: "all", enabled: false });
    // Then enable all
    handleSocketCommand({ cmd: "toggle", scope: "all", enabled: true });

    const {
      TTS_DISABLED_FILE: tts,
      MIC_DISABLED_FILE: mic,
      VOICE_DISABLED_FILE: voice,
    } = require("../paths");

    expect(existsSync(voice)).toBe(false);
    expect(existsSync(tts)).toBe(false);
    expect(existsSync(mic)).toBe(false);
  });
});

describe("H5: Socket record command checks session booking", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;

  beforeEach(() => {
    broadcastSpy = spyOn(socketServer, "broadcast").mockImplementation(
      () => {},
    );
  });

  afterEach(() => {
    broadcastSpy.mockRestore();
    // Clean up lock file
    try {
      if (existsSync(LOCK_FILE)) unlinkSync(LOCK_FILE);
    } catch {}
  });

  it("rejects record when voice session is booked by another process", () => {
    // Simulate another process owning the voice session
    // PID 1 = launchd — always alive on macOS, never our PID
    const fakeLock = {
      pid: 1,
      sessionId: "other-claude-session",
      startedAt: new Date().toISOString(),
    };
    writeFileSync(LOCK_FILE, JSON.stringify(fakeLock));

    handleSocketCommand({ cmd: "record" });

    const calls = broadcastSpy.mock.calls.map((c: any) => c[0]);

    // Should broadcast an error about session being busy
    const errorBroadcast = calls.find(
      (b: any) => b.type === "error" && b.message?.includes("busy"),
    );
    expect(errorBroadcast).toBeDefined();

    // Should NOT have started recording (no "recording" state broadcast)
    const recordingBroadcast = calls.find(
      (b: any) => b.type === "state" && b.state === "recording",
    );
    expect(recordingBroadcast).toBeUndefined();
  });

  it("allows record when session is booked by our own process", () => {
    // Book session by OUR process (should be allowed)
    const ourLock = {
      pid: process.pid,
      sessionId: `mcp-${process.pid}`,
      startedAt: new Date().toISOString(),
    };
    writeFileSync(LOCK_FILE, JSON.stringify(ourLock));

    // Block sox so recording doesn't actually start
    blockSox = true;
    handleSocketCommand({ cmd: "record" });
    blockSox = false;

    const calls = broadcastSpy.mock.calls.map((c: any) => c[0]);

    // Should NOT have blocked with "busy" error — our own session
    const busyError = calls.find(
      (b: any) => b.type === "error" && b.message?.includes("busy"),
    );
    expect(busyError).toBeUndefined();
  });
});
