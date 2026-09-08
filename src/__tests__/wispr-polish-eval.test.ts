import { describe, expect, it } from "bun:test";
import { aggregatePolishScores, scorePolishOutput } from "../wispr-polish-eval";

const selfCorrectionCase = {
  id: "self",
  input: "Okay, let's do Gemini deep, well, no, Claude deep research.",
  target: "Okay, let's do Claude deep research.",
  tags: ["self-correction"],
};

const listCase = {
  id: "list",
  input:
    "First of all, I want to do x, and second of all, I want to do y.",
  target: "1. I want to do x.\n2. I want to do y.",
  tags: ["spoken-list"],
};

describe("wispr-polish-eval", () => {
  it("scores successful self-correction collapse separately from meaning guard", () => {
    const score = scorePolishOutput({
      ...selfCorrectionCase,
      output: "Okay, let's do Claude deep research.",
    });

    expect(score.selfCorrectionPass).toBe(true);
    expect(score.noMeaningLossPass).toBe(true);
    expect(score.targetSimilarity).toBeGreaterThan(score.inputSimilarity);
  });

  it("fails the meaning guard when a candidate invents protected code tokens", () => {
    const score = scorePolishOutput({
      id: "hallucination",
      input: "Ask c mux whether brain layer is ready.",
      target: "Ask cmux whether BrainLayer is ready.",
      output: "Ask cmux whether BrainSearch is ready.",
      tags: [],
    });

    expect(score.noMeaningLossPass).toBe(false);
    expect(score.hallucinatedTokens).toContain("brainsearch");
  });

  it("scores markdown spoken-list formatting by numbered item count", () => {
    const unchanged = scorePolishOutput({ ...listCase, output: listCase.input });
    const formatted = scorePolishOutput({ ...listCase, output: listCase.target });

    expect(unchanged.listFormatPass).toBe(false);
    expect(formatted.listFormatPass).toBe(true);
  });

  it("does not count ordinal prose as a list-format case without numbered target items", () => {
    const score = scorePolishOutput({
      id: "ordinal-prose",
      input: "Can I see the collab that's first of all second of all can we try this?",
      target: "Can I see the collab? First of all, second of all, can we try this?",
      output: "Can I see the collab? First of all, second of all, can we try this?",
      tags: ["spoken-list"],
    });

    expect(score.listFormatPass).toBeNull();
  });

  it("aggregates behavior rates and overall pass rate", () => {
    const summary = aggregatePolishScores([
      scorePolishOutput({
        ...selfCorrectionCase,
        output: "Okay, let's do Claude deep research.",
      }),
      scorePolishOutput({ ...listCase, output: listCase.input }),
    ]);

    expect(summary.total).toBe(2);
    expect(summary.selfCorrectionRate).toBe(1);
    expect(summary.listFormatRate).toBe(0);
    expect(summary.noMeaningLossRate).toBe(1);
    expect(summary.overallPassRate).toBe(0.5);
  });
});
