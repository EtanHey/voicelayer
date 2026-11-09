/**
 * Lane B (2.4): the ONE seam where VoiceLayer gets narration audio. Etan (2026-11-08): narration
 * moves to NarrationLayer, "the single place where narration is generated". VoiceLayer keeps
 * playback control, the teleprompter, F5 and capture; it asks a NarrationSource for audio.
 *
 * Contract: speakable text + voice/rate profile -> audio file + word timings. Every synthesis
 * call (Option+F5 reads, voice_speak, the voice_ask prompt, prosody segments) goes through
 * narrationSource(). Swapping to NarrationLayer is a change to src/narration/adapter.ts only.
 */
import type { WordBoundary } from "../socket-protocol";

/** Optional emphasis hints; an adapter may ignore them. */
export interface NarrationProsody {
  pitch: string;
  volume: string;
}

export interface NarrationRequest {
  /** What the voice says (VoiceLayer keeps the display text and maps timings back to it). */
  text: string;
  /** Today's engine families: "edge" (preset voices) or "clone" (Qwen3/XTTS cloned voices). */
  engine: "edge" | "clone";
  /** The voice/rate profile. NarrationLayer will own this store; VoiceLayer passes what it resolved. */
  voice: string;
  rate: string;
  /** Where the audio must land (VoiceLayer owns the file's lifetime). */
  outFile: string;
  signal?: AbortSignal;
  /** Attempts for a transient synthesis failure. */
  retries?: number;
  prosody?: NarrationProsody;
}

export interface NarrationAudio {
  audioFile: string;
  /** 0 when the source cannot measure it; the caller probes the file. */
  durationMs: number;
  /** Word timings in the audio's own clock; empty when the source has none (VoiceLayer aligns). */
  wordBoundaries: WordBoundary[];
  /** The engine that actually produced the audio, for archives and receipts. */
  engine: string;
  voice: string;
}

export interface NarrationSource {
  readonly id: string;
  /**
   * Resolves null when the requested engine family is unavailable for this voice, so the caller
   * keeps its fallback policy (a cloned voice falling back to edge). Rejects on a real failure.
   */
  synthesize(request: NarrationRequest): Promise<NarrationAudio | null>;
}

let active: NarrationSource | undefined;

export function narrationSource(): NarrationSource {
  if (!active) throw new Error("No narration source is configured");
  return active;
}

/** Install a source; returns the previous one (tests restore it). */
export function setNarrationSource(source: NarrationSource): NarrationSource | undefined {
  const previous = active;
  active = source;
  return previous;
}
