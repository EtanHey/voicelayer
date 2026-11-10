import { expect, it } from "bun:test";
import { TakeStageTimings, measureTakeStage, measureTakeStageAsync, withTakeStageTimings } from "../take-stage-timings";

it("splits nested gates out of decode and accumulates chunks without double counting", async () => {
  let now = 100;
  const take = new TakeStageTimings(() => now);
  await withTakeStageTimings(take, async () => {
    take.captureEnded();
    now += 5;
    measureTakeStage("gates", () => { now += 2; });
    await measureTakeStageAsync("decode", async () => {
      now += 10;
      await measureTakeStageAsync("gates", async () => { now += 4; });
      now += 10;
    });
    await measureTakeStageAsync("decode", async () => { now += 3; });
    measureTakeStage("dictionary_rules", () => { now += 1; });
    await measureTakeStageAsync("polish", async () => { now += 8; });
    await measureTakeStageAsync("delivery", async () => { now += 2; });
  });
  expect(take.snapshot()).toEqual({ capture_end_to_decode: 5, decode: 23,
    dictionary_rules: 1, polish: 8, gates: 6, delivery: 2, total: 45 });
});

it("retains elapsed time when an asynchronous stage throws", async () => {
  let now = 0;
  const take = new TakeStageTimings(() => now);
  take.captureEnded();
  await expect(withTakeStageTimings(take, () => measureTakeStageAsync("decode", async () => {
    now = 25;
    throw new Error("fake failure");
  }))).rejects.toThrow("fake failure");
  expect(take.snapshot().decode).toBe(25);
});
