import { displayTokens } from "./display-tokens";
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

const tokensOf = (text: string) => displayTokens(text).map(match => match[0]);

/**
 * Fill each untimed token with an even share of the gap between its timed neighbours,
 * bounded by the chunk [0, endMs]. Mirrors VoiceBar's `TeleprompterBoundary.interpolated`
 * so a replay reproduces the first run's per-chunk estimates.
 */
function interpolateChunk(rows: AlignedWordBoundary[], endMs: number, markers: Set<number>): void {
  const timed = rows.flatMap((row, i) => row.offset_ms === null ? [] : [i]);
  if (!timed.length) return;
  const end = (i: number) => rows[i].offset_ms! + (rows[i].duration_ms ?? 0);
  const fill = (from: number, to: number, first: number, last: number) => {
    const count = last - first;
    if (count <= 0 || to <= from) return;
    for (let step = 0; step < count; step++) {
      if (markers.has(first + step)) continue;
      const start = from + Math.trunc((to - from) * step / count), stop = from + Math.trunc((to - from) * (step + 1) / count);
      if (stop > start) rows[first + step] = { ...rows[first + step], offset_ms: start, duration_ms: stop - start, estimated: true };
    }
  };
  fill(0, rows[timed[0]].offset_ms!, 0, timed[0]);
  for (let k = 1; k < timed.length; k++) {
    const left = timed[k - 1], right = timed[k], next = rows[right].offset_ms!;
    fill(end(left) < next ? end(left) : rows[left].offset_ms! + 1, next, left + 1, right);
  }
  fill(end(timed.at(-1)!), endMs, timed.at(-1)! + 1, rows.length);
}

/**
 * WORDTIME1: the timeline a read actually showed, re-indexed against the whole history
 * text and shifted onto the history file. Each chunk keeps its own estimates (interpolated
 * inside its own audio) and Edge zero-duration seek anchors, both marked `estimated`;
 * clone rows still need a positive span inside their audio. Chunks append; an untimed
 * chunk contributes nulls and erases nothing. Undefined when nothing was measured.
 */
export function combineHistoryTimings(chunks: HistoryChunkTiming[]): AlignedWordBoundary[] | undefined {
  const combined: AlignedWordBoundary[] = [];
  let startMs = 0;
  for (const chunk of chunks) {
    const tokens = tokensOf(chunk.text);
    const aligned = new Map(chunk.aligned?.map(word => [word.word_index, word]));
    const edge = chunk.words?.length === tokens.length && chunk.words.every((word, i) => word.text === tokens[i])
      ? chunk.words : undefined;
    const rows: AlignedWordBoundary[] = tokens.map((text, i) => {
      const source = aligned.get(i) ?? edge?.[i];
      const offset = source?.text === text ? source.offset_ms : null, duration = source?.duration_ms ?? null;
      const finite = offset !== null && duration !== null && Number.isFinite(offset) && Number.isFinite(duration) &&
        offset >= 0 && offset + duration <= chunk.durationMs;
      if (finite && duration! > 0) return { word_index: i, text, offset_ms: offset, duration_ms: duration };
      // The live Edge decoder seeks a zero-duration markdown anchor; history keeps that seek.
      if (finite && duration === 0 && !aligned.has(i) && edge) return { word_index: i, text, offset_ms: offset, duration_ms: 0, estimated: true };
      return { word_index: i, text, offset_ms: null, duration_ms: null };
    });
    const markers = new Set(displayTokens(chunk.text).flatMap((token, i) =>
      /^[-+*•◦▪‣]$/.test(token[0]) &&
      /^[ \t]*$/.test(chunk.text.slice(chunk.text.lastIndexOf("\n", token.index - 1) + 1, token.index)) &&
      /[ \t]/.test(chunk.text[token.index + token[0].length] ?? "") ? [i] : []));
    interpolateChunk(rows, chunk.durationMs, markers);
    for (const row of rows) combined.push({ ...row, word_index: combined.length,
      offset_ms: row.offset_ms === null ? null : startMs + row.offset_ms });
    startMs += chunk.durationMs;
  }
  return combined.some(word => word.offset_ms !== null) ? combined : undefined;
}

/** Replay shows at most `max` characters; never cut a token in half, so stored timings still name whole tokens. */
export function replayDisplayText(text: string, max = 2000): string {
  if (text.length <= max || /\s/u.test(text[max])) return text.slice(0, max);
  return text.slice(0, max).replace(/\S+$/u, "").trimEnd() || text.slice(0, max);
}

/** Replay displays a bounded prefix of the text; keep only rows that still name a displayed token. */
export function clipAlignedWordsToText(words: AlignedWordBoundary[], text: string): AlignedWordBoundary[] {
  const tokens = tokensOf(text);
  return words.filter(word => tokens[word.word_index] === word.text);
}

/** Edge boundaries one per display token, cut to the displayed prefix; [] when they do not line up. */
export function clipWordBoundariesToText(words: WordBoundary[], text: string): WordBoundary[] {
  const tokens = tokensOf(text);
  return words.length >= tokens.length && tokens.every((token, i) => words[i].text === token) ? words.slice(0, tokens.length) : [];
}
