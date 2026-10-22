import { expect, test } from "bun:test";
import { systemDeadlineClock } from "../deadline-clock";

test("system deadline clock fires scheduled callbacks", async () => {
  let fired = false;
  const before = systemDeadlineClock.now();
  const cancel = systemDeadlineClock.schedule(() => { fired = true; }, 10);
  try {
    // Independent watchdog makes a missing production timer an assertion failure.
    const watchdog = performance.now() + 1000;
    while (!fired && performance.now() < watchdog) await Bun.sleep(10);
    expect(fired).toBe(true);
    expect(systemDeadlineClock.now()).toBeGreaterThanOrEqual(before);
  } finally {
    cancel();
  }
});

test("system deadline clock cancellation prevents the callback", async () => {
  let fired = false;
  const cancel = systemDeadlineClock.schedule(() => { fired = true; }, 10);
  cancel();
  await Bun.sleep(30);
  expect(fired).toBe(false);
});
