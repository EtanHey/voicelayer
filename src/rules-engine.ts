/**
 * Dev-aware post-processing rule engine for dictation output.
 *
 * Seven stages in priority order (total target: <5ms):
 * 1. Filler removal
 * 2. Spoken punctuation
 * 3. Case formatting commands
 * 4. Number formatting
 * 5. Tech vocabulary
 * 6. Auto-capitalization
 * 7. Custom aliases
 *
 * AIDEV-NOTE: This is rules-only, no LLM. Zero hallucination risk.
 * LLM cleanup is deferred to Phase B6. Rules process in <1ms typically.
 */

export interface RulesConfig {
  aliases?: Record<string, string>;
  disabledStages?: Set<string>;
}

/**
 * Apply all post-processing rules to raw transcription text.
 * Returns cleaned, dev-formatted text ready for paste.
 */
export function applyRules(text: string, config?: RulesConfig): string {
  let result = text;

  const disabled = config?.disabledStages;

  // Stage 1: Filler removal (highest priority — clean noise first)
  if (!disabled?.has("fillers")) {
    result = removeFillers(result);
  }

  // Stage 7: Custom aliases (before tech vocab to allow user overrides)
  if (!disabled?.has("aliases") && config?.aliases) {
    result = applyAliases(result, config.aliases);
  }

  // Stage 5: Tech vocabulary
  if (!disabled?.has("techVocab")) {
    result = applyTechVocab(result);
  }

  if (!disabled?.has("codeTokens")) {
    result = preserveCodeTokens(result);
  }

  // Stage 3: Case formatting commands (before punctuation — "camel case foo bar" must be detected as phrase)
  if (!disabled?.has("caseFormatting")) {
    result = applyCaseFormatting(result);
  }

  // Stage 4: Number formatting
  if (!disabled?.has("numbers")) {
    result = applyNumberFormatting(result);
  }

  // Stage 2: Spoken punctuation
  if (!disabled?.has("punctuation")) {
    result = applyPunctuation(result);
    result = normalizePunctuationClusters(result);
  }

  // Percent normalization (depends on number formatting and punctuation stages)
  if (!disabled?.has("numbers") && !disabled?.has("punctuation")) {
    result = normalizePercentPhrases(result);
  }

  // Stage 6: Auto-capitalization (last — after all text transformations)
  if (!disabled?.has("capitalization")) {
    result = autoCapitalize(result);
  }

  // Final cleanup: collapse multiple spaces, trim
  result = result.replace(/  +/g, " ").trim();

  return result;
}

const CODE_TOKEN_PATTERNS: [RegExp, string][] = [
  [/\bdot\s+([A-Za-z_][\w$]*)\b/g, ".$1"],
  [/\bon click\b/gi, "onClick"],
  [/\bon change\b/gi, "onChange"],
  [/\bon submit\b/gi, "onSubmit"],
  [/\bopen paren\b/gi, "("],
  [/\bclose paren\b/gi, ")"],
];

export function preserveCodeTokens(text: string): string {
  let result = text;
  for (const [pattern, replacement] of CODE_TOKEN_PATTERNS) {
    result = result.replace(pattern, replacement);
  }
  result = result.replace(/\(\s+/g, "(");
  result = result.replace(/\)\s+\./g, ").");
  result = result.replace(/\s+\)/g, ")");
  return result.trim();
}

// --- Stage 1: Filler removal ---

const FILLER_PATTERNS: RegExp[] = [
  // English fillers
  /\b(?:um|uh|er|ah)\b/gi,
  /\b(?:basically|essentially|actually|literally)\b/gi,
  /\bkind of\b/gi,
  /\bsort of\b/gi,
  /\blike\b(?=\s+(?:really|very|so|just|totally|super))/gi, // "like" before intensifiers
  /^like\b\s*/gi, // "like" at start
  /\s+like$/gi, // "like" at end
  // Hebrew acoustic fillers. Keep discourse markers like "כאילו" in prose.
  // The lookahead excludes ש so legitimate words starting with אמ
  // (e.g. אמש "last night", אמת "truth") and אה (e.g. אהבה "love") are
  // never partially matched and corrupted.
  /(?:^|\s)(?:אמ|אה)(?=\s|$)/g,
];

function removeFillers(text: string): string {
  let result = text;
  for (const pattern of FILLER_PATTERNS) {
    result = result.replace(pattern, " ");
  }
  return result.replace(/  +/g, " ").trim();
}

// --- Stage 2: Spoken punctuation ---

const PUNCTUATION_MAP: [RegExp, string][] = [
  [/\bperiod\b/gi, "."],
  [/\bfull stop\b/gi, "."],
  [/\bcomma\b/gi, ","],
  [/\bquestionmark\b/gi, "?"],
  [/\bquestion mark\b/gi, "?"],
  [/\bexclamation mark\b/gi, "!"],
  [/\bexclamation point\b/gi, "!"],
  [/\bopen paren\b/gi, "("],
  [/\bclose paren\b/gi, ")"],
  [/\bopen bracket\b/gi, "["],
  [/\bclose bracket\b/gi, "]"],
  [/\bopen brace\b/gi, "{"],
  [/\bclose brace\b/gi, "}"],
  [/\bcolon\b/gi, ":"],
  [/\bsemicolon\b/gi, ";"],
  [/\bdash\b/gi, "-"],
  [/\bhyphen\b/gi, "-"],
  [/\bunderscore\b/gi, "_"],
  [/\barrow\b/gi, "=>"],
  [/\btriple equals\b/gi, "==="],
  [/\bdouble equals\b/gi, "=="],
  [/\bnot equals\b/gi, "!="],
  [/\bequals\b/gi, "="],
  [/\bplus\b/gi, "+"],
  [/\bminus\b/gi, "-"],
  [/\basterisk\b/gi, "*"],
  [/\bslash\b/gi, "/"],
  [/\bbackslash\b/gi, "\\"],
  [/\bdouble pipe\b/gi, "||"],
  [/\bdouble ampersand\b/gi, "&&"],
  [/\bpipe\b/gi, "|"],
  [/\bampersand\b/gi, "&"],
  [/\bat sign\b/gi, "@"],
  [/\bhash\b/gi, "#"],
  [/\bdollar sign\b/gi, "$"],
  [/\bpercent\b/gi, "%"],
  [/\bcaret\b/gi, "^"],
  [/\btilde\b/gi, "~"],
  [/\bbacktick\b/gi, "`"],
  [/\bsingle quote\b/gi, "'"],
  [/\bdouble quote\b/gi, '"'],
  [/\bnew line\b/gi, "\n"],
  [/\bnew paragraph\b/gi, "\n\n"],
  [/\btab\b/gi, "\t"],
  [/\bspace\b/gi, " "],
  [/\bellipsis\b/gi, "..."],
];

const TERMINAL_PERIOD_ABBREVIATIONS = new Set([
  "dr",
  "e.g",
  "co",
  "corp",
  "etc",
  "i.e",
  "inc",
  "jr",
  "ltd",
  "m.d",
  "mr",
  "mrs",
  "ms",
  "ph.d",
  "prof",
  "sr",
  "st",
  "vs",
]);

function preservesPeriodBeforeTerminalPunctuation(token: string): boolean {
  if (token.endsWith("..")) {
    return true;
  }

  const normalized = normalizeTerminalPunctuationToken(token);

  if (TERMINAL_PERIOD_ABBREVIATIONS.has(normalized)) {
    return true;
  }

  return (
    /^(?:[a-z]\.)+[a-z]$/i.test(normalized) ||
    /\d+\.\d+/.test(normalized)
  );
}

function preservesPeriodBeforeComma(token: string): boolean {
  if (token.endsWith("..")) {
    return true;
  }

  const normalized = normalizeTerminalPunctuationToken(token);

  return (
    TERMINAL_PERIOD_ABBREVIATIONS.has(normalized) ||
    /^(?:[a-z]\.)+[a-z]$/i.test(normalized)
  );
}

function normalizeTerminalPunctuationToken(token: string): string {
  return token
    .replace(/^[^\p{L}\p{N}]+|[^\p{L}\p{N}.]+$/gu, "")
    .toLowerCase();
}

function applyPunctuation(text: string): string {
  let result = text;
  for (const [pattern, replacement] of PUNCTUATION_MAP) {
    result = result.replace(pattern, ` ${replacement}`);
  }
  // Clean up space before punctuation that should attach left
  result = result.replace(
    /\s+([.,;:?%)}\]`'"]|!(?!=))/g,
    (match: string, punctuation: string, offset: number) => {
      const nextChar = result[offset + match.length] ?? "";
      if (punctuation === "." && /[A-Za-z_]/u.test(nextChar)) {
        return match;
      }
      return punctuation;
    },
  );
  // Whisper can auto-append the same terminal punctuation after spoken commands
  // such as "question mark?", which would otherwise become "??".
  result = result.replace(/([!?])\.{1,2}(?=\s|$)/g, "$1");
  result = result.replace(
    /(\S+)\.([!?])(?=\s|$)/g,
    (match, token, punctuation) =>
      preservesPeriodBeforeTerminalPunctuation(token)
        ? match
        : `${token}${punctuation}`,
  );
  result = result.replace(/(\S+)\.,(?=\s|$)/g, (match, token) =>
    preservesPeriodBeforeComma(token) ? match : `${token},`,
  );
  result = result.replace(/([!?])\1+/g, "$1");
  result = result.replace(/,{2,}/g, ",");
  result = result.replace(/,\s*([!?])(?=\s*$)/g, "$1");
  result = result.replace(/\bsecond\s*-\s*s\b/gi, "second-S");
  // Clean up space after open brackets
  result = result.replace(/([({[\[`'"])\s+/g, "$1");
  result = result.replace(
    /([\p{L}\p{N}])"(?=\p{L}[^"]*[.!?]")/gu,
    (match, prefix: string, offset: number) => {
      const quoteIndex = offset + prefix.length;
      return hasCodeStringPrefixBeforeQuote(result, quoteIndex)
        ? match
        : `${prefix} "`;
    },
  );
  result = spaceAfterClosingProseQuotes(result);
  return result;
}

function normalizePunctuationClusters(text: string): string {
  return text
    .replace(/,\s*\.{1,}(?=\s|$)/g, ".")
    .replace(/,\s*([!?])(?=\s|$)/g, "$1");
}

function hasCodeStringPrefixBeforeQuote(text: string, quoteIndex: number): boolean {
  const beforeQuote = text.slice(0, quoteIndex);
  return /(?:^|[^\p{L}\p{N}_])(?:[rRuUbBfF]|[rR][fFbB]|[fFbB][rR])$/u.test(
    beforeQuote,
  );
}

function spaceAfterClosingProseQuotes(text: string): string {
  return text.replace(/(?<=[.!?])"(?=\p{L})/gu, (match, offset) => {
    const beforeClosingQuote = text.slice(0, offset);
    const quoteCountBefore = beforeClosingQuote.match(/"/g)?.length ?? 0;
    if (quoteCountBefore % 2 !== 1) {
      return match;
    }

    const openingQuoteIndex = beforeClosingQuote.lastIndexOf('"');
    const charBeforeOpeningQuote =
      openingQuoteIndex > 0 ? text[openingQuoteIndex - 1] : "";
    if (charBeforeOpeningQuote && !/\s/u.test(charBeforeOpeningQuote)) {
      return match;
    }

    return `${match} `;
  });
}

function normalizePercentPhrases(text: string): string {
  return text
    .replace(/\ba\s+(100%)(?=\s+sure\b|[.!?,;:]|$)/gi, "$1")
    .replace(/\b(\d{1,3})\s+sure(?=\s*[.!?,;]|\s*$)/gi, "$1% sure");
}

// --- Stage 3: Case formatting commands ---

const CASE_COMMANDS: [RegExp, (words: string[]) => string][] = [
  [
    /\bcamel case\s+([\w\s]+?)(?=\.|,|;|$|\bcamel|\bsnake|\bpascal|\bkebab|\ball caps)/gi,
    (words) =>
      words
        .map((w, i) =>
          i === 0
            ? w.toLowerCase()
            : w[0].toUpperCase() + w.slice(1).toLowerCase(),
        )
        .join(""),
  ],
  [
    /\bsnake case\s+([\w\s]+?)(?=\.|,|;|$|\bcamel|\bsnake|\bpascal|\bkebab|\ball caps)/gi,
    (words) => words.map((w) => w.toLowerCase()).join("_"),
  ],
  [
    /\bpascal case\s+([\w\s]+?)(?=\.|,|;|$|\bcamel|\bsnake|\bpascal|\bkebab|\ball caps)/gi,
    (words) =>
      words.map((w) => w[0].toUpperCase() + w.slice(1).toLowerCase()).join(""),
  ],
  [
    /\bkebab case\s+([\w\s]+?)(?=\.|,|;|$|\bcamel|\bsnake|\bpascal|\bkebab|\ball caps)/gi,
    (words) => words.map((w) => w.toLowerCase()).join("-"),
  ],
  [
    /\ball caps\s+([\w\s]+?)(?=\.|,|;|$|\bcamel|\bsnake|\bpascal|\bkebab|\ball caps)/gi,
    (words) => words.map((w) => w.toUpperCase()).join(" "),
  ],
];

function applyCaseFormatting(text: string): string {
  let result = text;
  for (const [pattern, formatter] of CASE_COMMANDS) {
    result = result.replace(pattern, (_match, captured: string) => {
      const words = captured.trim().split(/\s+/).filter(Boolean);
      if (words.length === 0) return "";
      return formatter(words);
    });
  }
  return result;
}

// --- Stage 4: Number formatting ---

const WORD_TO_NUMBER: Record<string, number> = {
  zero: 0,
  one: 1,
  two: 2,
  three: 3,
  four: 4,
  five: 5,
  six: 6,
  seven: 7,
  eight: 8,
  nine: 9,
  ten: 10,
  eleven: 11,
  twelve: 12,
  thirteen: 13,
  fourteen: 14,
  fifteen: 15,
  sixteen: 16,
  seventeen: 17,
  eighteen: 18,
  nineteen: 19,
  twenty: 20,
  thirty: 30,
  forty: 40,
  fifty: 50,
  sixty: 60,
  seventy: 70,
  eighty: 80,
  ninety: 90,
};

const MULTIPLIERS: Record<string, number> = {
  hundred: 100,
  thousand: 1000,
  million: 1_000_000,
};

function parseNumberWords(words: string[]): number | null {
  if (words.length === 0) return null;
  let total = 0;
  let current = 0;

  for (const word of words) {
    const lower = word.toLowerCase();
    if (lower in WORD_TO_NUMBER) {
      current += WORD_TO_NUMBER[lower];
    } else if (lower in MULTIPLIERS) {
      if (current === 0) current = 1;
      current *= MULTIPLIERS[lower];
      if (MULTIPLIERS[lower] >= 1000) {
        total += current;
        current = 0;
      }
    } else {
      return null; // non-number word
    }
  }

  return total + current;
}

function applyNumberFormatting(text: string): string {
  const numberWords = new Set([
    ...Object.keys(WORD_TO_NUMBER),
    ...Object.keys(MULTIPLIERS),
  ]);

  const words = text.split(/\s+/);
  const result: string[] = [];
  let numBuffer: string[] = [];

  const flushBuffer = () => {
    if (numBuffer.length > 0) {
      const num = parseNumberWords(numBuffer);
      if (num !== null) {
        result.push(String(num));
      } else {
        result.push(...numBuffer);
      }
      numBuffer = [];
    }
  };

  for (const word of words) {
    if (numberWords.has(word.toLowerCase())) {
      numBuffer.push(word);
    } else {
      flushBuffer();
      result.push(word);
    }
  }
  flushBuffer();

  return result.join(" ");
}

// --- Stage 5: Tech vocabulary ---

const TECH_VOCAB: [RegExp, string][] = [
  [/\bPR\s*(\d+)(['’]s)\b/gi, "PR $1$2"],
  [/\bvision pro\b/gi, "Vision Pro"],
  [/\bsecond\s+dash\s+s\b/gi, "second-S"],
  [/\btype script\b/gi, "TypeScript"],
  [/\bjava script\b/gi, "JavaScript"],
  [/\bnode js\b/gi, "Node.js"],
  [/\bnext js\b/gi, "Next.js"],
  [/\breact js\b/gi, "React"],
  [/\bvue js\b/gi, "Vue.js"],
  [/\buse effect\b/gi, "useEffect"],
  [/\buse state\b/gi, "useState"],
  [/\buse ref\b/gi, "useRef"],
  [/\buse memo\b/gi, "useMemo"],
  [/\buse callback\b/gi, "useCallback"],
  [/\buse context\b/gi, "useContext"],
  [/\buse reducer\b/gi, "useReducer"],
  [/\bGit Hub\b/gi, "GitHub"],
  [/\bvs code\b/gi, "VS Code"],
  [/\bAPI\b/g, "API"], // preserve case
  [/\bjson\b/gi, "JSON"],
  [/\bhtml\b/gi, "HTML"],
  [/\bcss\b/gi, "CSS"],
  [/\bsql\b/gi, "SQL"],
  [/\bhttp\b/gi, "HTTP"],
  [/\bhttps\b/gi, "HTTPS"],
  [/\burl\b/gi, "URL"],
  [/\brest api\b/gi, "REST API"],
  [/\bgraph ql\b/gi, "GraphQL"],
  [/\bweb socket\b/gi, "WebSocket"],
  [/\bweb pack\b/gi, "Webpack"],
  [/\btail wind\b/gi, "Tailwind"],
  [/\bpost gres\b/gi, "Postgres"],
  [/\bmongo db\b/gi, "MongoDB"],
  [/\bredis\b/gi, "Redis"],
  [/\bdocker\b/gi, "Docker"],
  [/\bkubernetes\b/gi, "Kubernetes"],
];

function applyTechVocab(text: string): string {
  let result = text;
  for (const [pattern, replacement] of TECH_VOCAB) {
    result = result.replace(pattern, replacement);
  }
  return result;
}

// --- Stage 6: Auto-capitalization ---

function autoCapitalize(text: string): string {
  if (!text) return text;

  let result = capitalizeLeadingToken(text);

  // Capitalize after sentence-ending punctuation followed by space
  result = result.replace(/([.!?]\s+)([a-z][\w$]*)/g, (_m, prefix, word) => {
    return `${prefix}${capitalizeWordUnlessCodeIdentifier(word)}`;
  });

  // Capitalize after newline
  result = result.replace(/(\n\s*)([a-z][\w$]*)/g, (_m, prefix, word) => {
    return `${prefix}${capitalizeWordUnlessCodeIdentifier(word)}`;
  });

  result = result.replace(
    /\bi\b/g,
    (match: string, offset: number, source: string) => {
      if (isLikelyCodeIdentifierI(source, offset)) {
        return match;
      }
      return "I";
    },
  );
  result = result.replace(
    /\bi(['’](?:m|d|ll|ve))\b/gi,
    (_m, suffix: string) => {
      return `I${suffix}`;
    },
  );

  return result;
}

function capitalizeLeadingToken(text: string): string {
  return text.replace(/^(\s*)([a-z][\w$]*)/, (_m, prefix, word) => {
    return `${prefix}${capitalizeWordUnlessCodeIdentifier(word)}`;
  });
}

function capitalizeWordUnlessCodeIdentifier(word: string): string {
  if (isLowerCamelCodeIdentifier(word)) {
    return word;
  }
  return word[0].toUpperCase() + word.slice(1);
}

function isLowerCamelCodeIdentifier(word: string): boolean {
  return /^[a-z][\w$]*[A-Z][\w$]*$/.test(word);
}

function isLikelyCodeIdentifierI(source: string, offset: number): boolean {
  const before = source.slice(Math.max(0, offset - 12), offset);
  const after = source.slice(offset + 1, offset + 8);

  if (/[\[({.=+\-*/%]\s*$/.test(before)) return true;
  if (/^\s*[\])}.=+\-*/%]/.test(after)) return true;
  if (/\b(?:let|const|var|for)\s+$/.test(before)) return true;

  return false;
}

// --- Stage 7: Custom aliases ---

const ALIAS_PATTERN_CACHE = new WeakMap<
  Record<string, string>,
  [string, RegExp, string][]
>();

function applyAliases(text: string, aliases: Record<string, string>): string {
  let result = text;
  let patterns = ALIAS_PATTERN_CACHE.get(aliases);
  if (!patterns) {
    patterns = Object.entries(aliases).map(([from, to]) => {
      // Use Unicode-aware word boundaries — \b doesn't work with Hebrew/Arabic
      const escaped = escapeRegex(from);
      return [
        from.toLowerCase(),
        new RegExp(
          `(?<=^|\\s|[^\\p{L}])${escaped}(?=$|\\s|[^\\p{L}])`,
          "giu",
        ),
        to,
      ];
    });
    ALIAS_PATTERN_CACHE.set(aliases, patterns);
  }

  const lowerResult = result.toLowerCase();
  for (const [fromLower, pattern, to] of patterns) {
    if (!lowerResult.includes(fromLower)) continue;
    result = result.replace(pattern, to);
  }
  return result;
}

function escapeRegex(str: string): string {
  return str.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
