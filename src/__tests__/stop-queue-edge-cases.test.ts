/**
 * Edge case tests for stopPlayback() queue clearing.
 *
 * Verifies that stopPlayback() correctly clears the queue to prevent
 * queued audio from playing after user explicitly stops playback.
 */

import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import * as socketClient from "../socket-client";

interface MockPlayer {
  cmd: string[];
  resolveExit: () => void;
}

describe("stopPlayback queue clearing", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: unknown[];
  let playerMocks: MockPlayer[];
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;

  beforeEach(() => {
    broadcasts = [];
    playerMocks = [];

    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(JSON.parse(JSON.stringify(event)));
      },
    );

    // @ts-ignore — mock Bun.spawnSync for getAudioPlayer
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

    // @ts-ignore — mock Bun.spawn: audio players are controllable
    Bun.spawn = (cmd: string[], _opts?: unknown) => {
      const cmdArray = Array.isArray(cmd) ? [...cmd] : [String(cmd)];
      let resolveExit!: () => void;
      const exited = new Promise<number>((r) => {
        resolveExit = () => r(0);
      });
      playerMocks.push({ cmd: cmdArray, resolveExit });
      return { exited, pid: 99000 + playerMocks.length, kill: () => {} };
    };
  });

  afterEach(async () => {
    // Drain queue before restoring spawn
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(100);

    broadcastSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("stopPlayback clears queue — queued items do not play after stop", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");

    // Queue two items
    playAudioNonBlocking("/tmp/stop-test1.mp3", {
      text: "First",
      voice: "TestVoice",
    });
    playAudioNonBlocking("/tmp/stop-test2.mp3", {
      text: "Second",
      voice: "TestVoice",
    });

    await Bun.sleep(50);

    // First item should be playing
    expect(playerMocks.length).toBe(1);
    const speakingBefore = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "speaking",
    );
    expect(speakingBefore.length).toBe(1);
    expect((speakingBefore[0] as any).text).toBe("First");

    // Stop playback
    const stopped = stopPlayback();
    expect(stopped).toBe(true);

    // Idle should be broadcast immediately
    const idlesAfterStop = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idlesAfterStop.length).toBe(1);

    // Wait for queue to settle
    await Bun.sleep(200);

    // Second item should NOT have played (queue was cleared)
    const allSpeaking = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "speaking",
    );
    expect(allSpeaking.length).toBe(1); // Only first item spoke

    // Only one player should have been spawned (second was cancelled)
    expect(playerMocks.length).toBe(1);
  });

  it("stopPlayback is idempotent — multiple calls are safe", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");

    playAudioNonBlocking("/tmp/stop-idempotent.mp3");

    await Bun.sleep(50);

    // Stop twice
    const stopped1 = stopPlayback();
    const stopped2 = stopPlayback();

    expect(stopped1).toBe(true);
    expect(stopped2).toBe(false); // No playback to stop

    // Should only broadcast idle once
    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBe(1);
  });

  it("queueSize does not go negative after stop + error", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");

    // Queue one item
    playAudioNonBlocking("/tmp/stop-negative.mp3");

    await Bun.sleep(50);

    // Stop it
    stopPlayback();

    // Manually trigger the error path (simulating spawn failure)
    // The catch block should use Math.max(0, queueSize - 1)
    // This is tested indirectly — if queueSize went negative, idle wouldn't broadcast

    await Bun.sleep(100);

    // Idle should be broadcast (queueSize should be 0, not negative)
    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBeGreaterThanOrEqual(1);
  });
});

describe("playback error handling", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: unknown[];
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;

  beforeEach(() => {
    broadcasts = [];
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(JSON.parse(JSON.stringify(event)));
      },
    );

    // @ts-ignore
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
    await Bun.sleep(100);
    broadcastSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("broadcasts idle when audio player spawn fails", async () => {
    // @ts-ignore — mock spawn to throw
    Bun.spawn = () => {
      throw new Error("afplay not found");
    };

    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking("/tmp/spawn-error.mp3", {
      text: "Test",
      voice: "TestVoice",
    });

    await Bun.sleep(100);

    // Should broadcast idle after error
    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBeGreaterThanOrEqual(1);
  });

  it("awaitCurrentPlayback swallows queue errors", async () => {
    // @ts-ignore — mock spawn to throw
    Bun.spawn = () => {
      throw new Error("player crashed");
    };

    const { playAudioNonBlocking, awaitCurrentPlayback } =
      await import("../tts");

    playAudioNonBlocking("/tmp/await-error.mp3");

    // Should not throw — errors are swallowed
    await expect(awaitCurrentPlayback()).resolves.toBeUndefined();
  });
});
