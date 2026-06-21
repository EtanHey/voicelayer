/**
 * Golden-WAV STT regression-eval detectors.
 *
 * Deterministic, dependency-free assertions used by the golden-WAV gate
 * (src/__tests__/stt-golden-eval.test.ts) to judge a real transcription of a
 * KNOWN spoken script. Split out from the test so the detector logic itself has
 * a CI-safe RED→GREEN unit gate (it must CATCH a fabricated/non-overlapping
 * append, a dropped section, and missing punctuation — and PASS a clean decode)
 * even on machines without whisper.
 *
 * The failure modes this guards (gen-17/18 Whisper regressions):
 *  - non-overlapping / fabricated append at a chunk boundary (a repeated tail
 *    n-gram, or a runaway hallucinated continuation that balloons word count)
 *  - dropped content (anchor phrases missing)
 *  - punctuation drop (the regression fixed in PR #308 — guarded end-to-end)
 */

export function normalizeEvalWords(text: string): string[] {
  return text
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]+/gu, " ")
    .split(/\s+/u)
    .filter(Boolean);
}

/**
 * Find the first immediately-repeated block of >= minRun words
 * (`A B C D A B C D`). This is the signature of a non-overlapping chunk-boundary
 * append / hallucinated echo that the merge layer is supposed to dedupe.
 * Returns the run length and start index, or null if none.
 */
export function findAdjacentDuplicateRun(
  words: string[],
  minRun = 4,
): { start: number; length: number } | null {
  const maxRun = Math.floor(words.length / 2);
  for (let length = maxRun; length >= minRun; length--) {
    for (let start = 0; start + 2 * length <= words.length; start++) {
      let match = true;
      for (let i = 0; i < length; i++) {
        if (words[start + i] !== words[start + length + i]) {
          match = false;
          break;
        }
      }
      if (match) return { start, length };
    }
  }
  return null;
}

export interface GoldenAssessmentOptions {
  /** Distinct content words that MUST appear (proves no large drop). */
  anchors?: string[];
  /** Max allowed actual/expected word-count ratio (runaway-append guard). */
  maxDriftRatio?: number;
  /** Min allowed actual/expected word-count ratio (large-drop guard). */
  minDriftRatio?: number;
  /** Min adjacent-duplicate run length treated as a fabricated append. */
  minDupRun?: number;
  /** How many anchors may be missing before it fails. */
  maxMissingAnchors?: number;
}

export interface GoldenAssessment {
  ok: boolean;
  hasPunctuation: boolean;
  endsTerminated: boolean;
  driftRatio: number;
  fabricatedAppend: { start: number; length: number } | null;
  missingAnchors: string[];
  reasons: string[];
}

export function assessGoldenTranscript(
  expected: string,
  actual: string,
  options: GoldenAssessmentOptions = {},
): GoldenAssessment {
  const {
    anchors = [],
    maxDriftRatio = 1.35,
    minDriftRatio = 0.6,
    minDupRun = 4,
    maxMissingAnchors = 0,
  } = options;

  const expectedWords = normalizeEvalWords(expected);
  const actualWords = normalizeEvalWords(actual);
  const driftRatio = actualWords.length / Math.max(1, expectedWords.length);

  const hasPunctuation = /[.?!]/u.test(actual);
  const endsTerminated = /[.?!]["'”’)\]]?$/u.test(actual.trim());
  const fabricatedAppend = findAdjacentDuplicateRun(actualWords, minDupRun);

  const actualSet = new Set(actualWords);
  const missingAnchors = anchors
    .map((a) => a.toLowerCase())
    .filter((a) => !actualSet.has(a));

  const reasons: string[] = [];
  if (!hasPunctuation) reasons.push("no sentence punctuation");
  if (!endsTerminated) reasons.push("transcript not terminated");
  if (fabricatedAppend) {
    reasons.push(
      `fabricated append: ${fabricatedAppend.length}-word block repeated at index ${fabricatedAppend.start}`,
    );
  }
  if (driftRatio > maxDriftRatio) {
    reasons.push(`runaway append: drift ratio ${driftRatio.toFixed(2)}`);
  }
  if (driftRatio < minDriftRatio) {
    reasons.push(`dropped content: drift ratio ${driftRatio.toFixed(2)}`);
  }
  if (missingAnchors.length > maxMissingAnchors) {
    reasons.push(`missing anchors: ${missingAnchors.join(", ")}`);
  }

  return {
    ok: reasons.length === 0,
    hasPunctuation,
    endsTerminated,
    driftRatio,
    fabricatedAppend,
    missingAnchors,
    reasons,
  };
}
