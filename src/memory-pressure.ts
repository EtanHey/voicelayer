/**
 * c8-M2: what the daemon releases when macOS reports memory pressure (VoiceBar forwards its
 * DispatchSource warning/critical events as `memory_pressure`).
 *
 * 1. The polish server always goes first: its prompt cache grew to 2.3 GB on 2026-11-11 and nothing
 *    released it, while the next dictation reloaded the Parakeet model we had unloaded.
 * 2. Parakeet is unloaded when the polish release freed nothing, when the pressure is critical, or
 *    when it persists (another event within PERSIST_WINDOW_MS of the previous one).
 * Each step logs one JSON line with the bytes it freed (the released process's RSS), never text.
 */
import { releaseSTTPolishServerForMemoryPressure, processFootprintMb, type PolishPressureRelease } from "./stt-polish-server";
import { unloadParakeetForMemoryPressure } from "./recognizer-controller";
import { parakeetServer } from "./parakeet-server";

export const PRESSURE_PERSIST_WINDOW_MS = 5 * 60_000;

type ParakeetResult = { outcome: "accept" | "noop" | "reject"; reason?: string };

export interface MemoryPressureDeps {
  releasePolish(): Promise<PolishPressureRelease>;
  unloadParakeet(): Promise<ParakeetResult>;
  parakeetRssMb(): number | null;
  now(): number;
  log(line: string): void;
  persistWindowMs?: number;
}

export interface MemoryPressureOutcome {
  outcome: "accept" | "noop" | "reject";
  reason?: string;
  /** "released", or why the polish server was not released. */
  polish: string;
  parakeet: "unloaded" | "kept" | "skipped";
}

const MiB = 1024 * 1024;

export function createMemoryPressureResponder(deps: MemoryPressureDeps) {
  let lastEventAt: number | null = null;
  const window = deps.persistWindowMs ?? PRESSURE_PERSIST_WINDOW_MS;
  return async (level: "warning" | "critical"): Promise<MemoryPressureOutcome> => {
    const now = deps.now();
    const persisted = lastEventAt !== null && now - lastEventAt <= window;
    lastEventAt = now;

    const polish = await deps.releasePolish();
    deps.log(JSON.stringify({
      event: "memory_pressure_release", level, step: "polish",
      released: polish.released,
      bytes_freed: polish.released && polish.rss_mb !== null ? polish.rss_mb * MiB : 0,
      ...(polish.released
        ? { polish_cache_sequences: polish.cache?.sequences ?? null, polish_cache_gb: polish.cache?.gb ?? null, polish_rss_mb: polish.rss_mb }
        : { reason: polish.reason }),
    }));

    // RM-memory P2: Parakeet waits only when the polish release actually freed memory on a first
    // warning. With nothing released, a warning unloads Parakeet exactly as the old handler did.
    if (polish.released && level !== "critical" && !persisted) {
      deps.log(JSON.stringify({ event: "memory_pressure_release", level, step: "parakeet", released: false,
        bytes_freed: 0, reason: "polish-released-first" }));
      return { outcome: "accept", polish: "released", parakeet: "kept" };
    }

    const rss = deps.parakeetRssMb();
    const parakeet = await deps.unloadParakeet();
    const unloaded = parakeet.outcome === "accept";
    deps.log(JSON.stringify({
      event: "memory_pressure_release", level, step: "parakeet", persisted,
      released: unloaded, bytes_freed: unloaded && rss !== null ? rss * MiB : 0, parakeet_rss_mb: rss,
      ...(parakeet.reason ? { reason: parakeet.reason } : {}),
    }));
    if (polish.released || unloaded) {
      return { outcome: "accept", polish: polish.released ? "released" : polish.reason,
        parakeet: unloaded ? "unloaded" : "skipped" };
    }
    return { outcome: parakeet.outcome, ...(parakeet.reason ? { reason: parakeet.reason } : {}),
      polish: polish.reason, parakeet: "skipped" };
  };
}

let responder: ReturnType<typeof createMemoryPressureResponder> | null = null;

/** The daemon's single responder; its persistence clock lives for the daemon process. */
let pressureChain: Promise<unknown> = Promise.resolve();
export function respondToMemoryPressure(level: "warning" | "critical"): Promise<MemoryPressureOutcome> {
  responder ??= createMemoryPressureResponder({
    releasePolish: releaseSTTPolishServerForMemoryPressure,
    unloadParakeet: unloadParakeetForMemoryPressure,
    parakeetRssMb: () => processFootprintMb(parakeetServer.pid),
    now: () => Date.now(),
    log: line => console.error(`[voicelayer] ${line}`),
  });
  // Overlapping events run one after another, so each sees the previous one's releases.
  const run = responder;
  const next = pressureChain.then(() => run(level), () => run(level));
  pressureChain = next.catch(() => {});
  return next;
}

/** Tests only. */
export function resetMemoryPressureResponderForTests(): void { responder = null; pressureChain = Promise.resolve(); }
