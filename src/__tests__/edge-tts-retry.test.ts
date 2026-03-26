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
    // @ts-ignore
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "python3") {
        return {
          exitCode: 0,
          stdout: Buffer.from("ok"),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    const { checkEdgeTTSHealth, resetHealthCache } =
      await import("../tts-health");
    resetHealthCache();
    const result = checkEdgeTTSHealth();
    expect(result).toBe(true);
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

  it("resolvePython3Path finds python3 via which", async () => {
    const { resolvePython3Path, getPython3Path } =
      await import("../tts-health");
    const path = resolvePython3Path();
    // On this machine python3 exists
    expect(path).toContain("python3");
    expect(path.startsWith("/")).toBe(true);
    // getPython3Path should return the cached value
    expect(getPython3Path()).toBe(path);
  });

  it("resolvePython3Path falls back to known paths when which fails", async () => {
    const originalSpawnSyncLocal = Bun.spawnSync;
    // @ts-ignore
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd[0] === "which") {
        return {
          exitCode: 1,
          stdout: Buffer.from(""),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSyncLocal(cmd);
    };

    const { resolvePython3Path } = await import("../tts-health");
    const path = resolvePython3Path();
    // Should still find python3 via fallback candidates
    expect(path).toContain("python3");

    Bun.spawnSync = originalSpawnSyncLocal;
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

  it("synthesizeWithRetry fails after max retries with error context", async () => {
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
    // Error should include the actual exit code, not a misleading message
    expect(result.error).toContain("exit code 2");
  });

  it("synthesizeWithRetry preserves spawn errors in failure message", async () => {
    // @ts-ignore — throw on spawn
    Bun.spawn = () => {
      throw new Error("python3 not found");
    };

    const { synthesizeWithRetry } = await import("../tts-health");
    const result = await synthesizeWithRetry(
      "test text",
      "en-US-JennyNeural",
      "+0%",
      `/tmp/voicelayer-retry-test-${process.pid}.mp3`,
      "src/scripts/edge-tts-words.py",
    );

    expect(result.success).toBe(false);
    expect(result.error).toContain("python3 not found");
  });
});
