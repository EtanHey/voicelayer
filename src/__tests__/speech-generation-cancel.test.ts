import { expect, test } from "bun:test";
import { runSpeechGeneration } from "../tts/generation-process";
test("cancel kills and reaps the owned generator process group", async () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const controller = new AbortController();
  let pid = 0;
  const task = runSpeechGeneration([process.execPath, "-e", "setInterval(() => {}, 1000)"], controller.signal, 5000,
    processId => { pid = processId; controller.abort(new Error("fixture cancellation")); });
  await expect(task).rejects.toThrow("fixture cancellation");
  expect(pid).toBeGreaterThan(0);
  expect(() => process.kill(pid, 0)).toThrow();
  expect(() => process.kill(-pid, 0)).toThrow();
});
