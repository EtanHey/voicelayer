import { afterEach, describe, expect, it, mock } from "bun:test";
import { TEST_TMP } from "./setup/test-tmp";
import { checkEdgeTTSHealth, resetHealthCache, synthesizeWithRetry } from "../tts-health";

const originalSpawnSync = Bun.spawnSync;
const originalConsoleError = console.error;

afterEach(() => {
  Bun.spawnSync = originalSpawnSync;
  console.error = originalConsoleError;
  mock.restore();
  resetHealthCache();
});

describe("edge-tts version health", () => {
  for (const [version, warning] of [["7.2.7", true], ["7.3.1", false], ["7.4.0", false], ["7.3.1.post1", false], ["7.4", false], ["8.0.0rc1", false], ["7.3.1rc1", true], ["7.3", true], ["", true]] as const) {
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

  it("probes the version once across exhausted requests and health cache expiry", async () => {
    const originalSpawn = Bun.spawn;
    const originalNow = Date.now;
    let now = 100_000;
    let versions = 0;
    let imports = 0;
    try {
      Date.now = () => now;
      Bun.spawnSync = ((cmd: string[]) => {
        if (cmd[2].includes("metadata")) versions++;
        else imports++;
        return { exitCode: 0, stdout: Buffer.from(cmd[2].includes("metadata") ? "7.2.7" : "ok"), stderr: Buffer.from("") };
      }) as typeof Bun.spawnSync;
      Bun.spawn = (() => ({ exited: Promise.resolve(2), kill: () => {} })) as typeof Bun.spawn;
      console.error = () => {};
      resetHealthCache();
      for (let i = 0; i < 3; i++) {
        expect((await synthesizeWithRetry("test", "voice", "+0%", `${TEST_TMP}/edge-floor-test.mp3`, "script", 0)).success).toBe(false);
      }
      now += 60_000;
      expect(checkEdgeTTSHealth()).toBe(true);
      expect(imports).toBe(4);
      expect(versions).toBe(1);
    } finally {
      Bun.spawn = originalSpawn;
      Date.now = originalNow;
    }
  });

  it("keeps missing-package behavior", () => {
    Bun.spawnSync = (() => ({ exitCode: 1, stdout: Buffer.from(""), stderr: Buffer.from("missing") })) as typeof Bun.spawnSync;
    const logs = mock(() => {});
    console.error = logs;
    resetHealthCache();
    expect(checkEdgeTTSHealth()).toBe(false);
    expect(logs).not.toHaveBeenCalled();
  });
});
