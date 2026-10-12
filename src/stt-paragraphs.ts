import {
  endsWithAbbreviation,
  BOUNDARY_PAUSE_TOLERANCE_SECONDS,
  type TranscriptSegment,
} from "./stt-sentence-boundaries";
import type { PauseSpan } from "./stt-pause-map";

// Archive measurement (10 long recordings, Oct 6–11): typical medians .672–1.28s,
// p75 .96–3.648s. The floor excludes ordinary breaths; p75 adapts to the speaker.
export const MIN_PARAGRAPH_PAUSE_SECONDS = 1.5;
export const MIN_PARAGRAPH_CHARS = 240;

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
 * Segment-end anchors use four words on each side, uniquely matched in final text;
 * no internal word timing is guessed. Existing paragraphs are kept.
 * Chunk segments already use absolute times.
 */
export function applyPauseParagraphs(
  text: string,
  segments: TranscriptSegment[],
  pauses: PauseSpan[],
): string {
  if (text.length < 2 * MIN_PARAGRAPH_CHARS || /\n\s*\n/u.test(text) || segments.length < 2) return text;
  if (segments.some((s, i) =>
    !Number.isFinite(s.startS) || !Number.isFinite(s.endS) ||
    s.startS < 0 || s.endS <= s.startS || (i > 0 && s.startS < segments[i - 1].endS)
  )) return text;
  const validPause = (p: PauseSpan): boolean =>
    Number.isFinite(p.startS) && Number.isFinite(p.endS) && p.endS > p.startS;
  if (pauses.some((p) => !validPause(p))) return text;
  const gaps = segments.slice(0, -1).map((s, i) => ({
    startS: s.endS, endS: segments[i + 1].startS,
  })).filter(validPause);
  // A supplied Silero map is stronger evidence than apparent segment gaps.
  const evidence = (pauses.length ? pauses : gaps).filter((p) =>
    p.startS > segments[0].startS && p.endS <= segments.at(-1)!.endS
  );
  if (!evidence.length) return text;
  const durations = evidence.map((p) => p.endS - p.startS).sort((a, b) => a - b);
  const threshold = Math.max(
    MIN_PARAGRAPH_PAUSE_SECONDS,
    durations[Math.ceil(durations.length * .75) - 1],
  );
  const raw = segments.flatMap((s) => words(s.text));
  const final = words(text);
  const edits: Array<{ start: number; end: number }> = [];
  let rawOffset = 0;
  let paragraphStart = 0;
  for (let i = 0; i < segments.length - 1; i++) {
    rawOffset += words(segments[i].text).length;
    if (!evidence.some((p) =>
      p.endS - p.startS >= threshold - 1e-9 &&
      Math.abs(p.startS - segments[i].endS) <= BOUNDARY_PAUSE_TOLERANCE_SECONDS + 1e-9
    )) continue;
    const anchorStart = Math.max(0, rawOffset - 4);
    const anchor = raw.slice(anchorStart, rawOffset + 4);
    const leftWords = rawOffset - anchorStart;
    if (leftWords < 2 || anchor.length - leftWords < 2) continue;
    let matchIndex = -1;
    let matches = 0;
    for (let f = 0; f + anchor.length <= final.length; f++) {
      if (anchor.every((w, j) => w.value === final[f + j].value)) {
        matchIndex = f;
        matches++;
      }
    }
    if (matches !== 1) continue;
    const end = final[matchIndex + leftWords - 1].end;
    // Keep closing quotes/brackets in the left paragraph and every mark byte.
    const terminal = /^[.!?]["'”’»\)\]]*(\s+)(?=\S)/u.exec(text.slice(end));
    if (!terminal || (text[end] === "." && endsWithAbbreviation(text, end))) continue;
    const start = end + terminal[0].length - terminal[1].length;
    const next = end + terminal[0].length;
    if (start - paragraphStart < MIN_PARAGRAPH_CHARS || text.length - next < MIN_PARAGRAPH_CHARS) continue;
    edits.push({ start, end: next });
    paragraphStart = next;
  }
  for (const edit of edits.reverse()) {
    text = text.slice(0, edit.start) + "\n\n" + text.slice(edit.end);
  }
  return text;
}
