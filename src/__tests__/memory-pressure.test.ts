/**
 * c8-M2: bound our own memory. Fail-first on candidate f1eb3434, where the polish server launched
 * with mlx_lm's defaults (10 KV caches, no byte cap; 2.3 GB on 2026-11-11) and memory pressure
 * unloaded only Parakeet, at the first warning, while the polish cache stayed.
 */
import { describe, expect, it } from "bun:test";
import {
  ensureSTTPolishServer, releaseSTTPolishServerForMemoryPressure, resetSTTPolishServerManagerForTests,
  POLISH_PROMPT_CACHE_BYTES, POLISH_PROMPT_CACHE_ENTRIES,
} from "../stt-polish-server";
import { createMemoryPressureResponder, PRESSURE_PERSIST_WINDOW_MS, type MemoryPressureDeps } from "../memory-pressure";

function fakePolish(stderrLines: string[] = []) {
  const spawnCalls: string[][] = [];
  let exit!: (code: number) => void;
  const exited = new Promise<number>(resolve => { exit = resolve; });
  let readinessChecks = 0;
  const options = {
    env: { QA_VOICE_STT_POLISH: "on" },
    findBinary: () => "/tmp/mlx_lm.server",
    // Not answering before the spawn (otherwise it adopts an external server), ready after it.
    isEndpointReady: async () => ++readinessChecks >= 2,
    findPortOwnerPids: () => (readinessChecks >= 2 ? [4567] : []),
    startupTimeoutMs: 2_000,
    sleep: (ms: number) => Bun.sleep(Math.min(ms, 5)),
    appendEvent: () => {},
    log: () => {},
    spawn: (args: string[]) => {
      spawnCalls.push(args);
      return {
        pid: 4567, exited,
        kill: () => exit(0),
        stderr: new ReadableStream<Uint8Array>({
          start(controller) {
            for (const line of stderrLines) controller.enqueue(new TextEncoder().encode(line));
            controller.close();
          },
        }),
      };
    },
  };
  return { options, spawnCalls };
}

describe("c8-M2 polish prompt cache has a hard cap", () => {
  it("launches mlx_lm.server with an entry and byte cap when the binary supports them", async () => {
    resetSTTPolishServerManagerForTests();
    const { options, spawnCalls } = fakePolish();
    await ensureSTTPolishServer({ ...options, probeCacheCaps: async () => true });
    expect(spawnCalls).toHaveLength(1);
    const args = spawnCalls[0];
    expect(args[args.indexOf("--prompt-cache-size") + 1]).toBe(String(POLISH_PROMPT_CACHE_ENTRIES));
    expect(args[args.indexOf("--prompt-cache-bytes") + 1]).toBe(String(POLISH_PROMPT_CACHE_BYTES));
    expect(POLISH_PROMPT_CACHE_ENTRIES).toBeLessThan(10); // mlx_lm's default
    expect(POLISH_PROMPT_CACHE_BYTES).toBeLessThanOrEqual(1024 ** 3);
    resetSTTPolishServerManagerForTests();
  });

  it("an older mlx_lm without the flags still starts, with the old arguments", async () => {
    resetSTTPolishServerManagerForTests();
    const { options, spawnCalls } = fakePolish();
    await ensureSTTPolishServer({ ...options, probeCacheCaps: async () => false });
    expect(spawnCalls[0]).not.toContain("--prompt-cache-size");
    expect(spawnCalls[0]).not.toContain("--prompt-cache-bytes");
    resetSTTPolishServerManagerForTests();
  });

  it("memory pressure releases the polish server and reports the cache size it held", async () => {
    resetSTTPolishServerManagerForTests();
    const { options } = fakePolish(["2026-11-11 23:23:01,000 - INFO - Prompt Cache: 10 sequences, 2.30 GB\n"]);
    await ensureSTTPolishServer({ ...options, probeCacheCaps: async () => true });
    await Bun.sleep(5); // let the stderr drain read the line
    const released = await releaseSTTPolishServerForMemoryPressure();
    expect(released).toMatchObject({ released: true, cache: { sequences: 10, gb: 2.3 } });
    expect(await releaseSTTPolishServerForMemoryPressure()).toEqual({ released: false, reason: "not-running" });
    resetSTTPolishServerManagerForTests();
  });

  it("reads a Prompt Cache line split across two pipe reads", async () => {
    resetSTTPolishServerManagerForTests();
    const { options } = fakePolish(["INFO - Prompt Cache: 7 seq", "uences, 1.25 GB\nINFO - next\n"]);
    await ensureSTTPolishServer({ ...options, probeCacheCaps: async () => false });
    await Bun.sleep(5);
    expect(await releaseSTTPolishServerForMemoryPressure()).toMatchObject({ released: true, cache: { sequences: 7, gb: 1.25 } });
    resetSTTPolishServerManagerForTests();
  });
});

function harness(polishRunning = true) {
  const order: string[] = [];
  const lines: string[] = [];
  let clock = 1_000_000;
  const deps: MemoryPressureDeps = {
    releasePolish: async () => {
      order.push("polish");
      return polishRunning
        ? { released: true, cache: { sequences: 10, gb: 2.3 }, rss_mb: 2900 }
        : { released: false, reason: "not-running" };
    },
    unloadParakeet: async () => { order.push("parakeet"); return { outcome: "accept" }; },
    parakeetRssMb: () => 1400,
    now: () => clock,
    log: line => lines.push(line),
  };
  return { respond: createMemoryPressureResponder(deps), order, lines, advance: (ms: number) => { clock += ms; } };
}

describe("c8-M2 memory pressure releases the polish cache first", () => {
  it("a first warning releases only the polish server; Parakeet stays loaded", async () => {
    const h = harness();
    expect(await h.respond("warning")).toMatchObject({ outcome: "accept", polish: "released", parakeet: "kept" });
    expect(h.order).toEqual(["polish"]);
  });

  it("pressure that persists unloads Parakeet too, after the polish server", async () => {
    const h = harness();
    await h.respond("warning");
    h.advance(60_000);
    expect(await h.respond("warning")).toMatchObject({ parakeet: "unloaded" });
    expect(h.order).toEqual(["polish", "polish", "parakeet"]);
  });

  it("critical pressure unloads both at once, polish first", async () => {
    const h = harness();
    await h.respond("critical");
    expect(h.order).toEqual(["polish", "parakeet"]);
  });

  it("a warning long after the last one counts as new pressure", async () => {
    const h = harness();
    await h.respond("warning");
    h.advance(PRESSURE_PERSIST_WINDOW_MS + 1);
    await h.respond("warning");
    expect(h.order).toEqual(["polish", "polish"]);
  });

  // RM-memory P2: a warning must always free something measurable when anything is loaded.
  it("with no polish server to release, a first warning unloads Parakeet (as before this lane)", async () => {
    const h = harness(false);
    expect(await h.respond("warning")).toMatchObject({ outcome: "accept", parakeet: "unloaded" });
    expect(h.order).toEqual(["polish", "parakeet"]);
  });

  it("every release line states the bytes it freed", async () => {
    const h = harness(false);
    await h.respond("warning");
    const events = h.lines.map(line => JSON.parse(line));
    const parakeet = events.find(e => e.step === "parakeet");
    expect(parakeet).toMatchObject({ released: true, bytes_freed: 1400 * 1024 * 1024 });
    const polish = events.find(e => e.step === "polish");
    expect(polish).toMatchObject({ released: false, bytes_freed: 0 });
  });

  it("every release is logged with sizes and nothing else", async () => {
    const h = harness();
    await h.respond("critical");
    const events = h.lines.map(line => JSON.parse(line));
    expect(events).toEqual([
      { event: "memory_pressure_release", level: "critical", step: "polish", released: true,
        bytes_freed: 2900 * 1024 * 1024, polish_cache_sequences: 10, polish_cache_gb: 2.3, polish_rss_mb: 2900 },
      { event: "memory_pressure_release", level: "critical", step: "parakeet", persisted: false,
        released: true, bytes_freed: 1400 * 1024 * 1024, parakeet_rss_mb: 1400 },
    ]);
  });
});
