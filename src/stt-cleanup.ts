import { applyRules, type RulesConfig } from "./rules-engine";

const BUILTIN_STT_ALIASES: Record<string, string> = {
  "voice layer codex": "VoiceLayerCodex",
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
  "orc clawed": "orcClaude",
  orcclawed: "orcClaude",
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
  return normalizeCanonicalTerms(
    cleaned,
    new Set(Object.values(ORDERED_BUILTIN_STT_ALIASES)),
  );
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
