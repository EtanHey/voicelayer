/**
 * c8-M2: what the daemon releases when macOS reports memory pressure (VoiceBar forwards its
 * DispatchSource warning/critical events as `memory_pressure`).
 *
 * 1. The polish server always goes first: its prompt cache grew to 2.3 GB on 2026-11-11 and nothing
 *    released it, while the next dictation reloaded the Parakeet model we had unloaded.
 * 2. Parakeet is unloaded only when the pressure is critical, or persists (another event within
 *    PERSIST_WINDOW_MS of the previous one).
 * Each step logs one JSON line with sizes, never transcript or prompt text.
 */
import { releaseSTTPolishServerForMemoryPressure, processRssMb, type PolishPressureRelease } from "./stt-polish-server";
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
      ...(polish.released
        ? { polish_cache_sequences: polish.cache?.sequences ?? null, polish_cache_gb: polish.cache?.gb ?? null, polish_rss_mb: polish.rss_mb }
        : { reason: polish.reason }),
    }));

    if (level !== "critical" && !persisted) {
      deps.log(JSON.stringify({ event: "memory_pressure_release", level, step: "parakeet", released: false, reason: "first-warning" }));
      return polish.released
        ? { outcome: "accept", polish: "released", parakeet: "kept" }
        : { outcome: "noop", reason: polish.reason, polish: polish.reason, parakeet: "kept" };
    }

    const rss = deps.parakeetRssMb();
    const parakeet = await deps.unloadParakeet();
    deps.log(JSON.stringify({
      event: "memory_pressure_release", level, step: "parakeet", persisted,
      released: parakeet.outcome === "accept", parakeet_rss_mb: rss,
      ...(parakeet.reason ? { reason: parakeet.reason } : {}),
    }));
    if (polish.released || parakeet.outcome === "accept") {
      return { outcome: "accept", polish: polish.released ? "released" : polish.reason,
        parakeet: parakeet.outcome === "accept" ? "unloaded" : "skipped" };
    }
    return { outcome: parakeet.outcome, ...(parakeet.reason ? { reason: parakeet.reason } : {}),
      polish: polish.reason, parakeet: "skipped" };
  };
}

let responder: ReturnType<typeof createMemoryPressureResponder> | null = null;

/** The daemon's single responder; its persistence clock lives for the daemon process. */
export function respondToMemoryPressure(level: "warning" | "critical"): Promise<MemoryPressureOutcome> {
  responder ??= createMemoryPressureResponder({
    releasePolish: releaseSTTPolishServerForMemoryPressure,
    unloadParakeet: unloadParakeetForMemoryPressure,
    parakeetRssMb: () => processRssMb(parakeetServer.pid),
    now: () => Date.now(),
    log: line => console.error(`[voicelayer] ${line}`),
  });
  return responder(level);
}

/** Tests only. */
export function resetMemoryPressureResponderForTests(): void { responder = null; }
