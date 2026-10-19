import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { stripHallucinatedCaption } from "../stt-caption-gate";
import { privateCorpusPaths } from "./setup/private-specimens";

/**
 * HALLU1 regression on the real recording, read-only. The mic died mid-take:
 * speech ends ~22.3 s, then 33 s of {-1, 0, 1} dead-device samples. The live
 * decode appended "You Transcription by CastingWords." over that span.
 *
 * Never copy this specimen or its transcript into the repo. The spoken text
 * here is a placeholder; only the WAV is read, and only with
 * VOICELAYER_TEST_REAL_ARCHIVE=1.
 */
const PRIVATE_CORPUS = privateCorpusPaths("caption-hallu1");
const ID = "2026-10-19T03-33-25-431Z-6164de04";
const SHA256 = "a00eb4590ce1a4e0e65aea8ee083f076b53a005de4e48942ae2b2fbc546b53c8";
const wavPath = join(PRIVATE_CORPUS?.recordings ?? "", "2026-10-19", ID, "audio.wav");
const available = Boolean(PRIVATE_CORPUS) && existsSync(wavPath);
if (PRIVATE_CORPUS && !available) {
  console.error(`[caption-hallu1] SKIPPING missing private specimen ${ID}.`);
}
const specimenTest = available ? test : test.skip;

const SPOKEN = "placeholder words for the spoken take";

describe("HALLU1 private specimen", () => {
  specimenTest("drops the CastingWords tail over the dead-device span", async () => {
    const wav = new Uint8Array(readFileSync(wavPath));
    expect(createHash("sha256").update(wav).digest("hex")).toBe(SHA256);
    // Timings from a scratch re-decode of a copy: speech ends 22.14 s and
    // Whisper's first hallucinated segment starts at 30.00 s.
    const segments = [
      { text: SPOKEN, startS: 0, endS: 22.14 },
      { text: " You", startS: 30, endS: 32.06 },
      { text: " Transcription by CastingWords.", startS: 32.06, endS: 56.74 },
    ];
    const text = segments.map((segment) => segment.text).join("");
    const result = await stripHallucinatedCaption(text, wav, { segments, segmentsText: text });
    expect(result.text).toBe(SPOKEN);
    expect(result.removed?.class).toBe("castingwords");
  });

  specimenTest("keeps the same caption when its span covers his real speech", async () => {
    const wav = new Uint8Array(readFileSync(wavPath));
    const segments = [
      { text: SPOKEN, startS: 0, endS: 15 },
      { text: " You Transcription by CastingWords.", startS: 15.5, endS: 18 },
    ];
    const text = segments.map((segment) => segment.text).join("");
    const result = await stripHallucinatedCaption(text, wav, { segments, segmentsText: text });
    expect(result.text).toBe(text);
    expect(result.removed).toBeNull();
  });
});
