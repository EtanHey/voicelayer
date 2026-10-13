/** Convert markdown to speech text without fetching links or evaluating code. */
export function markdownToSpeech(markdown: string): string {
  const lines: string[] = [];
  let fence: { marker: string; length: number } | undefined;
  for (const raw of markdown.replace(/\r\n?/g, "\n").split("\n")) {
    const match = raw.match(/^\s{0,3}(`{3,}|~{3,})(.*)$/);
    if (fence) {
      if (match && match[1][0] === fence.marker && match[1].length >= fence.length && !match[2].trim()) fence = undefined;
      continue;
    }
    if (match) {
      fence = { marker: match[1][0], length: match[1].length };
      lines.push("code block");
      continue;
    }
    if (/^\s*\[[^\]]+\]:\s*\S+/.test(raw) || /^\s*([-*_])(?:\s*\1){2,}\s*$/.test(raw) || /^\s*=+\s*$/.test(raw)) continue;
    let line = raw.replace(/^\s{0,3}#{1,6}\s+/, "").replace(/\s+#+\s*$/, "").replace(/^\s*>\s?/, "");
    if (/^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line)) continue;
    const list = /^\s*(?:[-+*]|\d+[.)])\s+/.test(line);
    line = line.replace(/^\s*(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s*)?/, "");
    line = stripInlineLinkTargets(line)
      .replace(/!?\[([^\]]+)\]\[[^\]]*\]/g, "$1")
      .replace(/<https?:\/\/[^>]+>/gi, "link")
      .replace(/(?:https?:\/\/|www\.)[^\s<>]+/gi, (url) => `link${url.match(/[.,!?;:]+$/)?.[0] ?? ""}`)
      .replace(/`+/g, "").replace(/\*\*|__/g, "").replace(/\*([^*]+)\*/g, "$1").replace(/_([^_]+)_/g, "$1");
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
