/**
 * Language configuration for STT — whisper language args and initial prompts.
 *
 * Three modes:
 * - auto: whisper auto-detects language (best for mixed Hebrew-English)
 * - hebrew: force Hebrew language detection
 * - english: force English (legacy default)
 *
 * AIDEV-NOTE: From R1 research — "Stock Whisper with auto-detection is a better
 * starting point for bilingual speech than ivrit-ai models, which degrade English."
 * Auto mode passes `-l auto` explicitly because whisper.cpp defaults to English
 * when the language flag is omitted.
 *
 * Initial prompts help whisper recognize domain-specific vocabulary.
 * Limited to ~224 tokens (~900 chars). Most critical terms first.
 * VOCABULARY-ONLY format (no complete sentences) reduces hallucination risk on
 * silence/noise while still priming for correct casing and term recognition.
 */

export type LanguageMode = "auto" | "hebrew" | "english";

export interface LanguageConfig {
  mode: LanguageMode;
  /** Whisper language code: "en", "he", or "auto" */
  whisperLang: string;
  /** Complete whisper CLI args for language and initial prompt */
  whisperArgs: string[];
}

/**
 * English dev vocabulary for initial prompt.
 * Vocabulary-only format (no imperative sentences) reduces hallucination risk
 * while still priming Whisper for correct casing and recognition.
 */
const ENGLISH_DEV_PROMPT =
  "TypeScript JavaScript React Next.js Node.js Docker Kubernetes " +
  "useEffect useState useCallback handleSocketCommand socket-handlers.ts " +
  "CI/CD pipeline deployment CodeRabbit GitHub WebSocket bun test";

/**
 * Hebrew dev vocabulary for initial prompt.
 * Common Hebrew dev terms mixed with English code terms. Vocabulary format only.
 */
const HEBREW_DEV_PROMPT =
  "TypeScript Docker handleSocketCommand באג פונקציה לוגין טסטים " +
  "פוש ברנץ' פול ריקווסט ארכיטקטורה שרת ריסטארט קונטיינר";

/**
 * Mixed prompt for auto-detect mode — both languages represented.
 * Vocabulary-only to prevent hallucinating imperative commands on silence.
 */
const AUTO_PROMPT =
  "TypeScript React useEffect handleSocketCommand CI/CD WebSocket Docker " +
  "באג פונקציה לוגין פוש ברנץ' פול ריקווסט bun test";

/**
 * Get the initial prompt for the given language mode.
 */
export function getInitialPrompt(mode: LanguageMode): string {
  switch (mode) {
    case "hebrew":
      return HEBREW_DEV_PROMPT;
    case "english":
      return ENGLISH_DEV_PROMPT;
    case "auto":
    default:
      return AUTO_PROMPT;
  }
}

/**
 * Get full language configuration for whisper CLI.
 *
 * @param mode Language mode from config or env var
 * @returns Config with whisperLang code and complete CLI args
 */
export function getLanguageConfig(mode: LanguageMode | string): LanguageConfig {
  const normalized = normalizeMode(mode);
  const prompt = getInitialPrompt(normalized);

  const args: string[] = [];

  // Always pass the language flag: whisper.cpp defaults to English when omitted.
  const langCode =
    normalized === "hebrew" ? "he" : normalized === "english" ? "en" : "auto";
  args.push("-l", langCode);

  // Initial prompt for vocabulary priming. Auto mode skips prompts so
  // borderline silence/noise cannot decode into prompt-biased dev phrases.
  if (normalized !== "auto") {
    args.push("--prompt", prompt);
  }

  return {
    mode: normalized,
    whisperLang:
      normalized === "hebrew" ? "he" : normalized === "english" ? "en" : "auto",
    whisperArgs: args,
  };
}

/**
 * Normalize mode string to a valid LanguageMode.
 */
function normalizeMode(mode: string): LanguageMode {
  const lower = mode.toLowerCase().trim();
  if (lower === "hebrew" || lower === "he") return "hebrew";
  if (lower === "english" || lower === "en") return "english";
  if (lower === "auto") return "auto";
  return "auto"; // default
}

/**
 * Read language mode from environment or config.
 * Priority: QA_VOICE_WHISPER_LANG env var > config file > "auto"
 */
export function getLanguageModeFromEnv(): LanguageMode {
  const envLang = process.env.QA_VOICE_WHISPER_LANG;
  if (envLang) return normalizeMode(envLang);
  return "auto";
}
