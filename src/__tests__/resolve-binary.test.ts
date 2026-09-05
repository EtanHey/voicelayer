/**
 * Tests for binary resolution in daemon/LaunchAgent context.
 */

import { afterEach, describe, it, expect } from "bun:test";
import {
  __resetBinarySpawnForTests,
  __setBinarySpawnForTests,
  initEnrichedPATH,
  resolveBinary,
  type BinarySpawnSync,
} from "../resolve-binary";

describe("initEnrichedPATH", () => {
  it("returns a non-empty string", () => {
    const path = initEnrichedPATH();
    expect(path.length).toBeGreaterThan(0);
  });

  it("includes /usr/bin", () => {
    const path = initEnrichedPATH();
    expect(path).toContain("/usr/bin");
  });

  it("includes fallback Homebrew path", () => {
    const path = initEnrichedPATH();
    expect(path).toContain("/opt/homebrew/bin");
  });

  it("sets process.env.PATH", () => {
    initEnrichedPATH();
    expect(process.env.PATH).toContain("/opt/homebrew/bin");
  });

  it("returns cached result on second call", () => {
    const first = initEnrichedPATH();
    const second = initEnrichedPATH();
    expect(first).toBe(second);
  });
});

describe("resolveBinary", () => {
  it("finds system binaries via which", () => {
    const path = resolveBinary("ls");
    expect(path).not.toBeNull();
    expect(path).toContain("/ls");
  });

  it("returns null for nonexistent binary", () => {
    const path = resolveBinary("definitely_not_a_real_binary_12345");
    expect(path).toBeNull();
  });

  it("finds binary via candidate paths when which would fail", () => {
    // python3 --version works reliably on macOS
    const path = resolveBinary("nonexistent_via_which", ["/usr/bin/python3"]);
    expect(path).toBe("/usr/bin/python3");
  });

  it("finds rec (sox) if installed", () => {
    const path = resolveBinary("rec", [
      "/opt/homebrew/bin/rec",
      "/usr/local/bin/rec",
    ]);
    // May or may not be installed — just verify it doesn't crash
    if (path) {
      expect(path).toContain("rec");
    }
  });
});


describe("resolveBinary is bounded", () => {
  afterEach(() => {
    __resetBinarySpawnForTests();
  });

  /**
   * Stands in for the real `Bun.spawnSync`, and holds it to its contract: a
   * child that is given a finite `timeout` is killed at that timeout, and one
   * that is not runs to completion. A `resolveBinary` that forgets to pass a
   * bound therefore waits the full `childDurationMs` here, exactly as it would
   * against a wedged `which` or `--version` on a real machine.
   */
  function wedgedSpawn(
    childDurationMs: number,
    seen: Array<{ cmd: string[]; timeout: unknown }>,
  ): BinarySpawnSync {
    return (cmd, options) => {
      const timeout = options?.timeout;
      seen.push({ cmd, timeout });
      if (typeof timeout !== "number" || !Number.isFinite(timeout)) {
        Bun.sleepSync(childDurationMs);
        return { exitCode: 1 };
      }
      Bun.sleepSync(Math.min(childDurationMs, timeout));
      return childDurationMs > timeout
        ? { exitCode: null, exitedDueToTimeout: true }
        : { exitCode: 1 };
    };
  }

  it("returns the not-found shape inside its budget when every probe wedges", () => {
    const seen: Array<{ cmd: string[]; timeout: unknown }> = [];
    __setBinarySpawnForTests(wedgedSpawn(60_000, seen));

    const started = Date.now();
    const resolved = resolveBinary("x", [], {
      spawnTimeoutMs: 60,
      budgetMs: 120,
    });
    const elapsed = Date.now() - started;

    // Same "not found" contract callers already handle — never a throw, never
    // a partial path.
    expect(resolved).toBeNull();
    expect(elapsed).toBeLessThan(320);
    // The budget stops the sequence: without it, `which` plus three candidate
    // probes would each have burned the full per-spawn bound.
    expect(seen.length).toBeLessThanOrEqual(3);
  });

  it("passes a finite timeout to every spawn at its shipped defaults", () => {
    const seen: Array<{ cmd: string[]; timeout: unknown }> = [];
    __setBinarySpawnForTests((cmd, options) => {
      seen.push({ cmd, timeout: options?.timeout });
      return { exitCode: 1 };
    });

    expect(resolveBinary("definitely_not_a_real_binary_12345")).toBeNull();
    expect(seen.length).toBeGreaterThan(1);
    for (const call of seen) {
      expect(typeof call.timeout).toBe("number");
      expect(Number.isFinite(call.timeout as number)).toBe(true);
      expect(call.timeout as number).toBeGreaterThan(0);
      expect(call.timeout as number).toBeLessThanOrEqual(1_500);
    }
  });

  it("cannot stall a caller past ~3s at its shipped defaults", () => {
    // The literal hazard: a wedged login shell or binary that never returns.
    const seen: Array<{ cmd: string[]; timeout: unknown }> = [];
    __setBinarySpawnForTests(wedgedSpawn(60_000, seen));

    const started = Date.now();
    const resolved = resolveBinary("x");
    const elapsed = Date.now() - started;

    expect(resolved).toBeNull();
    expect(elapsed).toBeLessThan(3_200);
  });

  it("still resolves a binary that answers promptly", () => {
    __setBinarySpawnForTests((cmd) => {
      if (cmd[0] === "which") return { exitCode: 0, stdout: "/fake/bin/thing\n" };
      return { exitCode: 1 };
    });

    expect(resolveBinary("thing")).toBe("/fake/bin/thing");
  });

  it("still falls through to a candidate path when which fails", () => {
    __setBinarySpawnForTests((cmd) => {
      if (cmd[0] === "which") return { exitCode: 1 };
      return cmd[0] === "/fake/candidate" ? { exitCode: 0 } : { exitCode: 1 };
    });

    expect(resolveBinary("thing", ["/fake/candidate"])).toBe("/fake/candidate");
  });
});
