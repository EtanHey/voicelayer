import { expect, test } from "bun:test";
import { darwinProcessStartMs } from "../../scripts/t3-optf5-proof";

test.skipIf(process.platform !== "darwin")("kernel start timestamp retains microseconds and rejects missing processes", () => {
  const started = darwinProcessStartMs(process.pid);
  expect(started).toBeGreaterThan(0);
  expect(started).toBeLessThanOrEqual(Date.now());
  expect(() => darwinProcessStartMs(2_000_000_000)).toThrow();
});

import { processStartMs } from "../../scripts/t3-optf5-proof";

test.skipIf(process.platform !== "darwin")("fresh child start follows install within the same second (200 loops)", async () => {
  for (let i = 0; i < 200; i++) {
    const installed = Date.now();
    const child = Bun.spawn([process.execPath, "-e", "setInterval(()=>{},1000)"], {
      env: process.env, stdout: "ignore", stderr: "ignore",
    });
    try {
      const started = processStartMs(child.pid);
      expect(started).toBeGreaterThanOrEqual(installed);
      // The already-running parent predates this install and remains stale.
      expect(processStartMs(process.pid)).toBeLessThan(installed);
    } finally {
      child.kill();
      await child.exited;
    }
  }
}, 30_000);
