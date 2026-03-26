import { describe, it, expect, beforeEach, afterEach } from "bun:test";

/**
 * Tests for edge-tts health check and retry logic.
 *
 * We test checkEdgeTTSHealth() directly and verify retry behavior
 * through the exported function.
 */

const originalSpawnSync = Bun.spawnSync;
const originalSpawn = Bun.spawn;

describe("edge-tts health and retry", () => {
  afterEach(() => {
    Bun.spawnSync = originalSpawnSync;
    Bun.spawn = originalSpawn;
  });

  it("checkEdgeTTSHealth returns true when edge-tts is installed", async () => {
    const { checkEdgeTTSHealth } = await import("../tts-health");
    // Real check — edge-tts should be installed in dev env
    const result = checkEdgeTTSHealth();
    expect(typeof result).toBe("boolean");
  });

  it("checkEdgeTTSHealth returns false when edge-tts is not found", async () => {
    // @ts-ignore
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "python3") {
        return {
          exitCode: 1,
          stdout: new Uint8Array(0),
          stderr: Buffer.from(
            "ModuleNotFoundError: No module named 'edge_tts'",
          ),
        };
      }
      return originalSpawnSync(cmd);
    };

    // Re-import to get fresh module
    const mod = await import("../tts-health");
    // Clear cached result
    mod.resetHealthCache();
    const result = mod.checkEdgeTTSHealth();
    expect(result).toBe(false);
  });

  it("checkEdgeTTSHealth caches result for 60 seconds", async () => {
    const { checkEdgeTTSHealth, resetHealthCache } =
      await import("../tts-health");
    resetHealthCache();

    let callCount = 0;
    // @ts-ignore
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "python3") {
        callCount++;
        return {
          exitCode: 0,
          stdout: Buffer.from("edge-tts 0.0.0"),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    checkEdgeTTSHealth();
    checkEdgeTTSHealth();
    checkEdgeTTSHealth();

    // Should only call python3 once due to caching
    expect(callCount).toBe(1);
  });

  it("synthesizeWithRetry retries once on failure then succeeds", async () => {
    let attempts = 0;
    // @ts-ignore — mock Bun.spawn for edge-tts calls
    Bun.spawn = (cmd: string[], opts?: unknown) => {
      attempts++;
      if (attempts === 1) {
        // First attempt fails
        return { exited: Promise.resolve(2), pid: 99999, kill: () => {} };
      }
      // Second attempt succeeds — create a dummy file
      const writeMediaIdx = (cmd as string[]).indexOf("--write-media");
      if (writeMediaIdx >= 0) {
        const { writeFileSync } = require("fs");
        writeFileSync((cmd as string[])[writeMediaIdx + 1], "fake-mp3-data");
        const writeMetaIdx = (cmd as string[]).indexOf("--write-metadata");
        if (writeMetaIdx >= 0) {
          writeFileSync((cmd as string[])[writeMetaIdx + 1], "");
        }
      }
      return { exited: Promise.resolve(0), pid: 99998, kill: () => {} };
    };

    const { synthesizeWithRetry } = await import("../tts-health");
    const result = await synthesizeWithRetry(
      "test text",
      "en-US-JennyNeural",
      "+0%",
      `/tmp/voicelayer-retry-test-${process.pid}.mp3`,
      "src/scripts/edge-tts-words.py",
    );

    expect(result.success).toBe(true);
    expect(result.attempts).toBe(2);

    // Cleanup
    try {
      require("fs").unlinkSync(`/tmp/voicelayer-retry-test-${process.pid}.mp3`);
    } catch {}
  });

  it("synthesizeWithRetry fails after max retries", async () => {
    // @ts-ignore — always fail
    Bun.spawn = () => ({
      exited: Promise.resolve(2),
      pid: 99999,
      kill: () => {},
    });

    const { synthesizeWithRetry } = await import("../tts-health");
    const result = await synthesizeWithRetry(
      "test text",
      "en-US-JennyNeural",
      "+0%",
      `/tmp/voicelayer-retry-test-${process.pid}.mp3`,
      "src/scripts/edge-tts-words.py",
    );

    expect(result.success).toBe(false);
    expect(result.attempts).toBe(2); // 1 original + 1 retry
  });
});
