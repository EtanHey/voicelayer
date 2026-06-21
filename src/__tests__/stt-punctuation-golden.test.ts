import { describe, expect, test } from "bun:test";
import { existsSync } from "fs";
import { join } from "path";
import { WhisperCppBackend } from "../stt";
import { finalizeTranscriptionText } from "../input";

// Golden-WAV live-outcome gate (R-008 / R-014 family): a committed real WAV is
// run through the REAL whisper backend + REAL finalize pipeline and the output
// is asserted to be punctuation-rich. This catches the "ZERO punctuation"
// regression end-to-end (whisper losing punctuation, the deterministic restorer
// being removed, or the pipeline delivering a bare transcript).
//
// Skips cleanly when whisper-cli / the model is absent (e.g. minimal CI) — the
// fixture + assertion still document the contract, and the deterministic unit
// test in stt-punctuation.test.ts holds the hard RED→GREEN.

const FIXTURE = join(import.meta.dir, "fixtures", "golden-punctuation.wav");
const modelInfo = new WhisperCppBackend().getModelInfo();
const hasWhisper = Boolean(modelInfo.binary && modelInfo.model);
const maybe = hasWhisper ? test : test.skip;

describe("golden-WAV STT punctuation", () => {
  test("the golden fixture exists", () => {
    expect(existsSync(FIXTURE)).toBe(true);
  });

  maybe(
    "real whisper + finalize delivers punctuation-rich text (auto/default)",
    async () => {
      const backend = new WhisperCppBackend();
      const result = await backend.transcribe(FIXTURE);
      const finalized = finalizeTranscriptionText(result.text);

      // Real transcription, not empty.
      expect(finalized.length).toBeGreaterThan(0);
      // Content words from the known utterance survived.
      expect(finalized.toLowerCase()).toContain("fixed");
      // Punctuation-rich: contains terminal punctuation AND ends with it —
      // the regression delivered NEITHER.
      expect(finalized).toMatch(/[.?!]/);
      expect(finalized.trim()).toMatch(/[.?!]["')\]]?$/);
    },
    60_000,
  );
});
