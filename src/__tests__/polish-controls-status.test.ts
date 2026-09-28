import { describe, expect, test } from "bun:test";
import { readPolishControlsStatus } from "../polish-controls-status";

describe("polish controls status", () => {
  test("reports the four independent parser defaults", () => {
    expect(readPolishControlsStatus({})).toEqual({
      model_polish: { source: "default", raw: null, effective: "on" },
      outro_gate: { source: "default", raw: null, effective: true },
      smart_chunks: { source: "default", raw: null, effective: false },
      smart_boundaries: { source: "default", raw: null, effective: false },
    });
  });

  test("reports explicit values through existing parsers, including unknown values", () => {
    expect(readPolishControlsStatus({
      QA_VOICE_STT_POLISH: " SHADOW ",
      VOICELAYER_STT_OUTRO_GATE: "maybe",
      VOICELAYER_STT_SMART_CHUNKS: "yes",
      VOICELAYER_STT_SMART_BOUNDARIES: "yes",
    })).toEqual({
      model_polish: { source: "environment", raw: " SHADOW ", effective: "shadow" },
      outro_gate: { source: "environment", raw: "maybe", effective: false },
      smart_chunks: { source: "environment", raw: "yes", effective: true },
      smart_boundaries: { source: "environment", raw: "yes", effective: true },
    });
  });
});
