import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import * as socketClient from "../socket-client";

interface MockPlayer {
  resolveExit: () => void;
}

describe("audio queue visualization events", () => {
  let broadcastSpy: ReturnType<typeof spyOn>;
  let broadcasts: any[];
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
    Bun.spawn = (_cmd: string[], _opts?: unknown) => {
      let resolveExit!: () => void;
      const exited = new Promise<number>((resolve) => {
        resolveExit = () => resolve(0);
      });
      playerMocks.push({ resolveExit });
      return {
        exited,
        pid: 91000 + playerMocks.length,
        kill: () => resolveExit(),
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

  it("emits ordered queue items with current progress when multiple speaks are queued", async () => {
    const { playAudioNonBlocking } = await import("../tts");

    playAudioNonBlocking("/tmp/qv-current.mp3", {
      text: "Current line",
      voice: "jenny",
      priority: "normal",
      durationMs: 400,
    });
    playAudioNonBlocking("/tmp/qv-next.mp3", {
      text: "Queued line",
      voice: "jenny",
      priority: "high",
      durationMs: 300,
    });

    await Bun.sleep(140);

    const queueEvents = broadcasts.filter((event) => event.type === "queue");
    expect(queueEvents.length).toBeGreaterThan(0);

    const latest = queueEvents.at(-1);
    expect(latest).toMatchObject({
      type: "queue",
      depth: 2,
    });
    expect(latest.items).toHaveLength(2);
    expect(latest.items[0]).toMatchObject({
      text: "Current line",
      is_current: true,
      priority: "normal",
    });
    expect(latest.items[0].progress).toBeGreaterThan(0);
    expect(latest.items[0].progress).toBeLessThanOrEqual(1);
    expect(latest.items[1]).toMatchObject({
      text: "Queued line",
      is_current: false,
      priority: "high",
      progress: 0,
    });
  });

  it("clears queue items after stop", async () => {
    const { playAudioNonBlocking, stopPlayback } = await import("../tts");

    playAudioNonBlocking("/tmp/qv-stop-current.mp3", {
      text: "Current line",
      voice: "jenny",
      priority: "normal",
      durationMs: 400,
    });
    playAudioNonBlocking("/tmp/qv-stop-next.mp3", {
      text: "Queued line",
      voice: "jenny",
      priority: "normal",
      durationMs: 300,
    });

    await Bun.sleep(40);
    stopPlayback();
    await Bun.sleep(40);

    const latest = broadcasts.filter((event) => event.type === "queue").at(-1);
    expect(latest).toMatchObject({
      type: "queue",
      depth: 0,
      items: [],
    });
  });
});
