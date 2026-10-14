/** Convert markdown to speech text without fetching links or evaluating code. */
export function markdownToSpeech(markdown: string): string {
  const lines: string[] = [];
  for (const raw of speechLinesFromFences(markdown)) {
    if (/^\s*\[[^\]]+\]:\s*\S+/.test(raw) || /^\s*([-*_])(?:\s*\1){2,}\s*$/.test(raw) || /^\s*=+\s*$/.test(raw)) continue;
    let line = raw.replace(/^\s{0,3}#{1,6}\s+/, "").replace(/\s+#+\s*$/, "").replace(/^\s*>\s?/, "");
    if (/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line)) continue;
    const list = /^\s*(?:[-+*]|\d+[.)])\s+/.test(line);
    line = line.replace(/^\s*(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, "");
    line = stripInlineLinkTargets(line)
      .replace(/!?\[([^\]]+)\]\[[^\]]*\]/g, "$1")
      .replace(/<https?:\/\/[^>]+>/gi, "link")
      .replace(/(?:https?:\/\/|www\.)[^\s<>]+/gi, (url) => `link${url.match(/[.,!?;:]+$/)?.[0] ?? ""}`)
      .replace(/`+/g, "").replace(/\*\*/g, "").replace(/\*([^*]+)\*/g, "$1")
      // Prefer identifiers for ambiguous __word__; strip underscores only at boundaries.
      .replace(/(?<![\p{L}\p{N}_])__([^_\n]*\s[^_\n]*)__(?![\p{L}\p{N}_])/gu, "$1")
      .replace(/(?<![\p{L}\p{N}_])_([^_\n]+)_(?![\p{L}\p{N}_])/gu, "$1");
    if (line.includes("|")) line = line.trim().replace(/^\||\|$/g, "").split("|").map((cell) => cell.trim()).filter(Boolean).join(", ");
    line = line.trim();
    if (line && (list || raw.includes("|")) && !/[.!?…。！？]$/.test(line)) line += ".";
    if (line) lines.push(line);
  }
  return lines.join(" ").replace(/\s+/g, " ").trim();
}

function stripInlineLinkTargets(line: string): string {
  const start = /!?\[([^\[\]\n]*)\]\(/g;
  const pieces: string[] = [];
  let copiedThrough = 0;
  for (let match = start.exec(line); match; match = start.exec(line)) {
    let depth = 1;
    let end = start.lastIndex;
    for (; end < line.length && depth > 0; end++) {
      if (line[end] === "\\") { end++; continue; }
      if (line[end] === "(") depth++;
      if (line[end] === ")") depth--;
    }
    if (depth > 0) break;
    pieces.push(line.slice(copiedThrough, match.index), match[1]);
    copiedThrough = end;
    start.lastIndex = end;
  }
  pieces.push(line.slice(copiedThrough));
  return pieces.join("");
}

/** Recognize syntax only; unknown lines in a partial selection are retained as prose. */
function looksLikeCode(line: string): boolean {
  const text = line.trim();
  return /^(?:const|let|var)\s+[\w$]+\s*(?:=|:)/.test(text) ||
    /^(?:(?:import|from)\s+[\w."'{}*]|(?:def|class|function)\s+\w+\s*[(:{])/.test(text) ||
    /^(?:[\w$]+\.)*[\w$]+\([^)]*\)\s*;?$/.test(text) ||
    /^(?:[{}[\];]+|\/\/.*)$/.test(text);
}

/**
 * Complete fences are unambiguous. For incomplete selections, remove only recognizable
 * code and preserve every unknown/prose line. A code-only prefix before a bare fence is
 * a selection starting inside code: that fence closes the prefix, not the later prose.
 */
function speechLinesFromFences(markdown: string): string[] {
  const raw = markdown.replace(/\r\n?/g, "\n").split("\n");
  const output: string[] = [];
  const fencePattern = /^\s{0,3}(`{3,}|~{3,})(.*)$/;
  const fences = raw.map((line) => line.match(fencePattern));
  const closingCache = new Map<string, number[]>();
  let hasPrefix = false;
  let codeOnlyPrefix = true;
  let recoverPartialCode = false;
  for (let index = 0; index < raw.length; index++) {
    const fence = fences[index];
    if (!fence) {
      if (!recoverPartialCode || !looksLikeCode(raw[index])) {
        output.push(raw[index]);
        if (raw[index].trim()) { hasPrefix = true; codeOnlyPrefix &&= looksLikeCode(raw[index]); }
      }
      continue;
    }
    let next = index + 1;
    while (next < raw.length && !raw[next].trim()) next++;
    const nextContent = raw[next] ?? "";
    const obviousProse = !looksLikeCode(nextContent) &&
      (/^\s*(?:#{1,6}\s|[-*+]\s)/.test(nextContent) || /[\p{L}].*[.!?]$/u.test(nextContent.trim()));
    const codePrefix = hasPrefix && codeOnlyPrefix;
    if (!fence[2].trim() && (codePrefix || obviousProse)) {
      if (codePrefix) output.length = 0;
      output.push("code block");
      hasPrefix = true; codeOnlyPrefix = false;
      recoverPartialCode = false;
      continue;
    }
    // Index each marker length once; repeated unmatched fences do not rescan the tail.
    const key = `${fence[1][0]}:${fence[1].length}`;
    let positions = closingCache.get(key);
    if (!positions) {
      positions = [];
      for (let candidate = 0; candidate < fences.length; candidate++) {
        const end = fences[candidate];
        if (end && end[1][0] === fence[1][0] && end[1].length >= fence[1].length && !end[2].trim()) positions.push(candidate);
      }
      closingCache.set(key, positions);
    }
    let low = 0, high = positions.length;
    while (low < high) {
      const middle = (low + high) >>> 1;
      if (positions[middle] <= index) low = middle + 1;
      else high = middle;
    }
    const closing = positions[low] ?? -1;
    output.push("code block");
    hasPrefix = true; codeOnlyPrefix = false;
    if (closing >= 0) { index = closing; recoverPartialCode = false; }
    else recoverPartialCode = true;
  }
  return output;
}
