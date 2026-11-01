/** Compile an already escaped source (or the engine's proclitic group).
 * L/N/M/underscore neighbors are part of the occurrence, never delimiters.
 * An immediately trailing Unicode dash, U+2026 or ASCII ... marks an
 * unfinished surface: abstain without consuming or normalizing any bytes.
 */
export function dictionaryOccurrencePattern(source: string): RegExp {
  return new RegExp(`(?<![\\p{L}\\p{N}\\p{M}_])${source}(?![\\p{L}\\p{N}\\p{M}_]|[\\p{Pd}]|…|\\.\\.\\.)`, "giu");
}

/** Only whole stored surfaces, never a substring of another address/word. */
export function dictionarySurfacePattern(from: string, to = from): RegExp {
  const escaped = from.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  if (from.includes("@") || to.includes("@")) {
    // RFC local-part punctuation can continue an address before this surface.
    // A single opening quote is a delimiter only when it is not attached to a
    // preceding local part: 'miss@…' is quoted; o'miss@… is another address.
    const local = "\\p{L}\\p{N}\\p{M}!#$%&'*+/=?^_`{|}~@.\\-";
    const plainLeft = "(?<![" + local + "])";
    const quotedLeft = "(?<=(?<![" + local + "])')";
    // Terminal sentence punctuation/quotes may follow the complete domain;
    // punctuation continuing a longer surface must not authorize replacement.
    const right = "(?![\\p{L}\\p{N}\\p{M}_%+@\\-]|\\.(?=[" + local + "])|[!#$&'*+/=?^`{|}~](?=[" + local + "]))";
    return new RegExp("(?:" + plainLeft + escaped + right + "|" + quotedLeft + escaped + "(?='(?![" + local + "])))", "giu");
  }
  return dictionaryOccurrencePattern(escaped);
}

/** A stored surface inside a different quoted-local address is not authority
 * to change that address. Quotes around a standalone address remain eligible.
 * Apply this to each actual match, so unrelated nearby addresses do not veto it. */
export function isWholeDictionarySurface(
  text: string, start: number, end: number, from: string, to = from,
): boolean {
  if (/^(?:[\p{Pd}]|…|\.\.\.)/u.test(text.slice(end))) return false;
  // Fences are line-delimited. Backticks in a string inside a fence cannot
  // close it, and a closing run may be longer than the opening run.
  const fenced: Array<{ start: number; end: number }> = [];
  let fenceStart = -1, fenceCharacter = "", fenceLength = 0;
  for (const line of text.matchAll(/^.*(?:\n|$)/gm)) {
    const body = line[0].replace(/\r?\n$/u, "");
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/u.exec(body);
    if (!marker) continue;
    if (fenceStart < 0) {
      if (marker[1]![0] === "`" && marker[2]!.includes("`")) continue;
      fenceStart = line.index!;
      fenceCharacter = marker[1]![0]!;
      fenceLength = marker[1]!.length;
    } else if (
      marker[1]![0] === fenceCharacter &&
      marker[1]!.length >= fenceLength &&
      /^\s*$/u.test(marker[2]!)
    ) {
      fenced.push({ start: fenceStart, end: line.index! + line[0].length });
      fenceStart = -1;
    }
  }
  if (fenceStart >= 0) fenced.push({ start: fenceStart, end: text.length });
  if (fenced.some((span) => start < span.end && end > span.start)) return false;

  // Stored prose variants are not permission to rewrite inline code either,
  // including an unfinished span. Fence delimiters are not inline delimiters.
  let codeStart = -1, delimiterLength = 0;
  for (const delimiter of text.matchAll(/`+/gu)) {
    const offset = delimiter.index!;
    if (fenced.some((span) => offset >= span.start && offset < span.end)) continue;
    // An escaped backtick is ordinary text (an even backslash run is not).
    let escapes = 0;
    for (let index = offset - 1; index >= 0 && text[index] === "\\"; index--) escapes++;
    if (escapes % 2) continue;
    if (codeStart < 0) {
      codeStart = offset; delimiterLength = delimiter[0].length;
    } else if (delimiter[0].length === delimiterLength) {
      if (start < offset + delimiterLength && end > codeStart) return false;
      codeStart = -1;
    }
  }
  if (codeStart >= 0 && end > codeStart) return false;
  const left = text.slice(0, start), right = text.slice(end);
  // An occurrence within a longer address/path/identifier is not the stored
  // surface. A terminal sentence dot/colon and quotes remain delimiters.
  // Whole stored addresses and command/path variants still pass these checks.
  if (/[\/\\@._\p{Pd}]$/u.test(left) || /::$/u.test(left)) return false;
  if (/^(?:[\/\\@_]|\.[\p{L}\p{N}_]|::|['’][\p{L}\p{N}])/u.test(right)) return false;
  if (!from.includes("@") && !to.includes("@")) return true;
  const envelopes = /"(?:\\[\s\S]|[^"\\\r\n])*"@(?:\[[^\]\r\n]+\]|[\p{L}\p{N}](?:[\p{L}\p{N}.\-]*[\p{L}\p{N}])?)/gu;
  for (const envelope of text.matchAll(envelopes)) {
    const left = envelope.index!, right = left + envelope[0].length;
    if (start < right && end > left && (start !== left || end !== right)) return false;
  }
  return true;
}
