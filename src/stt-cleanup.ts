import { applyRules, type RulesConfig } from "./rules-engine";

const BUILTIN_STT_ALIASES: Record<string, string> = {
  "voice layer codex": "VoiceLayerCodex",
  "sessions of codecs": "sessions of Codex",
  "session of codecs": "session of Codex",
  "skill creator claude": "SkillCreatorClaude",
  whisperflow: "Wispr Flow",
  "whisper flow": "Wispr Flow",
  "wisper flow": "Wispr Flow",
  "repo golems": "repoGolem",
  "brain layer": "BrainLayer",
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
};

const ORDERED_BUILTIN_STT_ALIASES = Object.fromEntries(
  Object.entries(BUILTIN_STT_ALIASES).sort((a, b) => b[0].length - a[0].length),
);

export function getSTTVocabularyPrompt(): string {
  const canonicalTerms = [...new Set(Object.values(ORDERED_BUILTIN_STT_ALIASES))];
  return canonicalTerms.join(", ");
}

export function cleanupTranscriptionText(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return "";

  const rulesConfig: RulesConfig = {
    aliases: ORDERED_BUILTIN_STT_ALIASES,
  };
  const cleaned = applyRules(trimmed, rulesConfig);
  const normalized = normalizeCanonicalTerms(
    cleaned,
    new Set(Object.values(ORDERED_BUILTIN_STT_ALIASES)),
  );
  const sentenceCased = normalizeSentenceStarts(normalized);
  return isMeaningfulTranscription(sentenceCased) ? sentenceCased : "";
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

  if (
    normalizedWords === "thank you" ||
    normalizedWords === "thanks" ||
    normalizedWords === "sad music" ||
    speechWords === "thank you" ||
    speechWords === "thanks" ||
    speechWords === "sad music" ||
    speechWords === "oh my god"
  ) {
    return false;
  }

  const nonSpeechCue =
    "\\s*(?:music|sad music|applause|laughter|laughs|noise|silence|inaudible)\\s*";
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

function normalizeCanonicalTerms(text: string, canonicalTerms: Set<string>): string {
  let result = text;
  for (const term of canonicalTerms) {
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const pattern = new RegExp(
      `(?<=^|\\s|[^\\p{L}])${escaped}(?=$|\\s|[^\\p{L}])`,
      "giu",
    );
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
  return result;
}
