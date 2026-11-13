import { isInterrogative, QUESTION_AUX_OPENERS, QUESTION_SUBJECTS } from "./stt-interrogative";
import { endsWithAbbreviation } from "./stt-transcript-alignment";

/**
 * Model polish may not turn a statement into a question (reported 2026-11-13).
 *
 * Polish keeps every "?" it writes except in a statement or request that only
 * CONTAINS a question clause ("I'm not sure which crate it is, but anyway",
 * "Tell me which shelf you prefer, but anyway"). Losing a real "?" is the worse
 * error, so every doubt keeps the "?".
 *
 * Text alone cannot tell "I'm not sure." from "I'm not sure?" said rising; the
 * recognizer heard the audio, so a mark goes back only on its affirmative
 * statement evidence: an explicit "." or "!" at that place in the cleaned text.
 * The frame says this is where polish invents a "?"; without that evidence
 * (no mark, a comma, a dash, an ellipsis) nothing is demoted.
 *
 * A polished sentence's final "?" becomes the cleaned text's "." or "!" only
 * when all hold:
 *   1. after spoken lead-ins, the sentence opens with a first-person
 *      not-knowing frame ("I'm not sure", "I don't know", "I wonder") or an
 *      imperative request for information ("tell me", "let me know");
 *   2. no later clause opens as a direct question by the floor's
 *      `isInterrogative` or in the second person ("I'm not sure, is it
 *      merged?", "I can't tell — you think so?"), no question word stands in
 *      direct-question order ("I don't understand what do you mean"), and the
 *      sentence does not end in a confirmation tag ("I don't know right?");
 *   3. exactly one cleaned span holds the sentence's words in order (only
 *      fillers skipped), and right after it (fillers and
 *      closing quotes skipped) stands "." or "!": the cleaned sentence ends
 *      where the polished one does;
 *   4. the cleaned text contains neither "?" nor "？", so no recognizer mark can have moved.
 * Only that one mark changes, in place; words and every other polish change stay.
 */

const TERMINAL_RUN = /[.!?…]+(?=["'”’)\]]*(?:\s|$))/gu;
const WORD = /[\p{L}\p{N}][\p{L}\p{N}'’-]*/gu;
const FRAME_WINDOW = 6;

const LEAD_INS = new Set([
  "also", "so", "and", "but", "well", "okay", "ok", "now", "then", "anyway", "actually",
  "hey", "wait", "oh", "um", "uh", "alright", "yeah", "like", "maybe",
]);

const BE = "(?:i'm|im|i am|we're|were|we are)";
const NOT_SURE = "not (?:(?:really|quite|entirely|totally|so|too|100(?: percent)?) )?sure";
const DONT = "(?:don't|dont|do not)";
const CANT = "(?:can't|cant|cannot|can not)";
const NOT_KNOWING = [
  `${BE} ${NOT_SURE}`,
  NOT_SURE,
  `(?:i|we) ${DONT} (?:know|understand|remember|recall|get)`,
  "i dunno",
  "(?:(?:i|we) have )?no idea",
  `(?:i|we) ${CANT} tell`,
  "(?:i|we) wonder",
  `(?:${BE}|i was|we were) wondering`,
  `${BE} curious`,
  `${BE} trying to (?:figure out|understand)`,
];
const INFORMATION_REQUEST = [
  "tell me",
  "let me know",
  "explain",
  "show me",
  "remind me",
  "walk me through",
  "figure out",
  "find out",
  "check (?:if|whether|what|which|who|when|where|why|how)",
  "see (?:if|whether)",
];
const FRAME = new RegExp(`^(?:${[...NOT_KNOWING, ...INFORMATION_REQUEST].join("|")})(?: |$)`, "u");

const CLAUSE_SPLIT = /[,;:—–]|\s-\s|\s+(?:or|but)\s+/u;
const WH = new Set(["what", "which", "who", "whom", "whose", "where", "when", "why", "how"]);
const SECOND_PERSON = new Set(["you", "you're", "youre", "y'all", "you've", "you'd", "you'll"]);
// A sentence ending in one of these asks for confirmation, comma or not.
const TAGS = new Set(["right", "no", "huh", "correct"]);
// Fillers polish may drop between a sentence's last word and its mark.
const FILLERS = new Set(["um", "uh", "er", "erm", "ah", "hmm", "mm"]);

interface Token {
  word: string;
  start: number;
  end: number;
}

interface Terminal {
  at: number;
  run: string;
}

export interface QuestionMarkGuardResult {
  text: string;
  demoted: number;
}

function tokenize(text: string): Token[] {
  return [...text.matchAll(WORD)].map((match) => ({
    word: match[0].toLowerCase().replace(/’/gu, "'"),
    start: match.index!,
    end: match.index! + match[0].length,
  }));
}

function words(text: string): string[] {
  return tokenize(text).map((token) => token.word);
}

function terminals(text: string): Terminal[] {
  const found: Terminal[] = [];
  for (const match of text.matchAll(TERMINAL_RUN)) {
    const at = match.index!;
    if (match[0] === "." && endsWithAbbreviation(text, at + 1)) continue;
    found.push({ at, run: match[0] });
  }
  return found;
}

function sentenceStart(text: string, found: Terminal[], index: number): number {
  const previous = found[index - 1];
  const afterPrevious = previous ? previous.at + previous.run.length : 0;
  const lineBreak = text.lastIndexOf("\n", found[index]!.at - 1) + 1;
  return Math.max(afterPrevious, lineBreak);
}

function withoutLeadIns(clause: string): string {
  let rest = clause.replace(/^[^\p{L}\p{N}]+/u, "");
  for (;;) {
    const match = rest.match(/^([\p{L}]+)[^\p{L}\p{N}]+(?=[\p{L}\p{N}])/u);
    if (!match || !LEAD_INS.has(match[1]!.toLowerCase())) return rest;
    rest = rest.slice(match[0].length);
  }
}

/** A later clause that asks directly: "is it merged", "you think so". */
function asksDirectly(clause: string): boolean {
  const rest = withoutLeadIns(clause);
  return isInterrogative(rest) || SECOND_PERSON.has(words(rest)[0] ?? "");
}

/** A question word in direct-question order ("… what do you mean"), not "which one it is". */
function hasInvertedWhQuestion(sentenceWords: string[]): boolean {
  return sentenceWords.some((word, index) => {
    const next = sentenceWords[index + 1];
    return WH.has(word) && next !== undefined && !isInterrogative(next) &&
      isInterrogative(sentenceWords.slice(index + 1, index + 3).join(" "));
  });
}

/** A statement or request that only contains a question clause (rules 2 and 3). */
export function onlyContainsQuestion(sentence: string): boolean {
  const sentenceWords = words(withoutLeadIns(sentence));
  const frame = sentenceWords.slice(0, FRAME_WINDOW).join(" ").match(FRAME);
  if (!frame) return false;
  const [opener, subject] = sentenceWords.slice(frame[0].trim().split(" ").length);
  if (QUESTION_AUX_OPENERS.has(opener ?? "") && QUESTION_SUBJECTS.has(subject ?? "")) return false;
  if (hasInvertedWhQuestion(sentenceWords)) return false;
  if (TAGS.has(sentenceWords.at(-1)!)) return false;
  const later = sentence.split(CLAUSE_SPLIT).slice(1).filter((clause) => words(clause).length > 0);
  return !later.some(asksDirectly);
}

/**
 * Every cleaned-text span whose words equal the polished sentence's words in
 * order, skipping only fillers polish is known to remove. Returns [first, last]
 * token indices.
 */
function alignedSpans(cleanedTokens: Token[], sentenceWords: string[]): Array<[number, number]> {
  const spans: Array<[number, number]> = [];
  for (let first = 0; first < cleanedTokens.length; first += 1) {
    if (cleanedTokens[first]!.word !== sentenceWords[0]) continue;
    let matched = 1;
    let cursor = first + 1;
    while (matched < sentenceWords.length && cursor < cleanedTokens.length) {
      const word = cleanedTokens[cursor]!.word;
      if (word === sentenceWords[matched]) matched += 1;
      else if (!FILLERS.has(word)) break;
      cursor += 1;
    }
    if (matched === sentenceWords.length) spans.push([first, cursor - 1]);
  }
  return spans;
}

/** The terminal mark right after a token (fillers and closing quotes or brackets skipped), if any. */
function markAfter(text: string, end: number): { mark: string; at: number } | null {
  let cursor = end;
  for (;;) {
    const filler = text.slice(cursor).match(/^[\s,]+([\p{L}]+)(?![\p{L}\p{N}'’-])/u);
    if (!filler || !FILLERS.has(filler[1]!.toLowerCase())) break;
    cursor += filler[0].length;
  }
  const found = text.slice(cursor).match(/^\s*["'”’)\]]*\s*([.!?…]+)(?=["'”’)\]]*(?:\s|$))/u);
  return found ? { mark: found[1]!, at: cursor + found[0].length - found[1]!.length } : null;
}

/**
 * The cleaned text's affirmative statement mark for a polished sentence: "." or
 * "!" right after the one cleaned span that holds the sentence's words.
 * Null (keep the "?") on any doubt.
 */
function statementMark(cleanedText: string, cleanedTokens: Token[], sentenceWords: string[]): string | null {
  if (sentenceWords.length === 0) return null;
  const spans = alignedSpans(cleanedTokens, sentenceWords);
  if (spans.length !== 1) return null;
  const [, last] = spans[0]!;
  const after = markAfter(cleanedText, cleanedTokens[last]!.end);
  if (!after || !/^[.!]$/u.test(after.mark)) return null;
  if (after.mark === "." && endsWithAbbreviation(cleanedText, after.at + 1)) return null;
  return after.mark;
}

/**
 * Repair the terminal "?" marks of a polish candidate against its input. Returns
 * the candidate byte-identical when nothing needs repair.
 */
export function guardPolishQuestionMarks(
  cleanedText: string,
  polishedText: string,
): QuestionMarkGuardResult {
  if (/[?？]/u.test(cleanedText)) return { text: polishedText, demoted: 0 };
  const cleanedTokens = tokenize(cleanedText);
  const polishedTokens = tokenize(polishedText);
  const polishedTerminals = terminals(polishedText);
  const repairs: Array<{ at: number; mark: string }> = [];

  polishedTerminals.forEach((terminal, index) => {
    if (terminal.run !== "?") return;
    const start = sentenceStart(polishedText, polishedTerminals, index);
    if (!onlyContainsQuestion(polishedText.slice(start, terminal.at))) return;
    const sentenceWords = polishedTokens
      .filter((token) => token.end > start && token.end <= terminal.at)
      .map((token) => token.word);
    const mark = statementMark(cleanedText, cleanedTokens, sentenceWords);
    if (mark) repairs.push({ at: terminal.at, mark });
  });

  if (repairs.length === 0) return { text: polishedText, demoted: 0 };
  let text = polishedText;
  for (const { at, mark } of repairs) text = text.slice(0, at) + mark + text.slice(at + 1);
  return { text, demoted: repairs.length };
}
