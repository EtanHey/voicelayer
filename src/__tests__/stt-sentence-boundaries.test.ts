/**
 * Unit tables for the pause-aware sentence-boundary stage.
 *
 * Everything here is pure — no model, no WAV, no whisper server. The real-audio
 * proof lives in `stt-pause-boundaries-golden.test.ts`.
 */

import { describe, expect, test } from "bun:test";
import type { PauseSpan } from "../stt-pause-map";
import {
  applyPauseAwareBoundaries,
  BOUNDARY_PAUSE_TOLERANCE_SECONDS,
  isCompleteClauseEnding,
  MIN_BOUNDARY_PAUSE_SECONDS,
  pauseStartsAt,
  pauseSupportedWordIndices,
  continuesSameClause,
  endsWithAbbreviation,
  smartBoundariesEnabled,
  speechRunsWithin,
  WORD_ALIGNMENT_TOLERANCE,
  type TranscriptSegment,
} from "../stt-sentence-boundaries";

function words(text: string): string[] {
  return (text.toLowerCase().match(/[\p{L}\p{N}'’]+/gu) ?? []).map((word) =>
    word.replace(/’/g, "'"),
  );
}

describe("isCompleteClauseEnding", () => {
  const complete = [
    "words",
    "itself",
    "now",
    "guess",
    "redeployed",
    "on",
    "fast",
    "week",
    "usage",
    "silence",
  ];
  const incomplete = [
    "and",
    "or",
    "but",
    "so",
    "because",
    "that",
    "which",
    "to",
    "of",
    "for",
    "with",
    "the",
    "a",
    "an",
    "i",
    "i'm",
    "you",
    "we",
    "they",
    "is",
    "are",
    "was",
    "were",
    "like",
    "just",
    "then",
    "if",
    "when",
  ];

  for (const word of complete) {
    test(`"${word}" can end a clause`, () => {
      expect(isCompleteClauseEnding(word)).toBe(true);
    });
  }
  for (const word of incomplete) {
    test(`"${word}" cannot end a clause`, () => {
      expect(isCompleteClauseEnding(word)).toBe(false);
    });
  }

  test("is case-insensitive and accepts curly apostrophes", () => {
    expect(isCompleteClauseEnding("I'm")).toBe(false);
    expect(isCompleteClauseEnding("I’m")).toBe(false);
    expect(isCompleteClauseEnding("The")).toBe(false);
    expect(isCompleteClauseEnding("Words")).toBe(true);
  });

  test("an empty token is never a complete ending", () => {
    expect(isCompleteClauseEnding("")).toBe(false);
  });
});

describe("speechRunsWithin", () => {
  test("splits a window on every overlapping pause", () => {
    const pauses: PauseSpan[] = [
      { startS: 2, endS: 3 },
      { startS: 5, endS: 6 },
    ];
    expect(speechRunsWithin(pauses, 0, 8)).toEqual([
      { startS: 0, endS: 2 },
      { startS: 3, endS: 5 },
      { startS: 6, endS: 8 },
    ]);
  });

  test("clips a pause that straddles the window edge", () => {
    const pauses: PauseSpan[] = [{ startS: 7, endS: 12 }];
    expect(speechRunsWithin(pauses, 5, 10)).toEqual([{ startS: 5, endS: 7 }]);
  });

  test("a window entirely inside a pause has no speech", () => {
    expect(speechRunsWithin([{ startS: 0, endS: 10 }], 3, 6)).toEqual([]);
  });

  test("no pauses means the whole window is one run", () => {
    expect(speechRunsWithin([], 1, 4)).toEqual([{ startS: 1, endS: 4 }]);
  });

  test("unsorted pauses give the same answer", () => {
    const pauses: PauseSpan[] = [
      { startS: 5, endS: 6 },
      { startS: 2, endS: 3 },
    ];
    expect(speechRunsWithin(pauses, 0, 8)).toEqual([
      { startS: 0, endS: 2 },
      { startS: 3, endS: 5 },
      { startS: 6, endS: 8 },
    ]);
  });

  test("an empty or inverted window has no runs", () => {
    expect(speechRunsWithin([], 4, 4)).toEqual([]);
    expect(speechRunsWithin([], 6, 2)).toEqual([]);
  });
});

describe("pauseStartsAt", () => {
  const pauses: PauseSpan[] = [
    { startS: 10, endS: 10.2 }, // too short to be a stop
    { startS: 20, endS: 21 },
  ];

  test("a long enough pause starting at the time counts", () => {
    expect(pauseStartsAt(pauses, 20)).toBe(true);
  });

  test("it counts inside the tolerance and not outside it", () => {
    expect(pauseStartsAt(pauses, 20 - BOUNDARY_PAUSE_TOLERANCE_SECONDS)).toBe(
      true,
    );
    expect(pauseStartsAt(pauses, 20 + BOUNDARY_PAUSE_TOLERANCE_SECONDS)).toBe(
      true,
    );
    expect(pauseStartsAt(pauses, 20.4)).toBe(false);
  });

  test("a pause shorter than the floor is breath, not a stop", () => {
    expect(pauseStartsAt(pauses, 10)).toBe(false);
    expect(MIN_BOUNDARY_PAUSE_SECONDS).toBe(0.4);
  });
});

describe("pauseSupportedWordIndices", () => {
  test("marks the words around each run end, within the tolerance", () => {
    const segments: TranscriptSegment[] = [
      { text: "one two three four five", startS: 0, endS: 5 },
    ];
    const pauses: PauseSpan[] = [
      { startS: 3, endS: 4 },
      { startS: 5, endS: 6 },
    ];
    // Runs [0,3] = 3 s and [4,5] = 1 s over 5 words: the first run ends at
    // round(3/4*5) = 4 words, so index 3 closes it, index 4 closes the second,
    // and WORD_ALIGNMENT_TOLERANCE widens each by a word.
    expect([...pauseSupportedWordIndices(segments, pauses)].sort()).toEqual([
      2, 3, 4,
    ]);
  });

  test("a word far from any run end is never supported", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie delta echo foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
    ];
    const supported = pauseSupportedWordIndices(segments, [
      { startS: 8, endS: 9 },
    ]);
    // One run, ending on "hotel" (7); tolerance reaches back to "golf" (6).
    expect([...supported].sort((a, b) => a - b)).toEqual([6, 7]);
    expect(supported.has(2)).toBe(false);
  });

  test("the tolerance is one word on each side", () => {
    expect(WORD_ALIGNMENT_TOLERANCE).toBe(1);
  });

  test("a segment whose end is not a pause marks no final word", () => {
    const segments: TranscriptSegment[] = [
      { text: "one two three", startS: 0, endS: 3 },
    ];
    expect(
      pauseSupportedWordIndices(segments, [{ startS: 9, endS: 10 }]).size,
    ).toBe(0);
  });

  test("indices continue across segments", () => {
    const segments: TranscriptSegment[] = [
      { text: "one two", startS: 0, endS: 2 },
      { text: "three four", startS: 3, endS: 5 },
    ];
    const pauses: PauseSpan[] = [
      { startS: 2, endS: 3 },
      { startS: 5, endS: 6 },
    ];
    expect([...pauseSupportedWordIndices(segments, pauses)].sort()).toEqual([
      0, 1, 2, 3,
    ]);
  });

  test("a run too short to hold a word marks nothing", () => {
    const segments: TranscriptSegment[] = [
      { text: "alpha beta gamma delta", startS: 0, endS: 5 },
    ];
    const pauses: PauseSpan[] = [
      { startS: 0.05, endS: 1 },
      { startS: 5, endS: 6 },
    ];
    const supported = pauseSupportedWordIndices(segments, pauses);
    expect(supported.has(0)).toBe(false);
    expect(supported.has(3)).toBe(true);
  });

  test("no segments and no pauses give nothing", () => {
    expect(pauseSupportedWordIndices([], [{ startS: 0, endS: 1 }]).size).toBe(0);
    expect(
      pauseSupportedWordIndices([{ text: "one", startS: 0, endS: 1 }], []).size,
    ).toBe(0);
  });
});

/**
 * Two pause-delimited segments, long enough that a break in the middle of one
 * is unambiguously far from its run end:
 *   "alpha bravo charlie delta echo foxtrot golf hotel" | pause |
 *   "india juliett kilo lima mike" | pause
 * Supported words are "golf"/"hotel" (6,7) and "lima"/"mike" (11,12).
 */
const SEGMENTS: TranscriptSegment[] = [
  {
    text: "alpha bravo charlie delta echo foxtrot golf hotel",
    startS: 0,
    endS: 8,
  },
  { text: "india juliett kilo lima mike", startS: 9, endS: 14 },
];
const PAUSES: PauseSpan[] = [
  { startS: 8, endS: 9 },
  { startS: 14, endS: 15 },
];

describe("applyPauseAwareBoundaries", () => {
  test("keeps a break that sits on a pause after a complete clause", () => {
    const text =
      "Alpha bravo charlie delta echo foxtrot golf hotel. India juliett kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, SEGMENTS, PAUSES);
    expect(result.text).toBe(text);
    expect(result.demotions).toEqual([]);
  });

  test("Rule B keeps a break with no pause when a new subject follows", () => {
    // Etan ruled B: no pause is fine as long as the next words really do start
    // a new sentence. "Delta ..." is not a continuation of "alpha bravo charlie".
    const text =
      "Alpha bravo charlie. Delta echo foxtrot golf hotel india juliett kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, SEGMENTS, PAUSES);
    expect(result.text).toBe(text);
    expect(result.demotions).toEqual([]);
  });

  test("Rule B demotes a break the following words carry on", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie i guess foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie. I guess foxtrot golf hotel india juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.text).toBe(
      "Alpha bravo charlie, I guess foxtrot golf hotel india juliett kilo lima mike.",
    );
    expect(result.demotions).toEqual([
      { wordIndex: 2, word: "charlie", mark: ".", reason: "continues-clause" },
    ]);
  });

  test("a pause outranks the continuation test", () => {
    // "hotel" sits on a real pause, so its mark survives even though "I guess"
    // follows: (i) is satisfied and (ii) never has to be asked.
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie delta echo foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      { text: "i guess kilo lima mike", startS: 9, endS: 14 },
    ];
    const text =
      "Alpha bravo charlie delta echo foxtrot golf hotel. I guess kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, segments, PAUSES);
    expect(result.text).toBe(text);
    expect(result.demotions).toEqual([]);
  });

  test("demotes a break on a pause when the clause is incomplete", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie delta echo foxtrot golf and",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie delta echo foxtrot golf and. India juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.text).toBe(
      "Alpha bravo charlie delta echo foxtrot golf and, india juliett kilo lima mike.",
    );
    expect(result.demotions[0]).toMatchObject({
      word: "and",
      reason: "incomplete-clause",
    });
  });

  test("never adds a break at a pause the text did not mark", () => {
    const text =
      "Alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, SEGMENTS, PAUSES);
    expect(result.text).toBe(text);
    expect(result.demotions).toEqual([]);
  });

  test("never touches the final mark", () => {
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie delta echo foxtrot golf hotel india juliett kilo lima mike.",
      SEGMENTS,
      PAUSES,
    );
    expect(result.text.endsWith(".")).toBe(true);
  });

  test("leaves an ellipsis fragment alone", () => {
    // AGENTS.md: a cut-off word keeps its "fu…" and carries on.
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo fu delta echo foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const text =
      "Alpha bravo fu... delta echo foxtrot golf hotel. India juliett kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, segments, PAUSES);
    expect(result.text).toBe(text);
    expect(result.demotions).toEqual([]);
  });

  test("keeps 'I' capitalised after a demotion", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie i guess foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie. I guess foxtrot golf hotel india juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.text).toContain("charlie, I guess");
  });

  test("demotes a break followed by a word that cannot open a sentence", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie of echo foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie. Of echo foxtrot golf hotel india juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.demotions[0]).toMatchObject({
      word: "charlie",
      reason: "continues-clause",
    });
  });

  test("keeps a proper noun capitalised after a demotion", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie i guess voicelayer golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    // "VoiceLayer" is CamelCase, so it is a name and not a sentence start.
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie. I guess VoiceLayer golf hotel india juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.text).toContain("charlie, I guess VoiceLayer");
  });

  test("demotes a question mark to a comma too", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie i mean echo golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie? I mean echo golf hotel india juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.demotions[0]?.mark).toBe("?");
    expect(result.text).toContain("charlie, I mean");
  });

  test("skips loudly rather than guessing", () => {
    expect(applyPauseAwareBoundaries("", SEGMENTS, PAUSES).skippedReason).toBe(
      "empty text",
    );
    expect(
      applyPauseAwareBoundaries("Alpha bravo.", [], PAUSES).skippedReason,
    ).toBe("no segments");
    // An empty pause map is NOT a skip any more — see "no pause map" above.
    expect(
      applyPauseAwareBoundaries("Alpha bravo.", SEGMENTS, []).skippedReason,
    ).toBeUndefined();
    const unrelated = applyPauseAwareBoundaries(
      "Totally different text here.",
      SEGMENTS,
      PAUSES,
    );
    expect(unrelated.skippedReason).toBe("could not align to segments");
    expect(unrelated.text).toBe("Totally different text here.");
  });

  test("a word polish rewrote keeps its neighbours judgeable", () => {
    // Raw "1", polished "one": the rewritten word has no alignment of its own,
    // but the break after "and" is still judged (incomplete clause).
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie and 1 foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie and. One foxtrot golf hotel india juliett kilo lima mike.",
      segments,
      PAUSES,
    );
    expect(result.text).toContain("and, one foxtrot");
  });
});

describe("word preservation (property)", () => {
  const cases: string[] = [
    "Alpha bravo charlie. Delta echo foxtrot golf hotel india juliett kilo lima mike.",
    "Alpha bravo? Charlie delta! Echo foxtrot golf hotel india juliett kilo lima mike.",
    "Alpha bravo charlie delta. Echo foxtrot. Golf hotel india juliett kilo lima mike.",
  ];

  for (const [index, text] of cases.entries()) {
    test(`case ${index + 1} never loses, adds or reorders a word`, () => {
      const result = applyPauseAwareBoundaries(text, SEGMENTS, PAUSES);
      // Etan, AGENTS.md: a fix that loses his words is worse than the bug.
      expect(words(result.text)).toEqual(words(text));
    });
  }

  test("the count of terminal marks never grows", () => {
    for (const text of cases) {
      const result = applyPauseAwareBoundaries(text, SEGMENTS, PAUSES);
      const terminals = (value: string): number =>
        (value.match(/[.!?]/g) ?? []).length;
      expect(terminals(result.text)).toBeLessThanOrEqual(terminals(text));
    }
  });

  test("a demotion only rewrites the mark and the following word's case", () => {
    const segments: TranscriptSegment[] = [
      {
        text: "alpha bravo charlie i guess foxtrot golf hotel",
        startS: 0,
        endS: 8,
      },
      SEGMENTS[1],
    ];
    const text =
      "Alpha bravo charlie. I guess foxtrot golf hotel india juliett kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, segments, PAUSES);
    expect(result.demotions).toHaveLength(1);
    expect(result.text.toLowerCase()).toBe(
      text.toLowerCase().replace(". i guess", ", i guess"),
    );
  });
});

describe("abbreviations are never demoted", () => {
  const segments: TranscriptSegment[] = [
    {
      text: "alpha bravo dr smith echo foxtrot golf hotel",
      startS: 0,
      endS: 8,
    },
    { text: "india juliett kilo lima mike", startS: 9, endS: 14 },
  ];
  const pauses: PauseSpan[] = [
    { startS: 8, endS: 9 },
    { startS: 14, endS: 15 },
  ];

  test("endsWithAbbreviation recognises the shared rules-engine set", () => {
    for (const text of ["Dr.", "Mr.", "e.g.", "vs.", "Ph.D.", "etc."]) {
      expect(endsWithAbbreviation(text, text.length)).toBe(true);
    }
  });

  test("it recognises dotted initialisms like U.S.", () => {
    expect(endsWithAbbreviation("in the U.S.", "in the U.S.".length)).toBe(true);
    expect(endsWithAbbreviation("a.m.", "a.m.".length)).toBe(true);
  });

  test("an ordinary word ending a sentence is not an abbreviation", () => {
    expect(endsWithAbbreviation("the words.", "the words.".length)).toBe(false);
    expect(endsWithAbbreviation("", 0)).toBe(false);
  });

  test("'Dr. Smith' keeps its period even with no pause under it", () => {
    // Demoting it would corrupt the word into "Dr, Smith".
    const text =
      "Alpha bravo Dr. Smith echo foxtrot golf hotel india juliett kilo lima mike.";
    const result = applyPauseAwareBoundaries(text, segments, pauses);
    expect(result.text).toContain("Dr. Smith");
    expect(result.demotions).toEqual([]);
  });

  test("a question mark is still judged — only periods can be abbreviations", () => {
    const withHedge: TranscriptSegment[] = [
      { text: "alpha bravo charlie i mean echo golf hotel", startS: 0, endS: 8 },
      segments[1],
    ];
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie? I mean echo golf hotel india juliett kilo lima mike.",
      withHedge,
      pauses,
    );
    expect(result.demotions).toHaveLength(1);
  });
});

describe("no pause map (Rule B arm (ii) alone)", () => {
  const segments: TranscriptSegment[] = [
    { text: "alpha bravo charlie i guess foxtrot golf hotel", startS: 0, endS: 8 },
    { text: "india juliett kilo lima mike", startS: 9, endS: 14 },
  ];

  test("it still judges, instead of skipping", () => {
    // Macroscope round 1: an empty pause map used to skip the stage entirely.
    // Rule B's second arm needs no audio, so it must still run.
    const result = applyPauseAwareBoundaries(
      "Alpha bravo charlie. I guess foxtrot golf hotel india juliett kilo lima mike.",
      segments,
      [],
    );
    expect(result.skippedReason).toBeUndefined();
    expect(result.text).toContain("charlie, I guess");
  });

  test("a mark followed by a new subject still survives with no pauses", () => {
    const fresh: TranscriptSegment[] = [
      { text: "alpha bravo charlie delta echo foxtrot golf hotel", startS: 0, endS: 8 },
      segments[1],
    ];
    const text =
      "Alpha bravo charlie. Delta echo foxtrot golf hotel india juliett kilo lima mike.";
    expect(applyPauseAwareBoundaries(text, fresh, []).text).toBe(text);
  });
});

describe("decomposed Unicode", () => {
  test("a combining mark does not split a word in two", () => {
    // "café" as c-a-f-e + U+0301. Before the fix the tokenizer cut after "cafe".
    const decomposed = "cafe\u0301";
    const segments: TranscriptSegment[] = [
      {
        text: `alpha bravo ${decomposed} i guess foxtrot golf hotel`,
        startS: 0,
        endS: 8,
      },
      { text: "india juliett kilo lima mike", startS: 9, endS: 14 },
    ];
    const result = applyPauseAwareBoundaries(
      `Alpha bravo ${decomposed}. I guess foxtrot golf hotel india juliett kilo lima mike.`,
      segments,
      [
        { startS: 8, endS: 9 },
        { startS: 14, endS: 15 },
      ],
    );
    expect(result.skippedReason).toBeUndefined();
    expect(result.demotions[0]?.word).toBe(decomposed);
  });
});

describe("continuesSameClause (Rule B)", () => {
  const carriesOn: string[][] = [
    ["i", "guess", "like"],
    ["i", "think", "so"],
    ["i", "mean", "really"],
    ["you", "know", "what"],
    ["or", "something", "else"],
    ["kind", "of", "slow"],
    ["of", "the", "thing"],
    ["with", "them"],
    ["than", "that"],
  ];
  const startsFresh: string[][] = [
    ["it", "might", "have"],
    ["delta", "echo"],
    ["so", "here", "is"],
    ["well", "anyway"],
    ["voicelayer", "works"],
    ["i", "went", "there"],
    ["you", "should", "know"],
    ["the", "recording", "died"],
  ];

  for (const words of carriesOn) {
    test(`"${words.join(" ")}" carries on the clause`, () => {
      expect(continuesSameClause(words, 0)).toBe(true);
    });
  }
  for (const words of startsFresh) {
    test(`"${words.join(" ")}" starts a new subject`, () => {
      expect(continuesSameClause(words, 0)).toBe(false);
    });
  }

  test("it reads from the given index, and past the end is not a continuation", () => {
    expect(continuesSameClause(["alpha", "i", "guess"], 1)).toBe(true);
    expect(continuesSameClause(["alpha", "i", "guess"], 0)).toBe(false);
    expect(continuesSameClause(["alpha"], 5)).toBe(false);
  });

  test("case and curly apostrophes do not matter", () => {
    expect(continuesSameClause(["I", "Guess"], 0)).toBe(true);
  });
});

describe("known limitations", () => {
  // Macroscope round 1, finding 7. The LCS backtrack can anchor a position to a
  // different occurrence of a repeated word. The alignment stays monotonic, so
  // the effect is a word or two of timing drift that WORD_ALIGNMENT_TOLERANCE
  // already absorbs — documented rather than fixed until a real transcript
  // breaks on it.
  test.todo(
    "alignWords should anchor a repeated word to its nearest occurrence",
  );
});

describe("smartBoundariesEnabled", () => {
  test("only an explicit opt-in turns it on", () => {
    expect(smartBoundariesEnabled({})).toBe(false);
    expect(smartBoundariesEnabled({ VOICELAYER_STT_SMART_BOUNDARIES: "" })).toBe(
      false,
    );
    expect(
      smartBoundariesEnabled({ VOICELAYER_STT_SMART_BOUNDARIES: "0" }),
    ).toBe(false);
    expect(
      smartBoundariesEnabled({ VOICELAYER_STT_SMART_BOUNDARIES: "off" }),
    ).toBe(false);
    for (const value of ["1", "true", "on", "yes", "TRUE", " On "]) {
      expect(
        smartBoundariesEnabled({ VOICELAYER_STT_SMART_BOUNDARIES: value }),
      ).toBe(true);
    }
  });
});
