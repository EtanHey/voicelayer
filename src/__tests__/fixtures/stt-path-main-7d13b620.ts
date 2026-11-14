/** Verbatim normalizePathTokens and replacePathTokenSpans from main 7d13b620. */
export function normalizePathTokens(text: string): string {
  let result = text.replace(
    /\b(in|at|under|inside)\s+-\s*,\s+is it\s+(?=~\s*\/)/giu,
    (_match, preposition: string) => `${preposition} `,
  );

  result = result.replace(/~\s*\/[^,;!?]*/gu, (match) =>
    match
      .replace(/\s*\/\s*/g, "/")
      .replace(/\s*-\s*/g, "-")
      .toLowerCase(),
  );

  result = replacePathTokenSpans(result, (match) => {
      if (/^\/[A-Za-z0-9-]+$/u.test(match.trim())) return match;
      if (/^[A-Za-z]+\s+\/\s*[A-Za-z0-9-]+$/u.test(match.trim())) {
        return match;
      }
      return match
        .replace(/\s*\/\s*/g, "/")
        .replace(/\s*-\s*/g, "-")
        .toLowerCase();
  });

  return result;
}

/** Match the existing path grammar in O(n), including hyphens in both roles.
 * Each state records the greedy accepted suffix end; 0 means no match.
 * This avoids exploring every partition of a run of hyphens on a near miss.
 */
function replacePathTokenSpans(text: string, replace: (match: string) => string): string {
  const size = text.length;
  const segment = new Int32Array(size + 1);
  const beforeSeparator = new Int32Array(size + 1);
  const afterSeparator = new Int32Array(size + 1);
  const firstSegment = new Int32Array(size + 1);
  const leadingSlash = new Uint8Array(size + 1);
  let slashAfterSpaces = false;
  for (let i = size - 1; i >= 0; i--) {
    const isSegment = /[A-Za-z0-9._~-]/u.test(text[i]);
    const isSpace = /\s/u.test(text[i]);
    slashAfterSpaces = isSpace ? slashAfterSpaces : text[i] === "/";
    leadingSlash[i] = isSegment ? leadingSlash[i + 1] : Number(slashAfterSpaces);
    if (isSegment) {
      const boundaryEnd = i + 1 === size || /\s/u.test(text[i + 1]) ? i + 1 : 0;
      segment[i] = segment[i + 1] || beforeSeparator[i + 1] || boundaryEnd;
      firstSegment[i] = firstSegment[i + 1] || beforeSeparator[i + 1];
    }
    afterSeparator[i] = isSpace ? afterSeparator[i + 1] : segment[i];
    beforeSeparator[i] = isSpace
      ? beforeSeparator[i + 1]
      : text[i] === "/" || text[i] === "-" ? afterSeparator[i + 1] : 0;
  }
  const parts: string[] = [];
  let cursor = 0;
  for (let index = 0; index < size; index++) {
    const end = firstSegment[index];
    if (index < cursor || end === 0 || !leadingSlash[index]) continue;
    if (index > 0 && !/\s/u.test(text[index - 1])) continue;
    parts.push(text.slice(cursor, index), replace(text.slice(index, end)));
    cursor = end;
  }
  parts.push(text.slice(cursor));
  return parts.join("");
}


export { normalizePathTokens as mainNormalizePathTokens };
