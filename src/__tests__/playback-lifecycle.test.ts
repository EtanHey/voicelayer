import { expect, it } from "bun:test";
import { PlaybackLifecycle } from "../tts/playback-lifecycle";

it("PLAYER0 quiesced attempt can exit while its logical utterance remains retained", async () => {
  const life = new PlaybackLifecycle();
  life.track(Promise.resolve(0));
  let terminal = false; void life.playerExited.then(() => { terminal = true; });
  await life.waitForPlayerExit();
  expect(terminal).toBe(false);
  expect(life.hasWork).toBe(false);
  life.complete(); await life.playerExited;
  expect(terminal).toBe(true);
});

it("PLAYER0 rejected child exit never becomes confirmed physical cleanup", async () => {
  const life = new PlaybackLifecycle();
  life.track(Promise.reject(undefined)); life.complete();
  expect(await life.playerExited.then(() => "silent", () => "unknown")).toBe("unknown");
  expect(await life.waitForPlayerExit().then(() => "silent", () => "unknown")).toBe("unknown");
});
