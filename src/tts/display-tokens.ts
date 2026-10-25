/** Bare word/word is also a legal relative path. Only known prose alternatives
 * are disambiguated; explicit paths, URLs and numeric slash syntax stay lexical. */
export const proseSlashPattern = /(?<![\p{L}\p{M}\p{N}_./\\:`-])(?:list\/paragraph|completion\/cancellation)(?![\p{L}\p{M}\p{N}_/\\`-]|\.[\p{L}\p{M}\p{N}_])/gu;

/** Consume backtick code spans before considering prose alternatives. */
export function proseSlashMatches(text: string) {
  const pattern = new RegExp("`+[^`]*`+|" + proseSlashPattern.source, "gu");
  return Array.from(text.matchAll(pattern)).filter(m => !m[0].startsWith("`"));
}

/** Keep slash glyphs in the raw display, attached to the following word. */
export function displayTokens(text: string): {0: string; index: number}[] {
  const cuts = new Set(proseSlashMatches(text).map(m => m.index + m[0].indexOf("/")));
  return Array.from(text.matchAll(/\S+/gu)).flatMap(m => {
    const boundaries = [m.index, ...Array.from(cuts).filter(at => at > m.index && at < m.index + m[0].length), m.index + m[0].length];
    return boundaries.slice(0, -1).map((at, i) => ({0: m[0].slice(at - m.index, boundaries[i + 1] - m.index), index: at}));
  });
}
