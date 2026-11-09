/**
 * Lane B (2.4): THE file to change when narration moves to NarrationLayer.
 *
 * Today it returns the default adapter over VoiceLayer's own engines. A NarrationLayer adapter
 * implements NarrationSource (text + voice/rate profile -> audio file + word timings) and is
 * returned here instead; no other VoiceLayer file changes. Its contract is not final, so it is
 * not implemented yet (Etan, 2026-11-08).
 */
import { createEngineNarrationSource, type EngineNarrationDeps } from "./engines";
import type { NarrationSource } from "./source";

export function createNarrationSource(engines: EngineNarrationDeps): NarrationSource {
  return createEngineNarrationSource(engines);
}
