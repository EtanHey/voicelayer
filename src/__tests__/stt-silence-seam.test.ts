import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync } from "fs";
import { join } from "path";
import { WhisperServerBackend } from "../stt";
import { computePauseMap, parseWavAudioInfo } from "../stt-pause-map";
import { findAdjacentDuplicateRun, findNearRepeat } from "./transcript-defects";

/**
 * Silence seams end to end, with a REAL pause map and a mocked decoder.
 *
 * `stt.test.ts` builds its long fixtures from a 180 Hz sine. Silero correctly
 * scores that as non-speech, so those fixtures exercise the fixed-cut path via
 * the speech-ratio guard and can say nothing about seams. This suite builds a
 * ≥90 s fixture out of real synthesized speech separated by real silence, so
 * `computePauseMap` returns genuine pauses and the boundaries are genuine
 * silence seams. Only the whisper call is faked — the decision of WHERE to cut
 * and HOW to join is the production code's.
 *
 * Skips loudly without `say`/`sox`.
 */

const FIXTURE_DIR = join(import.meta.dir, "../../docs.local/test-fixtures/pause-map");
const LONG_WAV = join(FIXTURE_DIR, "long-speech-with-gaps.wav");
const GAP_SECONDS = 2.5;
const SENTENCES = [
  "The morning train left the station a few minutes behind schedule today.",
  "She poured the coffee slowly and watched the steam rise toward the ceiling.",
  "Our team shipped the new release after a long and careful review.",
  "A gentle rain fell across the valley while the farmers finished their work.",
  "He fixed the broken fence before the storm arrived from the west.",
  "The children played in the park until the streetlights flickered on.",
];

/** No shared wording between entries, so a repeat can only come from the merge. */
const DISTINCT_CHUNK_TEXTS = [
  "the morning train left behind schedule",
  "she poured coffee watching steam rise",
  "our team shipped after careful review",
  "gentle rain fell across farmland",
  "he repaired fencing before westerly storms",
  "children played until streetlights flickered",
  "we measured twice and ordered lumber",
  "an orchestra tuned as audiences arrived",
];

function whichOk(bin: string): boolean {
  try {
    return Bun.spawnSync(["which", bin]).exitCode === 0;
  } catch {
    return false;
  }
}

const hasSay = whichOk("say");
const hasSox = whichOk("sox");
const ready = hasSay && hasSox;
if (!ready) {
  console.error(
    `[silence-seam] SKIPPING — missing: ${[hasSay ? null : "say", hasSox ? null : "sox"]
      .filter(Boolean)
      .join(", ")}. The pure merge tests in stt.test.ts still run.`,
  );
}
const seamTest = ready ? test : test.skip;

function run(cmd: string[]): void {
  const proc = Bun.spawnSync(cmd, { cwd: FIXTURE_DIR });
  if (proc.exitCode !== 0) {
    throw new Error(
      `${cmd.join(" ")} failed: ${new TextDecoder().decode(proc.stderr)}`,
    );
  }
}

/** ~105 s: six spoken sentences, each said three times with 2.5 s gaps. */
function buildLongFixture(): void {
  if (existsSync(LONG_WAV)) return;
  mkdirSync(FIXTURE_DIR, { recursive: true });
  run(["sox", "-n", "-r", "16000", "-c", "1", "-b", "16", "seam-gap.wav", "trim", "0.0", String(GAP_SECONDS)]);
  const parts: string[] = [];
  SENTENCES.forEach((sentence, index) => {
    run(["say", "-o", `seam-${index}.aiff`, sentence]);
    run(["sox", `seam-${index}.aiff`, "-r", "16000", "-c", "1", "-b", "16", `seam-${index}.wav`]);
    // Repeated so the file clears the ≥90 s chunked-decode gate with margin.
    for (let repeat = 0; repeat < 3; repeat++) {
      parts.push(`seam-${index}.wav`, "seam-gap.wav");
    }
  });
  run(["sox", ...parts, "-r", "16000", "-c", "1", "-b", "16", LONG_WAV]);
}

describe("silence seams end to end", () => {
  seamTest(
    "cuts inside pauses and joins the chunks without inventing a repeat",
    async () => {
      buildLongFixture();
      const wav = new Uint8Array(readFileSync(LONG_WAV));
      const info = parseWavAudioInfo(wav);
      const duration = (info?.dataSize ?? 0) / (16000 * 2);
      expect(duration).toBeGreaterThan(90);

      const pauseMap = await computePauseMap(wav);
      expect(pauseMap.length).toBeGreaterThanOrEqual(6);

      // Wholly distinct text per decode — the way real audio reads once a seam
      // re-decodes only silence. Sharing wording between chunks would make the
      // repeat detectors fire on the fixture rather than on the merge.
      const decoded: string[] = [];
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async () => {
          const text = DISTINCT_CHUNK_TEXTS[decoded.length % DISTINCT_CHUNK_TEXTS.length];
          decoded.push(text);
          return text;
        },
      });

      const result = await backend.transcribe(LONG_WAV);

      expect(result.backend).toContain("chunks");
      expect(findAdjacentDuplicateRun(result.text)).toBeNull();
      expect(findNearRepeat(result.text)).toBeNull();

      // Concatenation must not drop words: whichever decodes were kept, each
      // one contributes its whole sentence or none of it.
      const kept = DISTINCT_CHUNK_TEXTS.filter((text) =>
        result.text.includes(text.split(" ").slice(0, 3).join(" ")),
      );
      expect(kept.length).toBeGreaterThanOrEqual(3);
      for (const text of kept) expect(result.text).toContain(text);
    },
    300_000,
  );

  seamTest(
    "the escape hatch restores the fixed-cut schedule",
    async () => {
      buildLongFixture();
      const sizes: number[] = [];
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (wavData) => {
          sizes.push(wavData.byteLength);
          return `chunk ${sizes.length} text`;
        },
      });

      process.env.VOICELAYER_STT_SMART_CHUNKS = "0";
      try {
        await backend.transcribe(LONG_WAV);
      } finally {
        delete process.env.VOICELAYER_STT_SMART_CHUNKS;
      }

      // Fixed cuts are always exactly WAV_CHUNK_SECONDS of audio (+44 header).
      const thirtySeconds = 30 * 16000 * 2 + 44;
      expect(sizes[0]).toBe(thirtySeconds);
    },
    300_000,
  );
});
