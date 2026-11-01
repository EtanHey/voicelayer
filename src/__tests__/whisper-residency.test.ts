import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { writeFileSync, unlinkSync } from "fs";
import { LOCK_FILE } from "../paths";
import { handleSocketCommand } from "../socket-handlers";
import * as input from "../input";
import {
  __resetWhisperServerStateForTests,
  __setWhisperServerLaunchRecordForTests,
  __setWhisperServerTestHooksForTests,
  unloadOwnedServer,
  ensureServer,
} from "../whisper-server";

describe("explicit whisper-server unload", () => {
  afterEach(() => {
    __resetWhisperServerStateForTests(null);
    __setWhisperServerTestHooksForTests({});
  });

  test("never signals an adopted server", async () => {
    let killed = false;
    __resetWhisperServerStateForTests({
      proc: null, port: 18880, pid: 55100, adopted: true,
    });
    __setWhisperServerTestHooksForTests({
      reserveVoiceMaintenance: () => () => {},
      isServerHealthy: async () => true,
      findPortListenerPids: () => [55100],
      killExternalPid: () => { killed = true; },
    });
    expect(await unloadOwnedServer(() => false)).toEqual({
      outcome: "reject", reason: "not owned",
    });
    expect(killed).toBe(false);
  });

  test("rejects a recycled PID before signalling the child", async () => {
    let killed = false;
    __resetWhisperServerStateForTests({
      proc: { pid: 55101, kill: () => { killed = true; }, exited: Promise.resolve(0) } as never,
      port: 18881, pid: 55101, adopted: false,
    });
    __setWhisperServerLaunchRecordForTests({
      pid: 55101, startedAt: "2026-09-23T00:00:00.000Z",
      binary: "/tmp/whisper-server", modelPath: "/tmp/model.bin", args: [],
      performanceEffort: "accurate", accelerationMode: "metal",
    });
    __setWhisperServerTestHooksForTests({
      reserveVoiceMaintenance: () => () => {},
      isPidAlive: () => true,
      findPortListenerPids: () => [55101],
      processStartTimeMs: () => Date.parse("2026-09-23T00:01:00.000Z"),
    });
    expect(await unloadOwnedServer(() => false)).toEqual({
      outcome: "reject", reason: "owner identity unavailable",
    });
    expect(killed).toBe(false);
  });

  test("owned stop waits for exit and fresh negative health", async () => {
    let killed = false;
    let exit!: (code: number) => void;
    let healthy = true;
    let listeners = [55102];
    const exited = new Promise<number>((resolve) => { exit = resolve; });
    __resetWhisperServerStateForTests({
      proc: { pid: 55102, kill: () => { killed = true; }, exited } as never,
      port: 18882, pid: 55102, adopted: false,
    });
    __setWhisperServerLaunchRecordForTests({
      pid: 55102, startedAt: "2026-09-23T00:00:00.000Z",
      binary: "/tmp/whisper-server", modelPath: "/tmp/model.bin", args: [],
      performanceEffort: "accurate", accelerationMode: "metal",
    });
    __setWhisperServerTestHooksForTests({
      reserveVoiceMaintenance: () => () => {},
      isPidAlive: () => true,
      findPortListenerPids: () => listeners,
      processStartTimeMs: () => Date.parse("2026-09-22T23:59:59.000Z"),
      isServerHealthy: async () => healthy,
      postUnloadListeners: () => listeners,
    });
    const pending = unloadOwnedServer(() => false);
    expect(killed).toBe(true);
    let finished = false;
    void pending.then(() => { finished = true; });
    await Promise.resolve();
    expect(finished).toBe(false);
    healthy = false;
    listeners = [];
    exit(0);
    expect(await pending).toEqual({ outcome: "accept", residency: "not_loaded" });
  });

  test("an unconfirmed unload blocks replacement until a late child exit, then reloads once", async () => {
    let exit!: (code: number) => void;
    const exited = new Promise<number>((resolve) => { exit = resolve; });
    let spawns = 0;
    let alive = false, bornAt = 0;
    const signals: string[] = [];
    __setWhisperServerTestHooksForTests({
      reserveVoiceMaintenance: () => () => {},
      residentLiveStack: () => false,
      findServerBinary: () => "/tmp/whisper-server",
      findModel: () => "/tmp/model.bin",
      readHelpText: () => ({ helpText: "" }),
      isPidAlive: () => alive,
      processStartTimeMs: () => bornAt,
      isServerHealthy: async () => alive,
      findPortListenerPids: () => alive ? [55110 + spawns] : [],
      findExternalWhisperServerPids: () => [],
      spawn: () => {
        spawns++;
        alive = true;
        bornAt = Date.now() - 1_000;
        return {
          pid: 55110 + spawns, stderr: null, exitCode: null,
          exited: spawns === 1 ? exited : new Promise<number>(() => {}),
          kill: (signal?: number | NodeJS.Signals) => { signals.push(String(signal)); },
        };
      },
    });
    expect(await ensureServer(18884)).toBe(18884);
    expect(await unloadOwnedServer(() => false)).toEqual({ outcome: "reject", reason: "child exit unconfirmed" });
    expect(signals).toEqual(["SIGTERM"]);
    await expect(ensureServer(18884)).rejects.toThrow("unload unconfirmed");
    expect(spawns).toBe(1);
    alive = false;
    exit(0);
    await exited;
    expect(await ensureServer(18884)).toBe(18884);
    expect(await ensureServer(18884)).toBe(18884);
    expect(spawns).toBe(2);
  });

  test("F5 capture starts while a signalled unload yields its result", async () => {
    let exit!: (code: number) => void;
    let listeners = [55103];
    const exited = new Promise<number>((resolve) => { exit = resolve; });
    __resetWhisperServerStateForTests({
      proc: { pid: 55103, kill: () => {}, exited } as never,
      port: 18883, pid: 55103, adopted: false,
    });
    __setWhisperServerLaunchRecordForTests({
      pid: 55103, startedAt: "2026-09-23T00:00:00.000Z",
      binary: "/tmp/whisper-server", modelPath: "/tmp/model.bin", args: [],
      performanceEffort: "accurate", accelerationMode: "metal",
    });
    __setWhisperServerTestHooksForTests({
      reserveVoiceMaintenance: () => () => {},
      isPidAlive: () => true,
      findPortListenerPids: () => listeners,
      processStartTimeMs: () => Date.parse("2026-09-22T23:59:59.000Z"),
      isServerHealthy: async () => false,
      postUnloadListeners: () => listeners,
    });
    const recording = spyOn(input, "getRecordingState").mockReturnValue("idle");
    const capture = spyOn(input, "waitForInput").mockResolvedValue(null);
    try {
      const unload = unloadOwnedServer(() => false);
      expect(handleSocketCommand({ cmd: "record", id: "f5-unload-race" }))
        .toMatchObject({ outcome: "accept" });
      expect(capture).toHaveBeenCalledTimes(1);
      listeners = [];
      exit(0);
      expect(await unload).toEqual({ outcome: "reject", reason: "capture took priority" });
    } finally {
      recording.mockRestore();
      capture.mockRestore();
    }
  });

  test("a late external booking names the competing session at unload reservation", async () => {
    writeFileSync(LOCK_FILE, JSON.stringify({
      pid: 1, sessionId: "other-process", startedAt: new Date().toISOString(),
    }));
    try {
      expect(await unloadOwnedServer(() => false)).toEqual({
        outcome: "reject", reason: "Another app is using the voice session",
      });
    } finally { unlinkSync(LOCK_FILE); }
  });
});
