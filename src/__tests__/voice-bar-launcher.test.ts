import { afterEach, expect, spyOn, test } from "bun:test";
import { ensureVoiceBarRunning, resetLaunchState, isVoiceBarRunning } from "../voice-bar-launcher";
afterEach(resetLaunchState);
for (const state of ["running", "absent", "failed"] as const) {
  test(`MCP startup uses the shared launchd starter: ${state}`, () => {
    resetLaunchState();
    const commands: string[][] = [];
    const spawn = spyOn(Bun, "spawnSync").mockImplementation((command, options) => {
      const args = command as string[]; commands.push(args);
      if (args[0] !== "pgrep") expect(options?.env).toBe(process.env);
      return { exitCode: args[0] === "pgrep" ? state === "running" ? 0 : 1 : state === "failed" ? 1 : 0 } as ReturnType<typeof Bun.spawnSync>;
    });
    const log = spyOn(console, "error").mockImplementation(() => {});
    try {
      expect(isVoiceBarRunning()).toBe(state === "running");
      ensureVoiceBarRunning(); ensureVoiceBarRunning();
      const starts = commands.filter(args => args[0] !== "pgrep");
      expect(starts).toHaveLength(state === "running" ? 0 : 1);
      if (starts.length) {
        expect(starts[0]![0]).toBe("/bin/bash");
        expect(starts[0]![1]).toEndWith("/scripts/start-voicebar.sh");
      }
      expect(commands.flat()).not.toContain("open");
      if (state === "failed") expect(log.mock.calls.flat().join(" ")).toContain("launchd startup/ownership verification failed");
    } finally { spawn.mockRestore(); log.mockRestore(); }
  });
}
