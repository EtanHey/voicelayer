import { existsSync, readdirSync, readFileSync, statSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { applyRules, type RulesConfig } from "./rules-engine";
import {
  getSTTVocabularyPath,
  isUnsafeDynamicAliasSource,
} from "./stt-vocabulary-store";

export interface STTCleanupEnv {
  [key: string]: string | undefined;
  QA_VOICE_STT_VOCABULARY_PATH?: string;
  QA_VOICE_STT_VOCABULARY_DISABLED?: string;
  QA_VOICE_STT_COMMANDS_DIR?: string;
}

interface STTVocabularyAlias {
  from: string;
  to: string;
}

interface STTVocabularySnapshot {
  prompt_terms?: unknown;
  aliases?: unknown;
}

type CanonicalTermPattern = [string, RegExp, string];

const BUILTIN_STT_ALIASES: Record<string, string> = {
  "voice layer codex": "VoiceLayerCodex",
  "sessions of codecs": "sessions of Codex",
  "session of codecs": "session of Codex",
  "skill creator claude": "SkillCreatorClaude",
  "פול ריקווסט": "Pull Request",
  "לבראנץ": "ל-branch",
  "לבראנץ'": "ל-branch",
  "לברנץ": "ל-branch",
  "לברנץ'": "ל-branch",
  "בראנץ": "branch",
  "בראנץ'": "branch",
  "ברנץ": "branch",
  "ברנץ'": "branch",
  "קומיט": "commit",
  "פוש": "push",
  "yash claude": "YashClaude",
  "yash claud": "YashClaude",
  "yash clawed": "YashClaude",
  yashclaude: "YashClaude",
  yashclaud: "YashClaude",
  yashclawed: "YashClaude",
  whisperflow: "Wispr Flow",
  "whisper flow": "Wispr Flow",
  "wisper flow": "Wispr Flow",
  "repo golems": "repoGolem",
  "brain layer": "BrainLayer",
  "brain layer claude": "BrainLayer Claude",
  "brain layer clawed": "BrainLayer Claude",
  "brain layer claud": "BrainLayer Claude",
  "brain bar": "BrainBar",
  "voice bar": "VoiceBar",
  "voice layer": "VoiceLayer",
  "orc claude": "orcClaude",
  "orc claud": "orcClaude",
  "orc clawed": "orcClaude",
  orcclaud: "orcClaude",
  orcclawed: "orcClaude",
  "ask or claude": "ask orcClaude",
  "tell or claude": "tell orcClaude",
  "message or claude": "message orcClaude",
  "pending cue is working": "pending queue is working",
  "pending cues are working": "pending queues are working",
  meital: "Meytal",
  maital: "Meytal",
  "may tall": "Meytal",
  maytal: "Meytal",
  mailing: "MaiLinh",
  mylan: "MaiLinh",
  myelin: "MaiLinh",
  "mai linh": "MaiLinh",
  mailinh: "MaiLinh",
  "work claude": "orcClaude",
  "skill creator": "skillCreator",
  "skill creator clawed": "SkillCreatorClaude",
  "repo golem": "repoGolem",
  "c mux": "cmux",
  "cee mux": "cmux",
  "c max": "cmux",
  "see mux": "cmux",
  seamux: "cmux",
  golems: "Golems",
  "t 3 code": "T3 Code",
  "t three code": "T3 Code",
  "tee three code": "T3 Code",
  "q e l o s": "Qelos",
  "qelos": "Qelos",
  "key loss": "Qelos",
  "keylos": "Qelos",
  "kilos project": "Qelos project",
  "kilos programming project": "Qelos programming project",
  "nano claw": "nanoClaw",
  "nano clawed": "nanoClaw",
  nanoclaw: "nanoClaw",
  nanoclawed: "nanoClaw",
  "apple container": "Apple Container",
  docker: "Docker",
  telegram: "Telegram",
  "whats app": "WhatsApp",
  whatsapp: "WhatsApp",
  carabiner: "Karabiner",
  "claude md": "CLAUDE.md",
  "claude dot md": "CLAUDE.md",
  "gpt 5.5": "GPT-5.5",
  "gpt 5 5": "GPT-5.5",
  zigon: "zikaron",
  zikaron: "zikaron",
  "golems brain": "golems-brain",
  "golems-brain": "golems-brain",
  "~/.golems-brain/zikaron": "~/.golems-brain/zikaron",
  "osek patur": "עוסק פטור",
  osekpatur: "עוסק פטור",
  "reshut hamisim": "רשות המסים",
  reshutamisin: "רשות המסים",
  bereshutamisin: "ברשות המסים",
  rechovot: "רחובות",
  "still accept voicelayer to keep": "still expect VoiceLayer to keep",
  "still accept voice layer to keep": "still expect VoiceLayer to keep",
  "real tale of the sentence": "real tail of the sentence",
  bun: "bun",
};

function sortAliasesBySourceLength(
  aliases: Record<string, string>,
): Record<string, string> {
  return Object.fromEntries(
    Object.entries(aliases).sort((a, b) => b[0].length - a[0].length),
  );
}

const ORDERED_BUILTIN_STT_ALIASES = sortAliasesBySourceLength(
  BUILTIN_STT_ALIASES,
);
const CLEANUP_ONLY_ALIAS_VALUES = new Set([
  "still expect VoiceLayer to keep",
  "real tail of the sentence",
]);
const DUPLICATED_FUNCTION_WORD_PATTERN =
  /\b(the|an|and|to|of|a|i)\b(?:\s+\1\b)+/giu;

function buildCanonicalTermPatterns(
  aliases: Record<string, string>,
): CanonicalTermPattern[] {
  return [...new Set(Object.values(aliases))].map((term) => {
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    return [
      term.toLowerCase(),
      new RegExp(
        `(?<=^|\\s|[^\\p{L}])${escaped}(?=$|\\s|[^\\p{L}])`,
        "giu",
      ),
      term,
    ] as [string, RegExp, string];
  });
}

const BUILTIN_CANONICAL_TERM_PATTERNS = buildCanonicalTermPatterns(
  ORDERED_BUILTIN_STT_ALIASES,
);

interface LoadedVocabularySnapshot {
  path: string;
  mtimeMs: number;
  promptTerms: string[];
  aliases: Record<string, string>;
}

function getVocabularySnapshotPath(env: STTCleanupEnv): string | null {
  if (
    env.QA_VOICE_STT_VOCABULARY_PATH === "" ||
    env.QA_VOICE_STT_VOCABULARY_DISABLED
  ) {
    return null;
  }
  return getSTTVocabularyPath({ env });
}

function parseVocabularySnapshot(
  snapshot: STTVocabularySnapshot,
): Pick<LoadedVocabularySnapshot, "promptTerms" | "aliases"> {
  const promptTerms = Array.isArray(snapshot.prompt_terms)
    ? snapshot.prompt_terms.filter(
        (term): term is string => typeof term === "string" && term.trim() !== "",
      )
    : [];
  const aliases: Record<string, string> = {};
  if (Array.isArray(snapshot.aliases)) {
    for (const alias of snapshot.aliases) {
      if (
        alias &&
        typeof alias === "object" &&
        "from" in alias &&
        "to" in alias
      ) {
        const { from, to } = alias as Partial<STTVocabularyAlias>;
        if (typeof from === "string" && typeof to === "string") {
          const trimmedFrom = from.trim();
          const trimmedTo = to.trim();
          if (
            trimmedFrom &&
            trimmedTo &&
            !isUnsafeDynamicAliasSource(trimmedFrom)
          ) {
            aliases[trimmedFrom] = trimmedTo;
          }
        }
      }
    }
  }
  return { promptTerms, aliases };
}

function buildLoadedVocabularySnapshot(
  path: string,
  mtimeMs: number,
  snapshot: Pick<LoadedVocabularySnapshot, "promptTerms" | "aliases">,
): LoadedVocabularySnapshot {
  return {
    path,
    mtimeMs,
    ...snapshot,
  };
}

function getSlashCommandRoots(env: STTCleanupEnv): string[] {
  if (env.QA_VOICE_STT_COMMANDS_DIR !== undefined) {
    return env.QA_VOICE_STT_COMMANDS_DIR.split(":")
      .map((part) => part.trim())
      .filter(Boolean);
  }
  return [join(homedir(), ".claude", "commands")];
}

function commandNameFromMarkdownEntry(name: string): string | null {
  if (!name || name.startsWith(".")) return null;
  if (!name.endsWith(".md")) return null;
  if (name.toLowerCase() === "readme.md") return null;
  const commandName = name.endsWith(".md") ? name.slice(0, -3) : name;
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(commandName)) return null;
  if (commandName.toLowerCase() === "skill") return null;
  return commandName;
}

function commandNameFromDirectoryEntry(name: string): string | null {
  if (!name || name.startsWith(".")) return null;
  if (!/^[a-z0-9][a-z0-9-]*$/i.test(name)) return null;
  if (name.toLowerCase() === "skill") return null;
  return name;
}

type SlashCommandCacheEntry = {
  key: string;
  loadedAtMs: number;
  commands: string[];
};

const SLASH_COMMAND_CACHE_TTL_MS = 1000;
const SLASH_COMMAND_SUPPORT_DIRS = new Set(["assets", "references"]);
let slashCommandCache: SlashCommandCacheEntry | null = null;

function loadInstalledSlashCommands(env: STTCleanupEnv): string[] {
  const roots = getSlashCommandRoots(env);
  const key = roots.join("\0");
  if (
    slashCommandCache &&
    slashCommandCache.key === key &&
    Date.now() - slashCommandCache.loadedAtMs < SLASH_COMMAND_CACHE_TTL_MS
  ) {
    return slashCommandCache.commands;
  }

  const commands: string[] = [];
  const seen = new Set<string>();

  const visit = (dir: string) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      const entryPath = join(dir, entry.name);
      const isDirectory =
        entry.isDirectory() ||
        (entry.isSymbolicLink() &&
          (() => {
            try {
              return statSync(entryPath).isDirectory();
            } catch {
              return false;
            }
          })());

      if (isDirectory) {
        if (entry.name.startsWith(".")) continue;
        if (SLASH_COMMAND_SUPPORT_DIRS.has(entry.name.toLowerCase())) continue;
        const commandName = existsSync(join(entryPath, "SKILL.md"))
          ? commandNameFromDirectoryEntry(entry.name)
          : null;
        if (commandName) {
          const command = `/${commandName}`;
          if (!seen.has(command)) {
            seen.add(command);
            commands.push(command);
          }
          continue;
        }
        visit(entryPath);
        continue;
      }
      if (!entry.isFile() && !entry.isSymbolicLink()) continue;

      const commandName = commandNameFromMarkdownEntry(entry.name);
      if (!commandName) continue;

      const command = `/${commandName}`;
      if (!seen.has(command)) {
        seen.add(command);
        commands.push(command);
      }
    }
  };

  for (const root of roots) {
    if (!existsSync(root)) continue;
    visit(root);
  }

  slashCommandCache = { key, loadedAtMs: Date.now(), commands };
  return commands;
}

function spokenSlashCommandForms(command: string): string[] {
  const commandName = command.replace(/^\/+/, "");
  if (!commandName) return [];

  const baseWords = commandName.replace(/[-_]+/g, " ").trim();
  const variants = new Set<string>([baseWords]);
  if (/\bwhats\b/i.test(baseWords)) {
    variants.add(baseWords.replace(/\bwhats\b/gi, "what's"));
    variants.add(baseWords.replace(/\bwhats\b/gi, "what s"));
    variants.add(baseWords.replace(/\bwhats\b/gi, "what is"));
  }

  return [...variants].flatMap((variant) => [
    `/ ${variant}`,
    `slash ${variant}`,
  ]);
}

function buildSlashCommandAliases(commands: string[]): Record<string, string> {
  const aliases: Record<string, string> = {};
  for (const command of commands) {
    if (!/^\/[A-Za-z0-9][A-Za-z0-9-]*$/.test(command)) continue;
    for (const spoken of spokenSlashCommandForms(command)) {
      aliases[spoken] = command;
    }
  }
  return sortAliasesBySourceLength(aliases);
}

function collectSlashCommands(
  env: STTCleanupEnv,
  promptTerms: string[] = [],
): string[] {
  const commands = new Set<string>();
  for (const term of promptTerms) {
    const trimmed = term.trim();
    if (/^\/[A-Za-z0-9][A-Za-z0-9-]*$/.test(trimmed)) {
      commands.add(trimmed);
    }
  }
  for (const command of loadInstalledSlashCommands(env)) {
    commands.add(command);
  }
  return [...commands].sort();
}

type RuntimeAliasesCacheEntry = {
  key: string;
  aliases: Record<string, string>;
};

let runtimeAliasesCache: RuntimeAliasesCacheEntry | null = null;

function buildRuntimeAliases(
  env: STTCleanupEnv,
  snapshot: LoadedVocabularySnapshot | null,
): Record<string, string> {
  const slashCommands = collectSlashCommands(env, snapshot?.promptTerms);
  const snapshotAliases = snapshot?.aliases ?? {};
  const key = JSON.stringify({
    slashCommands,
    snapshotAliases: Object.entries(snapshotAliases).sort(([a], [b]) =>
      a.localeCompare(b),
    ),
  });

  if (runtimeAliasesCache?.key === key) {
    return runtimeAliasesCache.aliases;
  }

  const aliases = sortAliasesBySourceLength({
    ...ORDERED_BUILTIN_STT_ALIASES,
    ...buildSlashCommandAliases(slashCommands),
    ...snapshotAliases,
  });
  runtimeAliasesCache = { key, aliases };
  return aliases;
}

function loadVocabularySnapshot(
  env: STTCleanupEnv = process.env,
): LoadedVocabularySnapshot | null {
  const path = getVocabularySnapshotPath(env);
  if (!path) return null;

  if (!existsSync(path)) {
    return null;
  }

  try {
    const { mtimeMs } = statSync(path);
    const parsed = JSON.parse(
      readFileSync(path, "utf8"),
    ) as STTVocabularySnapshot;
    const snapshot = parseVocabularySnapshot(parsed);
    return buildLoadedVocabularySnapshot(path, mtimeMs, snapshot);
  } catch {
    return null;
  }
}

export function getSTTVocabularyPrompt(env: STTCleanupEnv = process.env): string {
  const snapshot = loadVocabularySnapshot(env);
  const slashCommands = collectSlashCommands(env, snapshot?.promptTerms ?? []);
  const canonicalTerms = [
    ...new Set([
      ...(snapshot?.promptTerms ?? []),
      ...slashCommands,
      "zikaron",
      "golems-brain",
      "~/.golems-brain/zikaron",
      "עוסק פטור",
      "רשות המסים",
      "רחובות",
      ...Object.values(ORDERED_BUILTIN_STT_ALIASES).filter(
        (term) => !CLEANUP_ONLY_ALIAS_VALUES.has(term),
      ),
    ]),
  ];
  return canonicalTerms.join(", ");
}

export function cleanupTranscriptionText(
  text: string,
  env: STTCleanupEnv = process.env,
): string {
  const trimmed = text.trim();
  if (!trimmed) return "";

  const snapshot = loadVocabularySnapshot(env);
  const aliases = buildRuntimeAliases(env, snapshot);
  const rulesConfig: RulesConfig = {
    aliases,
  };
  const cleaned = applyRules(trimmed, rulesConfig);
  const oneNormalized = normalizeConversationalOne(cleaned);
  const deduplicated = collapseDuplicatedFunctionWords(oneNormalized);
  const normalized = normalizeCanonicalTerms(
    deduplicated,
    buildCanonicalTermPatterns(aliases),
  );
  const pathNormalized = normalizePathTokens(normalized);
  const sentenceCased = normalizeSentenceStarts(pathNormalized);
  return isMeaningfulTranscription(sentenceCased) ? sentenceCased : "";
}

function collapseDuplicatedFunctionWords(text: string): string {
  return text.replace(
    DUPLICATED_FUNCTION_WORD_PATTERN,
    (_match, word: string) => word,
  );
}

function normalizeConversationalOne(text: string): string {
  return text
    .replace(/\b1(?=\s+more\b)/giu, "one")
    .replace(/\b(other)\s+1\b/giu, "$1 one")
    .replace(/\bBrainLayer\s+(?:clawed|claud)\b/giu, "BrainLayer Claude");
}

function normalizePathTokens(text: string): string {
  let result = text.replace(
    /\b(in|at|under|inside)\s+-\s*,\s+is it\s+(?=~\s*\/)/giu,
    (_match, preposition: string) => `${preposition} `,
  );

  result = result.replace(/~\s*\/[^,;!?]*/gu, (match) =>
    match.replace(/\s*\/\s*/g, "/").replace(/\s*-\s*/g, "-").toLowerCase(),
  );

  result = result.replace(
    /(?<!\S)(?=[A-Za-z0-9._~-]*\s*\/)[A-Za-z0-9._~-]+(?:\s*[/-]\s*[A-Za-z0-9._~-]+)+(?!\S)/gu,
    (match) => {
      if (/^\/[A-Za-z0-9-]+$/u.test(match.trim())) return match;
      if (/^[A-Za-z]+\s+\/\s*[A-Za-z0-9-]+$/u.test(match.trim())) {
        return match;
      }
      return match
        .replace(/\s*\/\s*/g, "/")
        .replace(/\s*-\s*/g, "-")
        .toLowerCase();
    },
  );

  return result;
}

function isMeaningfulTranscription(text: string): boolean {
  const trimmed = text.trim();
  if (!trimmed) return false;

  if (trimmed === "?" || /^[/@]\S/.test(trimmed)) {
    return true;
  }

  const lower = trimmed.toLowerCase();
  const normalizedWords = lower
    .replace(/^[\s"'`]+|[\s"'`]+$/g, "")
    .replace(/[.!?]+$/g, "")
    .trim();
  const speechWords = lower
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .replace(/\s+/g, " ")
    .trim();

  const exactNoisePhrases = new Set([
    "blank audio",
    "music playing",
    "sad music",
    "subtitle by rev com",
    "subtitle by rev.com",
    "subtitle by rev dot com",
    "thank you",
    "thanks",
    "thanks for watching",
    "oh my god",
  ]);

  if (exactNoisePhrases.has(normalizedWords) || exactNoisePhrases.has(speechWords)) {
    return false;
  }

  const nonSpeechCue =
    "\\s*(?:blank[_\\s-]*audio|music|music playing|sad music|applause|laughter|laughs|noise|silence|inaudible)\\s*";
  const bracketedCuePattern = new RegExp(
    `^(?:\\(${nonSpeechCue}\\)|\\[${nonSpeechCue}\\]|\\{${nonSpeechCue}\\}|<${nonSpeechCue}>)$`,
    "iu",
  );
  if (bracketedCuePattern.test(trimmed)) {
    return false;
  }

  if (/^[\p{P}\p{S}\s]+$/u.test(trimmed)) {
    return false;
  }

  if (/^-\s+\S/.test(trimmed)) {
    return true;
  }

  return true;
}

function normalizeCanonicalTerms(
  text: string,
  patterns = BUILTIN_CANONICAL_TERM_PATTERNS,
): string {
  let result = text;
  const lowerResult = result.toLowerCase();
  for (const [termLower, pattern, term] of patterns) {
    if (!lowerResult.includes(termLower)) continue;
    result = result.replace(pattern, term);
  }
  return result;
}

function normalizeSentenceStarts(text: string): string {
  if (!text) return text;
  let result = text.replace(
    /(^|[.!?]\s+)(ask|tell|message) orcClaude\b/giu,
    (_match, prefix: string, verb: string) => {
      return `${prefix}${verb[0].toUpperCase()}${verb.slice(1).toLowerCase()} orcClaude`;
    },
  );
  result = result.replace(
    /(^|[.!?]\s+)pending queue(s?) (is|are) working\b/giu,
    (_match, prefix: string, plural: string, verb: string) => {
      return `${prefix}Pending queue${plural.toLowerCase()} ${verb.toLowerCase()} working`;
    },
  );
  result = result.replace(
    /(^|[.!?]\s+)still expect VoiceLayer to keep\b/giu,
    "$1Still expect VoiceLayer to keep",
  );
  result = result.replace(
    /(^|[.!?]\s+)real tail of the sentence\b/giu,
    "$1Real tail of the sentence",
  );
  result = result.replace(/(^|[.!?]\s+)one more\b/giu, "$1One more");
  return result;
}
