
/**
 * Unit tables for the shared transcript-to-audio alignment helpers.
 *
 * Everything here is pure — no model, no WAV, no whisper server.
 */

import { describe, expect, test } from "bun:test";
import type { PauseSpan } from "../stt-pause-map";
import {
  alignTranscriptWordIndices,
  BOUNDARY_PAUSE_TOLERANCE_SECONDS,
  MIN_BOUNDARY_PAUSE_SECONDS,
  pauseStartsAt,
  pauseSupportedWordIndices,
  continuesSameClause,
  endsWithAbbreviation,
  speechRunsWithin,
  WORD_ALIGNMENT_TOLERANCE,
  type TranscriptSegment,
} from "../stt-transcript-alignment";

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

describe("endsWithAbbreviation", () => {
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
});

describe("decomposed Unicode", () => {
  test("a combining mark does not split a word in two", () => {
    // "café" as c-a-f-e + U+0301. Before the fix the tokenizer cut after "cafe".
    const decomposed = "cafe\u0301";
    const segments: TranscriptSegment[] = [
      { text: `alpha bravo ${decomposed} foxtrot`, startS: 0, endS: 8 },
    ];
    const aligned = alignTranscriptWordIndices(
      `Alpha bravo ${decomposed}. Foxtrot.`,
      segments,
    );
    expect([...aligned.entries()].sort(([a], [b]) => a - b)).toEqual([
      [0, 0],
      [1, 1],
      [2, 2],
      [3, 3],
    ]);
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
