import { proseSlashPattern, proseSlashMatches } from "./tts/display-tokens";
import type { ProjectionRange } from "./tts/structured-speech";

export type SpeakableEngine = "edge" | "clone";
export interface PronunciationRule { pattern: RegExp; replacement: string }
export interface SpeakableText { displayText: string; speechText: string; ranges: ProjectionRange[] }
interface Piece { start: number; end: number; text: string; protected?: boolean; atomic?: boolean }
const ones = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split(" ");
const tens = "  twenty thirty forty fifty sixty seventy eighty ninety".split(" ");
function number(raw: string): string {
  const n = Number(raw);
  if (raw.length > 2 || /^0\d/.test(raw)) return [...raw].map(d => ones[+d]).join(" ");
  return n < 20 ? ones[n] : tens[Math.floor(n / 10)] + (n % 10 ? `-${ones[n % 10]}` : "");
}
const lexicon: Record<string, string> = {
  JSON: "JSON", YAML: "yammel", YML: "yammel", TOML: "tommel", REST: "rest", GUI: "gooey",
  RAM: "ram", ROM: "rom", DOM: "dom", CORS: "cors", CUDA: "cooda", ONNX: "onyx",
  README: "read me", CHANGELOG: "change log", WAV: "wave", FLAC: "flack", INT: "int",
  MP3: "M P three", MP4: "M P four", H264: "H two sixty-four", BASE64: "base sixty-four",
  ARM64: "arm sixty-four", UTF8: "U T F eight", UTF16: "U T F sixteen",
  GRPC: "G R P C", MACOS: "mac O S", MPS: "M P S", ICL: "I C L", BF: "B F", FP: "F P",
};
const initialisms = new Set("API CLI SDK URL URI HTML CSS JSX TSX SQL SSH SSL TLS HTTP HTTPS TCP UDP DNS CDN AWS GCP CPU GPU NPU ANE SSD LLM ASR TTS STT VAD IPA WER CER MLX GGUF GGML RVQ MTP BPE AST EOF EOS BOS OOM PR CI CD IO OS UI UV AAC PCM RGB RGBA JWT CSRF XSS NPM ENV PY NG".split(" "));
const proseShortForms = new Set("OK US AM PM ID TV".split(" "));
const ordinary = new Set("AND FOR THE NOT ALL NEW MAX MIN SET GET PUT RUN LOG MAP KEY APP WEB NET DOC RED TOP END OUT LOW RAW TAG ROW COL PIN PAD FIX ADD DEL SUB REF BASE FAST VOICE CLONE PROMPT CACHE AUDIO ENABLE FALLBACK PYTORCH INCIDENT INVENTORY TOKENS POST".split(" "));
const extensions: Record<string, string> = {
  md: "M D", markdown: "markdown", ts: "T S", tsx: "T S X", js: "J S", jsx: "J S X",
  json: "JSON", jsonl: "JSON L", yaml: "yammel", yml: "yammel", toml: "tommel",
  py: "P Y", rs: "R S", sh: "shell", cpp: "C plus plus", wav: "wave", mp3: "M P three",
  mp4: "M P four", env: "E N V", gitignore: "git ignore", txt: "text", csv: "C S V",
  mjs: "M J S", cjs: "C J S", ipynb: "I python notebook", go: "go", rb: "ruby", php: "P H P", java: "java", kt: "kotlin",
  c: "C", h: "H", hpp: "H plus plus", cs: "C sharp", bash: "bash", zsh: "Z shell", sql: "S Q L",
  scss: "S C S S", svg: "S V G", png: "P N G", jpg: "J peg", jpeg: "J peg", gif: "gif", webp: "web P",
  flac: "flack", m4a: "M four A", gguf: "G G U F", onnx: "onyx", safetensors: "safe tensors",
  pt: "P T", pth: "P T H", npz: "N P Z", dockerignore: "docker ignore", tsv: "T S V", pdf: "P D F",
  zip: "zip", wasm: "wasm", dylib: "dylib", so: "S O", dll: "D L L", exe: "E X E",
  html: "H T M L", css: "C S S", swift: "swift", lock: "lock", gz: "G Z", tar: "tar",
};
function identifier(raw: string, compound = false, engine: SpeakableEngine = "clone"): string {
  if (/[\u0590-\u05ff]/.test(raw)) return raw;
  const upper = raw.toUpperCase();
  if (proseShortForms.has(raw)) return raw;
  if (lexicon[upper]) return engine === "edge" && /\b[A-Z]\b/.test(lexicon[upper]) ? raw : lexicon[upper];
  if (initialisms.has(upper)) return engine === "clone" ? upper.split("").join(" ") : raw;
  if (/^\d+(?:[./-]\d+)+$/.test(raw)) return raw;
  const mixed = raw.match(/^([A-Za-z]+)?(\d+(?:\.\d+)?)([A-Za-z]*)$/);
  if (mixed && (mixed[1] || mixed[3])) {
    const [, head, digits, tail] = mixed;
    if (engine === "edge" && head?.length === 1 && !tail) return raw;
    const unit: Record<string, string> = { Hz: "hertz", ms: "milliseconds", B: "B" };
    return [head ? identifier(head, true, engine) : "", digits.split(".").map(number).join(" point "),
      tail ? unit[tail] ?? identifier(tail, true, engine) : ""].filter(Boolean).join(" ");
  }
  const separated = raw.split(/[_-]+/).filter(Boolean);
  if (separated.length > 1) return separated.map(p => identifier(p, true, engine)).join(" ");
  if (/^\d+(?:\.\d+)?$/.test(raw)) return compound ? raw.split(".").map(number).join(" point ") : raw;
  const parts = raw.replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2").split(/[_\s-]+/).filter(Boolean);
  if (parts.length > 1) return parts.map(p => identifier(p, true, engine)).join(" ");
  if (/^[A-Z]$/.test(raw)) return raw;
  if (/^[A-Z]{2,}$/.test(raw)) {
    if (!compound) return raw;
    if (engine === "clone" && !ordinary.has(raw) && !/[AEIOUY]/.test(raw)) return raw.split("").join(" ");
    return raw.toLowerCase();
  }
  return compound ? raw.toLowerCase() : raw;
}
function filename(raw: string, engine: SpeakableEngine): string {
  const base = raw.split(/[\\/]/).filter(Boolean).at(-1) ?? raw;
  if (!base.startsWith(".") && !extensions[base.split(".").at(-1)?.toLowerCase() ?? ""]) return identifier(base, false, engine);
  return base.split(".").map((part, i) => i ? `dot ${extensions[part.toLowerCase()] ?? identifier(part, false, engine)}` : identifier(part, false, engine)).filter(Boolean).join(" ");
}
function clonePath(raw: string, rules: readonly PronunciationRule[] = []): string {
  return (raw.startsWith("/") ? "slash " : "") + raw.split(/[\\/]/).filter(Boolean).map(part => {
    if (part === "." || part === "..") return part === "." ? "dot" : "dot dot";
    const wholeOverride = rules.some(rule => {
      const match = new RegExp(rule.pattern.source, rule.pattern.flags.replace(/[gy]/g, "")).exec(part);
      return match?.index === 0 && match[0].length === part.length;
    });
    return (!rules.length || wholeOverride ? [part] : part.split(/[_-]+/))
      .map(word => projectSpeakableText(word, rules, "clone").speechText).join(" ");
  }).join(" slash ");
}

/** Scan balanced JSON once. Parse only to validate; never round-trip numeric values. */
function jsonEdits(input: string): {start: number; end: number; text: string}[] {
  const edits: {start: number; end: number; text: string}[] = [];
  let start = -1, quoted = false, escaped = false;
  const stack: string[] = [];
  for (let i = 0; i < input.length; i++) {
    const char = input[i];
    if (start < 0) {
      if ((char !== "{" && char !== "[") || /[\p{L}\p{N}_]/u.test(input[i - 1] ?? "")) continue;
      start = i; stack.push(char); continue;
    }
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === "\\") escaped = true;
      else if (char === '"') quoted = false;
      continue;
    }
    if (char === '"') { quoted = true; continue; }
    if (char === "{" || char === "[") stack.push(char);
    if (char !== "}" && char !== "]") continue;
    const open = stack.pop();
    if (open !== (char === "}" ? "{" : "[")) { stack.length = 0; start = -1; continue; }
    if (stack.length) continue;
    const end = i + 1, raw = input.slice(start, end);
    try {
      JSON.parse(raw);
      // Keep keys, values and their original positions; only edit syntax/escapes.
      const tokens = /"(?:[^"\\]|\\[\s\S])*"|\[\s*\]|\{\s*\}|[{}\[\]:,]/g;
      for (const token of raw.matchAll(tokens)) {
        const at = start + token.index, text = token[0];
        const gap = /[{\["“”\p{L}\p{N}_]/u.test(input[at + text.length] ?? "") ? " " : "";
        if (text.startsWith('"')) {
          if (text === '""') edits.push({start: at, end: at + text.length, text: "empty string"});
          else {
            edits.push({start: at, end: at + 1, text: ""});
            // Decode just the escape. Literal words between escapes keep their
            // own source spans instead of sharing the whole quoted value.
            for (const escape of text.matchAll(/\\(?:u[0-9a-fA-F]{4}|["\\/bfnrt])/g)) {
              const decoded = (JSON.parse('"' + escape[0] + '"') as string)
                .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g,
                  char => ` control ${number(String(char.charCodeAt(0)))} `);
              edits.push({start: at + escape.index, end: at + escape.index + escape[0].length, text: decoded});
            }
            edits.push({start: at + text.length - 1, end: at + text.length, text: ""});
          }
        } else edits.push({start: at, end: at + text.length, text:
          text.startsWith("[") && text.length > 1 ? " an empty list" + gap :
          text.startsWith("{") && text.length > 1 ? " an empty object" + gap :
          text === "[" ? "list: " : text === ":" ? ": " : text === "," ? ", " :
          text !== "{" ? gap : ""});
      }
    } catch { /* Unknown/partial code stays lexical; the clone symbol pass handles it. */ }
    start = -1;
  }
  return edits;
}
function url(raw: string, rules: readonly PronunciationRule[] = [], engine: SpeakableEngine = "clone"): string {
  const word = (text: string) => rules.length ? projectSpeakableText(text, rules, engine).speechText : identifier(text, false, engine);
  try {
    const parsed = new URL(raw.startsWith("www.") ? `https://${raw}` : raw);
    const host = parsed.hostname.replace(/^www\./, "").split(".").map(word).join(" dot ");
    const path = parsed.pathname.split("/").filter(Boolean);
    if (parsed.search || parsed.hash || (path.length > 2 && parsed.hostname !== "localhost")) return `link to ${host}`;
    return host + (parsed.port ? ` port ${[...parsed.port].map(number).join(" ")}` : "") +
      path.map(p => ` slash ${/^v\d+$/.test(p) ? `version ${number(p.slice(1))}` : word(p)}`).join("");
  } catch { return raw; }
}

/** A replacement owns its whole source span. Never interpolate inside an edit. */
function rewrite(pieces: Piece[], pattern: RegExp, replace: (match: RegExpExecArray) => string | undefined, protect = false, skipProtected = false): void {
  const input = pieces.map(p => p.text).join("");
  const edits = Array.from(input.matchAll(pattern)).flatMap(m => {
    const text = replace(m);
    return text === undefined ? [] : [{start: m.index, end: m.index + m[0].length, text}];
  });
  applyEdits(pieces, input, edits, protect, skipProtected);
}
function applyEdits(pieces: Piece[], input: string, edits: {start: number; end: number; text: string}[], protect: boolean, skipProtected = false): void {
  for (const edit of edits.reverse()) {
    if (!protect && input.slice(edit.start, edit.end) === edit.text) continue;
    if (!protect) {
      const before = input.slice(edit.start, edit.end);
      let prefix = 0, suffix = 0;
      while (prefix < before.length && prefix < edit.text.length && before[prefix] === edit.text[prefix]) prefix++;
      while (suffix < before.length - prefix && suffix < edit.text.length - prefix && before[before.length - 1 - suffix] === edit.text[edit.text.length - 1 - suffix]) suffix++;
      edit.start += prefix; edit.end -= suffix;
      edit.text = edit.text.slice(prefix, edit.text.length - suffix);
    }
    let cursor = 0, first = -1, last = -1, firstOffset = 0, lastOffset = 0;
    for (let i = 0; i < pieces.length; i++) {
      const end = cursor + pieces[i].text.length;
      if (first < 0 && (end > edit.start || (edit.start === input.length && i === pieces.length - 1))) {
        first = i; firstOffset = edit.start - cursor;
      }
      if (first >= 0 && end >= edit.end) { last = i; lastOffset = edit.end - cursor; break; }
      cursor = end;
    }
    if (first < 0 || last < 0 || (skipProtected && pieces.slice(first, last + 1).some(p => p.protected))) continue;
    const a = pieces[first], b = pieces[last];
    const aIdentity = !a.atomic;
    const bIdentity = !b.atomic;
    const start = aIdentity ? a.start + firstOffset : a.start;
    const end = bIdentity ? b.start + lastOffset : b.end;
    const prefix = a.text.slice(0, firstOffset), suffix = b.text.slice(lastOffset);
    const replacement: Piece[] = [];
    if (aIdentity && prefix) replacement.push({start: a.start, end: start, text: prefix});
    replacement.push({start, end, text: (aIdentity ? "" : prefix) + edit.text + (bIdentity ? "" : suffix), protected: protect, atomic: true});
    if (bIdentity && suffix) replacement.push({start: end, end: b.end, text: suffix});
    pieces.splice(first, last - first + 1, ...replacement);
  }
}

/** Pure projection; clone is the default. Runtime callers choose the actual engine. */
export function projectSpeakableText(displayText: string, rules: readonly PronunciationRule[] = [], engine: SpeakableEngine = "clone"): SpeakableText {
  const pieces: Piece[] = displayText ? [{start: 0, end: displayText.length, text: displayText}] : [];
  const edit = (pattern: RegExp, replacement: string | ((m: RegExpExecArray) => string | undefined), protect = false, skip = false) =>
    rewrite(pieces, pattern, typeof replacement === "string" ? () => replacement : replacement, protect, skip);
  // Structural syntax first. No generated table headers or guessed capture structure.
  if (/[`~]{3}/.test(displayText)) edit(/^\s{0,3}(`{3,}|~{3,})[^\r\n]*\r?\n[\s\S]*?^\s{0,3}\1\s*$/gm, "code block", true);
  const tableRows = (): Set<number> => {
    const lines = pieces.map(p => p.text).join("").split("\n");
    const rows = new Set<number>();
    let offset = 0, previous = 0, active = false;
    for (let i = 0; i < lines.length; i++) {
      const separator = /^[ \t]*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?[ \t]*$/.test(lines[i]);
      if (separator && i && lines[i-1].includes("|")) { rows.add(previous); active = true; }
      else if (active && lines[i].includes("|")) rows.add(offset);
      else active = false;
      previous = offset; offset += lines[i].length + 1;
    }
    return rows;
  };
  let rows = tableRows();
  edit(/[^\r\n]+$/gm, m => rows.has(m.index) && !/^[ \t]*:?-{3,}/.test(m[0]) && !/[.!?]$/.test(m[0].replace(/\|[ \t]*$/, "").trimEnd()) ? m[0] + "." : m[0]);
  rows = tableRows();
  const tableInput = pieces.map(p => p.text).join("");
  edit(/[ \t]*\|[ \t]*/g, m => {
    const lineStart = tableInput.lastIndexOf("\n", m.index - 1) + 1;
    if (!rows.has(lineStart)) return m[0];
    const atStart = !tableInput.slice(lineStart, m.index).trim();
    const after = tableInput.slice(m.index + m[0].length).split(/\r?\n/, 1)[0];
    return atStart || /^\.?$/.test(after) ? "" : ", ";
  });
  edit(/^[ \t]*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?[ \t]*(?:\r?\n|$)/gm, "");
  edit(/^([ \t]*(?:[-+*]|\d+[.)])[ \t]+)([^\r\n]+)/gm, m => m[1] + m[2] + (/[.!?]$/.test(m[2].trimEnd()) ? "" : "."));
  // Keep the marker's own source span: alignment maps the spoken number back to it.
  edit(/^[ \t]*(\d+)[.)](?=[ \t]+)/gm, m => {
    const line = m.input.slice(m.index).split(/\r?\n/, 1)[0];
    // Let the voice frontend pronounce digits in Hebrew rather than injecting English.
    return `${/[\u0590-\u05ff]/.test(line) || m[1].length > 2 ? m[1] : number(m[1])}.`;
  }, true);
  edit(/^[ \t]*(?:#{1,6}[ \t]+|>[ \t]?|[-+*][ \t]+(?:\[[ xX]\][ \t]*)?)/gm, "");
  edit(/!?\[([^\]\n]+)\]\((?:[^()\n]|\([^()\n]*\))*\)/g, m => m[1]);
  if (engine === "clone") {
    const input = pieces.map(p => p.text).join("");
    applyEdits(pieces, input, jsonEdits(input), false);
  }
  // Edit only the separator so both words retain independent source anchors.
  {
    const input = pieces.map(p => p.text).join("");
    applyEdits(pieces, input, proseSlashMatches(input).map(m => ({
      start: m.index + m[0].indexOf("/"), end: m.index + m[0].indexOf("/") + 1, text: " "
    })), false, true);
  }
  edit(/`+|\*\*|\*([^*\n]+)\*|~~/g, m => m[1] ?? "");
  edit(/(?<![A-Za-z0-9\u0080-\uffff_])_([^_\n]+)_(?![A-Za-z0-9\u0080-\uffff_])/gu, m => m[1]);
  // Existing YAML rules run in their existing order and remain atomic/protected.
  for (const rule of rules) edit(new RegExp(rule.pattern.source, rule.pattern.flags.includes("g") ? rule.pattern.flags : rule.pattern.flags + "g"),
    m => {
      const pattern = new RegExp(rule.pattern.source, rule.pattern.flags.replace(/[gy]/g, "") + "y");
      pattern.lastIndex = m.index;
      const replaced = pattern[Symbol.replace](m.input, rule.replacement);
      return replaced.slice(m.index, replaced.length - (m.input.length - m.index - m[0].length));
    }, true);
  edit(/[A-Za-z0-9\u0590-\u05ff_.-]+/gu, m => {
    // Clone path projection owns the whole path and preserves Hebrew components.
    if (engine === "clone" && /[\\/]/.test((m.input[m.index - 1] ?? "") + (m.input[m.index + m[0].length] ?? ""))) return undefined;
    return /[\u0590-\u05ff]/.test(m[0]) ? m[0] : undefined;
  }, true);
  // Keep numeric prose out of path/identifier rules, including fractions and times.
  edit(/[$€£¥₪][ \t]*\d[\d,]*(?:\.\d+)?(?:[ \t]?(?:USD|EUR|GBP|ILS))?/g, m => m[0], true);
  edit(/(?<![\w./])\d+(?:\/\d+)+(?![\w./])/g, m => m[0], true);
  edit(/(?<![\w:])(?:\d{1,2}:\d{2}(?::\d{2})?(?:[ \t]?[AP]M)?|\d{1,2}[AP]M)(?![\w:])/gi, m => m[0], true);
  if (engine === "clone") {
    // Replace only the unit: the original number keeps its own click/timing span.
    const input = pieces.map(p => p.text).join("");
    const units = Array.from(input.matchAll(/(?<![\p{L}\p{N}_.,])(\d+(?:,\d{3})*(?:\.\d+)?)([ \t]+)mm(?![\p{L}\p{N}_])/gu));
    applyEdits(pieces, input, units.map(m => ({start: m.index + m[1].length + m[2].length,
      end: m.index + m[0].length, text: Number(m[1].replace(/,/g, "")) === 1 ? "millimeter" : "millimeters"})), false, true);
  }
  // YAML may add spaces inside a path/file/URL. Revisit those composites in
  // source coordinates so basename/suffix rules still wrap the protected override.
  const composites = engine === "clone"
    ? /(?<![A-Za-z0-9\u0080-\uffff_])(?:(?:https?:\/\/|www\.)[^\s<>\])`]+|(?:[A-Za-z]:[\\/]|\.{0,2}[\\/]|[\p{L}\p{M}\p{N}_.-]+[\\/])[\p{L}\p{M}\p{N}_./\\-]+|[\w-]+\.[a-zA-Z]+)(?![\p{L}\p{M}\p{N}_])/gu
    : /(?<![A-Za-z0-9\u0080-\uffff_])(?:(?:https?:\/\/|www\.)[^\s<>\])`]+|(?:[A-Za-z]:\\|\.{0,2}\/|[\w.-]+\/)[\w./\\-]+|[\w-]+\.[a-zA-Z]+)\b/gu;
  if (rules.length) for (const match of Array.from(displayText.matchAll(composites)).reverse()) {
    // Only clone directories extend the source span through a trailing separator.
    if (engine === "clone" && !/^(?:https?:|www\.)/.test(match[0])) {
      match[0] += displayText.slice(match.index + match[0].length).match(/^[\\/]+/)?.[0] ?? "";
    }
    if (Array.from(match[0].matchAll(proseSlashPattern)).some(m => m[0] === match[0])) continue;
    const start = match.index, end = start + match[0].length;
    if (/^\d+(?:\/\d+)+$/.test(match[0])) continue;
    if (!pieces.some(p => p.protected && p.start >= start && p.end <= end)) continue;
    if (rules.some(rule => { const m = new RegExp(rule.pattern.source, rule.pattern.flags.replace(/[gy]/g, "")).exec(match[0]); return m?.index === 0 && m[0].length === match[0].length; })) continue;
    let offset = 0, left = -1, right = -1;
    for (const p of pieces) {
      if (p.start <= start && start < p.end && (!p.atomic || p.start === start)) left = offset + (p.atomic ? 0 : start - p.start);
      if (p.start < end && end <= p.end && (!p.atomic || p.end === end)) right = offset + (p.atomic ? p.text.length : end - p.start);
      offset += p.text.length;
    }
    if (left < 0 || right < left) continue; // A phrase/link owns a larger span.
    if (/^(?:https?:|www\.)/.test(match[0])) {
      const trailing = match[0].match(/[.,!?;:]+$/)?.[0] ?? "";
      const text = url(match[0].slice(0, match[0].length - trailing.length), rules, engine) + trailing;
      applyEdits(pieces, pieces.map(p => p.text).join(""), [{start: left, end: right, text}], true);
      continue;
    }
    if (engine === "clone" && /[\\/]/.test(match[0])) {
      applyEdits(pieces, pieces.map(p => p.text).join(""), [{start: left, end: right, text: clonePath(match[0], rules)}], true);
      continue;
    }
    const base = match[0].split(/[\\/]/).filter(Boolean).at(-1)!;
    const dot = base.lastIndexOf("."), extension = dot >= 0 ? extensions[base.slice(dot + 1).toLowerCase()] : undefined;
    if (!extension && base === match[0]) continue;
    const stem = extension ? base.slice(0, dot) : base;
    const suffix = base.slice(dot + 1);
    const spokenExtension = extension && rules.some(rule => new RegExp(rule.pattern.source, rule.pattern.flags.replace(/[gy]/g, "")).test(suffix))
      ? projectSpeakableText(suffix, rules, engine).speechText : extension;
    const spoken = projectSpeakableText(stem, rules, engine).speechText + (spokenExtension ? ` dot ${spokenExtension}` : "");
    applyEdits(pieces, pieces.map(p => p.text).join(""), [{start: left, end: right, text: spoken}], true);
  }
  edit(/(?:https?:\/\/|www\.)[^\s<>\])`]+/g, m => {
    const trailing = m[0].match(/[.,!?;:]+$/)?.[0] ?? "";
    return url(m[0].slice(0, m[0].length - trailing.length), [], engine) + trailing;
  }, true, true);
  edit(/\bHTTP\/(\d+)\b/gi, m => `H T T P ${number(m[1])}`, true, true);
  const paths = engine === "clone"
    ? /(?<![A-Za-z0-9\u0080-\uffff_])(?:[A-Za-z]:[\\/]|\.{0,2}[\\/]|[\p{L}\p{M}\p{N}_.-]+[\\/])[\p{L}\p{M}\p{N}_./\\-]+/gu
    : /(?<![A-Za-z0-9\u0080-\uffff_])(?:[A-Za-z]:\\|\.{0,2}\/|[\w.-]+\/)[\w./\\-]+/gu;
  edit(paths, m => {
    const raw = m[0].replace(/[.,;:!?]+$/, "");
    const spoken = engine === "clone" ? clonePath(raw) : filename(raw, engine);
    return spoken + (m[0].match(/[.,;:!?]+$/)?.[0] ?? "");
  }, true, true);
  // Extension components require dots so letter runs have only one partition.
  edit(/(?<![A-Za-z0-9\u0080-\uffff_.])(?:v|V|\^|~)?\d+(?:\.\d+)+(?:-(?:rc|alpha|beta)(?:\.\d+)?)?(?![A-Za-z0-9\u0080-\uffff_])/gu, m => {
    const before = m.input.slice(Math.max(0, m.index - 40), m.index);
    if (/[$€£¥₪]\s*$/.test(before) || (!/^[vV^~]/.test(m[0]) && !/(?:\b(?:version|release|semver)\s+|[<>]=?\s*)$/i.test(before))) return undefined;
    let raw = m[0], prefix = "";
    if (/^[vV^~]/.test(raw)) { prefix = /^[vV]/.test(raw) ? "version " : raw[0] === "^" ? "caret " : "tilde "; raw = raw.slice(1); }
    const [core, suffix] = raw.split("-");
    return prefix + core.split(".").map(number).join(" point ") + (suffix ? " " + suffix.replace(/^rc/, "release candidate").split(".").map(p => /^\d+$/.test(p) ? number(p) : p).join(" ") : "");
  }, true, true);
  edit(/\b0x[0-9a-f]+\b|\b(?=[0-9a-f]{7,40}\b)(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{7,40}\b/gi, m => {
    const hex = /^0x/i.test(m[0]);
    const chars = hex ? m[0].slice(2) : m[0].slice(0, 7);
    const letters: Record<string, string> = {a: "ay", b: "bee", c: "see", d: "dee", e: "ee", f: "eff"};
    return (hex ? "zero X " : m[0].length === 40 ? "commit " : "") + [...chars.toLowerCase()].map(c => letters[c] ?? number(c)).join(" ");
  }, true, true);
  edit(/(?<![A-Za-z0-9\u0080-\uffff_])(?:[\w-]+\.[a-zA-Z][\w]*(?:\.[a-zA-Z][\w]*)*\.?|\.[a-zA-Z]+(?:\.[a-zA-Z]+)*)(?![A-Za-z0-9\u0080-\uffff_])/gu, m => {
    const raw = m[0].replace(/\.$/, "");
    return filename(raw, engine) + (m[0].endsWith(".") ? "." : "");
  }, true, true);
  edit(/(?<![A-Za-z0-9\u0080-\uffff_])--?[A-Za-z][\w-]*/gu, m => (m[0].startsWith("--") ? "dash dash " : "dash ") + identifier(m[0].replace(/^-+/, ""), false, engine), true, true);
  edit(/[A-Za-z0-9\u0590-\u05ff_]+(?:[.-][A-Za-z0-9\u0590-\u05ff_]+)*/gu, m => identifier(m[0], false, engine), true, true);
  edit(/>=|<=|!==|!=|===|==|=>|->|&&|\|\||\||=/g, m => " " + ({">=": "greater than or equal to", "<=": "less than or equal to", "!==": "not equal", "!=": "not equal", "===": "triple equals", "==": "equals", "=>": "arrow", "->": "arrow", "&&": "and", "||": "or", "|": "pipe", "=": "equals"}[m[0]]) + " ", false, true);
  if (engine === "clone") {
    // Even partial code or dictionary output must not send these symbols to Qwen.
    edit(/\[\s*\]|\{\s*\}/g, m => m[0][0] === "[" ? " an empty list " : " an empty object ");
    edit(/[{}\[\]]/g, m => " " + ({"{": "open brace", "}": "close brace", "[": "open bracket", "]": "close bracket"}[m[0]]) + " ");
    edit(/["“”]/g, m => /[\p{L}\p{N}]/u.test(m.input[m.index - 1] ?? "") && /[\p{L}\p{N}]/u.test(m.input[m.index + 1] ?? "") ? " " : "");
  }
  edit(/\s+/g, " ");
  edit(/^ | $/g, "");
  let speech = 0;
  const ranges: ProjectionRange[] = pieces.map(p => {
    const start = speech; speech += p.text.length;
    return { source: {start: p.start, end: p.end}, display: {start: p.start, end: p.end}, speech: {start, end: speech},
      kind: p.start === p.end ? "insertion" : !p.text ? "omission" : displayText.slice(p.start, p.end) === p.text ? "identity" : "replacement" };
  });
  return {displayText, speechText: pieces.map(p => p.text).join(""), ranges};
}
