/**
 * Transcript defect detectors for the chunk-seam gates.
 *
 * These name the three things AGENTS.md promises about a transcript — nothing
 * added, nothing repeated back-to-back, nothing lost — in a form a test can
 * assert. Kept out of the `.test.ts` files so they are importable and unit
 * tested on their own, with no fixture, no model and no whisper server.
 */

/** Lowercase, strip punctuation, collapse whitespace — casing varies run to run. */
function normalize(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s.']/gu, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function words(text: string): string[] {
  return normalize(text).replace(/[.']/g, "").split(" ").filter(Boolean);
}

/**
 * Longest run of ≥4 words that repeats immediately after itself.
 * This is AGENTS.md defect #2 — "a sentence sometimes repeats back-to-back".
 */
export function findAdjacentDuplicateRun(text: string): string | null {
  const list = words(text);
  for (let length = Math.floor(list.length / 2); length >= 4; length--) {
    for (let index = 0; index + 2 * length <= list.length; index++) {
      const left = list.slice(index, index + length).join(" ");
      const right = list.slice(index + length, index + 2 * length).join(" ");
      if (left === right) return left;
    }
  }
  return null;
}

/**
 * Anchor matching compares LETTER SEQUENCES, not tokens.
 *
 * Whisper splits the same audio as "CodeRabbit.yaml" or "code rabbit.yaml",
 * "ChatGPT" or "chat gpt", run to run. Those are spacing choices, not words
 * Etan lost, and a gate that fails on them measures the tokenizer instead of
 * the defect. Dropping separators keeps the check on the thing that matters:
 * did the sounds he actually said survive the chunk seam?
 */
export function anchorKey(text: string): string {
  return text.toLowerCase().replace(/[^\p{L}\p{N}]/gu, "");
}

export function findMissingAnchors(text: string, anchors: string[]): string[] {
  const haystack = anchorKey(text);
  return anchors.filter((anchor) => !haystack.includes(anchorKey(anchor)));
}

/**
 * A >=3-word phrase said twice with only a few words between the two copies.
 *
 * `findAdjacentDuplicateRun` only sees an exact back-to-back repeat of >=4
 * words. The damage a chunk seam actually leaves is looser than that: round 2
 * of PR #21 produced "and I mean, just like, and I mean, ChatGPT Codex
 * Connector" — three words repeated across a two-word gap, invisible to the
 * strict detector and to a >=4-word floor. Both knobs are deliberately tight
 * (>=3 words, <=`maxGapWords` between copies) because loosening either starts
 * flagging speech Etan really said, and AGENTS.md is explicit that a genuine
 * repeat must survive.
 */
export function findNearRepeat(
  text: string,
  { minWords = 3, maxGapWords = 3 }: { minWords?: number; maxGapWords?: number } = {},
): string | null {
  const list = words(text);
  for (let length = Math.max(minWords, 3); length <= 8; length++) {
    for (let index = 0; index + length <= list.length; index++) {
      const phrase = list.slice(index, index + length).join(" ");
      for (let gap = 0; gap <= maxGapWords; gap++) {
        const start = index + length + gap;
        if (start + length > list.length) break;
        if (list.slice(start, start + length).join(" ") === phrase) {
          return gap === 0 ? phrase : `${phrase} (+${gap}-word gap)`;
        }
      }
    }
  }
  return null;
}

export function findInventedBreaks(
  text: string,
  breaks: Array<{ name: string; pattern: string }>,
): string[] {
  return breaks
    .filter((entry) => new RegExp(entry.pattern, "i").test(text))
    .map((entry) => entry.name);
}

