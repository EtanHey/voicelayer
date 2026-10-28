import { afterEach, describe, expect, it, mock } from "bun:test";
import { checkEdgeTTSHealth, resetHealthCache } from "../tts-health";

const originalSpawnSync = Bun.spawnSync;
const originalConsoleError = console.error;

afterEach(() => {
  Bun.spawnSync = originalSpawnSync;
  console.error = originalConsoleError;
  mock.restore();
  resetHealthCache();
});

describe("edge-tts version health", () => {
  for (const [version, warning] of [["7.2.7", true], ["7.3.1", false], ["7.4.0", false], ["", true]] as const) {
    it(`reports ${version || "unknown"} without failing health`, () => {
      Bun.spawnSync = ((cmd: string[]) => ({
        exitCode: 0,
        stdout: Buffer.from(cmd[2] === "import edge_tts; print('ok')" ? "ok" : version),
        stderr: Buffer.from(""),
      })) as typeof Bun.spawnSync;
      const logs = mock(() => {});
      console.error = logs;
      resetHealthCache();
      expect(checkEdgeTTSHealth()).toBe(true);
      const output = logs.mock.calls.map((args) => args.join(" ")).join("\n");
      if (warning) {
        expect(output).toContain(version || "unknown");
        expect(output).toContain("edge-tts>=7.3.1");
      } else {
        expect(output).toBe("");
      }
    });
  }

  it("keeps missing-package behavior", () => {
    Bun.spawnSync = (() => ({ exitCode: 1, stdout: Buffer.from(""), stderr: Buffer.from("missing") })) as typeof Bun.spawnSync;
    const logs = mock(() => {});
    console.error = logs;
    resetHealthCache();
    expect(checkEdgeTTSHealth()).toBe(false);
    expect(logs).not.toHaveBeenCalled();
  });
});
