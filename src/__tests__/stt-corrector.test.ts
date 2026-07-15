import { describe, expect, it } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";

import {
  classifyCorrectionContext,
  correctTranscriptionText,
  getSTTCorrectorMode,
} from "../stt-corrector";

describe("stt-corrector", () => {
  it("defaults to off so callers can preserve existing cleanup behavior", () => {
    expect(getSTTCorrectorMode({})).toBe("off");
    expect(getSTTCorrectorMode({ QA_VOICE_CORRECTOR: "" })).toBe("off");
  });

  it("returns unchanged text for identity mode", () => {
    const result = correctTranscriptionText("brain layer", { mode: "identity" });

    expect(result).toMatchObject({
      inputText: "brain layer",
      text: "brain layer",
      mode: "identity",
      changed: false,
    });
    expect(result.latencyMs).toBeGreaterThanOrEqual(0);
  });

  it("classifies high-confidence dictionary triggers separately from prose", () => {
    expect(classifyCorrectionContext("ask yash clawed about brain layer")).toBe(
      "dictionary-heavy",
    );
    expect(classifyCorrectionContext("I am a hundred percent sure.")).toBe(
      "dictionary-heavy",
    );
    expect(classifyCorrectionContext("Ok, it's researching. I'll let you know.")).toBe(
      "no-op",
    );
    expect(classifyCorrectionContext("K שווה שישים זה הסטנדרט")).toBe("mixed");
  });

  it("applies deterministic rules only for high-confidence dictionary-heavy text", () => {
    correctTranscriptionText("warm up brain layer", { mode: "rules" });
    const result = correctTranscriptionText("ask yash clawed about brain layer", {
      mode: "rules",
    });

    expect(result.text).toBe("Ask YashClaude about BrainLayer");
    expect(result.context).toBe("dictionary-heavy");
    expect(result.changed).toBe(true);
    expect(result.latencyMs).toBeLessThan(10);
  });

  it("passes no-op prose through without mutating capitalization or fillers", () => {
    const result = correctTranscriptionText(
      "Ok, it's researching. I'll let you know when it's done.",
      { mode: "rules" },
    );

    expect(result.text).toBe("Ok, it's researching. I'll let you know when it's done.");
    expect(result.context).toBe("no-op");
    expect(result.changed).toBe(false);
  });

  it("passes content-edit prose through instead of converting dictated punctuation", () => {
    const result = correctTranscriptionText(
      "I said question mark, and it dictated it like you saw here.",
      { mode: "rules" },
    );

    expect(result.text).toBe(
      "I said question mark, and it dictated it like you saw here.",
    );
    expect(result.context).toBe("content-edit");
    expect(result.changed).toBe(false);
  });

  it("suppresses non-speech hallucinations in rules mode", () => {
    expect(correctTranscriptionText("thank you", { mode: "rules" }).text).toBe("");
  });

  it("preserves every Phase-0 should_change:false tripwire", () => {
    const fixturePath = join(
      import.meta.dir,
      "../../eval/fixtures/stt-phase0-mined.jsonl",
    );
    const rows = readFileSync(fixturePath, "utf8")
      .trim()
      .split("\n")
      .map((line) => JSON.parse(line))
      .filter((row) => row.should_change === false);

    expect(rows).toHaveLength(52);
    for (const row of rows) {
      expect(
        correctTranscriptionText(row.input_text, { mode: "rules" }).text,
        row.id,
      ).toBe(row.target_text);
    }
  });

  it("keeps warm p95 latency under the 5ms budget", () => {
    correctTranscriptionText("ask yash clawed about brain layer", { mode: "rules" });
    const latencies = Array.from({ length: 50 }, () =>
      correctTranscriptionText("ask yash clawed about brain layer", { mode: "rules" })
        .latencyMs,
    ).sort((a, b) => a - b);
    const p95 = latencies[Math.floor(latencies.length * 0.95)];

    expect(p95).toBeLessThan(5);
  });
});
