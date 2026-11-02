import { VOICEBAR_SOCKET_EVENT_MAX_BYTES, type AlignedWordBoundary, type SubtitleEvent, type WordBoundary } from "../socket-protocol";
import { displayTokens } from "./display-tokens";

/** The first playing frame owns a timeline, without waiting for clone alignment. */
export function initialPlaybackTiming(text: string, durationMs: number | undefined,
  words: WordBoundary[] = [], aligned: AlignedWordBoundary[] = []): SubtitleEvent {
  const span = durationMs && Number.isFinite(durationMs) && durationMs > 0 ? Math.round(durationMs) : displayTokens(text).length * 300;
  // Leave room for text, identities and the decoded envelope. A compact estimate
  // is expanded by VoiceState; the existing following real subtitle still wins.
  const bounded = (event: SubtitleEvent): SubtitleEvent => Buffer.byteLength(JSON.stringify(event)) <= VOICEBAR_SOCKET_EVENT_MAX_BYTES / 4
    ? event : { type: "subtitle", words: [], estimated_duration_ms: Math.max(1, span) };
  if (aligned.some(word => word.offset_ms !== null))
    return bounded({ type: "subtitle", words: [], aligned_words: aligned, duration_ms: durationMs });
  if (words.length) return bounded({ type: "subtitle", words });
  const tokens = displayTokens(text);
  const estimatedSpan = Math.max(tokens.length, span);
  const estimates = tokens.map((token, word_index): AlignedWordBoundary => {
    const offset_ms = Math.floor(word_index / tokens.length * estimatedSpan);
    return { word_index, text: token[0], offset_ms,
      duration_ms: Math.floor((word_index + 1) / tokens.length * estimatedSpan) - offset_ms, estimated: true };
  });
  return bounded({ type: "subtitle", words: [], aligned_words: estimates, duration_ms: estimatedSpan });
}
