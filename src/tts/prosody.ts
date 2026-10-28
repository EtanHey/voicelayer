import type { SpeakableText } from "../speakable-text";
import { createHash } from "node:crypto";
import { projectStructuredSpeech, type ProjectionRange, type StructuredSpeech, type TextRange } from "./structured-speech";

/** Total silence (ms) from the last word of one utterance to the first of the next. */
export const PROSODY_POLICY = Object.freeze({
  version: "vl-structural-pauses-v1",
  cloneEmphasis: "none",
  pauses: Object.freeze({ heading: 800, h1: 900, h2: 750, beforeHeading: 600,
    label: 320, listIntro: 600, shortItem: 450, longItem: 700,
    sentence: 550, paragraph: 1000, beforeAside: 200, afterAside: 300, askQuestion: 600,
    number: 250, longNumber: 280 }),
});
/** Same limit as the long-read chunker (TTS_CHUNK_MAX_CHARS); one owner of request size. */
export const PROSODY_MAX_CHARS = 400;
export const CLONE_CHUNK_POLICY = Object.freeze({ synthMsPerChar: 48, playbackMsPerChar: 65, bodyMaxChars: 200, lookahead: 2 as const });
export function createCloneChunkBudget(maxChars = PROSODY_MAX_CHARS, playbackSpeed = 1) {
  const playbackStarts: number[] = [];
  let playbackEnd = 0, synthesisEnd = 0, previousPauseMs = 0;
  const synthesisStart = () => Math.max(synthesisEnd, playbackStarts.at(-CLONE_CHUNK_POLICY.lookahead) ?? 0);
  return {
    chars() {
      return playbackStarts.length === 0 ? maxChars : Math.max(1, Math.min(maxChars, CLONE_CHUNK_POLICY.bodyMaxChars,
        Math.floor((playbackEnd - synthesisStart()) / CLONE_CHUNK_POLICY.synthMsPerChar)));
    },
    append(chars: number, pauseMs = 0) {
      if (playbackStarts.length) synthesisEnd = synthesisStart() + chars * CLONE_CHUNK_POLICY.synthMsPerChar;
      const start = Math.max(playbackEnd, synthesisEnd);
      playbackEnd = start + chars * CLONE_CHUNK_POLICY.playbackMsPerChar / playbackSpeed + previousPauseMs;
      previousPauseMs = pauseMs;
      playbackStarts.push(start);
      if (playbackStarts.length > CLONE_CHUNK_POLICY.lookahead) playbackStarts.shift();
    },
  };
}
/** Engine requests in flight at once for one read. */
export const PROSODY_SYNTH_CONCURRENCY = 3;
/** Request-size ramp, in projected speech characters. Speech plays at ~15 chars/s (MS_PER_CHAR) while an
 * engine renders far faster, so audio already queued ahead (words and planned pauses) covers the synthesis
 * of about RAMP times its length. Nothing ahead: the full limit, like the long-read chunker's first chunk.
 * FAST_MIN (~6–8 words) is the smallest request worth splitting off. */
const RAMP = 8, FAST_MIN = 40, MS_PER_CHAR = 65;
export function prosodyBudget(charsAhead: number, maxChars = PROSODY_MAX_CHARS): number {
  return charsAhead === 0 ? maxChars : Math.min(maxChars, Math.max(FAST_MIN, RAMP * charsAhead));
}

export type ProsodySegmentKind = "heading" | "label" | "prose" | "item" | "aside" | "number";
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
  renderIdentity: string;
  pausePlacement?: "trailing";
  readText: string;
  /** Engine texts joined by single spaces: what the synthesizer and the clone aligner receive. */
  speechText: string;
  segments: ProsodySegment[];
  chunks: ProsodyChunk[];
}
export interface ProsodyInput {
  playbackSpeed?: number;
  engine?: "edge" | "clone";
  policy?: { version: string; cloneEmphasis: "none"; pauses: { [K in keyof typeof PROSODY_POLICY.pauses]: number } };
  /** The text the read is about: sanitized markdown (speak), or flattened structured speech (selection). */
  readText: string;
  /** Main's projection of `readText`, computed once by the caller; never redone per fragment. */
  projection: SpeakableText;
  /** Selection reads: the source structure whose `speechText` is `readText`. */
  structure?: StructuredSpeech;
  /** voice_ask: pause before the question itself. */
  ask?: boolean;
  /** "separate" (default): a spoken list number is its own utterance, followed by the number pause.
   * "inline": it stays inside the item request (engines that fail on one-word requests). */
  listNumbers?: "separate" | "inline";
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
export function mapper(ranges: readonly ProjectionRange[], side: "source" | "display" = "source") {
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
  const policy = input.policy ?? PROSODY_POLICY;
  const PAUSE = policy.pauses;
  if (projection.displayText !== readText) throw new Error("Prosody projection must be of the read text");
  const clone = input.engine === "clone";
  const maxChars = input.maxChars ?? PROSODY_MAX_CHARS;
  const structured = input.structure?.speechText === readText ? input.structure : undefined;
  const source = structured?.displayText ?? readText;
  const blocks = (structured ?? projectStructuredSpeech(readText)).blocks;
  const readAt = structured ? mapper(structured.ranges) : (offset: number) => offset;
  const speechAt = mapper(projection.ranges);
  const spoken = (read: number) => projection.ranges.some((r) => r.kind === "identity" && r.source.start <= read && read < r.source.end);

  const units: Unit[] = [];
  /** Read offsets just after each inline list number's delimiter ("1." → after "."). */
  const markers: number[] = [];
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
  const label = (lineStart: number, lineEnd: number, content: number, item: boolean, readFrom = readAt(lineStart)) => {
    const match = source.slice(content, lineEnd).match(LABEL);
    // A label names what follows: it carries a colon. Plain inline emphasis is prose.
    if (!match || !(match[2].endsWith(":") || match[3])) return false;
    const sourceEnd = content + match[0].length;
    let end: number;
    if (!structured) end = sourceEnd;
    else {
      const readLine = readText.slice(readFrom, readAt(lineEnd));
      const text = match[2].replace(/[*_`]/g, "") + match[3];
      const lead = readLine.length - readLine.trimStart().length;
      if (!readLine.startsWith(text, lead)) return false;
      end = readFrom + lead + text.length;
    }
    push(readFrom, "label", PAUSE.label, true, item);
    push(end, item ? "item" : "prose", 0, false, item);
    return end;
  };

  /** Read offset just after a numbered marker ("1. ", "100) "), if the item has one. */
  function numberEnd(start: number, lineEnd: number, raw: string): number | undefined {
    const marker = raw.match(/^[ \t]*\d+[.)][ \t]+/)?.[0];
    if (!marker) return undefined;
    if (!structured) return start + marker.length;
    const readStart = readAt(start), readLine = readText.slice(readStart, readAt(lineEnd));
    const lead = readLine.length - readLine.trimStart().length;
    const kept = readLine.slice(lead).match(/^\d+[.)][ \t]+/)?.[0];
    return kept ? readStart + lead + kept.length : undefined;
  }

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
      const words = source.slice(start + marker, lineEnd).split(/\s+/).filter((w) => WORD.test(w)).length;
      const long = words >= 6;
      // A spoken number ("one.", "1.", "100.") is its own utterance: the item starts after it.
      let content = readAt(start);
      const numbered = numberEnd(start, lineEnd, raw);
      // An inline number stays in the item request; remember where its delimiter sits in the read.
      if (input.listNumbers === "inline" && numbered !== undefined) markers.push(readText.slice(0, numbered).trimEnd().length);
      const number = input.listNumbers === "inline" ? undefined : numbered;
      if (number !== undefined && WORD.test(projection.speechText.slice(speechAt(content), speechAt(number)))) {
        push(content, "number", long ? PAUSE.longNumber : PAUSE.number, false, true);
        content = number;
      }
      const body = label(start, lineEnd, start + marker, true, content);
      if (body === false) push(content, "item", 0, false, true);
      asides(body === false ? content : body, readAt(lineEnd), raw, true);
      pause(long ? PAUSE.longItem : PAUSE.shortItem);
      fresh = true;
      continue;
    }
    // Paragraph, code and table blocks: a soft wrap or an adjacent code/table block is not a boundary.
    // A continuation line is structural only inside a run of label/heading lines ("**A:** x\n**B:** y").
    let structuralLine = true;
    for (const line of raw.matchAll(/[^\r\n]*(?:\r\n|\r|\n|$)/g)) {
      if (!line[0]) break;
      const text = line[0].replace(/[\r\n]+$/, "");
      const lineStart = start + line.index, lineEnd = lineStart + text.length;
      if (!text.trim()) continue;
      const structural: boolean = block.kind === "paragraph" && structuralLine;
      if (structural && BOLD_LINE.test(text) && !/:[*_]*\s*$/.test(text)) {
        if (units.length) pause(PAUSE.beforeHeading);
        push(readAt(lineStart), "heading", PAUSE.heading, true);
        fresh = true;
        continue;
      }
      const body: number | false = structural ? label(lineStart, lineEnd, lineStart + (text.length - text.trimStart().length), false) : false;
      structuralLine = body !== false;
      if (body === false && fresh) push(readAt(lineStart), "prose");
      fresh = false;
      if (block.kind === "paragraph") asides(body === false ? readAt(lineStart) : body, readAt(lineEnd), text, false);
    }
    const next = blocks.slice(index + 1).find((b) => b.kind !== "separator");
    if (/:\s*$/.test(raw) && next?.kind === "list-item") pause(PAUSE.listIntro);
  }

  // Read spans → engine spans. Units are cut points; an utterance without words joins its neighbour.
  let segments = mergeWordless(units.flatMap((unit, i) => {
    const readStart = i === 0 ? 0 : unit.at, readEnd = units[i + 1]?.at ?? readText.length;
    return readEnd < readStart ? [] : [makeSegment(unit, readStart, readEnd)];
  }));

  /** Every phase that cuts ends here: no engine request without a word, read ownership preserved. */
  function mergeWordless(list: (ProsodySegment & { item?: boolean })[]) {
    const out: (ProsodySegment & { item?: boolean })[] = [];
    let carry: number | undefined;
    for (const segment of list) {
      const current = carry === undefined ? segment : { ...makeSegment(segment, carry, segment.read.end), pauseMs: segment.pauseMs };
      if (WORD.test(current.text)) { out.push(current); carry = undefined; continue; }
      const previous = out.at(-1);
      if (previous) out[out.length - 1] = { ...makeSegment(previous, previous.read.start, current.read.end), pauseMs: Math.max(previous.pauseMs, current.pauseMs) };
      else carry = current.read.start;
    }
    if (!out.length && projection.speechText.trim()) return [makeSegment({ kind: "prose", emphasis: false, pauseMs: 0 }, 0, readText.length)];
    if (carry !== undefined && out.length) out[out.length - 1] = { ...makeSegment(out.at(-1)!, out.at(-1)!.read.start, readText.length), pauseMs: out.at(-1)!.pauseMs };
    return out;
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
  /** A cut is valid only outside atomic projection edits: a replacement is never split. */
  const clean = (read: number) => !projection.ranges.some((r) => r.kind !== "identity" && r.source.start < read && read < r.source.end);
  /** Engine request size: projected speech characters, trimmed. */
  const speechLength = (start: number, end: number) => makeSegment({ kind: "prose", emphasis: false, pauseMs: 0 }, start, end).text.length;
  /** Both halves keep the kind and emphasis; only the last piece of an utterance closes it with a period. */
  const split = (segment: ProsodySegment & { item?: boolean }, cut: number, pauseMs: number) => [
    { ...makeSegment(segment, segment.read.start, cut), pauseMs, continues: segment.emphasis },
    makeSegment(segment, cut, segment.read.end),
  ];

  // Size the requests. Whole sentences pack up to the budget, like the long-read chunker; a sentence
  // over the budget splits into whitespace word runs. The budget ramps with the audio queued ahead,
  // so a request after a short label or heading is ready before that audio ends. Cuts never fall
  // inside a token or an atomic replacement; an oversized replacement stays one whole request.
  let ahead = 0;
  const cloneBudget = createCloneChunkBudget(maxChars, input.playbackSpeed);
  const budget = () => clone ? cloneBudget.chars() : prosodyBudget(ahead, maxChars);
  segments = mergeWordless(segments.flatMap((segment) => {
    if (segment.text.length <= budget()) {
      ahead += segment.text.length + 1 + segment.pauseMs / MS_PER_CHAR;
      cloneBudget.append(segment.text.length + (segment.emphasis && !TERMINAL.test(segment.text) ? 1 : 0), segment.pauseMs);
      return [segment];
    }
    const sentences: TextRange[] = [];
    const starts = sentenceStarts(segment);
    starts.forEach((from, i) => {
      const span = trim(from, starts[i + 1] ?? segment.read.end);
      if (span.end <= span.start) return;
      const last = sentences.at(-1);
      if (last && !clean(span.start)) last.end = span.end; else sentences.push(span);
    });
    const pieces: TextRange[] = [];
    let current: TextRange | undefined;
    const emit = () => {
      const length = speechLength(current!.start, current!.end);
      ahead += length + 1 + (TERMINAL.test(readText.slice(current!.start, current!.end)) ? PAUSE.sentence / MS_PER_CHAR : 0);
      cloneBudget.append(length + (segment.emphasis && current!.end === trim(segment.read.start, segment.read.end).end ? 1 : 0),
        current!.end === trim(segment.read.start, segment.read.end).end ? segment.pauseMs
          : !segment.emphasis && TERMINAL.test(readText.slice(current!.start, current!.end)) ? PAUSE.sentence : 0);
      pieces.push(current!); current = undefined;
    };
    for (const sentence of sentences) {
      if (current && speechLength(current.start, sentence.end) <= budget()) { current.end = sentence.end; continue; }
      if (current) emit();
      if (speechLength(sentence.start, sentence.end) <= budget()) { current = { ...sentence }; continue; }
      const words = [...readText.slice(sentence.start, sentence.end).matchAll(/\S+/g)]
        .map((w) => sentence.start + w.index).filter((at, i) => i === 0 || clean(at));
      words.forEach((at, i) => {
        const word = trim(at, words[i + 1] ?? sentence.end);
        // Word runs are never longer than the long-read chunker's own word split (read characters).
        if (current && Math.max(speechLength(current.start, word.end), word.end - current.start) <= budget()) { current.end = word.end; return; }
        if (current) emit();
        current = word;
      });
    }
    if (current) emit();
    ahead += segment.pauseMs / MS_PER_CHAR;
    const out: ProsodySegment[] = [];
    let rest: ProsodySegment & { item?: boolean } = segment;
    for (const piece of pieces.slice(1)) {
      const [head, tail] = split(rest, piece.start, 0);
      head.pauseMs = !head.emphasis && TERMINAL.test(head.text) ? PAUSE.sentence : 0;
      out.push(head);
      rest = tail;
    }
    return [...out, rest];
  }));

  if (input.ask) {
    const at = segments.findLastIndex((s) => (s.kind === "prose" || s.kind === "aside") && !(s as { item?: boolean }).item);
    const question = segments[at];
    if (question && /\?["'”’)]*$/.test(question.text)) {
      const cut = trim(sentenceStarts(question).at(-1)!, question.read.end).start;
      if (clean(cut) && WORD.test(readText.slice(question.read.start, cut))) {
        segments.splice(at, 1, ...split(question, cut, PAUSE.askQuestion));
        segments = mergeWordless(segments);
      }
    }
  }

  for (const [i, segment] of segments.entries()) {
    const item = (segment as { item?: boolean }).item;
    if (clone && input.listNumbers === "inline" && item) {
      // Only the segment holding the item's own marker; a later body segment ("2025. It shipped.") keeps its stop.
      const marker = markers.find((at) => segment.read.start < at && at <= segment.read.end);
      if (marker !== undefined) {
        const delimiter = speechAt(marker) - segment.speech.start - 1;
        if (segment.text[delimiter] === ".")
          segment.text = segment.text.slice(0, delimiter) + "," + segment.text.slice(delimiter + 1);
      }
    }
    if (!item && (segment.kind === "prose" || segment.kind === "aside") && TERMINAL.test(segment.text) && i < segments.length - 1)
      segment.pauseMs = Math.max(segment.pauseMs, PAUSE.sentence);
    const continues = (segment as { continues?: boolean }).continues;
    delete (segment as { continues?: boolean }).continues;
    if (segment.emphasis && !continues) segment.text = segment.text.endsWith(":") ? `${segment.text.slice(0, -1)}.` : TERMINAL.test(segment.text) ? segment.text : `${segment.text}.`;
    delete (segment as { item?: boolean }).item;
  }
  if (segments.length) segments.at(-1)!.pauseMs = 0;
  const chunks = planChunks(readText, segments, maxChars, input.concurrency ?? PROSODY_SYNTH_CONCURRENCY, clone);
  let renderIdentity: string | undefined;
  return { readText, speechText: segments.map((s) => s.text).join(" "), segments, chunks,
    ...(clone ? { pausePlacement: "trailing" as const } : {}),
    get renderIdentity() { return renderIdentity ??= createHash("sha256").update(JSON.stringify([
      policy, projection, segments, chunks, ...(clone ? ["trailing-pauses-v1"] : []),
    ])).digest("hex"); } };
}

function planChunks(readText: string, segments: ProsodySegment[], maxChars: number, concurrency: number, clone: boolean): ProsodyChunk[] {
  const groups: [number, number][] = [];
  let size = 0, before = 0;
  for (const [i, segment] of segments.entries()) {
    const group = groups.at(-1);
    const count = group ? group[1] - group[0] : 0;
    const length = segment.text.length;
    const fits = !clone && group && groups.length > 1 && size + 1 + length <= prosodyBudget(before, maxChars)
      && (groups.length > 2 || count < concurrency);
    if (fits) { group[1] = i + 1; size += 1 + length; }
    else {
      if (group) before += size + 1 + segments.slice(group[0], group[1]).reduce((ms, s) => ms + s.pauseMs, 0) / MS_PER_CHAR;
      groups.push([i, i + 1]); size = length;
    }
  }
  return groups.map(([first, end], i) => {
    const start = i === 0 ? 0 : segments[first].read.start;
    const stop = groups[i + 1] ? segments[groups[i + 1][0]].read.start : readText.length;
    return { first, end, read: { start, end: stop }, text: readText.slice(start, stop).trim(), trailingPauseMs: segments[end - 1].pauseMs };
  });
}
