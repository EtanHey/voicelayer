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
 * Auto mode omits the -l flag entirely, letting whisper choose.
 *
 * Initial prompts help whisper recognize domain-specific vocabulary.
 * Limited to ~224 tokens (~900 chars). Most critical terms first.
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
 * Helps whisper recognize technical terms it might otherwise garble.
 */
const ENGLISH_DEV_PROMPT =
  "The developer discussed the TypeScript deployment and Docker containerization, " +
  "mentioning the handleSocketCommand function in socket-handlers.ts and the CI/CD pipeline. " +
  "They used useEffect, useState, and React hooks with Next.js and Node.js. " +
  "The PR was merged after CodeRabbit review. Run bun test and check the WebSocket connection.";

/**
 * Hebrew dev vocabulary for initial prompt.
 * Contains common Hebrew phrases Israeli developers use, mixed with English code terms.
 */
const HEBREW_DEV_PROMPT =
  "המפתח דיבר על TypeScript ועל Docker, והזכיר את הפונקציה handleSocketCommand. " +
  "צריך לתקן באג בפונקציה של הלוגין ולהריץ את הטסטים. " +
  "תעשה פוש לברנץ' ותפתח פול ריקווסט. הפגישה על השינויים בארכיטקטורה. " +
  "השרת לא מגיב, צריך לעשות ריסטארט לקונטיינר.";

/**
 * Mixed prompt for auto-detect mode — both languages represented.
 */
const AUTO_PROMPT =
  "The developer discussed TypeScript and React with useEffect hooks. " +
  "They mentioned the handleSocketCommand function and CI/CD pipeline. " +
  "צריך לתקן באג בפונקציה של הלוגין. תעשה פוש לברנץ' ותפתח פול ריקווסט. " +
  "Run bun test, check the WebSocket, and deploy to Docker.";

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

  // Language flag: auto mode omits -l to let whisper detect
  if (normalized !== "auto") {
    const langCode = normalized === "hebrew" ? "he" : "en";
    args.push("-l", langCode);
  }

  // Initial prompt for vocabulary priming. In auto mode we skip prompting,
  // because weak/no-speech captures can hallucinate prompt-biased output.
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
