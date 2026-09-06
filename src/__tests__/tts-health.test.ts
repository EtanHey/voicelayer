import { describe, it, expect, afterEach } from "bun:test";
import { TEST_TMP } from "./setup/test-tmp";

/**
 * Regression tests for the edge-tts argparse exit-2 bug and its misleading
 * "Is edge-tts installed?" diagnosis.
 *
 * Root cause: scripts/edge-tts-words.py uses Python argparse. A two-token
 * `--text` `-hello` (or `--voice` `-x`, or a lone `--word`) makes argparse treat
 * the dash-leading value as a stray option and abort with exit code 2
 * ("expected one argument"). The failure is deterministic, so both the original
 * attempt and the retry hit it, and it surfaced as
 * "edge-tts failed after 2 attempts (exit code 2). Is edge-tts installed?" —
 * even though edge-tts was installed and working. Fix: pass caller-controlled
 * values in `--flag=value` form (buildEdgeTTSArgs) and make the exhausted-retries
 * message accurate rather than always blaming a missing install.
 */

const originalSpawnSync = Bun.spawnSync;
const originalSpawn = Bun.spawn;

describe("edge-tts argparse exit-2 regression", () => {
  afterEach(() => {
    Bun.spawnSync = originalSpawnSync;
    Bun.spawn = originalSpawn;
  });

  it("checkEdgeTTSHealth(forceFresh) bypasses a stale cache", async () => {
    const { checkEdgeTTSHealth, resetHealthCache } =
      await import("../tts-health");
    resetHealthCache();

    let importable = true;
    // @ts-ignore — health probe reflects the mutable `importable`
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd.includes("import edge_tts; print('ok')")) {
        return {
          exitCode: importable ? 0 : 1,
          stdout: Buffer.from(importable ? "ok" : ""),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    // Prime the cache as "importable".
    expect(checkEdgeTTSHealth()).toBe(true);
    // edge-tts is uninstalled underneath us; the cache would still say true.
    importable = false;
    expect(checkEdgeTTSHealth()).toBe(true); // stale cached value
    // forceFresh re-probes and sees the real state — the diagnosis path uses this.
    expect(checkEdgeTTSHealth(true)).toBe(false);
  });

  it("buildEdgeTTSArgs passes --text and --voice in =-bound form", async () => {
    const { buildEdgeTTSArgs } = await import("../tts-health");
    const args = buildEdgeTTSArgs(
      "/usr/bin/python3",
      "/path/edge-tts-words.py",
      "-hello there", // dash-leading text that broke the two-token form
      "en-US-JennyNeural",
      "-25%",
      `${TEST_TMP}/out.mp3`,
      `${TEST_TMP}/out.meta.ndjson`,
    );

    expect(args).toContain("--text=-hello there");
    expect(args).toContain("--voice=en-US-JennyNeural");
    expect(args).toContain("--rate=-25%");

    // Crucially: there must be NO bare `--text`/`--voice` token whose value
    // sits in a separate argv slot — the exact two-token shape argparse chokes on.
    expect(args).not.toContain("--text");
    expect(args).not.toContain("--voice");
  });

  it("does not blame a missing install when edge-tts is importable", async () => {
    // @ts-ignore — synthesis always fails with exit code 2
    Bun.spawn = () => ({
      exited: Promise.resolve(2),
      pid: 99999,
      kill: () => {},
    });
    // @ts-ignore — health check reports edge-tts IS importable
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd.includes("import edge_tts; print('ok')")) {
        return {
          exitCode: 0,
          stdout: Buffer.from("ok"),
          stderr: new Uint8Array(0),
        };
      }
      return originalSpawnSync(cmd);
    };

    const { synthesizeWithRetry, resetHealthCache } =
      await import("../tts-health");
    resetHealthCache();
    const result = await synthesizeWithRetry(
      "test text",
      "en-US-JennyNeural",
      "+0%",
      `${TEST_TMP}/voicelayer-health-test-${process.pid}.mp3`,
      "src/scripts/edge-tts-words.py",
    );

    expect(result.success).toBe(false);
    // Must NOT parrot the old misleading "Is edge-tts installed?" line when it IS.
    expect(result.error).not.toContain("Is edge-tts installed?");
    // Must still surface the real failure cause for diagnosis.
    expect(result.error).toContain("exit code 2");
    // Must correctly attribute this to a runtime/network error, not a bad install.
    expect(result.error?.toLowerCase()).toContain("runtime/network");
  });

  it("points at install only when edge-tts is NOT importable", async () => {
    // @ts-ignore — synthesis always fails
    Bun.spawn = () => ({
      exited: Promise.resolve(2),
      pid: 99999,
      kill: () => {},
    });
    // @ts-ignore — health check reports edge-tts is NOT importable
    Bun.spawnSync = (cmd: string[]) => {
      if (Array.isArray(cmd) && cmd.includes("import edge_tts; print('ok')")) {
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

    const { synthesizeWithRetry, resetHealthCache } =
      await import("../tts-health");
    resetHealthCache();
    const result = await synthesizeWithRetry(
      "test text",
      "en-US-JennyNeural",
      "+0%",
      `${TEST_TMP}/voicelayer-health-test-${process.pid}.mp3`,
      "src/scripts/edge-tts-words.py",
    );

    expect(result.success).toBe(false);
    expect(result.error?.toLowerCase()).toContain("not importable");
    expect(result.error).toContain("pip install edge-tts");
  });
});
