import { expect, test, spyOn } from "bun:test";
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

test("failed generator reports its bounded stderr tail", async () => {
  const log = spyOn(console, "error").mockImplementation(() => {});
  try {
    expect(await runSpeechGeneration([process.execPath, "-e", 'process.stderr.write("fixture xtts failure"); process.exit(7)'])).toBe(7);
    expect(log.mock.calls.flat().join(" ")).toContain("fixture xtts failure");
  } finally { log.mockRestore(); }
});
