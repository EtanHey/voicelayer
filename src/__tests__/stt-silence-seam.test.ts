import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync } from "fs";
import { join } from "path";
import { WhisperServerBackend } from "../stt";
import {
  chooseChunkEnd,
  computePauseMap,
  isSilenceSeam,
  parseWavAudioInfo,
  type PauseSpan,
} from "../stt-pause-map";
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

const SMART_CHUNK_ENV = "VOICELAYER_STT_SMART_CHUNKS";
const SILENCE_SEAM_OVERLAP = 0.5;
const ANCHOR_OVERLAP = 5;

/** Run `body` with the flag pinned, restoring whatever the caller had. */
async function withSmartChunks<T>(
  value: string | undefined,
  body: () => Promise<T>,
): Promise<T> {
  const saved = process.env[SMART_CHUNK_ENV];
  if (value === undefined) delete process.env[SMART_CHUNK_ENV];
  else process.env[SMART_CHUNK_ENV] = value;
  try {
    return await body();
  } finally {
    if (saved === undefined) delete process.env[SMART_CHUNK_ENV];
    else process.env[SMART_CHUNK_ENV] = saved;
  }
}

/** The schedule production will choose, recomputed from the same functions. */
function expectedSchedule(
  pauseMap: PauseSpan[],
  duration: number,
): Array<{ startS: number; endS: number; silence: boolean }> {
  const chunks: Array<{ startS: number; endS: number; silence: boolean }> = [];
  let start = 0;
  while (start < duration) {
    const end = Math.min(chooseChunkEnd(start, pauseMap, { min: 20, max: 30 }), duration);
    const silence = isSilenceSeam(end, pauseMap, SILENCE_SEAM_OVERLAP);
    chunks.push({ startS: start, endS: end, silence });
    if (end >= duration) break;
    start = end - (silence ? SILENCE_SEAM_OVERLAP : ANCHOR_OVERLAP);
  }
  return chunks;
}

function wavSeconds(bytes: number): number {
  return (bytes - 44) / (16000 * 2);
}

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
      const requestedSeconds: number[] = [];
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (wavData) => {
          requestedSeconds.push(wavSeconds(wavData.byteLength));
          const text = DISTINCT_CHUNK_TEXTS[decoded.length % DISTINCT_CHUNK_TEXTS.length];
          decoded.push(text);
          return text;
        },
      });

      const result = await withSmartChunks("1", () => backend.transcribe(LONG_WAV));

      // The mock ignores the audio, so without this the test would still pass
      // if the decoder silently reverted to fixed 30 s cuts. Assert the actual
      // request sizes match the schedule the pause map dictates.
      const expected = expectedSchedule(pauseMap, duration);
      expect(expected.length).toBeGreaterThan(2);
      expect(expected.some((chunk) => chunk.endS - chunk.startS !== 30)).toBe(true);
      // The first N requests are the chunks themselves; anything after is a
      // verification decode (short-final confirmation, head punctuation), which
      // re-reads audio already covered rather than adding a chunk.
      expect(requestedSeconds.length).toBeGreaterThanOrEqual(expected.length);
      expect(requestedSeconds.length).toBeLessThanOrEqual(expected.length + 2);
      expected.forEach((chunk, index) => {
        expect({ index, seconds: +requestedSeconds[index].toFixed(2) }).toEqual({
          index,
          seconds: +(chunk.endS - chunk.startS).toFixed(2),
        });
      });

      // Every interior cut sits inside a pause, and each one is a silence seam,
      // so the following chunk re-decodes only SILENCE_SEAM_OVERLAP seconds.
      for (const chunk of expected.slice(0, -1)) {
        const span = pauseMap.find(
          (p) => chunk.endS >= p.startS && chunk.endS <= p.endS,
        );
        expect({ cut: chunk.endS, inPause: Boolean(span), silenceSeam: chunk.silence }).toEqual(
          { cut: chunk.endS, inPause: true, silenceSeam: true },
        );
      }
      expect(expected[1].startS).toBeCloseTo(expected[0].endS - SILENCE_SEAM_OVERLAP, 6);

      // A silence seam must never trigger the anchor witness machinery.
      expect(result.backend).not.toContain("witness");

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
    "the default (unset) and an explicit off both use the fixed-cut schedule",
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

      const thirtySeconds = 30 * 16000 * 2 + 44;

      // Unset is the shipped default and must be the fixed schedule.
      await withSmartChunks(undefined, () => backend.transcribe(LONG_WAV));
      expect(sizes[0]).toBe(thirtySeconds);

      // ...and so is an explicit off-value.
      sizes.length = 0;
      await withSmartChunks("0", () => backend.transcribe(LONG_WAV));
      expect(sizes[0]).toBe(thirtySeconds);
    },
    300_000,
  );
});
