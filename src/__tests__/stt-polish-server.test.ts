import { describe, expect, it } from "bun:test";
import {
  ensureSTTPolishServer,
  onSTTPolishServerStatus,
  recoverDefaultSTTPolishServerAfterFailure,
  resetSTTPolishServerManagerForTests,
  stopSTTPolishServerAndWait,
} from "../stt-polish-server";

describe("stt-polish-server", () => {
  it("does not restart a busy healthy owner after an unclassified failure", async () => {
    resetSTTPolishServerManagerForTests();
    let spawns = 0;
    const killed: number[] = [];
    recoverDefaultSTTPolishServerAfterFailure({ QA_VOICE_STT_POLISH: "on" }, {
      isResidentStack: () => true,
      findBinary: () => "/tmp/mlx_lm.server",
      findStalePortOwnerPids: () => [70870],
      isEndpointReady: async () => true,
      killProcess: (pid) => { killed.push(pid); },
      spawn: () => { spawns++; return { pid: 456 }; },
      sleep: async () => {}, appendEvent: () => {},
    });
    await Bun.sleep(10);
    expect(killed).toEqual([]);
    expect(spawns).toBe(0);
    resetSTTPolishServerManagerForTests();
  });

  it("keeps an unresponsive listening owner instead of spawning a second server", async () => {
    resetSTTPolishServerManagerForTests();
    let spawns = 0;
    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => false,
      findPortOwnerPids: () => [70870],
      spawn: () => { spawns++; return { pid: 456 }; },
      startupTimeoutMs: 1, sleep: async () => {}, appendEvent: () => {},
    });
    expect(result).toEqual({ status: "starting", pid: 70870 });
    expect(spawns).toBe(0);
    resetSTTPolishServerManagerForTests();
  });

  it.each(["timeout", "endpoint-error"] as const)("does not probe or relaunch after %s", async (failureKind) => {
    resetSTTPolishServerManagerForTests();
    let probes = 0;
    let spawns = 0;
    recoverDefaultSTTPolishServerAfterFailure({ QA_VOICE_STT_POLISH: "on" }, {
      failureKind, isEndpointReady: async () => { probes++; return false; },
      findBinary: () => "/tmp/mlx_lm.server",
      spawn: () => { spawns++; return { pid: 456 }; },
      startupTimeoutMs: 1, sleep: async () => {}, appendEvent: () => {}, log: () => {},
    });
    await Bun.sleep(0);
    expect(probes).toBe(0);
    expect(spawns).toBe(0);
    resetSTTPolishServerManagerForTests();
  });

  it.each(["connection-refused", "transport-error"] as const)("coalesces %s recovery and preserves a managed child still alive after timeout", async (failureKind) => {
    resetSTTPolishServerManagerForTests();
    let spawns = 0;
    let alive = true;
    const options = {
      failureKind,
      findBinary: () => "/tmp/mlx_lm.server",
      isEndpointReady: async () => false,
      isProcessAlive: () => alive,
      findPortOwnerPids: () => [],
      spawn: () => { spawns++; return { pid: 456, kill: () => {} }; },
      startupTimeoutMs: 1, stopExitTimeoutMs: 1, sleep: async () => {}, appendEvent: () => {}, log: () => {},
    };
    for (let i = 0; i < 3; i++) recoverDefaultSTTPolishServerAfterFailure({ QA_VOICE_STT_POLISH: "on" }, options);
    await Bun.sleep(10);
    expect(spawns).toBe(1);
    expect(await ensureSTTPolishServer({ ...options, env: { QA_VOICE_STT_POLISH: "on" } })).toEqual({ status: "starting", pid: 456 });
    expect(spawns).toBe(1);
    alive = false;
    await ensureSTTPolishServer({ ...options, env: { QA_VOICE_STT_POLISH: "on" } });
    expect(spawns).toBe(2);
    resetSTTPolishServerManagerForTests();
  });

  it("retains a managed pid after SIGTERM until its exit is observed", async () => {
    resetSTTPolishServerManagerForTests();
    let probes = 0;
    let spawns = 0;
    const killed: number[] = [];
    const options = {
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isProcessAlive: () => true,
      isEndpointReady: async () => ++probes >= 2,
      findPortOwnerPids: () => spawns ? [456] : [],
      spawn: () => { spawns++; return { pid: 456, kill: () => {}, exited: new Promise<number>(() => {}) }; },
      appendEvent: () => {}, sleep: async () => {}, log: () => {}, startupTimeoutMs: 1_000,
    };
    try {
      expect(await ensureSTTPolishServer(options)).toEqual({ status: "ready", pid: 456 });
      expect(await ensureSTTPolishServer({
        ...options, forceRestart: true, isResidentStack: () => true, isEndpointReady: async () => false,
        findStalePortOwnerPids: () => [456], findPortOwnerPids: () => [],
        killProcess: (pid) => { killed.push(pid); },
      })).toEqual({ status: "starting", pid: 456 });
      expect(killed).toEqual([456]);
      expect(spawns).toBe(1);
    } finally { resetSTTPolishServerManagerForTests(); }
  });

  it("R1 F1 reports an existing unready owner as degraded after its readiness window", async () => {
    resetSTTPolishServerManagerForTests();
    const statuses: string[] = [];
    const off = onSTTPolishServerStatus((s) => statuses.push(s.status));
    try {
      await ensureSTTPolishServer({ env: { QA_VOICE_STT_POLISH: "on" }, isEndpointReady: async () => false,
        findPortOwnerPids: () => [70870], startupTimeoutMs: 5 });
      await Bun.sleep(25);
      expect(statuses).toEqual(["starting", "timeout"]);
    } finally { off(); resetSTTPolishServerManagerForTests(); }
  });

  it("R1 F1 clears the owner watchdog when readiness is observed", async () => {
    resetSTTPolishServerManagerForTests();
    const statuses: string[] = [];
    const off = onSTTPolishServerStatus((s) => statuses.push(s.status));
    const options = { env: { QA_VOICE_STT_POLISH: "on" }, findPortOwnerPids: () => [70870], startupTimeoutMs: 5 };
    try {
      await ensureSTTPolishServer({ ...options, isEndpointReady: async () => false });
      await ensureSTTPolishServer({ ...options, isEndpointReady: async () => true });
      await Bun.sleep(25);
      expect(statuses).toEqual(["starting", "already-ready"]);
    } finally { off(); resetSTTPolishServerManagerForTests(); }
  });

  it("R1 F6 escalates a startup-timeout child that ignores SIGTERM and releases custody on exit", async () => {
    resetSTTPolishServerManagerForTests();
    const signals: string[] = [];
    let exit!: (code: number) => void;
    const exited = new Promise<number>((resolve) => { exit = resolve; });
    const result = await ensureSTTPolishServer({ env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server", isEndpointReady: async () => false, findPortOwnerPids: () => [],
      spawn: () => ({ pid: 456, exited, kill: (signal) => { signals.push(signal!); if (signal === "SIGKILL") exit(137); } }),
      startupTimeoutMs: 1, stopExitTimeoutMs: 5, sleep: async () => {}, appendEvent: () => {}, log: () => {},
    });
    expect(result).toEqual({ status: "timeout" });
    expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
    let probes = 0, spawns = 0;
    await ensureSTTPolishServer({ env: { QA_VOICE_STT_POLISH: "on" }, findBinary: () => "/tmp/mlx_lm.server",
      isProcessAlive: () => true, isEndpointReady: async () => ++probes > 1,
      findPortOwnerPids: () => spawns ? [457] : [], spawn: () => { spawns++; return { pid: 457 }; },
      appendEvent: () => {}, log: () => {}, sleep: async () => {},
    });
    expect(spawns).toBe(1);
    resetSTTPolishServerManagerForTests();
  });

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
          failureKind: "connection-refused",
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

  it("reaps stale local polish port owners on an explicit force restart", async () => {
    resetSTTPolishServerManagerForTests();
    const events: Array<{ type: string; payload: Record<string, unknown> }> = [];
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];
    const spawnCalls: string[][] = [];
    let readinessChecks = 0;

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      findBinary: () => "/tmp/mlx_lm.server",
      isResidentStack: () => true,
      forceRestart: true,
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

  it("does NOT reap the live polish server when running under an isolated harness", async () => {
    // 2026-09-08: corpus-replay-verify isolates sockets, roots and the whisper
    // port, but the polish port is shared — so a harness daemon SIGTERMed Etan's
    // live polish server twice in one afternoon, and the daemon only ensures
    // polish at startup, so it stayed dead and every later dictation shipped
    // unpolished. A harness always overrides the socket path; that is the signal.
    resetSTTPolishServerManagerForTests();
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];
    let readinessChecks = 0;
    try {
      const result = await ensureSTTPolishServer({
        env: { QA_VOICE_STT_POLISH: "on" },
        findBinary: () => "/tmp/mlx_lm.server",
        isResidentStack: () => false,
        forceRestart: true,
        findStalePortOwnerPids: () => [70870],
        killProcess: (pid, signal) => {
          killed.push({ pid, signal });
        },
        isEndpointReady: async () => ++readinessChecks >= 2,
        spawn: () => ({ pid: 456, exited: new Promise(() => {}) }),
        appendEvent: () => {},
        sleep: async () => {},
        startupTimeoutMs: 10_000,
      });
      expect(result).toMatchObject({ status: "ready" });
      expect(killed).toEqual([]);
    } finally {
      resetSTTPolishServerManagerForTests();
    }
  });

  it("keeps a healthy polish owner even on an explicit user restart request", async () => {
    resetSTTPolishServerManagerForTests();
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];
    const spawnCalls: string[][] = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      forceRestart: true,
      findBinary: () => "/tmp/mlx_lm.server",
      isResidentStack: () => true,
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

    expect(result).toMatchObject({ status: "already-ready" });
    expect(killed).toEqual([]);
    expect(spawnCalls).toHaveLength(0);
  });

  it("does not spawn a replacement while a terminated owner still serves the polish port", async () => {
    resetSTTPolishServerManagerForTests();
    let spawns = 0;
    const killed: Array<{ pid: number; signal?: NodeJS.Signals }> = [];

    const result = await ensureSTTPolishServer({
      env: { QA_VOICE_STT_POLISH: "on" },
      forceRestart: true,
      findBinary: () => "/tmp/mlx_lm.server",
      isResidentStack: () => true,
      findStalePortOwnerPids: () => [70870],
      findPortOwnerPids: () => [70870],
      killProcess: (pid, signal) => {
        killed.push({ pid, signal });
      },
      isEndpointReady: async () => false,
      spawn: () => { spawns++; return { pid: 456 }; },
      appendEvent: () => {},
      sleep: async () => {},
      startupTimeoutMs: 1,
    });

    expect(result).toEqual({ status: "starting", pid: 70870 });
    expect(killed).toEqual([{ pid: 70870, signal: "SIGTERM" }]);
    expect(spawns).toBe(0);
    resetSTTPolishServerManagerForTests();
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
      startupTimeoutMs: 1, stopExitTimeoutMs: 1,
    });

    expect(result).toEqual({ status: "timeout" });
    expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
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

  describe("Polish toggled off while its server is starting (#146 round 2)", () => {
    function fakeProc(exitOn: (signal: string) => boolean) {
      const signals: string[] = [];
      let exit!: () => void;
      const exited = new Promise<number>((resolve) => { exit = () => resolve(0); });
      return {
        signals,
        proc: {
          pid: 777,
          exited,
          kill: (signal?: NodeJS.Signals) => {
            signals.push(signal ?? "SIGTERM");
            if (exitOn(signal ?? "SIGTERM")) exit();
          },
        },
      };
    }

    it("cancels a launch after spawn and publishes no stale status", async () => {
      resetSTTPolishServerManagerForTests();
      const { signals, proc } = fakeProc(() => true);
      const statuses: string[] = [];
      const off = onSTTPolishServerStatus((status) => statuses.push(status.status));
      let spawned = false;
      const startedAt = Date.now();
      try {
        const launch = ensureSTTPolishServer({
          env: { QA_VOICE_STT_POLISH: "on" },
          findBinary: () => "/tmp/mlx_lm.server",
          isEndpointReady: async () => false,
          spawn: () => { spawned = true; return proc; },
          appendEvent: () => {},
          sleep: () => Bun.sleep(5),
          startupTimeoutMs: 3_000,
          log: () => {},
        });
        for (let i = 0; i < 100 && !spawned; i++) await Bun.sleep(2);
        await stopSTTPolishServerAndWait();
        await launch;
        expect(signals[0]).toBe("SIGTERM");
        expect(Date.now() - startedAt).toBeLessThan(1_500);
        expect(statuses).not.toContain("timeout");
        expect(statuses).not.toContain("ready");
      } finally {
        off();
        resetSTTPolishServerManagerForTests();
      }
    });

    it("never spawns when Polish goes off during the pre-spawn reap", async () => {
      resetSTTPolishServerManagerForTests();
      let release!: () => void;
      const reapPause = new Promise<void>((resolve) => { release = resolve; });
      let spawned = false;
      try {
        const launch = ensureSTTPolishServer({
          env: { QA_VOICE_STT_POLISH: "on" },
          isResidentStack: () => true,
          findBinary: () => "/tmp/mlx_lm.server",
          forceRestart: true,
          findStalePortOwnerPids: () => [424_242],
          killProcess: () => {},
          isEndpointReady: async () => false,
          spawn: () => { spawned = true; return fakeProc(() => true).proc; },
          appendEvent: () => {},
          sleep: () => reapPause,
          startupTimeoutMs: 1_000,
          log: () => {},
        });
        await Bun.sleep(10);
        await stopSTTPolishServerAndWait();
        release();
        await launch;
        expect(spawned).toBe(false);
      } finally {
        resetSTTPolishServerManagerForTests();
      }
    });

    it("relaunches after a failed start: a settled launch is not reused (#146 round 3)", async () => {
      resetSTTPolishServerManagerForTests();
      let spawns = 0;
      const options = {
        env: { QA_VOICE_STT_POLISH: "on" },
        findBinary: () => "/tmp/mlx_lm.server",
        isEndpointReady: async () => false,
        spawn: () => { spawns++; return fakeProc(() => true).proc; },
        appendEvent: () => {},
        sleep: async () => {},
        startupTimeoutMs: 20,
        log: () => {},
      };
      try {
        expect(await ensureSTTPolishServer(options)).toMatchObject({ status: "timeout" });
        await ensureSTTPolishServer({ ...options, forceRestart: true });
        expect(spawns).toBe(2);
      } finally {
        resetSTTPolishServerManagerForTests();
      }
    });

    it("escalates to SIGKILL when our polish server ignores SIGTERM", async () => {
      resetSTTPolishServerManagerForTests();
      const { signals, proc } = fakeProc((signal) => signal === "SIGKILL");
      let probes = 0;
      try {
        await ensureSTTPolishServer({
          env: { QA_VOICE_STT_POLISH: "on" },
          findBinary: () => "/tmp/mlx_lm.server",
          isEndpointReady: async () => ++probes > 1,
          forceRestart: true,
          spawn: () => proc,
          appendEvent: () => {},
          sleep: async () => {},
          startupTimeoutMs: 1_000,
          log: () => {},
        });
        await stopSTTPolishServerAndWait();
        expect(signals).toEqual(["SIGTERM", "SIGKILL"]);
      } finally {
        resetSTTPolishServerManagerForTests();
      }
    });
  });
});
