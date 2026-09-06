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
  aggressiveFillerRemoval?: boolean;
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
    result = removeFillers(result, config?.aggressiveFillerRemoval ?? false);
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
    result = dropWhisperCommaBeforeNewline(result);
    result = unwrapCommaWrappedCommands(result);
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

const DISFLUENCY_PATTERNS: RegExp[] = [
  // English acoustic disfluencies.
  /\b(?:um|uh|er)\b/gi,
  // Hebrew acoustic fillers. Keep discourse markers like "כאילו" in prose.
  // The lookahead excludes ש so legitimate words starting with אמ
  // (e.g. אמש "last night", אמת "truth") and אה (e.g. אהבה "love") are
  // never partially matched and corrupted.
  /(?:^|\s)(?:אמ|אה)(?=\s|$)/g,
];

// These expressions can carry meaning and are ordinary English. They remain
// available only for callers that explicitly opt into the legacy aggressive
// behavior; deleting them unconditionally changes what the speaker asserted.
const AGGRESSIVE_FILLER_PATTERNS: RegExp[] = [
  /\b(?:basically|essentially|actually|literally)\b/gi,
  /\bkind of\b/gi,
  /\bsort of\b/gi,
  /\blike\b(?=\s+(?:really|very|so|just|totally|super))/gi,
  /^like\b\s*/gi,
  /\s+like$/gi,
];

function removeFillers(text: string, aggressive: boolean): string {
  let result = text;
  const patterns = aggressive
    ? [...DISFLUENCY_PATTERNS, ...AGGRESSIVE_FILLER_PATTERNS]
    : DISFLUENCY_PATTERNS;
  for (const pattern of patterns) {
    result = result.replace(pattern, " ");
  }
  return result.replace(/  +/g, " ").trim();
}

// --- Stage 2: Spoken punctuation ---

// AIDEV-NOTE: This used to be one always-on PUNCTUATION_MAP. Every entry fired
// unconditionally, and roughly a third of them are ordinary English words, so
// they ate real speech: "there's still sometimes a new line on codex agents"
// shipped as "...sometimes a. On codex agents" (polish-shadow line 7004,
// clip 2026-09-05T11-46-00-495Z-81090f01), and "some space to think" lost the
// word outright because "space" is the one command that deletes a word.
// AGENTS.md law: a fix that loses Etan's words is worse than the bug. So the
// map is split — ALWAYS entries are multi-word phrases or words nobody uses as
// a noun mid-sentence; AMBIGUOUS entries stay verbatim unless their neighbours
// prove the speaker dictated a symbol. See isSpokenAsNoun below.

/** Never ordinary prose: multi-word phrases, or single words only ever dictated as symbols. */
const ALWAYS_PUNCTUATION_MAP: [RegExp, string][] = [
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
  [/\bsemicolon\b/gi, ";"],
  [/\bhyphen\b/gi, "-"],
  [/\bunderscore\b/gi, "_"],
  [/\btriple equals\b/gi, "==="],
  [/\bdouble equals\b/gi, "=="],
  [/\bnot equals\b/gi, "!="],
  [/\basterisk\b/gi, "*"],
  [/\bbackslash\b/gi, "\\"],
  [/\bdouble pipe\b/gi, "||"],
  [/\bdouble ampersand\b/gi, "&&"],
  [/\bampersand\b/gi, "&"],
  [/\bat sign\b/gi, "@"],
  [/\bdollar sign\b/gi, "$"],
  [/\bcaret\b/gi, "^"],
  [/\btilde\b/gi, "~"],
  [/\bbacktick\b/gi, "`"],
  [/\bsingle quote\b/gi, "'"],
  [/\bdouble quote\b/gi, '"'],
  [/\bellipsis\b/gi, "..."],
];

/**
 * Ordinary English words that double as symbol commands. Each fires only when
 * the surrounding words show the speaker did not mean the noun.
 *
 * "tab" is deliberately absent and must stay absent: of the 41 corpus
 * dictations containing the word, 33 shipped a literal tab character
 * ("The tab is named run 9" -> "The \t is named run 9", polish-shadow 6490).
 * Etan effectively never dictates it as a command, so the word stays verbatim.
 */
const AMBIGUOUS_PUNCTUATION_MAP: [RegExp, string][] = [
  [/\bcolon\b/gi, ":"],
  [/\bdash\b/gi, "-"],
  [/\barrow\b/gi, "=>"],
  [/\bequals\b/gi, "="],
  [/\bplus\b/gi, "+"],
  [/\bminus\b/gi, "-"],
  [/\bslash\b/gi, "/"],
  [/\bpipe\b/gi, "|"],
  [/\bhash\b/gi, "#"],
  [/\bpercent\b/gi, "%"],
  [/\bnew line\b/gi, "\n"],
  [/\bnew paragraph\b/gi, "\n\n"],
];

/** Deletes a word rather than replacing one, so it needs its own evidence bar. */
const SPACE_COMMAND: [RegExp, string] = [/\bspace\b/gi, " "];

// A determiner or adjective immediately before an ambiguous word means the
// speaker said a noun: "a new line", "the dash", "some space", "that hash".
const NOUN_DETERMINERS_BEFORE = new Set([
  "a", "an", "the", "some", "this", "that", "my", "your", "our", "their",
  "no", "any", "every", "big", "little", "new", "next", "last",
]);

// A preposition or auxiliary verb immediately after means the same thing the
// other way round: "space to think", "the pipe was leaking", "hash is not".
const NOUN_FOLLOWERS_AFTER = new Set([
  "to", "for", "in", "on", "of", "between", "with", "was", "is", "are",
  "were", "at", "from", "into", "over", "under", "about",
]);

// "plus"/"minus" are arithmetic operators, but in speech they are far more
// often the conjunction ("the readme plus updating the about", shadow 6461;
// "the smoke plus listen to section 3", shadow 6685). They fire only between
// operands — a number or a code identifier on both sides.
const ARITHMETIC_ONLY = new Set(["plus", "minus"]);

// Binary operators: with an operand on both sides there is no noun reading left
// to protect, so the operand test outranks the determiner one. "a plus b" is
// `a + b`, not the article "a" shielding the noun "plus". "hash", "percent" and
// the newline commands are absent on purpose — they are not infix operators.
const BINARY_OPERATOR_COMMANDS = new Set([
  "colon", "dash", "arrow", "equals", "plus", "minus", "slash", "pipe",
]);

// AIDEV-NOTE: Whisper punctuates each spoken command as its own comma-delimited
// token. "update colon Q3 ... new line hey Sarah comma new paragraph" came back
// as "update, colon, Q3, ... new line, hey, Sarah, comma, new paragraph."
// (Etan's v2.2.12 acceptance dictation, shadow row 2026-09-06T14:42:25Z). Those
// delimiters are whisper's, not Etan's, and they broke stage 2 twice over: the
// attach-left cleanup collapsed ", : ," to ",:,", and it ate every "\n" that
// "new line" produced. The identical words without the commas already cleaned
// correctly.
//
// A command whisper isolated between two of its OWN delimiters is a command.
// That isolation is stronger evidence than isSpokenAsNoun, which sees a comma
// on both sides, finds neither a determiner nor a preposition, and abstains —
// and it is evidence prose never carries, because whisper does not wrap
// "a new line on codex agents" in commas. So this pass substitutes the symbol
// directly and drops both delimiters, leaving the #17/#20 ALWAYS/AMBIGUOUS
// policy to decide every command it does not match.
//
// "comma" is the one command whose own replacement is a comma, so the speaker's
// single comma survives while whisper's two do not.

/** The literal phrase each spoken-command pattern matches ("\bnew line\b" -> "new line"). */
function spokenPhraseOf(pattern: RegExp): string {
  const phrase = pattern.source.replace(/^\\b/, "").replace(/\\b$/, "");
  // Guard, not a parser: the phrase goes straight into an alternation, so a
  // pattern that is anything other than plain words must fail loudly here
  // rather than become a wildcard.
  if (!/^[a-z]+(?: [a-z]+)*$/.test(phrase)) {
    throw new Error(`Spoken-command pattern is not a literal phrase: ${pattern}`);
  }
  return phrase;
}

const COMMAND_REPLACEMENTS: Map<string, string> = new Map(
  [...ALWAYS_PUNCTUATION_MAP, ...AMBIGUOUS_PUNCTUATION_MAP]
    .map(([pattern, replacement]): [string, string] => [
      spokenPhraseOf(pattern),
      replacement,
    ])
    // "Plus," and "Minus," open a sentence as ordinary connectives — "Plus, I
    // don't know if we can match it" (5 shadow rows, e.g. the MLX-vs-Flex
    // dictation). Comma-isolation is not operand evidence, and ARITHMETIC_ONLY
    // demands operands on both sides, so these keep the #17 guard and never
    // unwrap. AGENTS.md: a fix that loses Etan's words is worse than the bug.
    .filter(([phrase]) => !ARITHMETIC_ONLY.has(phrase)),
);

// Longest first so "new paragraph" is not matched as "new" would be, and
// "question mark" wins over any shorter overlap.
const COMMA_WRAPPED_COMMAND_PATTERN = new RegExp(
  `[,.]\\s*(${[...COMMAND_REPLACEMENTS.keys()]
    .sort((a, b) => b.length - a.length)
    .join("|")})\\s*[,.]`,
  "gi",
);

const COMMAND_TRAILING_PATTERN = new RegExp(
  `(?:^|[^\\p{L}\\p{N}])(?:${[...COMMAND_REPLACEMENTS.keys()]
    .sort((a, b) => b.length - a.length)
    .join("|")})\\s*$`,
  "iu",
);

/** True when `text` ends with a spoken command, so a comma after it is that command's delimiter. */
function endsWithSpokenCommand(text: string): boolean {
  return COMMAND_TRAILING_PATTERN.test(text);
}

// Lead's ruling (2026-09-06): "DROP the comma whisper inserted immediately
// before a newline/paragraph command — Etan said 'update new line', not 'update
// comma new line'; a comma survives only when he actually dictated 'comma'".
//
// unwrapCommaWrappedCommands already drops it wherever whisper supplied BOTH
// delimiters. This covers the rest — a leading comma with no trailing one, as in
// "Here are a few things, new line first of all", which kept the comma.
//
// AIDEV-NOTE: order is load-bearing. This runs BEFORE the unwrap and before any
// substitution, while a comma Etan actually dictated is still the *word*
// "comma" and cannot be matched here. Run it afterwards and it eats the real
// comma in "hey, Sarah, comma, new paragraph" — the v2.2.12 specimen.
//
// The command still has to fire: isSpokenAsNoun is consulted on the text as it
// will look with the comma gone, so prose ("if you want a break, new line is
// what you need") keeps both its comma and its words.
function dropWhisperCommaBeforeNewline(text: string): string {
  return text.replace(
    /,(\s*)(new paragraph|new line)\b/gi,
    (match: string, gap: string, phrase: string, offset: number) => {
      const head = text.slice(0, offset);
      // This comma is the RIGHT delimiter of the command before it — in
      // "week. Colon, new line" it is what lets the unwrap see ". Colon," and
      // drop whisper's stray period. Taking it here leaves "week.:".
      if (endsWithSpokenCommand(head)) {
        return match;
      }
      const tail = text.slice(offset + match.length);
      const candidate = `${head} ${gap}${phrase}${tail}`;
      const start = head.length + 1 + gap.length;
      if (isSpokenAsNoun(candidate, start, start + phrase.length)) {
        return match;
      }
      return ` ${gap}${phrase}`;
    },
  );
}

function unwrapCommaWrappedCommands(text: string): string {
  return text.replace(COMMA_WRAPPED_COMMAND_PATTERN, (match, phrase: string) => {
    const replacement = COMMAND_REPLACEMENTS.get(phrase.toLowerCase());
    return replacement === undefined ? match : ` ${replacement} `;
  });
}

function wordBefore(text: string, index: number): string {
  const match = /([\p{L}\p{N}][\p{L}\p{N}'’]*)\s*$/u.exec(text.slice(0, index));
  return match ? match[1].toLowerCase() : "";
}

function wordAfter(text: string, index: number): string {
  const match = /^\s*([\p{L}\p{N}][\p{L}\p{N}'’]*)/u.exec(text.slice(index));
  return match ? match[1].toLowerCase() : "";
}

function isOperandToken(token: string): boolean {
  if (!token) return false;
  if (/^\d+$/.test(token)) return true;
  // camelCase / single-letter identifiers ("i", "makeCounter") read as code.
  return /^[a-z]$/.test(token) || /^[a-z][\w$]*[A-Z][\w$]*$/.test(token);
}

/**
 * True when an ambiguous spoken command is being used as an ordinary noun and
 * must be left verbatim.
 */
function isSpokenAsNoun(text: string, start: number, end: number): boolean {
  const before = wordBefore(text, start);
  const after = wordAfter(text, end);
  const command = text.slice(start, end).trim().toLowerCase();

  // Operand context first: "a plus b" and "a equals b" are code, and the "a"
  // is the left operand, not a determiner shielding a noun.
  if (BINARY_OPERATOR_COMMANDS.has(command)) {
    if (isOperandToken(before) && isOperandToken(after)) return false;
    // Arithmetic needs that operand evidence; without it the word is prose.
    if (ARITHMETIC_ONLY.has(command)) return true;
  }

  if (NOUN_DETERMINERS_BEFORE.has(before)) return true;
  if (NOUN_FOLLOWERS_AFTER.has(after)) return true;
  return false;
}

/**
 * The utterance already looks like code, which is the only context where a
 * dictated "space" is plausible enough to justify deleting a word.
 */
function isCodeShaped(text: string): boolean {
  if (/[{}()[\]<>=+*\/\\|@#$%^~_`]/.test(text)) return true;
  return /\b[a-z][\w$]*[A-Z][\w$]*\b/.test(text);
}

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

/**
 * Substitute a spoken command only where it is not being used as a noun.
 * The patterns passed here must be capture-group free so the replacer's second
 * argument is the match offset.
 */
function replaceUnlessSpokenAsNoun(
  text: string,
  pattern: RegExp,
  replacement: string,
): string {
  return text.replace(pattern, (match: string, offset: number) => {
    if (isSpokenAsNoun(text, offset, offset + match.length)) {
      return match;
    }
    return ` ${replacement}`;
  });
}

function applyPunctuation(text: string): string {
  let result = text;

  for (const [pattern, replacement] of ALWAYS_PUNCTUATION_MAP) {
    result = result.replace(pattern, () => ` ${replacement}`);
  }

  for (const [pattern, replacement] of AMBIGUOUS_PUNCTUATION_MAP) {
    result = replaceUnlessSpokenAsNoun(result, pattern, replacement);
  }

  // Last, and only in code-shaped speech: "space" is the sole command that
  // removes a word instead of swapping one for a symbol.
  //
  // AIDEV-NOTE: the gate is the SHAPE of the utterance, never the fact that
  // some other command fired. Arming it on "a command fired somewhere" made
  // every sentence ending in a dictated "period" a candidate for word loss:
  // "I saw outer space period" -> "I saw outer." (Macroscope, PR #17).
  // The shape is read off `result` rather than `text` so the symbols the maps
  // above just produced count — "foo space bar open paren close paren" is code
  // only once "open paren" has become "(".
  if (isCodeShaped(result)) {
    const [spacePattern, spaceReplacement] = SPACE_COMMAND;
    result = replaceUnlessSpokenAsNoun(result, spacePattern, spaceReplacement);
  }
  // Clean up space before punctuation that should attach left
  result = result.replace(
    /(\s+)([.,;:?%)}\]`'"]|!(?!=))/g,
    (match: string, whitespace: string, punctuation: string, offset: number) => {
      // AIDEV-NOTE: a newline in this run came from "new line"/"new paragraph",
      // and nothing Etan said can follow it with a bare comma or period — a
      // sentence never opens on one. That delimiter is whisper's, left over
      // from the comma-wrapped command. Attaching it left deleted the newline,
      // which is the whole payload of the command (specimen 2026-09-06).
      if (whitespace.includes("\n")) {
        return punctuation === "," || punctuation === "."
          ? whitespace
          : match;
      }
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
  // A newline between the two marks is a dictated line break, not a cluster:
  // collapsing across it would delete the break the speaker asked for.
  return text
    .replace(/,\s*\.{1,}(?=\s|$)/g, (match) =>
      match.includes("\n") ? match : ".",
    )
    .replace(/,(\s*)([!?])(?=\s|$)/g, (match, gap: string, mark: string) =>
      gap.includes("\n") ? match : mark,
    );
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
