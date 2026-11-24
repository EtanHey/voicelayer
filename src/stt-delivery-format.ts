import { inlineCodeSpans, isConditionalContinuation } from "./stt-coherent-paragraphs";
import { canonicalizeMarkedFillerFragments } from "./rules-engine";

/** Byte ranges, including unclosed literals: ambiguity keeps literal bytes. */
function literalRanges(text: string): Array<{ start: number; end: number }> {
  const ranges = inlineCodeSpans(text, true) ?? [];
  const fences = [...text.matchAll(/^[ \t]*(~{3,})[^\r\n]*(?:\r?\n|$)/gmu)];
  for (let i = 0; i < fences.length; i++) {
    const open = fences[i]; let close = i + 1;
    while (close < fences.length && fences[close][1].length < open[1].length) close++;
    ranges.push({ start: open.index!, end: close < fences.length
      ? fences[close].index! + fences[close][0].length : text.length });
    i = close;
  }
  for (const m of text.matchAll(/\S+/gu)) {
    if (/^(?:https?:\/\/|www\.|~\/|\.{1,2}\/|\/|[A-Za-z]:\\)/iu.test(m[0]) ||
        /[\\/]/u.test(m[0]) || /^[\w.—-]+\.[A-Za-z0-9]{1,8}[,;.!?]?$/u.test(m[0])) {
      ranges.push({ start: m.index!, end: m.index! + m[0].length });
    }
  }
  for (const m of text.matchAll(/"[^"\r\n]*[\\/][^"\r\n]*"/gu)) ranges.push({ start: m.index!, end: m.index! + m[0].length });
  return ranges.sort((a, b) => a.start - b.start);
}

function outsideLiterals(text: string, change: (prose: string, offset: number) => string): string {
  let from = 0, out = "";
  for (const range of literalRanges(text)) {
    if (range.end <= from) continue;
    const start = Math.max(from, range.start);
    out += change(text.slice(from, start), from) + text.slice(start, range.end);
    from = range.end;
  }
  return out + change(text.slice(from), from);
}

/** Canonicalize ONLY rules-marked fragments before model fidelity validation. */
export function canonicalDeliveryInput(text: string): string {
  return outsideLiterals(text, canonicalizeMarkedFillerFragments);
}

/** Preserve cutoff and range meaning before formatting other prose dashes as commas. */
export function formatDeliveryDashes(text: string): string {
  return outsideLiterals(text, (prose, offset) => prose.replace(
    /([,;:.!?]?)[^\S\r\n]*—[^\S\r\n]*([,;:.!?]?)[^\S\r\n]*/gu,
    (all: string, left: string, right: string, at: number) => {
      const before = text.slice(0, offset + at);
      const following = text.slice(offset + at + all.length);
      const previous = before.at(-1);
      // Numeric ranges are not clause separators, even with surrounding spaces.
      if (!left && !right && /\d$/u.test(before) && /^\d/u.test(following)) return "–";
      // A list marker at the beginning of a line must not invent a comma.
      if (/^[ \t]*$/u.test(before.slice(before.lastIndexOf("\n") + 1))) return all.match(/^[ \t]*/u)![0];
      const fragment = !left && /^[—]/u.test(all) ? before.match(/[\p{L}\p{M}]+$/u)?.[0] : undefined;
      const restart = following.match(/^[\p{L}\p{M}]+/u)?.[0];
      if (fragment && restart?.toLowerCase().startsWith(fragment.toLowerCase())) return "… ";
      const punctuation = left || right || (previous && /[,;:.!?]/u.test(previous) ? "" : ",");
      const next = text[offset + at + all.length];
      return punctuation + (next && !/[\r\n]/u.test(next) ? " " : "");
    }));
}

/** Only a newly automatic break is ours. Supplied layout is never inferred away. */
export function joinAutomaticConditionalParagraphs(source: string, candidate: string): string {
  if (/[\r\n]/u.test(source)) return candidate;
  return candidate.replace(/([.!?]["'”’»)\]]*)[^\S\r\n]*\r?\n(?:[^\S\r\n]*\r?\n)+[^\S\r\n]*(?=\S)/gu,
    (gap: string, terminal: string, at: number) => {
      const preceding = candidate.slice(0, at).split(/\r?\n\s*\r?\n/u).at(-1)!;
      if (/(?:^|\n)[ \t]*(?:[-*•]|\d+[.)]|#{1,6})[ \t]+/u.test(preceding)) return gap;
      return isConditionalContinuation(candidate.slice(at + gap.length)) ? terminal + " " : gap;
    });
}
