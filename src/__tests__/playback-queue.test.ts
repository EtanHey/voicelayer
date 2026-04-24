/**
 * P0-1 playback queue tests + P0-2 awaitCurrentPlayback queue awareness.
 *
 * TDD RED phase: tests define desired behavior that doesn't exist yet.
 *
 * P0-1: voice_speak audio overlap — rapid calls must queue, not overlap.
 *        Speaking broadcast must be tied to actual playback start.
 *        Idle broadcast only fires when queue fully drains.
 *
 * P0-2: awaitCurrentPlayback must wait for full queue, not just current item.
 *        This prevents voice_ask from starting recording while queued audio
 *        is still pending.
 */

import { describe, it, expect, beforeEach, afterEach, spyOn } from "bun:test";
import * as socketClient from "../socket-client";

// --- Mock helpers ---

interface MockPlayer {
  cmd: string[];
  resolveExit: () => void;
}

describe("playback queue — P0-1 sequential playback", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: unknown[];
  let playerMocks: MockPlayer[];
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;

  beforeEach(async () => {
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcasts = [];
    playerMocks = [];

    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      (event: unknown) => {
        broadcasts.push(JSON.parse(JSON.stringify(event)));
      },
    );

    // @ts-ignore — mock Bun.spawnSync for getAudioPlayer + ffprobe
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: new Uint8Array(0),
        };
      }
      if (Array.isArray(cmd) && cmd[0] === "ffprobe") {
        return {
          exitCode: 0,
          stdout: Buffer.from("1.0\n"),
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
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(50);
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcastSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("plays audio files sequentially — second spawns only after first finishes", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking("/tmp/pq-seq1.mp3");
    playAudioNonBlocking("/tmp/pq-seq2.mp3");

    await Bun.sleep(50);

    // Only first player should be spawned (queue serializes)
    expect(playerMocks.length).toBe(1);
    expect(playerMocks[0].cmd).toContain("/tmp/pq-seq1.mp3");

    // Finish first playback
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // Now second player should be spawned
    expect(playerMocks.length).toBe(2);
    expect(playerMocks[1].cmd).toContain("/tmp/pq-seq2.mp3");

    // Finish second
    playerMocks[1].resolveExit();
    await Bun.sleep(50);
  });

  it("broadcasts speaking via metadata when playback actually starts, not when queued", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    // Queue two items WITH metadata — this param doesn't exist yet (TDD RED)
    playAudioNonBlocking("/tmp/pq-meta1.mp3", {
      text: "First message",
      voice: "TestVoice",
    });
    playAudioNonBlocking("/tmp/pq-meta2.mp3", {
      text: "Second message",
      voice: "TestVoice",
    });

    await Bun.sleep(50);

    // Only first speaking broadcast should exist (second hasn't started playing yet)
    const speakingEvents = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "speaking",
    );
    expect(speakingEvents.length).toBe(1);
    expect((speakingEvents[0] as any).text).toBe("First message");

    // Finish first playback → second should start and broadcast
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    const allSpeaking = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "speaking",
    );
    expect(allSpeaking.length).toBe(2);
    expect((allSpeaking[1] as any).text).toBe("Second message");

    // Cleanup
    playerMocks[1].resolveExit();
    await Bun.sleep(50);
  });

  it("broadcasts idle only when queue fully drains, not between items", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking("/tmp/pq-idle1.mp3");
    playAudioNonBlocking("/tmp/pq-idle2.mp3");

    await Bun.sleep(50);

    // Finish first — second is still queued
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // No idle broadcast yet — queue not empty
    const idlesBeforeDrain = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idlesBeforeDrain.length).toBe(0);

    // Finish second — queue fully drained
    playerMocks[1].resolveExit();
    await Bun.sleep(50);

    // Exactly one idle broadcast
    const idlesAfterDrain = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idlesAfterDrain.length).toBe(1);
  });

  it("single item broadcasts idle immediately after finishing", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking("/tmp/pq-single.mp3");

    await Bun.sleep(50);
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    const idles = broadcasts.filter(
      (b: any) => b.type === "state" && b.state === "idle",
    );
    expect(idles.length).toBe(1);
  });
});

describe("awaitCurrentPlayback — P0-2 queue awareness", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let playerMocks: MockPlayer[];
  const originalSpawn = Bun.spawn;
  const originalSpawnSync = Bun.spawnSync;

  beforeEach(async () => {
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    playerMocks = [];
    broadcastSpy = spyOn(socketClient, "broadcast").mockImplementation(
      () => {},
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

    // @ts-ignore
    Bun.spawn = (cmd: string[], _opts?: unknown) => {
      let resolveExit!: () => void;
      const exited = new Promise<number>((r) => {
        resolveExit = () => r(0);
      });
      playerMocks.push({
        cmd: [...(Array.isArray(cmd) ? cmd : [String(cmd)])],
        resolveExit,
      });
      return { exited, pid: 99000 + playerMocks.length, kill: () => {} };
    };
  });

  afterEach(async () => {
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(100);
    for (let i = 0; i < playerMocks.length; i++) {
      try {
        playerMocks[i].resolveExit();
      } catch {}
    }
    await Bun.sleep(50);
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcastSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("awaitCurrentPlayback waits for full queue, not just current item", async () => {
    const { playAudioNonBlocking, awaitCurrentPlayback } =
      await import("../tts");

    playAudioNonBlocking("/tmp/pq-aw1.mp3");
    playAudioNonBlocking("/tmp/pq-aw2.mp3");

    let awaited = false;
    awaitCurrentPlayback().then(() => {
      awaited = true;
    });

    await Bun.sleep(50);
    expect(awaited).toBe(false);

    // Finish first — queue still has second pending
    playerMocks[0].resolveExit();
    await Bun.sleep(50);

    // Should NOT resolve yet — second item still queued
    expect(awaited).toBe(false);

    // Finish second — queue fully drained
    playerMocks[1].resolveExit();
    await Bun.sleep(50);

    // NOW it should resolve
    expect(awaited).toBe(true);
  });

  it("awaitCurrentPlayback resolves immediately if queue is empty", async () => {
    const { awaitCurrentPlayback } = await import("../tts");

    let awaited = false;
    awaitCurrentPlayback().then(() => {
      awaited = true;
    });

    await Bun.sleep(50);
    expect(awaited).toBe(true);
  });
});
