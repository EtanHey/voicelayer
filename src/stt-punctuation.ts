import {
  INTERROGATIVE_OPENERS,
  QUESTION_AUX_OPENERS,
  isInterrogative,
  lowerWords,
} from "./stt-interrogative";
import { questionBoundaryIndices } from "./stt-polish";
import {
  continuesSameClause,
  endsWithAbbreviation,
} from "./stt-transcript-alignment";

/**
 * Deterministic sentence-terminal punctuation restoration.
 *
 * Regression context (Etan, 2026-06-21): VoiceLayer transcriptions came back
 * with ZERO terminal punctuation ("no commas, no periods") whenever whisper did
 * not self-punctuate AND the optional LLM polish server (src/stt-polish.ts) was
 * not running. Punctuation must not depend on a separately-launched LLM daemon.
 *
 * This stage runs in the DEFAULT finalize path (see finalizeTranscriptionText)
 * and guarantees every delivered transcript ends with sentence-terminal
 * punctuation. It is deliberately conservative: it only touches the END of the
 * text, never rewrites internal content, and never appends to a bare code token,
 * slash command, or @mention. Rich INTERNAL punctuation (commas, mid-utterance
 * sentence splits) remains the job of the LLM polish layer when available — this
 * is the deterministic floor that holds when it is not.
 */

const LATER_STATEMENT_PREDICATES = new Map<string, Set<string>>([
  ["i", new Set(["am", "cannot", "don't", "dont", "guess", "had", "have", "need", "think", "want", "was", "will"])],
  ["i'm", new Set(["just", "not", "really", "so", "very"])],
  ["it", new Set(["can", "does", "doesn't", "doesnt", "has", "is", "isn't", "isnt", "was", "will"])],
  ["it's", new Set(["been", "not"])],
  ["its", new Set(["been", "not"])],
  ["this", new Set(["does", "has", "is", "isn't", "isnt", "was", "will"])],
  ["today", new Set(["is", "was"])],
  ["we", new Set(["are", "aren't", "arent", "can", "don't", "dont", "had", "have", "need", "should", "will"])],
]);

const EMBEDDED_STATEMENT_PREDECESSORS = new Set([
  "after", "although", "as", "because", "before", "how", "if", "since", "so", "that",
  "unless", "until", "what", "when", "where", "whether", "while", "why",
  "think", "know", "believe", "feel", "reckon", "suppose", "say",
]);

// Trailing terminal punctuation, optionally wrapped by a closing quote/paren/
// bracket (e.g. `go."` or `(see the notes.)`). If present, the text is already
// terminated and must be left untouched.
const ALREADY_TERMINATED = /[.!?…:;]["'”’)\]]?$/u;

// A single bare token that must never get a trailing period appended:
//   /slash-command   @mention   ~/path   ./rel   a/b/c   src/input.ts
// These are command/identifier payloads, not prose sentences. A SINGLE internal
// slash with no other path signal is NOT enough — spoken alternatives/fractions
// ("yes/no", "and/or", "3/4") are real one-word replies and must still be
// terminated. A path is recognised by a leading ~ . or /, two-or-more slashes,
// or a single slash plus a file-extension dot.
function isBareNonProseToken(text: string): boolean {
  if (/\s/u.test(text)) return false;
  if (text.startsWith("/") || text.startsWith("@")) return true;
  if (text.startsWith("~") || text.startsWith("./")) return true;
  const slashCount = (text.match(/\//gu) ?? []).length;
  if (slashCount >= 2) return true;
  if (slashCount === 1 && text.includes(".")) return true;
  return false;
}

function hasLaterStatementOpener(text: string): boolean {
  const words = lowerWords(text, Infinity);
  return words.some((word, index) => {
    if (index < 2 || index >= words.length - 1) return false;
    if (index === words.length - 2 && continuesSameClause(words, index)) {
      return false;
    }
    const predicates = LATER_STATEMENT_PREDICATES.get(word);
    if (!predicates?.has(words[index + 1]!)) return false;
    const previous = words[index - 1];
    if (!previous || QUESTION_AUX_OPENERS.has(previous)) return false;
    if (previous === "that" && words[index - 2] === "do") return true;
    return !EMBEDDED_STATEMENT_PREDECESSORS.has(previous);
  });
}

function isFreeRelativeWhClause(text: string): boolean {
  const [first, second, ...rest] = lowerWords(text, Infinity);
  return (
    first !== undefined &&
    INTERROGATIVE_OPENERS.has(first) &&
    second !== undefined &&
    !QUESTION_AUX_OPENERS.has(second) &&
    rest.some((word) => ["is", "are", "was", "were"].includes(word))
  );
}

function isBoundedTailQuestion(
  text: string,
  boundary: number,
): boolean {
  const suffix = text.slice(boundary).trim();
  const words = lowerWords(suffix, Infinity);
  const [first] = words;
  return (
    words.length <= 12 &&
    first !== undefined &&
    QUESTION_AUX_OPENERS.has(first) &&
    isInterrogative(suffix) &&
    !hasLaterStatementOpener(suffix)
  );
}

function finalClauseForTerminal(text: string): string | null {
  let finalPunctuationBoundary = -1;
  for (const match of text.matchAll(/[.!?…]["'”’)\]]?(?=\s|$)/gu)) {
    if (match.index !== undefined) {
      if (match[0].startsWith(".") && endsWithAbbreviation(text, match.index + 1)) {
        continue;
      }
      finalPunctuationBoundary = match.index + match[0].length;
    }
  }

  const questionBoundaries = questionBoundaryIndices(text);
  const finalQuestionBoundary =
    questionBoundaries.findLast((boundary) =>
      isBoundedTailQuestion(text, boundary),
    ) ?? -1;
  if (finalQuestionBoundary > finalPunctuationBoundary) {
    return text.slice(finalQuestionBoundary).trim();
  }
  if (finalPunctuationBoundary >= 0) {
    const finalClause = text.slice(finalPunctuationBoundary).trim();
    return isFreeRelativeWhClause(finalClause) ? null : finalClause;
  }

  if (isInterrogative(text) && hasLaterStatementOpener(text)) {
    return null;
  }

  return text;
}

export function restoreSentencePunctuation(text: string): string {
  const trimmed = text.trim();
  if (!trimmed) return "";

  // Already ends with sentence-terminal punctuation (optionally quoted) → done.
  if (ALREADY_TERMINATED.test(trimmed)) return trimmed;

  // Command / identifier payloads are delivered verbatim.
  if (isBareNonProseToken(trimmed)) return trimmed;

  // A dangling comma at the very end becomes the sentence terminal.
  const withoutDanglingComma = trimmed.replace(/[,，]+$/u, "");
  const base = withoutDanglingComma.length ? withoutDanglingComma : trimmed;

  // Etan's rule: never upgrade `.` to `?` without an interrogative signal from
  // the sentence that ends the text. Existing question marks remain untouched.
  const finalClause = finalClauseForTerminal(base);
  const terminal = finalClause && isInterrogative(finalClause) ? "?" : ".";
  return `${base}${terminal}`;
}
