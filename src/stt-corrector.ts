import { cleanupTranscriptionText } from "./stt-cleanup";

export type STTCorrectorMode = "off" | "identity" | "rules";
export type CorrectionContext =
  | "dictionary-heavy"
  | "content-edit"
  | "no-op"
  | "mixed";
export interface STTCorrectorEnv {
  [key: string]: string | undefined;
  QA_VOICE_CORRECTOR?: string;
}

export interface STTCorrectorResult {
  inputText: string;
  text: string;
  mode: STTCorrectorMode;
  context: CorrectionContext;
  changed: boolean;
  latencyMs: number;
}

export interface STTCorrectorOptions {
  mode?: STTCorrectorMode;
  env?: STTCorrectorEnv;
}

export function getSTTCorrectorMode(
  env: STTCorrectorEnv = process.env,
): STTCorrectorMode {
  const raw = env.QA_VOICE_CORRECTOR?.trim().toLowerCase();
  if (raw === "identity" || raw === "rules") return raw;
  return "off";
}

const MIXED_SCRIPT_PATTERN = /[\u0590-\u05ff]/;

const METALINGUISTIC_RULE_PHRASES =
  /\b(?:said|say|saying|dictated|dictate|word|phrase|literal(?:ly)?)\s+(?:a\s+)?(?:question mark|period|comma|plus|percent|space)\b/i;

const HIGH_CONFIDENCE_DICTIONARY_PATTERNS: RegExp[] = [
  /\b(?:brain|voice|skill creator|orc|yash)\s+(?:layer|bar|claude|clawed|claud|codex)\b/i,
  /\bwhisperflow\b/i,
  /\bwisper\s+flow\b/i,
  /\b(?:c|cee|see)\s*mux\b/i,
  /\bcarabiner\b/i,
  /\ba\s+hundred\s+percent\b/i,
  /\b(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)\s+hundred\s+percent\b/i,
  /\b[A-Za-z]\s+plus\s+[A-Za-z]\b/i,
  /\boption\s+plus\s+f5\b/i,
];

const NON_SPEECH_PATTERNS: RegExp[] = [
  /^(?:thank you|thanks|thanks for watching)$/i,
  /^\s*\[?(?:blank[_\s-]*audio|music|music playing|sad music|silence|inaudible)\]?\s*$/i,
];

function isLikelyNonSpeechCue(text: string): boolean {
  const trimmed = text.trim();
  return NON_SPEECH_PATTERNS.some((pattern) => pattern.test(trimmed));
}

export function classifyCorrectionContext(text: string): CorrectionContext {
  const trimmed = text.trim();
  if (!trimmed) return "no-op";
  if (MIXED_SCRIPT_PATTERN.test(trimmed)) return "mixed";
  if (METALINGUISTIC_RULE_PHRASES.test(trimmed)) return "content-edit";
  if (
    HIGH_CONFIDENCE_DICTIONARY_PATTERNS.some((pattern) => pattern.test(trimmed))
  ) {
    return "dictionary-heavy";
  }
  return "no-op";
}

export function correctTranscriptionText(
  text: string,
  options: STTCorrectorOptions = {},
): STTCorrectorResult {
  const mode = options.mode ?? getSTTCorrectorMode(options.env);
  const start = performance.now();
  const context = classifyCorrectionContext(text);
  const shouldApplyRules =
    mode === "rules" &&
    (context === "dictionary-heavy" || isLikelyNonSpeechCue(text));
  const corrected = shouldApplyRules ? cleanupTranscriptionText(text) : text;
  const latencyMs = performance.now() - start;

  return {
    inputText: text,
    text: corrected,
    mode,
    context,
    changed: corrected !== text,
    latencyMs,
  };
}
