import { describe, expect, it } from "bun:test";

import {
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

  it("applies the existing cleanup and rules pipeline in rules mode", () => {
    const result = correctTranscriptionText("ask yash clawed about brain layer", {
      mode: "rules",
    });

    expect(result.text).toBe("Ask YashClaude about BrainLayer");
    expect(result.changed).toBe(true);
    expect(result.latencyMs).toBeLessThan(10);
  });

  it("suppresses non-speech hallucinations in rules mode", () => {
    expect(correctTranscriptionText("thank you", { mode: "rules" }).text).toBe("");
  });
});
