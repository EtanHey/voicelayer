import * as os from "node:os";
/**
 * Tests for binary resolution in daemon/LaunchAgent context.
 */

import { afterEach, beforeEach, describe, it, expect, spyOn } from "bun:test";
import {
  __resetBinarySpawnForTests,
  __setBinarySpawnForTests,
  initEnrichedPATH,
  resolveBinary,
  resolveBinaryAsync,
  type BinarySpawnSync,
} from "../resolve-binary";

// Real subprocesses: standalone p95 <= 123 ms; 4x rounded up, with a 5 s scheduling floor.
const SUBPROCESS_TEST_TIMEOUT_MS = 5_000;

beforeEach(() => __resetBinarySpawnForTests());

describe("initEnrichedPATH", () => {
  it("returns a non-empty string", () => {
    const path = initEnrichedPATH();
    expect(path.length).toBeGreaterThan(0);
  }, SUBPROCESS_TEST_TIMEOUT_MS);

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
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  it("returns null for nonexistent binary", () => {
    const path = resolveBinary("definitely_not_a_real_binary_12345");
    expect(path).toBeNull();
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  it("finds binary via candidate paths when which would fail", () => {
    // python3 --version works reliably on macOS
    const path = resolveBinary("nonexistent_via_which", ["/usr/bin/python3"]);
    expect(path).toBe("/usr/bin/python3");
  }, SUBPROCESS_TEST_TIMEOUT_MS);

  it("finds rec (sox) if installed", () => {
    const path = resolveBinary("rec", [
      "/opt/homebrew/bin/rec",
      "/usr/local/bin/rec",
    ]);
    // May or may not be installed — just verify it doesn't crash
    if (path) {
      expect(path).toContain("rec");
    }
  }, SUBPROCESS_TEST_TIMEOUT_MS);
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


describe("ffmpeg executable validation", () => {
  afterEach(() => __resetBinarySpawnForTests());
  it("skips an EBADARCH PATH candidate in the sync resolver", () => {
    __setBinarySpawnForTests(cmd => {
      if (cmd[0] === "which") return {exitCode: 0, stdout: "/stale/ffmpeg\n"};
      if (cmd[0] === "/stale/ffmpeg") throw Object.assign(new Error("Bad CPU type"), {code: "EBADARCH"});
      return {exitCode: cmd[0] === "/working/ffmpeg" && cmd[1] === "-version" ? 0 : 1};
    });
    expect(resolveBinary("ffmpeg", ["/working/ffmpeg"])).toBe("/working/ffmpeg");
  });
  it("skips an EBADARCH PATH candidate in the async resolver", async () => {
    const original = Bun.spawn;
    Bun.spawn = ((cmd: string[]) => {
      if (cmd[0] === "/stale/ffmpeg") throw Object.assign(new Error("Bad CPU type"), {code: "EBADARCH"});
      return {stdout: new Blob([cmd[0] === "which" ? "/stale/ffmpeg\n" : ""]).stream(),
        exited: Promise.resolve(cmd[0] === "which" || (cmd[0] === "/working/ffmpeg" && cmd[1] === "-version") ? 0 : 1), kill() {}};
    }) as any;
    try { expect(await resolveBinaryAsync("ffmpeg", ["/working/ffmpeg"])).toBe("/working/ffmpeg"); }
    finally { Bun.spawn = original; }
  });
});


describe("media resolver review regressions", () => {
  afterEach(() => __resetBinarySpawnForTests());
  it("validates ffprobe and skips its EBADARCH PATH twin", () => {
    const calls: string[][] = [];
    __setBinarySpawnForTests(cmd => {
      calls.push(cmd);
      if (cmd[0] === "which") return {exitCode: 0, stdout: "/stale/ffprobe"};
      if (cmd[0] === "/stale/ffprobe") throw Object.assign(new Error("Bad CPU type"), {code:"EBADARCH"});
      return {exitCode: cmd[0] === "/working/ffprobe" && cmd[1] === "-version" ? 0 : 1};
    });
    expect(resolveBinary("ffprobe", ["/working/ffprobe"])).toBe("/working/ffprobe");
    expect(calls).toContainEqual(["/working/ffprobe", "-version"]);
  });
  it("memoizes successful paths across sync and async calls without another spawn", async () => {
    const calls: string[][] = [];
    __setBinarySpawnForTests(cmd => {calls.push(cmd); return {exitCode:0, stdout:"/working/tool"};});
    expect(resolveBinary("fixture-cache")).toBe("/working/tool");
    const count = calls.length;
    expect(resolveBinary("fixture-cache")).toBe("/working/tool");
    expect(await resolveBinaryAsync("fixture-cache")).toBe("/working/tool");
    expect(calls).toHaveLength(count);
    __resetBinarySpawnForTests();
    __setBinarySpawnForTests(cmd => {calls.push(cmd); return {exitCode:0, stdout:"/working/tool"};});
    expect(resolveBinary("fixture-cache")).toBe("/working/tool");
    expect(calls.length).toBeGreaterThan(count);
  });
});


it("prefers native Homebrew media binaries on arm64 before PATH", async () => {
  const platform = spyOn(os, "platform").mockReturnValue("darwin");
  const arch = spyOn(os, "arch").mockReturnValue("arm64");
  const calls: string[][] = [];
  __setBinarySpawnForTests(cmd => {calls.push(cmd); return {exitCode:0};});
  try {
    expect(resolveBinary("ffprobe")).toBe("/opt/homebrew/bin/ffprobe");
    expect(calls).toEqual([["/opt/homebrew/bin/ffprobe", "-version"]]);
    expect(await resolveBinaryAsync("ffprobe")).toBe("/opt/homebrew/bin/ffprobe");
    expect(calls).toHaveLength(1);
  } finally { platform.mockRestore(); arch.mockRestore(); __resetBinarySpawnForTests(); }
});


describe("candidate-aware resolver cache", () => {
  it("does not reuse a successful sync path for a different fallback list", () => {
    const calls: string[][] = [];
    __setBinarySpawnForTests(cmd => {
      calls.push(cmd);
      return {exitCode: cmd[0] === "/fixture/a" || cmd[0] === "/fixture/b" ? 0 : 1};
    });
    expect(resolveBinary("candidate-fixture", ["/fixture/a"])).toBe("/fixture/a");
    expect(resolveBinary("candidate-fixture", ["/fixture/b"])).toBe("/fixture/b");
    const count = calls.length;
    expect(resolveBinary("candidate-fixture", ["/fixture/b"])).toBe("/fixture/b");
    expect(calls).toHaveLength(count);
  });

  it("coalesces equivalent async inputs but separates different pending candidates", async () => {
    let release!: (code: number) => void;
    const gate = new Promise<number>(resolve => { release = resolve; });
    const calls: string[][] = [];
    const original = Bun.spawn;
    const pending: Promise<string | null>[] = [];
    Bun.spawn = ((cmd: string[]) => {
      calls.push(cmd);
      return {stdout: new Blob([]).stream(), exited: cmd[0] === "/fixture/a" ? gate : Promise.resolve(cmd[0] === "/fixture/b" ? 0 : 1), kill() {}};
    }) as any;
    try {
      const a = resolveBinaryAsync("pending-fixture", ["/fixture/a"]); pending.push(a);
      const same = resolveBinaryAsync("pending-fixture", ["/fixture/a", "/fixture/a"]);
      expect(same).toBe(a);
      const b = resolveBinaryAsync("pending-fixture", ["/fixture/b"]); pending.push(b);
      expect(b).not.toBe(a);
      release(0);
      expect(await a).toBe("/fixture/a");
      expect(await b).toBe("/fixture/b");
      const count = calls.length;
      expect(await resolveBinaryAsync("pending-fixture", ["/fixture/b"])).toBe("/fixture/b");
      expect(calls).toHaveLength(count);
    } finally { release(0); await Promise.allSettled(pending); Bun.spawn = original; }
  });

  it("shares the media cache for default and explicit equivalent fallback lists", async () => {
    __setBinarySpawnForTests(cmd => ({exitCode: cmd[0] === "/opt/homebrew/bin/ffmpeg" ? 0 : 1}));
    expect(resolveBinary("ffmpeg")).toBe("/opt/homebrew/bin/ffmpeg");
    const spawn = spyOn(Bun, "spawn").mockImplementation(() => { throw new Error("Cache hit must not spawn"); });
    try {
      expect(await resolveBinaryAsync("ffmpeg", ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])).toBe("/opt/homebrew/bin/ffmpeg");
      expect(spawn).not.toHaveBeenCalled();
    } finally { spawn.mockRestore(); }
  });
});
