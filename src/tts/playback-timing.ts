import type { AlignedWordBoundary, SubtitleEvent, WordBoundary } from "../socket-protocol";
import { displayTokens } from "./display-tokens";

/** The first playing frame owns a timeline, without waiting for clone alignment. */
export function initialPlaybackTiming(text: string, durationMs: number | undefined,
  words: WordBoundary[] = [], aligned: AlignedWordBoundary[] = []): SubtitleEvent {
  if (aligned.some(word => word.offset_ms !== null))
    return { type: "subtitle", words: [], aligned_words: aligned, duration_ms: durationMs };
  if (words.length) return { type: "subtitle", words };
  const tokens = displayTokens(text);
  const span = Math.max(tokens.length, Math.round(durationMs && Number.isFinite(durationMs) && durationMs > 0
    ? durationMs : tokens.length * 300));
  const estimates = tokens.map((token, word_index): AlignedWordBoundary => {
    const offset_ms = Math.floor(word_index / tokens.length * span);
    return { word_index, text: token[0], offset_ms,
      duration_ms: Math.floor((word_index + 1) / tokens.length * span) - offset_ms, estimated: true };
  });
  return { type: "subtitle", words: [], aligned_words: estimates, duration_ms: span };
}
