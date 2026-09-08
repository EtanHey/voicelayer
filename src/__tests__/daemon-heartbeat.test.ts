import { afterEach, describe, expect, it } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "fs";
import { startDaemonHeartbeat } from "../daemon-heartbeat";
import { testTmp } from "./setup/test-tmp";

let stopActivePublisher: (() => void) | undefined;

afterEach(() => {
  stopActivePublisher?.();
  stopActivePublisher = undefined;
});

describe("daemon event-loop heartbeat", () => {
  it("advances its sequence and removes its own heartbeat on stop", async () => {
    const path = testTmp(`daemon-heartbeat-${crypto.randomUUID()}.json`);
    const publisher = startDaemonHeartbeat({
      path,
      pid: 4_321,
      intervalMs: 10,
    });
    stopActivePublisher = publisher.stop;

    const initial = JSON.parse(readFileSync(path, "utf8"));
    await Bun.sleep(35);
    const advanced = JSON.parse(readFileSync(path, "utf8"));

    expect(initial).toMatchObject({ pid: 4_321, sequence: 1 });
    expect(advanced.sequence).toBeGreaterThan(initial.sequence);
    publisher.stop();
    stopActivePublisher = undefined;
    expect(existsSync(path)).toBeFalse();
  });

  it("does not unlink a successor owner's heartbeat", () => {
    const path = testTmp(`daemon-heartbeat-${crypto.randomUUID()}.json`);
    const publisher = startDaemonHeartbeat({
      path,
      pid: 4_321,
      intervalMs: 60_000,
    });
    stopActivePublisher = publisher.stop;
    writeFileSync(
      path,
      `${JSON.stringify({ pid: 9_876, sequence: 1, updated_at: new Date().toISOString() })}\n`,
    );

    publisher.stop();
    stopActivePublisher = undefined;

    expect(existsSync(path)).toBeTrue();
    expect(JSON.parse(readFileSync(path, "utf8")).pid).toBe(9_876);
  });

  it("logs a publish gap above half the watchdog threshold", async () => {
    const path = testTmp(`daemon-heartbeat-${crypto.randomUUID()}.json`);
    let nowMs = 0;
    const logs: string[] = [];
    const publisher = startDaemonHeartbeat({
      path,
      pid: 4_321,
      intervalMs: 10,
      gapLogThresholdMs: 15_000,
      now: () => new Date(nowMs),
      log: (message) => logs.push(message),
    });
    stopActivePublisher = publisher.stop;

    nowMs = 16_000;
    await Bun.sleep(15);

    expect(logs).toEqual([
      "[voicelayer-daemon] Heartbeat publish gap sequence 1 -> 2: 16.000s",
    ]);
  });
});
