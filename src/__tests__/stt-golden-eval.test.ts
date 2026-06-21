import { describe, expect, test } from "bun:test";
import {
  assessGoldenTranscript,
  findAdjacentDuplicateRun,
  normalizeEvalWords,
} from "../stt-golden-eval";

// Deterministic, CI-safe RED→GREEN for the golden-WAV gate's detectors. These
// prove the gate CATCHES the regression classes (fabricated/non-overlapping
// append, dropped content, punctuation drop) and PASSES a clean decode — so the
// live golden-WAV harness (stt-golden-eval-live.test.ts) is judging correctly.

const SCRIPT =
  "Item one is the first. Item two is the second. Item three is the third. Item four is the fourth.";

describe("findAdjacentDuplicateRun", () => {
  test("returns null on non-repeating text", () => {
    expect(findAdjacentDuplicateRun(normalizeEvalWords(SCRIPT), 4)).toBeNull();
  });

  test("detects an immediately-repeated block (chunk-boundary echo)", () => {
    const words = normalizeEvalWords(
      "the build is green the build is green ship it",
    );
    const run = findAdjacentDuplicateRun(words, 4);
    expect(run).not.toBeNull();
    expect(run?.length).toBeGreaterThanOrEqual(4);
  });

  test("ignores short incidental repeats below minRun", () => {
    expect(
      findAdjacentDuplicateRun(normalizeEvalWords("it is very very good"), 4),
    ).toBeNull();
  });
});

describe("assessGoldenTranscript", () => {
  const anchors = ["one", "two", "three", "four"];

  test("PASS on a clean, punctuation-rich, complete transcript", () => {
    const result = assessGoldenTranscript(SCRIPT, SCRIPT, { anchors });
    expect(result.ok).toBe(true);
    expect(result.reasons).toEqual([]);
  });

  test("FAIL when a fabricated/non-overlapping append is present", () => {
    const hallucinated = `${SCRIPT} Item four is the fourth. Item four is the fourth.`;
    const result = assessGoldenTranscript(SCRIPT, hallucinated, { anchors });
    expect(result.ok).toBe(false);
    expect(result.fabricatedAppend).not.toBeNull();
    expect(result.reasons.join(" ")).toContain("fabricated append");
  });

  test("FAIL on a runaway hallucinated continuation (drift ratio)", () => {
    const runaway = `${SCRIPT} and then everything kept going on and on far beyond what was ever spoken aloud here today friends`;
    const result = assessGoldenTranscript(SCRIPT, runaway, {
      anchors,
      maxDriftRatio: 1.35,
    });
    expect(result.ok).toBe(false);
    expect(result.reasons.join(" ")).toMatch(/append|drift/);
  });

  test("FAIL when content is dropped (anchors missing)", () => {
    const dropped = "Item one is the first.";
    const result = assessGoldenTranscript(SCRIPT, dropped, { anchors });
    expect(result.ok).toBe(false);
    expect(result.missingAnchors).toContain("two");
  });

  test("FAIL when punctuation is dropped (the PR #308 regression)", () => {
    const bare =
      "item one is the first item two is the second item three is the third item four is the fourth";
    const result = assessGoldenTranscript(SCRIPT, bare, { anchors });
    expect(result.ok).toBe(false);
    expect(result.hasPunctuation).toBe(false);
    expect(result.reasons.join(" ")).toContain("punctuation");
  });
});
