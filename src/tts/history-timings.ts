import type { AlignedWordBoundary, WordBoundary } from "../socket-protocol";

/** One synthesized chunk of a read, in the order its audio sits in the history file. */
export interface HistoryChunkTiming {
  text: string;
  durationMs: number;
  /** Clone alignment as published: chunk-local offsets, chunk-local word_index. */
  aligned?: AlignedWordBoundary[];
  /** Edge timings already mapped one per display token (alignWordBoundariesToDisplayText). */
  words?: WordBoundary[];
}

const tokensOf = (text: string) => Array.from(text.matchAll(/\S+/gu), match => match[0]);

/**
 * WORDTIME1: the timings a read actually used, re-indexed against the whole
 * history text and shifted onto the history file's timeline. Chunks append;
 * an untimed chunk only contributes nulls, so it never erases its neighbours.
 * Undefined when nothing was measured.
 */
export function combineHistoryTimings(chunks: HistoryChunkTiming[]): AlignedWordBoundary[] | undefined {
  const combined: AlignedWordBoundary[] = [];
  let startMs = 0;
  for (const chunk of chunks) {
    const tokens = tokensOf(chunk.text);
    const aligned = new Map(chunk.aligned?.map(word => [word.word_index, word]));
    const edge = chunk.words?.length === tokens.length && chunk.words.every((word, i) => word.text === tokens[i])
      ? chunk.words : undefined;
    tokens.forEach((text, i) => {
      const source = aligned.get(i) ?? edge?.[i];
      const offset = source?.text === text ? source.offset_ms : null, duration = source?.duration_ms ?? null;
      const valid = offset !== null && duration !== null && Number.isFinite(offset) && Number.isFinite(duration) &&
        offset >= 0 && duration > 0 && offset + duration <= chunk.durationMs;
      combined.push({ word_index: combined.length, text,
        offset_ms: valid ? startMs + offset : null, duration_ms: valid ? duration : null });
    });
    startMs += chunk.durationMs;
  }
  return combined.some(word => word.offset_ms !== null) ? combined : undefined;
}

/** Replay displays a bounded prefix of the text; keep only rows that still name a displayed token. */
export function clipAlignedWordsToText(words: AlignedWordBoundary[], text: string): AlignedWordBoundary[] {
  const tokens = tokensOf(text);
  return words.filter(word => tokens[word.word_index] === word.text);
}
