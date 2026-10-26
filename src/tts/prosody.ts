import type { SpeakableText } from "../speakable-text";
import { projectStructuredSpeech, type ProjectionRange, type StructuredSpeech, type TextRange } from "./structured-speech";

/** Total silence (ms) from the last word of one utterance to the first of the next. */
export const PAUSE = { heading: 800, h1: 900, h2: 750, beforeHeading: 600,
  label: 320, listIntro: 600, shortItem: 450, longItem: 700,
  sentence: 550, paragraph: 1000, beforeAside: 200, afterAside: 300, askQuestion: 600 };
/** Same limit as the long-read chunker (TTS_CHUNK_MAX_CHARS); one owner of request size. */
export const PROSODY_MAX_CHARS = 400;
/** Engine requests in flight at once for one read. */
export const PROSODY_SYNTH_CONCURRENCY = 3;
/** Request-size ramp. Speech plays at ~15 chars/s while an engine renders far faster, so text already
 * queued ahead covers the synthesis of about RAMP times its length. Nothing ahead: the full limit,
 * exactly like the long-read chunker's first chunk. Below FAST_MIN a split is not worth a request. */
const RAMP = 8, FAST_MIN = 120;
export function prosodyBudget(charsAhead: number, maxChars = PROSODY_MAX_CHARS): number {
  return charsAhead === 0 ? maxChars : Math.min(maxChars, Math.max(FAST_MIN, RAMP * charsAhead));
}

export type ProsodySegmentKind = "heading" | "label" | "prose" | "item" | "aside";
export interface ProsodySegment {
  kind: ProsodySegmentKind;
  /** Exact engine text: a slice of the projection, plus a closing period on emphasized utterances. */
  text: string;
  emphasis: boolean;
  /** Silence after this utterance; adjacent boundaries collapse to the max, never the sum. */
  pauseMs: number;
  /** Trimmed span of `projection.speechText`. */
  speech: TextRange;
  /** Untrimmed span of the read text; consecutive segments partition it. */
  read: TextRange;
}
/** One long-read chunk: consecutive segments, synthesized separately and spliced into one audio file. */
export interface ProsodyChunk {
  first: number;
  end: number;
  read: TextRange;
  /** Trimmed read slice, as the long-read runtime's chunk text. */
  text: string;
  trailingPauseMs: number;
}
export interface ProsodyPlan {
  readText: string;
  /** Engine texts joined by single spaces: what the synthesizer and the clone aligner receive. */
  speechText: string;
  segments: ProsodySegment[];
  chunks: ProsodyChunk[];
}
export interface ProsodyInput {
  /** The text the read is about: sanitized markdown (speak), or flattened structured speech (selection). */
  readText: string;
  /** Main's projection of `readText`, computed once by the caller; never redone per fragment. */
  projection: SpeakableText;
  /** Selection reads: the source structure whose `speechText` is `readText`. */
  structure?: StructuredSpeech;
  /** voice_ask: pause before the question itself. */
  ask?: boolean;
  maxChars?: number;
  concurrency?: number;
}

const TERMINAL = /[.!?…。！？]["'”’)\]]*$/u;
const WORD = /[\p{L}\p{N}]/u;
const MARKER = /^[ \t]*(?:[-+*]|\d+[.)])[ \t]+(?:\[[ xX]\][ \t]*)?/;
const LABEL = /^(\*\*|__)([^*_\n]*?\S)\1(:?)(?=[ \t]+\S)/;
const BOLD_LINE = /^[ \t]*(\*\*|__)(?=\S)[^\n]*?\S\1[ \t]*$/;
const PARENTHETICAL = /(?<=\s)\((?=[^()\n]*\p{L})[^()\n]*?\S\s[^()\n]*?\)[.,;:!?]*(?=\s|$)/gu;
const DASH_ASIDE = /(?<=\S)\s[—–]\s(?=[^\n—–]*\p{L})[^\n—–]*?\S\s[—–](?=\s)/gu;

/** Map an offset through an ordered partition. Interior offsets translate only inside identity
 * ranges; any other range is atomic and the offset snaps to its start, so it is never split. */
function mapper(ranges: readonly ProjectionRange[], side: "source" | "display" = "source") {
  return (offset: number): number => {
    for (const range of ranges) {
      const from = range[side];
      if (from.start >= offset) return range.speech.start;
      if (offset < from.end) return range.kind === "identity" ? range.speech.start + offset - from.start : range.speech.start;
    }
    return ranges.at(-1)?.speech.end ?? offset;
  };
}

interface Unit { at: number; kind: ProsodySegmentKind; emphasis: boolean; pauseMs: number; item: boolean }

/** Plan structural utterances over an already-projected read. Pure. */
export function planProsody(input: ProsodyInput): ProsodyPlan {
  const { readText, projection } = input;
  if (projection.displayText !== readText) throw new Error("Prosody projection must be of the read text");
  const maxChars = input.maxChars ?? PROSODY_MAX_CHARS;
  const structured = input.structure?.speechText === readText ? input.structure : undefined;
  const source = structured?.displayText ?? readText;
  const blocks = (structured ?? projectStructuredSpeech(readText)).blocks;
  const readAt = structured ? mapper(structured.ranges) : (offset: number) => offset;
  const speechAt = mapper(projection.ranges);
  const spoken = (read: number) => projection.ranges.some((r) => r.kind === "identity" && r.source.start <= read && read < r.source.end);

  const units: Unit[] = [];
  const pause = (ms: number) => { const last = units.at(-1); if (last) last.pauseMs = Math.max(last.pauseMs, ms); };
  const push = (at: number, kind: ProsodySegmentKind, pauseMs = 0, emphasis = false, item = false) =>
    units.push({ at, kind, emphasis, pauseMs, item });
  const hasWordsSince = (at: number) => WORD.test(readText.slice(units.at(-1)?.at ?? 0, at));

  /** Asides split a prose line in read coordinates; parentheses must actually be spoken. */
  const asides = (start: number, end: number, sourceLine: string, item: boolean) => {
    if (sourceLine.includes("`")) return;
    const line = readText.slice(start, end);
    const found = [...line.matchAll(PARENTHETICAL), ...line.matchAll(DASH_ASIDE)].sort((a, b) => a.index - b.index);
    let cursor = 0;
    for (const match of found) {
      if (match.index < cursor) continue;
      const open = start + match.index + (match[0][0] === "(" ? 0 : match[0].search(/[—–]/));
      if (!spoken(open)) continue;
      const close = start + match.index + match[0].length;
      if (hasWordsSince(start + match.index)) {
        pause(PAUSE.beforeAside);
        push(start + match.index, "aside", PAUSE.afterAside, false, item);
      } else Object.assign(units.at(-1)!, { kind: "aside" as const, pauseMs: PAUSE.afterAside });
      push(close, item ? "item" : "prose", 0, false, item);
      cursor = match.index + match[0].length;
    }
  };
  /** A bold label at the start of a source line; its end is found in read coordinates. */
  const label = (lineStart: number, lineEnd: number, content: number, item: boolean) => {
    const match = source.slice(content, lineEnd).match(LABEL);
    if (!match) return false;
    const sourceEnd = content + match[0].length;
    let end: number;
    if (!structured) end = sourceEnd;
    else {
      const readStart = readAt(lineStart), readLine = readText.slice(readStart, readAt(lineEnd));
      const text = match[2].replace(/[*_`]/g, "") + match[3];
      const lead = readLine.length - readLine.trimStart().length;
      if (!readLine.startsWith(text, lead)) return false;
      end = readStart + lead + text.length;
    }
    push(readAt(lineStart), "label", PAUSE.label, true, item);
    push(end, item ? "item" : "prose", 0, false, item);
    return end;
  };

  let fresh = true;
  for (const [index, block] of blocks.entries()) {
    const { start, end } = block.source;
    const raw = source.slice(start, end);
    if (block.kind === "separator") { pause(PAUSE.paragraph); fresh = true; continue; }
    if (block.kind === "heading") {
      if (units.length) pause(PAUSE.beforeHeading);
      const level = raw.match(/^\s{0,3}(#{1,6})\s/)?.[1].length ?? (/\n\s{0,3}=+\s*$/.test(raw) ? 1 : 2);
      push(readAt(start), "heading", level === 1 ? PAUSE.h1 : level <= 3 ? PAUSE.h2 : PAUSE.heading, true);
      fresh = true;
      continue;
    }
    if (block.kind === "list-item") {
      const marker = raw.match(MARKER)?.[0].length ?? 0;
      const lineEnd = start + raw.replace(/[\r\n]+$/, "").length;
      const body = label(start, lineEnd, start + marker, true);
      if (body === false) push(readAt(start), "item", 0, false, true);
      asides(body === false ? readAt(start) : body, readAt(lineEnd), raw, true);
      const words = source.slice(start + marker, lineEnd).split(/\s+/).filter((w) => WORD.test(w)).length;
      pause(words >= 6 ? PAUSE.longItem : PAUSE.shortItem);
      fresh = true;
      continue;
    }
    // Paragraph, code and table blocks: a soft wrap or an adjacent code/table block is not a boundary.
    for (const line of raw.matchAll(/[^\r\n]*(?:\r\n|\r|\n|$)/g)) {
      if (!line[0]) break;
      const text = line[0].replace(/[\r\n]+$/, "");
      const lineStart = start + line.index, lineEnd = lineStart + text.length;
      if (!text.trim()) continue;
      if (block.kind === "paragraph" && BOLD_LINE.test(text)) {
        if (units.length) pause(PAUSE.beforeHeading);
        push(readAt(lineStart), "heading", PAUSE.heading, true);
        fresh = true;
        continue;
      }
      const body = block.kind === "paragraph" ? label(lineStart, lineEnd, lineStart + (text.length - text.trimStart().length), false) : false;
      if (body === false && fresh) push(readAt(lineStart), "prose");
      fresh = false;
      if (block.kind === "paragraph") asides(body === false ? readAt(lineStart) : body, readAt(lineEnd), text, false);
    }
    const next = blocks.slice(index + 1).find((b) => b.kind !== "separator");
    if (/:\s*$/.test(raw) && next?.kind === "list-item") pause(PAUSE.listIntro);
  }

  // Read spans → engine spans. Units are cut points; an utterance without words joins its neighbour.
  let segments: ProsodySegment[] = [];
  let carry: number | undefined;
  for (const [i, unit] of units.entries()) {
    const readStart = carry ?? (i === 0 ? 0 : unit.at), readEnd = units[i + 1]?.at ?? readText.length;
    if (readEnd < readStart) continue;
    const segment = makeSegment(unit, readStart, readEnd);
    if (WORD.test(segment.text)) { segments.push(segment); carry = undefined; continue; }
    const previous = segments.at(-1);
    if (previous) Object.assign(previous, makeSegment(previous, previous.read.start, readEnd), { pauseMs: Math.max(previous.pauseMs, unit.pauseMs) });
    else carry = readStart;
  }
  if (!segments.length && projection.speechText.trim()) segments = [makeSegment({ kind: "prose", emphasis: false, pauseMs: 0 }, 0, readText.length)];
  if (carry !== undefined && segments.length) {
    const last = segments.at(-1)!;
    Object.assign(last, makeSegment(last, last.read.start, readText.length));
  }

  function makeSegment(unit: Pick<Unit, "kind" | "emphasis" | "pauseMs"> & { item?: boolean }, readStart: number, readEnd: number): ProsodySegment & { item?: boolean } {
    let s = speechAt(readStart), e = readEnd >= readText.length ? projection.speechText.length : speechAt(readEnd);
    const slice = projection.speechText.slice(s, e);
    s += slice.length - slice.trimStart().length;
    e = Math.max(s, e - (slice.length - slice.trimEnd().length));
    return { kind: unit.kind, emphasis: unit.emphasis, pauseMs: unit.pauseMs, item: unit.item,
      text: projection.speechText.slice(s, e), speech: { start: s, end: e }, read: { start: readStart, end: readEnd } };
  }
  const sentenceStarts = (segment: ProsodySegment) => {
    const { start, end } = segment.read;
    const flat = readText.slice(start, end).replace(/[\r\n]/g, " ");
    return [...new Intl.Segmenter(undefined, { granularity: "sentence" }).segment(flat)].map((s) => start + s.index);
  };
  const trim = (start: number, end: number) => {
    const text = readText.slice(start, end);
    return { start: start + text.length - text.trimStart().length, end: end - (text.length - text.trimEnd().length) };
  };
  const readLength = (span: TextRange) => { const t = trim(span.start, span.end); return Math.max(0, t.end - t.start); };
  const split = (segment: ProsodySegment & { item?: boolean }, cut: number, pauseMs: number) => [
    { ...makeSegment(segment, segment.read.start, cut), pauseMs },
    { ...makeSegment(segment, cut, segment.read.end), kind: segment.kind === "label" || segment.kind === "heading" ? "prose" as const : segment.kind },
  ];

  // Oversized prose is packed like the long-read chunker: whole sentences up to the limit,
  // whitespace word runs for a giant sentence, and never a hard cut inside a token.
  let ahead = 0;
  segments = segments.flatMap((segment) => {
    const length = readLength(segment.read);
    if (length <= prosodyBudget(ahead, maxChars)) { ahead += length + 1; return [segment]; }
    const pieces: { start: number; end: number; length: number }[] = [];
    const starts = sentenceStarts(segment);
    starts.forEach((from, i) => {
      const span = trim(from, starts[i + 1] ?? segment.read.end);
      if (span.end <= span.start) return;
      if (span.end - span.start <= maxChars) { pieces.push({ ...span, length: span.end - span.start }); return; }
      let run: (typeof pieces)[number] | undefined;
      for (const word of readText.slice(span.start, span.end).matchAll(/\S+/g)) {
        const at = span.start + word.index;
        if (run && run.length + 1 + word[0].length <= maxChars) { run.end = at + word[0].length; run.length += 1 + word[0].length; }
        else pieces.push(run = { start: at, end: at + word[0].length, length: word[0].length });
      }
    });
    const packed: typeof pieces = [];
    for (const piece of pieces) {
      const last = packed.at(-1);
      if (last && last.length + 1 + piece.length <= prosodyBudget(ahead, maxChars)) { last.end = piece.end; last.length += 1 + piece.length; }
      else { if (last) ahead += last.length + 1; packed.push({ ...piece }); }
    }
    ahead += (packed.at(-1)?.length ?? 0) + 1;
    const out: ProsodySegment[] = [];
    let rest: ProsodySegment & { item?: boolean } = segment;
    for (const piece of packed.slice(1)) {
      const [head, tail] = split(rest, piece.start, 0);
      head.pauseMs = TERMINAL.test(head.text) ? PAUSE.sentence : 0;
      out.push(head);
      rest = tail;
    }
    return [...out, rest];
  });

  if (input.ask) {
    const at = segments.findLastIndex((s) => (s.kind === "prose" || s.kind === "aside") && !(s as { item?: boolean }).item);
    const question = segments[at];
    if (question && /\?["'”’)]*$/.test(question.text)) {
      const cut = sentenceStarts(question).at(-1)!;
      if (WORD.test(readText.slice(question.read.start, cut))) segments.splice(at, 1, ...split(question, cut, PAUSE.askQuestion));
    }
  }

  for (const [i, segment] of segments.entries()) {
    const item = (segment as { item?: boolean }).item;
    if (!item && (segment.kind === "prose" || segment.kind === "aside") && TERMINAL.test(segment.text) && i < segments.length - 1)
      segment.pauseMs = Math.max(segment.pauseMs, PAUSE.sentence);
    if (segment.emphasis) segment.text = segment.text.endsWith(":") ? `${segment.text.slice(0, -1)}.` : TERMINAL.test(segment.text) ? segment.text : `${segment.text}.`;
    delete (segment as { item?: boolean }).item;
  }
  if (segments.length) segments.at(-1)!.pauseMs = 0;
  return { readText, speechText: segments.map((s) => s.text).join(" "), segments, chunks: planChunks(readText, segments, maxChars, input.concurrency ?? PROSODY_SYNTH_CONCURRENCY) };
}

/** Chunk 0 is the first utterance alone, so first audio waits for one short request. Chunk 1 fits
 * one concurrent round; every chunk stays within the ramp budget of the text queued before it. */
function planChunks(readText: string, segments: ProsodySegment[], maxChars: number, concurrency: number): ProsodyChunk[] {
  const groups: [number, number][] = [];
  let size = 0, before = 0;
  for (const [i, segment] of segments.entries()) {
    const group = groups.at(-1);
    const count = group ? group[1] - group[0] : 0;
    const length = readText.slice(segment.read.start, segment.read.end).trim().length;
    const fits = group && groups.length > 1 && size + 1 + length <= prosodyBudget(before, maxChars) && (groups.length > 2 || count < concurrency);
    if (fits) { group[1] = i + 1; size += 1 + length; }
    else { before += group ? size + 1 : 0; groups.push([i, i + 1]); size = length; }
  }
  return groups.map(([first, end], i) => {
    const start = i === 0 ? 0 : segments[first].read.start;
    const stop = groups[i + 1] ? segments[groups[i + 1][0]].read.start : readText.length;
    return { first, end, read: { start, end: stop }, text: readText.slice(start, stop).trim(), trailingPauseMs: segments[end - 1].pauseMs };
  });
}
