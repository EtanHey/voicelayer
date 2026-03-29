import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import * as socketClient from "../socket-client";

interface MockPlayer {
  cmd: string[];
  killed: boolean;
  resolveExit: () => void;
}

describe("tts priority queue", () => {
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
      const mock: MockPlayer = {
        cmd: [...(Array.isArray(cmd) ? cmd : [String(cmd)])],
        killed: false,
        resolveExit: () => {},
      };
      const exited = new Promise<number>((resolve) => {
        resolveExit = () => resolve(0);
      });
      mock.resolveExit = resolveExit;
      playerMocks.push(mock);
      return {
        exited,
        pid: 88000 + playerMocks.length,
        kill: () => {
          mock.killed = true;
          resolveExit();
        },
      };
    };
  });

  afterEach(async () => {
    try {
      const { stopPlayback, awaitCurrentPlayback } = await import("../tts");
      stopPlayback();
      await awaitCurrentPlayback();
    } catch {}

    broadcastSpy.mockRestore();
    Bun.spawn = originalSpawn;
    Bun.spawnSync = originalSpawnSync;
  });

  it("critical playback barges in and discards stale queued low-priority items", async () => {
    const { playAudioNonBlocking, awaitCurrentPlayback } = await import("../tts");

    playAudioNonBlocking("/tmp/low-current.mp3", {
      text: "low current",
      voice: "voice",
      priority: "low",
    });
    playAudioNonBlocking("/tmp/low-queued.mp3", {
      text: "low queued",
      voice: "voice",
      priority: "low",
    });

    await Bun.sleep(30);
    expect(playerMocks.length).toBe(1);

    playAudioNonBlocking("/tmp/critical.mp3", {
      text: "critical now",
      voice: "voice",
      priority: "critical",
    });

    await Bun.sleep(30);

    expect(playerMocks[0].killed).toBe(true);
    expect(playerMocks.length).toBe(2);
    expect(playerMocks[1].cmd).toContain("/tmp/critical.mp3");

    playerMocks[1].resolveExit();
    await awaitCurrentPlayback();

    expect(playerMocks.length).toBe(2);
    const queueEvents = broadcasts.filter((event: any) => event.type === "queue");
    expect(queueEvents.at(-1)).toMatchObject({ type: "queue", depth: 0 });
  });

  it("collapses bursty low-priority chatter to the newest queued item", async () => {
    const { playAudioNonBlocking, awaitCurrentPlayback } = await import("../tts");

    playAudioNonBlocking("/tmp/current.mp3", {
      text: "current",
      voice: "voice",
      priority: "normal",
    });
    await Bun.sleep(30);

    playAudioNonBlocking("/tmp/low-a.mp3", {
      text: "low a",
      voice: "voice",
      priority: "low",
    });
    playAudioNonBlocking("/tmp/low-b.mp3", {
      text: "low b",
      voice: "voice",
      priority: "low",
    });
    playAudioNonBlocking("/tmp/low-c.mp3", {
      text: "low c",
      voice: "voice",
      priority: "low",
    });

    playerMocks[0].resolveExit();
    await Bun.sleep(40);

    expect(playerMocks.length).toBe(2);
    expect(playerMocks[1].cmd).toContain("/tmp/low-c.mp3");

    playerMocks[1].resolveExit();
    await awaitCurrentPlayback();
  });

  it("emits queue depth updates when items enter and leave the queue", async () => {
    const { playAudioNonBlocking, awaitCurrentPlayback } = await import("../tts");

    playAudioNonBlocking("/tmp/depth-1.mp3", {
      text: "depth 1",
      voice: "voice",
      priority: "normal",
    });
    playAudioNonBlocking("/tmp/depth-2.mp3", {
      text: "depth 2",
      voice: "voice",
      priority: "normal",
    });

    await Bun.sleep(30);

    const queueEvents = broadcasts.filter((event: any) => event.type === "queue");
    expect(queueEvents[0]).toMatchObject({ type: "queue", depth: 1 });
    expect(queueEvents.some((event: any) => event.depth === 2)).toBe(true);

    playerMocks[0].resolveExit();
    await Bun.sleep(30);
    playerMocks[1].resolveExit();
    await awaitCurrentPlayback();

    const lastQueueEvent = broadcasts
      .filter((event: any) => event.type === "queue")
      .at(-1);
    expect(lastQueueEvent).toMatchObject({ type: "queue", depth: 0 });
  });
});
