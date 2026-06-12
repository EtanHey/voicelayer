import { describe, expect, it } from "bun:test";
import {
  ensureSTTPolishServer,
  resetSTTPolishServerManagerForTests,
} from "../stt-polish-server";

describe("stt-polish-server", () => {
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
});
