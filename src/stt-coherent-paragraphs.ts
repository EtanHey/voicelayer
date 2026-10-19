import { endsWithAbbreviation } from "./stt-sentence-boundaries";

/**
 * Coherent paragraphs (PARA1): break a long dictation between coherent units —
 * a completed sentence, preferably where the subject changes — instead of only
 * where a long pause happens to sit under a full stop.
 *
 * Etan, 2026-10-19: "it's not about real pauses, it's about coherent sentence
 * ending or coherent subject changing". So this stage reads only the text: no
 * segments, no Silero, works on every backend and on the chunked path.
 *
 * AIDEV-NOTE: the ONLY edit is replacing the horizontal whitespace after an
 * existing single `.`, `?` or `!` with "\n\n". Ellipses, "fu…" fragments,
 * abbreviations, retractions and lowercase continuations are never break
 * points, and a final guard returns the input unchanged if any non-whitespace
 * character moved.
 */

/** Below either floor the dictation stays one paragraph. */
export const COHERENT_MIN_WORDS = 80;
export const COHERENT_MIN_SENTENCES = 4;
/** Preferred paragraph length; Etan's target is roughly 3–8 sentences. */
const TARGET_WORDS = 100;
const MAX_SENTENCES = 8;
/** A break must be earned: an even split alone does not pay for it. */
const BREAK_COST = 0.5;

export function coherentParagraphsEnabled(env: Record<string, string | undefined>): boolean {
  const raw = env.VOICELAYER_STT_COHERENT_PARAGRAPHS?.trim().toLowerCase();
  return !!raw && ["1", "true", "on", "yes"].includes(raw);
}

// The next sentence opens a new subject.
const SHIFT_OPENER = /^(?:anyways?\b|moving on\b|by the way\b|on another note\b|another thing\b|one more thing\b|separately\b|speaking of\b|(?:and )?as for\b|other than that\b|(?:apart|aside) from that\b|(?:okay|ok|alright|all right),? so\b|now,? (?:the|as|for|about|let)\b|next,|second(?:ly)?,|third,|finally\b|lastly\b|last thing\b|also,|oh,? and\b|in terms of\b|regarding\b|the other thing\b|then there'?s\b|on the other hand\b)/u;
// Weaker hints of a turn.
const SOFT_OPENER = /^(?:now\b|so,|okay,|ok,|alright,|also\b|besides\b|plus\b|meanwhile\b|oh,|well,|i'?m also\b|i also\b|and also\b|one of\b|a question\b|my question\b)/u;
// The next sentence leans on the previous one.
const CONTINUATION_OPENER = /^(?:because\b|'?cause\b|which\b|that'?s why\b|so that\b|or\b|but\b|and\b|nor\b|than\b|whereas\b|(?:even )?though\b|although\b|for\b|like\b|including\b|except\b)/u;
const ANAPHORA_OPENER = /^(?:it|it'?s|its|this|that|these|those|he|she|they|there)\b/u;

const STOPWORDS = new Set((
  "about above after again also always another anything because been before being both could does doing done each even every from have having here into just like little made make many more most much must need only other over really same should some something still such than that their them then there these they thing things think this those though through very want what when where which while will with would your yeah okay going actually maybe pretty kind sort know mean guess right well said says thats dont didnt cant wont im ive ill its theres were whats".split(" ")
));

function contentWords(sentence: string): Set<string> {
  const out = new Set<string>();
  for (const m of sentence.toLowerCase().matchAll(/[\p{L}\p{N}\p{M}'’]+/gu)) {
    const w = m[0].replace(/['’]/gu, "");
    if (w.length < 4 || STOPWORDS.has(w)) continue;
    out.add(w.endsWith("s") && w.length > 4 ? w.slice(0, -1) : w);
  }
  return out;
}

function wordCount(s: string): number {
  return (s.match(/[\p{L}\p{N}]+/gu) ?? []).length;
}

function opener(sentence: string): string {
  return sentence.replace(/^["'“‘(\[]+/u, "").toLowerCase();
}

interface Boundary { start: number; end: number }

// Titles, months, days and common short forms the shared set does not cover.
const EXTRA_ABBREVIATIONS = new Set((
  "capt col gen lt sgt cmdr adm gov sen rep rev hon pres supt det insp fr br sr jr st mt ft " +
  "jan feb mar apr jun jul aug sep sept oct nov dec mon tue tues wed thu thur thurs fri sat sun " +
  "approx dept est fig no nos vol vols ch sec pp op ed eds inc ltd corp co bros assn univ ave blvd rd hwy"
).split(" "));

/**
 * The whitespace-delimited token that owns the mark at `at` must read as a
 * plain word. When in doubt, no break: an initial ("J."), a short form, a URL
 * or path ("help?", "docs/setup.md."), an address or any dotted token
 * ("example.com.", "v2.3.") never ends a sentence here.
 */
function plainSentenceToken(text: string, at: number): boolean {
  const token = /\S*$/u.exec(text.slice(0, at))![0].replace(/^["'“‘(\[]+/u, "");
  if (/[/@\\:=&#]|www\.|\.\S/u.test(token)) return false;
  const word = token.replace(/["'”’»)\]]+$/u, "");
  if (text[at] === "." && /^\p{L}$/u.test(word)) return false;
  if (text[at] === "." && EXTRA_ABBREVIATIONS.has(word.toLowerCase())) return false;
  return true;
}

/** Whitespace runs after a completed sentence that may become "\n\n". */
function sentenceBoundaries(text: string): Boundary[] {
  const out: Boundary[] = [];
  for (const m of text.matchAll(/[.!?]["'”’»)\]]*([^\S\r\n]+)(?=\S)/gu)) {
    const at = m.index!;
    // A single mark after a word: "...", "?." or a bare mark is not a sentence end.
    if (!/[\p{L}\p{N}\p{M}'’"”)\]%]/u.test(text[at - 1] ?? "")) continue;
    if (text[at] === "." && endsWithAbbreviation(text, at)) continue;
    if (!plainSentenceToken(text, at)) continue;
    const next = text.slice(at + m[0].length);
    // A lowercase opener continues the sentence (cased scripts only).
    if (/^["'“‘(\[]*\p{Ll}/u.test(next)) continue;
    const start = at + m[0].length - m[1].length;
    out.push({ start, end: at + m[0].length });
  }
  return out;
}

function breakScore(prev: string[], next: string[]): number {
  const head = opener(next[0]);
  let score = 0;
  if (SHIFT_OPENER.test(head)) score += 2;
  else if (CONTINUATION_OPENER.test(head)) score -= 2;
  else if (SOFT_OPENER.test(head)) score += 1;
  else if (ANAPHORA_OPENER.test(head)) score -= 0.5;
  if (wordCount(next[0]) < 4) score -= 1;
  const last = prev.at(-1)!;
  if (wordCount(last) < 3) score -= 0.5;
  // A short lead-in ("Then she looked.") belongs with what follows it.
  else if (wordCount(last) < 5 && (CONTINUATION_OPENER.test(opener(last)) || /^then\b/u.test(opener(last)))) score -= 1;
  // Lexical shift: how little the two sides share (TextTiling-style).
  const left = contentWords(prev.slice(-2).join(" "));
  const right = contentWords(next.slice(0, 2).join(" "));
  if (left.size && right.size) {
    let shared = 0;
    for (const w of left) if (right.has(w)) shared++;
    score += 1 - shared / Math.min(left.size, right.size);
  }
  return score;
}

function paragraphCost(words: number, sentences: number): number {
  const over = Math.max(0, sentences - MAX_SENTENCES);
  return ((words - TARGET_WORDS) / 70) ** 2 + 3 * over;
}

function feasible(words: number, sentences: number): boolean {
  return words >= 40 && (sentences >= 3 || words >= 65);
}

export function applyCoherentParagraphs(text: string): string {
  // Existing paragraphs or list lines win; a lone soft wrap does not.
  if (/\r?\n[^\S\r\n]*\r?\n/u.test(text) || /(?:^|\n)[^\S\r\n]*(?:\d+[.)]|[-*•])[^\S\r\n]/u.test(text)) return text;
  const boundaries = sentenceBoundaries(text);
  const units: string[] = [];
  let from = 0;
  for (const b of boundaries) {
    units.push(text.slice(from, b.start));
    from = b.end;
  }
  units.push(text.slice(from));
  const counts = units.map(wordCount);
  const total = counts.reduce((a, b) => a + b, 0);
  if (units.length < COHERENT_MIN_SENTENCES || total < COHERENT_MIN_WORDS) return text;

  const n = units.length;
  const prefix = [0];
  for (const c of counts) prefix.push(prefix.at(-1)! + c);
  const scores = boundaries.map((_, k) => breakScore(units.slice(0, k + 1), units.slice(k + 1)));
  // best[j]: best value for units [0, j) where unit j starts a new paragraph.
  const best: number[] = new Array(n + 1).fill(-Infinity);
  const back: number[] = new Array(n + 1).fill(-1);
  best[0] = 0;
  for (let j = 1; j <= n; j++) {
    for (let i = 0; i < j; i++) {
      if (best[i] === -Infinity) continue;
      const words = prefix[j] - prefix[i];
      const sentences = j - i;
      const whole = i === 0 && j === n;
      if (!whole && !feasible(words, sentences)) continue;
      const gain = i === 0 ? 0 : scores[i - 1] - BREAK_COST;
      const value = best[i] + gain - paragraphCost(words, sentences);
      if (value > best[j]) { best[j] = value; back[j] = i; }
    }
  }
  const cuts: number[] = [];
  for (let j = n; j > 0; j = back[j]) if (back[j] > 0) cuts.push(back[j] - 1);
  if (!cuts.length) return text;
  let out = text;
  for (const k of cuts.sort((a, b) => b - a)) {
    out = out.slice(0, boundaries[k].start) + "\n\n" + out.slice(boundaries[k].end);
  }
  // Word-identity guard: only whitespace may differ.
  const strip = (s: string) => s.replace(/\s+/gu, " ").trim();
  return strip(out) === strip(text) ? out : text;
}
