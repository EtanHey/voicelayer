import { inlineCodeSpans, isConditionalContinuation } from "./stt-coherent-paragraphs";
import { canonicalizeMarkedFillerFragments } from "./rules-engine";

/** Byte ranges, including unclosed literals: ambiguity keeps literal bytes. */
function literalRanges(text: string): Array<{ start: number; end: number }> {
  const ranges: Array<{ start: number; end: number }> = [];
  const fences = [...text.matchAll(/^[ \t]*(`{3,}|~{3,})([^\r\n]*)(?:\r?\n|$)/gmu)];
  for (let i = 0; i < fences.length; i++) {
    const open = fences[i];
    if (open[1][0] === "`" && open[2].includes("`")) continue;
    let close = i + 1;
    for (; close < fences.length; close++) {
      const [, marker, suffix] = fences[close];
      if (marker[0] === open[1][0] && marker.length >= open[1].length && /^[ \t]*$/u.test(suffix)) break;
    }
    ranges.push({ start: open.index!, end: close < fences.length
      ? fences[close].index! + fences[close][0].length : text.length });
    i = close;
  }
  // Backticks inside a fenced block cannot open an inline span in the surrounding prose.
  const prose: string[] = [];
  let from = 0;
  for (const { start, end } of ranges) {
    prose.push(text.slice(from, start), text.slice(start, end).replace(/`/gu, " "));
    from = end;
  }
  prose.push(text.slice(from));
  ranges.push(...(inlineCodeSpans(prose.join(""), true) ?? []));
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

/** Mark source cutoffs before polish can change the dash spacing. */
export function canonicalDeliveryInput(text: string): string {
  return rewriteDeliveryDashes(outsideLiterals(text, canonicalizeMarkedFillerFragments), true);
}

/** Preserve cutoff and range meaning before formatting other prose dashes as commas. */
export function formatDeliveryDashes(text: string): string {
  return rewriteDeliveryDashes(text, false);
}

function rewriteDeliveryDashes(text: string, cutoffsOnly: boolean): string {
  return outsideLiterals(text, (prose, offset) => prose.replace(
    /([,;:.!?]?)[^\S\r\n]*—[^\S\r\n]*([,;:.!?]?)[^\S\r\n]*/gu,
    (all: string, left: string, right: string, at: number) => {
      const before = text.slice(0, offset + at);
      const following = text.slice(offset + at + all.length);
      const previous = before.at(-1);
      // Numeric ranges are not clause separators, even with surrounding spaces.
      if (!left && !right && /\d$/u.test(before) && /^\d/u.test(following)) return cutoffsOnly ? all : "–";
      // A list marker at the beginning of a line must not invent a comma.
      if (/^[ \t]*$/u.test(before.slice(before.lastIndexOf("\n") + 1))) return cutoffsOnly ? all : all.match(/^[ \t]*/u)![0];
      const fragment = !left && /^[—]/u.test(all) ? before.match(/[\p{L}\p{M}]+$/u)?.[0] : undefined;
      const restart = following.match(/^[\p{L}\p{M}]+/u)?.[0];
      if (fragment && restart?.toLowerCase().startsWith(fragment.toLowerCase())) return "… ";
      // A word cut off by a dash that the next word does not follow directly ("fu— no wait", or a
      // take that ends on "fu—") is an interruption, not a clause break: keep it as the ellipsis
      // fragment even when the restart does not repeat the same letters.
      if (fragment && (all.length > 1 || following === "")) {
        const gap = following === "" || /^[\r\n]/u.test(following) ? "" : " ";
        return "…" + gap;
      }
      if (cutoffsOnly) return all;
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
