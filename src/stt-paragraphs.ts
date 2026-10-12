import { appendControlLayerEvent } from "./control-layer-journal";
import {
  endsWithAbbreviation,
  alignTranscriptWordIndices,
  pauseSupportedWordIndices,
  type TranscriptSegment,
} from "./stt-sentence-boundaries";
import type { PauseSpan } from "./stt-pause-map";

// Archive measurement (10 long recordings, Oct 6–11): typical medians .672–1.28s,
// p75 .96–3.648s. Rank sentence-end pauses; the floor excludes tiny gaps.
export const MIN_PARAGRAPH_PAUSE_SECONDS = 0.6;
export const MIN_PARAGRAPH_CHARS = 200;

export function pauseParagraphsEnabled(env: Record<string, string | undefined>): boolean {
  const raw = env.VOICELAYER_STT_PAUSE_PARAGRAPHS?.trim().toLowerCase();
  return !raw || ["1", "true", "on", "yes"].includes(raw);
}

function words(text: string): Array<{ value: string; end: number }> {
  return Array.from(text.matchAll(/[\p{L}\p{N}\p{M}'’]+/gu), (m) => ({
    value: m[0].normalize("NFC").toLowerCase().replace(/’/g, "'"),
    end: m.index! + m[0].length,
  }));
}

/**
 * Only replaces inter-sentence whitespace. Missing or ambiguous evidence is a no-op.
 * Sentence-end anchors use the shared bounded word alignment; repeated final
 * context is skipped rather than assigning the same pause twice.
 * Pause support reuses the boundary stage's speech-run allocation and error bar.
 * Existing paragraphs are kept.
 * Chunk segments already use absolute times.
 */
export function applyPauseParagraphs(
  text: string,
  segments: TranscriptSegment[],
  pauses: PauseSpan[],
): string {
  if (pauses.length === 0) return text;
  if (text.length < 2 * MIN_PARAGRAPH_CHARS || /\n\s*\n/u.test(text) || segments.length < 2) return text;
  if (segments.some((s, i) =>
    !Number.isFinite(s.startS) || !Number.isFinite(s.endS) ||
    s.startS < 0 || s.endS <= s.startS || (i > 0 && s.startS < segments[i - 1].endS)
  )) return text;
  const validPause = (p: PauseSpan): boolean =>
    Number.isFinite(p.startS) && Number.isFinite(p.endS) && p.endS > p.startS;
  if (pauses.some((p) => !validPause(p))) return text;
  const evidence = pauses.filter((p) =>
    p.startS > segments[0].startS && p.endS <= segments.at(-1)!.endS
  );
  if (!evidence.length) return text;
  const targetBreaks = Math.round(text.length / 450);
  const final = words(text);
  const alignment = alignTranscriptWordIndices(text, segments, (cells, limit) => {
    appendControlLayerEvent("transcription.paragraphs.skipped", {
      reason: "alignment-cell-cap", alignment_cells: cells, max_alignment_cells: limit,
    }, { topic: "voice.transcription" });
  });
  if (alignment.size === 0) return text;
  const candidates: Array<{ start: number; end: number; pauseS: number }> = [];
  // Reuse the sentence-boundary stage's speech-run allocation (including its
  // one-word error bar), so pauses inside a verbose segment remain usable.
  const supports = evidence.filter(p => p.endS - p.startS >= MIN_PARAGRAPH_PAUSE_SECONDS - 1e-9)
    .map(p => ({ pauseS: p.endS - p.startS, indices: pauseSupportedWordIndices(
      segments, pauses, { minPauseSeconds: p.endS - p.startS },
    ) }));
  for (let i = 0; i < final.length - 1; i++) {
    const end = final[i].end;
    const terminal = /^[.!?]["'”’»\)\]]*([^\S\r\n]+)(?=\S)/u.exec(text.slice(end));
    if (!terminal || (text[end] === "." && endsWithAbbreviation(text, end))) continue;
    const lineStart = Math.max(text.lastIndexOf("\n", end - 1), text.lastIndexOf("\r", end - 1)) + 1;
    if (/^[^\S\r\n]*\d+\.[^\S\r\n]+/u.test(text.slice(lineStart, end))) continue;
    const anchorStart = Math.max(0, i - 3);
    const anchor = final.slice(anchorStart, i + 5);
    const leftWords = i - anchorStart + 1;
    if (leftWords < 2 || anchor.length - leftWords < 2) continue;
    // Repeated final context is ambiguous even if the decoder emitted it once.
    let matches = 0;
    for (let f = 0; f + anchor.length <= final.length; f++) {
      if (anchor.every((w, j) => w.value === final[f + j].value)) matches++;
    }
    const rawIndex = alignment.get(i);
    if (matches !== 1 || rawIndex === undefined) continue;
    const pauseS = Math.max(0, ...supports.filter(s => s.indices.has(rawIndex)).map(s => s.pauseS));
    if (!pauseS) continue;
    const start = end + terminal[0].length - terminal[1].length;
    const next = end + terminal[0].length;
    candidates.push({ start, end: next, pauseS });
  }
  const edits: Array<{ start: number; end: number }> = [];
  for (const candidate of candidates.sort((a, b) => b.pauseS - a.pauseS || a.start - b.start)) {
    if (edits.length >= targetBreaks) break;
    const before = Math.max(0, ...edits.filter(e => e.end <= candidate.start).map(e => e.end));
    const after = Math.min(text.length, ...edits.filter(e => e.start >= candidate.end).map(e => e.start));
    if (candidate.start - before < MIN_PARAGRAPH_CHARS || after - candidate.end < MIN_PARAGRAPH_CHARS) continue;
    edits.push(candidate);
  }
  edits.sort((a, b) => a.start - b.start);
  for (const edit of edits.reverse()) {
    text = text.slice(0, edit.start) + "\n\n" + text.slice(edit.end);
  }
  return text;
}
