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
  // Sentence evidence wins, even with a keyword, indentation or an equals sign.
  if (/\p{L}/u.test(text) && /\s/u.test(text) && /[.!?]$/u.test(text)) return false;
  const codePunctuation = /[;{}()[\]=:+*/\\<>"'`,]/u;
  const plainWords = text.split(/\s+/u).filter((word) => /^\p{L}+$/u.test(word));
  if (plainWords.length >= 4 && !codePunctuation.test(text)) return false;

  // Whole statements/calls, not keyword prefixes. Ambiguous lines remain spoken.
  return /^(?:import\s+(?:[\w$]+|\{[^}]+\}|\*\s+as\s+[\w$]+)\s+from\s+["'][^"']+["']|import\s+["'][^"']+["'])\s*;?$/.test(text) ||
    /^from\s+[\w.]+\s+import\s+\([^()]+\)\s*;?$/.test(text) ||
    /^(?:(?:const|let|var)\s+)?[\w$]+(?:\.[\w$]+|\[[^\]]+\])*\s*(?:[+*/-]?=|:=)\s*\S.*(?:;|,|[\]}])$/.test(text) ||
    // Literal-only assignments are strong evidence even without a JS semicolon.
    /^[\w$]+\s*=\s*(?:-?\d+(?:\.\d+)?|true|false|null|None|True|False|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')$/.test(text) ||
    /^return\s+(?:[\w$]+(?:\.[\w$]+)*|[\w$]+\([^\n]*\))\s*;$/.test(text) ||
    /^\/\//.test(text) ||
    /^(?:[\w$]+\.)*[\w$]+\([^\n]*\)\s*;?$/.test(text) ||
    /^(?:if|for|while|switch|catch)\s*\([^\n]*\)\s*\{$/.test(text) ||
    /^(?:function\s+[\w$]+\([^\n]*\)|class\s+[\w$]+)\s*\{$/.test(text) ||
    /^def\s+\w+\([^\n]*\)\s*:$/.test(text) ||
    /^(?:\[(?:|[^\n]*[;{}()=:+*/\\<>"'`,][^\n]*)\]|\{(?:|[^\n]*[;{}()=:+*/\\<>"'`,][^\n]*)\})\s*[,;]?$/.test(text) ||
    /^[{}[\]);,]+$/.test(text);
}

/**
 * Prefer complete fences unless a code-only prefix establishes a selection starting
 * inside code. After that closing boundary, remain in recovery: omit recognizable
 * code while preserving unknown/prose lines, even if a later bare fence could pair.
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
    let taggedBeforeCloser = false;
    if (closing >= 0) {
      for (let candidate = index + 1; candidate < closing; candidate++) {
        const inner = fences[candidate];
        if (inner && inner[1][0] === fence[1][0] && inner[1].length >= fence[1].length && inner[2].trim()) {
          taggedBeforeCloser = true;
          break;
        }
      }
    }
    const complete = closing >= 0 && !taggedBeforeCloser;
    // A strongly evidenced code-only prefix establishes a closing boundary,
    // even if the selection ends inside a later bare fence. Otherwise prefer
    // a complete block; an unmatched bare fence may sit before obvious prose.
    if (!fence[2].trim() && (codePrefix || (!complete && obviousProse))) {
      if (codePrefix) output.length = 0;
      output.push("code block");
      hasPrefix = true; codeOnlyPrefix = false;
      recoverPartialCode = codePrefix;
      continue;
    }
    output.push("code block");
    hasPrefix = true; codeOnlyPrefix = false;
    if (complete) { index = closing; recoverPartialCode = false; }
    else recoverPartialCode = true;
  }
  return output;
}
