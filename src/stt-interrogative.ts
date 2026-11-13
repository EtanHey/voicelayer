/**
 * The interrogative signal: one definition for every stage that may place a
 * question mark (the terminal-punctuation floor in stt-punctuation.ts and the
 * identifier-digit join in rules-engine.ts). Etan's law: never upgrade "." to
 * "?" without an interrogative signal from that sentence.
 */

// Question words that, when they START an utterance, make it interrogative.
export const INTERROGATIVE_OPENERS = new Set([
  "what",
  "what's",
  "whats",
  "why",
  "why's",
  "how",
  "how's",
  "hows",
  "when",
  "where",
  "where's",
  "who",
  "who's",
  "whom",
  "whose",
  "which",
]);

// Yes/no questions open with an auxiliary verb. A BARE aux opener is ambiguous
// with an imperative ("do not use wait_for_all", "have a nice day"), so we only
// treat aux openers as questions when the SECOND word is a subject pronoun /
// demonstrative ("do you ...", "is this ...", "should I ..."). This honours the
// standing rule that real questions must never be statement-ized, while leaving
// imperatives ("do not ...") as statements.
export const QUESTION_AUX_OPENERS = new Set([
  "do",
  "does",
  "did",
  "is",
  "are",
  "am",
  "was",
  "were",
  "can",
  "could",
  "should",
  "would",
  "will",
  "have",
  "has",
  "had",
  "may",
  "might",
  "shall",
  // Negated/contracted forms whisper emits before a subject ("isn't it",
  // "don't you", "can't we"). lowerWords normalizes curly apostrophes to ';
  // the apostrophe-less variants cover whisper dropping the apostrophe.
  "isn't",
  "isnt",
  "aren't",
  "arent",
  "wasn't",
  "wasnt",
  "weren't",
  "werent",
  "don't",
  "dont",
  "doesn't",
  "doesnt",
  "didn't",
  "didnt",
  "can't",
  "cant",
  "couldn't",
  "couldnt",
  "shouldn't",
  "shouldnt",
  "wouldn't",
  "wouldnt",
  "won't",
  "wont",
  "haven't",
  "havent",
  "hasn't",
  "hasnt",
  "hadn't",
  "hadnt",
]);

export const QUESTION_SUBJECTS = new Set([
  "you",
  "i",
  "we",
  "it",
  "he",
  "she",
  "they",
  "this",
  "that",
  "there",
  "these",
  "those",
]);

export function lowerWords(text: string, limit: number): string[] {
  return (text.toLowerCase().match(/[\p{L}\p{N}''’-]+/gu) ?? [])
    .slice(0, limit)
    .map((word) => word.replace(/[''’]/g, "'"));
}

export function isInterrogative(text: string): boolean {
  const [first, second] = lowerWords(text, 2);
  if (!first) return false;
  if (INTERROGATIVE_OPENERS.has(first)) return true;
  return (
    QUESTION_AUX_OPENERS.has(first) &&
    second !== undefined &&
    QUESTION_SUBJECTS.has(second)
  );
}

// Words that may open a sentence before the question proper ("Also, is it …").
const QUESTION_LEAD_INS = new Set([
  "also", "so", "and", "but", "well", "okay", "ok", "now", "then", "anyway",
  "actually", "hey", "wait", "oh", "um", "uh",
]);

const IMPERATIVE_CAPABLE_AUX = new Set(["do", "have", "had", "may", "might", "shall", "don't", "dont"]);
const NOUN_PHRASE_OPENERS = new Set([
  "the", "a", "an", "my", "your", "our", "their", "his", "her", "its", "any", "all", "some",
]);

/**
 * A stricter signal for MOVING an existing "?" within a sentence: some clause
 * of the sentence (after spoken lead-ins) opens as a direct question — an
 * auxiliary plus a subject ("is it", "did you", "is the fix") or a question word plus an
 * auxiliary ("why did", "what is"). A bare question word is not enough here
 * ("when I checked …" is a statement), so an unsure sentence keeps its marks.
 */
export function hasDirectQuestionOpener(sentence: string): boolean {
  return sentence.split(/[,;:\u2014]/u).some((clause) => {
    const words = lowerWords(clause, 6);
    while (words.length > 2 && QUESTION_LEAD_INS.has(words[0]!)) words.shift();
    const [first, second] = words;
    if (!first || !second) return false;
    if (QUESTION_AUX_OPENERS.has(first)) {
      if (QUESTION_SUBJECTS.has(second)) return true;
      // "Is the fix ready …", "Did our build pass …": a noun-phrase subject.
      // "do", "have", "had", "may" also open imperatives and wishes ("do the
      // thing", "have a look"), so those still need a pronoun subject.
      return !IMPERATIVE_CAPABLE_AUX.has(first) && NOUN_PHRASE_OPENERS.has(second);
    }
    return INTERROGATIVE_OPENERS.has(first) && QUESTION_AUX_OPENERS.has(second);
  });
}
