/**
 * Lane B (2.4): the default NarrationSource, today's engines behind the contract.
 * edge-tts for preset voices; synthesizeCloned (Qwen3 daemon, XTTS profiles) for cloned voices.
 * The engine functions are injected by tts.ts so this adapter owns no process or file policy.
 */
import { writeFileSync } from "fs";
import type { WordBoundary } from "../socket-protocol";
import type { NarrationAudio, NarrationProsody, NarrationRequest, NarrationSource } from "./source";

export interface EngineNarrationDeps {
  edge(text: string, voice: string, rate: string, outFile: string, signal?: AbortSignal, retries?: number,
    prosody?: NarrationProsody): Promise<{ audioFile: string; durationMs: number; wordBoundaries: WordBoundary[] }>;
  clone(text: string, voice: string, signal?: AbortSignal): Promise<Uint8Array | null>;
}

export function createEngineNarrationSource(deps: EngineNarrationDeps): NarrationSource {
  return {
    id: "voicelayer-engines",
    async synthesize(request: NarrationRequest): Promise<NarrationAudio | null> {
      if (request.engine === "edge") {
        const chunk = await deps.edge(request.text, request.voice, request.rate, request.outFile, request.signal,
          request.retries, request.prosody);
        return { ...chunk, engine: "edge-tts", voice: request.voice };
      }
      const audio = await deps.clone(request.text, request.voice, request.signal);
      if (!audio) return null;
      writeFileSync(request.outFile, audio);
      return { audioFile: request.outFile, durationMs: 0, wordBoundaries: [], engine: "qwen3-tts", voice: request.voice };
    },
  };
}
