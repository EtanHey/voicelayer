import { describe, expect, test } from "bun:test";
import {
  readProcessParentPid,
  resolveInitialParentPid,
  startParentProcessWatchdog,
} from "../daemon-parent-watchdog";

describe("daemon parent watchdog", () => {
  test("does not start when daemon begins without a VoiceBar parent", () => {
    let scheduled = false;

    const watchdog = startParentProcessWatchdog({
      initialParentPid: 1,
      getParentPid: () => 1,
      onParentLost: () => {
        throw new Error("should not fire for parentless startup");
      },
      setIntervalFn: () => {
        scheduled = true;
        return "timer";
      },
      clearIntervalFn: () => {},
    });

    expect(scheduled).toBe(false);
    watchdog.stop();
  });

  test("fires once and stops when daemon loses its original parent", () => {
    let currentParentPid = 4242;
    let tick: (() => void) | undefined;
    const clearedTimers: unknown[] = [];
    const parentLosses: Array<{
      initialParentPid: number;
      currentParentPid: number;
    }> = [];

    const watchdog = startParentProcessWatchdog({
      initialParentPid: 4242,
      getParentPid: () => currentParentPid,
      intervalMs: 25,
      onParentLost: (details) => parentLosses.push(details),
      setIntervalFn: (callback, intervalMs) => {
        expect(intervalMs).toBe(25);
        tick = callback;
        return "timer";
      },
      clearIntervalFn: (timer) => clearedTimers.push(timer),
    });

    currentParentPid = 1;
    tick?.();
    tick?.();
    watchdog.stop();

    expect(parentLosses).toEqual([
      { initialParentPid: 4242, currentParentPid: 1 },
    ]);
    expect(clearedTimers).toEqual(["timer"]);
  });

  test("resolves expected parent PID from VoiceBar launch environment", () => {
    expect(
      resolveInitialParentPid({ VOICEBAR_PARENT_PID: "5678" }, 1234),
    ).toBe(5678);
    expect(
      resolveInitialParentPid({ VOICEBAR_PARENT_PID: "not-a-pid" }, 1234),
    ).toBe(1234);
  });

  test("reads live parent PID from ps output instead of cached process.ppid", () => {
    const parentPid = readProcessParentPid(9999, (command) => {
      expect(command).toEqual(["ps", "-p", "9999", "-o", "ppid="]);
      return {
        exitCode: 0,
        stdout: Buffer.from("  1234\n"),
      };
    });

    expect(parentPid).toBe(1234);
  });

  test("falls back when live parent PID cannot be read", () => {
    const parentPid = readProcessParentPid(9999, () => ({
      exitCode: 1,
      stdout: Buffer.from(""),
    }), 5678);

    expect(parentPid).toBe(5678);
  });
});
