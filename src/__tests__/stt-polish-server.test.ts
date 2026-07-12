import { describe, expect, it } from "bun:test";
import {
  ensureSTTPolishServer,
  onSTTPolishServerStatus,
  recoverDefaultSTTPolishServerAfterFailure,
  resetSTTPolishServerManagerForTests,
} from "../stt-polish-server";

describe("stt-polish-server", () => {
  it("publishes later status transitions so daemon UI state can clear", async () => {
    resetSTTPolishServerManagerForTests();
    const statuses: string[] = [];
    const unsubscribe = onSTTPolishServerStatus((status) => {
      statuses.push(status.status);
    });

    try {
      await ensureSTTPolishServer({
        env: { QA_VOICE_STT_POLISH: "on" },
        findBinary: () => null,
        isEndpointReady: async () => false,
        appendEvent: () => {},
      });
      await ensureSTTPolishServer({
        env: { QA_VOICE_STT_POLISH: "on" },
        isEndpointReady: async () => true,
      });
    } finally {
      unsubscribe();
    }

    expect(statuses).toEqual(["missing-binary", "already-ready"]);
  });

  it("publishes a runtime recovery launch failure to daemon UI listeners", async () => {
    resetSTTPolishServerManagerForTests();
    const statuses: string[] = [];
    const unsubscribe = onSTTPolishServerStatus((status) => {
      statuses.push(status.status);
    });

    try {
      recoverDefaultSTTPolishServerAfterFailure(
        { QA_VOICE_STT_POLISH: "on" },
        {
          findBinary: () => {
            throw new Error("runtime spawn failed");
          },
          isEndpointReady: async () => false,
        },
      );
      for (let attempts = 0; attempts < 20 && statuses.length === 0; attempts++) {
        await Bun.sleep(0);
      }
    } finally {
      unsubscribe();
    }

    expect(statuses).toEqual(["launch-failed"]);
  });

  it("does not manage a server when polish is explicitly off", async () => {
    const spawnCalls: string[][] = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "off" },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => false,
      spawn: (args) => {
        spawnCalls.push(args);
        return { pid: 123, exited: new Promise(() => {}) };
      },
      sleep: async () => {},
    });

    expect(result.status).toBe("disabled");
    expect(spawnCalls).toEqual([]);
  });

  it("does not manage a custom polish endpoint", async () => {
    const result = await ensureSTTPolishServer({
      env: {
        QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_ENDPOINT: "http://127.0.0.1:9999/v1/chat/completions",
      },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => false,
      spawn: () => {
        throw new Error("should not spawn");
      },
      sleep: async () => {},
    });

    expect(result.status).toBe("external");
  });

  it("starts the default local MLX polish server and logs readiness", async () => {
    resetSTTPolishServerManagerForTests();
    const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const spawnCalls: string[][] = [];
    let readinessChecks = 0;

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => ++readinessChecks >= 2,
      spawn: (args) => {
        spawnCalls.push(args);
        return { pid: 456, exited: new Promise(() => {}) };
      },
      appendEvent: (type, payload) => {
        events.push({ type, payload });
      },
      sleep: async () => {},
      startupTimeoutMs: 10_000,
    });

    expect(result).toMatchObject({ status: "ready", pid: 456 });
    expect(spawnCalls).toHaveLength(1);
    expect(spawnCalls[0]).toEqual([
      "/tmp/mlx_lm.server",
      "--model",
      "mlx-community/Qwen3-4B-Instruct-2507-4bit",
      "--host",
      "127.0.0.1",
      "--port",
      "8080",
    ]);
    expect(events.map((event) => event.type)).toEqual([
      "transcription.polish_server_starting",
      "transcription.polish_server_ready",
    ]);
    expect(events[1].payload).toMatchObject({ pid: 456, port: 8080 });
  });

  it("reaps stale local polish port owners before spawning a replacement", async () => {
    resetSTTPolishServerManagerForTests();
    const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];
    const spawnCalls: string[][] = [];
    let readinessChecks = 0;

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      findStalePortOwnerPids: () => [70870],
      killProcess: (pid, signal) => {
        killed.push({ pid, signal });
      },
      isEndpointReady: async () => ++readinessChecks >= 2,
      spawn: (args) => {
        spawnCalls.push(args);
        return { pid: 456, exited: new Promise(() => {}) };
      },
      appendEvent: (type, payload) => {
        events.push({ type, payload });
      },
      sleep: async () => {},
      startupTimeoutMs: 10_000,
    });

    expect(result).toMatchObject({ status: "ready", pid: 456 });
    expect(killed).toEqual([{ pid: 70870, signal: "SIGTERM" }]);
    expect(spawnCalls).toHaveLength(1);
    expect(events.map((event) => event.type)).toEqual([
      "transcription.polish_server_stale_owner_reaped",
      "transcription.polish_server_starting",
      "transcription.polish_server_ready",
    ]);
    expect(events[0].payload).toMatchObject({ port: 8080, pids: [70870] });
  });

  it("force-restarts a local polish owner even when health checks pass", async () => {
    resetSTTPolishServerManagerForTests();
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];
    const spawnCalls: string[][] = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      forceRestart: true,
      findBinary: () => "/tmp/mlx_lm.server",
      findStalePortOwnerPids: () => [8080],
      killProcess: (pid, signal) => {
        killed.push({ pid, signal });
      },
      isEndpointReady: async () => true,
      spawn: (args) => {
        spawnCalls.push(args);
        return { pid: 456, exited: new Promise(() => {}) };
      },
      appendEvent: () => {},
      sleep: async () => {},
      startupTimeoutMs: 10_000,
    });

    expect(result).toMatchObject({ status: "ready", pid: 456 });
    expect(killed).toEqual([{ pid: 8080, signal: "SIGTERM" }]);
    expect(spawnCalls).toHaveLength(1);
  });

  it("does not report ready while a stale owner still serves the polish port", async () => {
    resetSTTPolishServerManagerForTests();
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];
    const signals: string[] = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      forceRestart: true,
      findBinary: () => "/tmp/mlx_lm.server",
      findStalePortOwnerPids: () => [70870],
      findPortOwnerPids: () => [70870],
      killProcess: (pid, signal) => {
        killed.push({ pid, signal });
      },
      isEndpointReady: async () => true,
      spawn: () => ({
        pid: 456,
        kill: (signal?: NodeJS.Signals) => {
          signals.push(signal ?? "SIGTERM");
        },
        exited: new Promise(() => {}),
      }),
      appendEvent: () => {},
      sleep: async () => {},
      startupTimeoutMs: 1,
    });

    expect(result).toEqual({ status: "timeout" });
    expect(killed).toEqual([{ pid: 70870, signal: "SIGTERM" }]);
    expect(signals).toEqual(["SIGTERM"]);
  });

  it("coalesces force restart with an in-flight polish launch", async () => {
    resetSTTPolishServerManagerForTests();
    const spawnCalls: string[][] = [];
    let ready = false;
    let releaseSleep: (() => void) | null = null;

    const firstLaunch = ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => ready,
      spawn: (args) => {
        spawnCalls.push(args);
        return { pid: 456, exited: new Promise(() => {}) };
      },
      appendEvent: () => {},
      sleep: async () =>
        new Promise<void>((resolve) => {
          releaseSleep = () => {
            ready = true;
            resolve();
          };
        }),
      startupTimeoutMs: 10_000,
    });

    for (let attempts = 0; attempts < 10 && !releaseSleep; attempts++) {
      await Bun.sleep(0);
    }
    if (!releaseSleep) throw new Error("first launch did not reach startup wait");

    const forcedRecovery = ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      forceRestart: true,
      findBinary: () => {
        throw new Error("force restart should reuse in-flight launch");
      },
    });

    expect(spawnCalls).toHaveLength(1);
    releaseSleep();
    await expect(firstLaunch).resolves.toMatchObject({
      status: "ready",
      pid: 456,
    });
    await expect(forcedRecovery).resolves.toMatchObject({
      status: "ready",
      pid: 456,
    });
    expect(spawnCalls).toHaveLength(1);
  });

  it("terminates a spawned polish server when startup readiness times out", async () => {
    resetSTTPolishServerManagerForTests();
    const signals: string[] = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => false,
      spawn: () => ({
        pid: 789,
        kill: (signal?: NodeJS.Signals) => {
          signals.push(signal ?? "SIGTERM");
        },
        exited: new Promise(() => {}),
      }),
      appendEvent: () => {},
      sleep: async () => {},
      startupTimeoutMs: 1,
    });

    expect(result).toEqual({ status: "timeout" });
    expect(signals).toEqual(["SIGTERM"]);
  });

  it("logs startup timeout health details including binary pid readiness and stderr tail", async () => {
    resetSTTPolishServerManagerForTests();
    const events: Array<{ type: string; payload: Record<string, unknown> }> = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => false,
      spawn: () => ({
        pid: 789,
        kill: () => {},
        stderr: new ReadableStream<Uint8Array>({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("loading qwen\n"));
            controller.enqueue(new TextEncoder().encode("still warming mlx\n"));
            controller.close();
          },
        }),
        exited: new Promise(() => {}),
      }),
      appendEvent: (type, payload) => {
        events.push({ type, payload });
      },
      sleep: async () => {
        await Bun.sleep(0);
      },
      startupTimeoutMs: 1,
    });

    expect(result).toEqual({ status: "timeout" });
    const timeoutEvent = events.find(
      (event) => event.type === "transcription.polish_server_timeout",
    );
    expect(timeoutEvent?.payload).toMatchObject({
      binary: "/tmp/mlx_lm.server",
      pid: 789,
      readiness_checks: expect.any(Number),
      stderr_tail: expect.stringContaining("still warming mlx"),
    });
  });
});
