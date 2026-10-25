/** Bare word/word is also a legal relative path. Only known prose alternatives
 * are disambiguated; explicit paths, URLs and numeric slash syntax stay lexical. */
export const proseSlashPattern = /(?<![\w./\\:-])(?:list\/paragraph|completion\/cancellation|and\/or)(?![\w/\\-]|\.[\w])/g;

/** Keep slash glyphs in the raw display, attached to the following word. */
export function displayTokens(text: string): {0: string; index: number}[] {
  const cuts = new Set(Array.from(text.matchAll(proseSlashPattern), m => m.index + m[0].indexOf("/")));
  return Array.from(text.matchAll(/\S+/gu)).flatMap(m => {
    const cut = Array.from(cuts).find(at => at > m.index && at < m.index + m[0].length);
    return cut === undefined ? [m] : [{0: m[0].slice(0, cut - m.index), index: m.index},
      {0: m[0].slice(cut - m.index), index: cut}];
  });
}
