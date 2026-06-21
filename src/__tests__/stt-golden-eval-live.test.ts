import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "crypto";
import {
  existsSync,
  mkdirSync,
  readFileSync,
  unlinkSync,
  writeFileSync,
} from "fs";
import { tmpdir } from "os";
import { join } from "path";
import {
  ChunkedRecordingSession,
  createWavBuffer,
  finalizeTranscriptionText,
  transcribeChunkSequence,
} from "../input";
import { WhisperCppBackend } from "../stt";
import { assessGoldenTranscript } from "../stt-golden-eval";

// Live golden-WAV STT regression gate (R-008 / R-014 family). Builds known
// spoken scripts with `say` + `sox`, runs them through the REAL whisper CLI
// backend (the resident-server fallback path) + REAL finalize pipeline — both
// the single-shot and chunked decode paths — and asserts each fixture has
// punctuation, no fabricated/non-overlapping append, no large drop, and bounded
// decode time. The detector RED→GREEN lives in stt-golden-eval.test.ts (CI-safe);
// this harness is the live-outcome probe and SKIPS cleanly when whisper / `say`
// / `sox` are unavailable (e.g. Linux CI). The 20-minute fixture is opt-in via
// QA_VOICE_GOLDEN_LONG=1 (heavy decode) — its skip is logged, never silent.

const SAMPLE_RATE = 16000;

function whichOk(bin: string): boolean {
  try {
    return Bun.spawnSync(["which", bin]).exitCode === 0;
  } catch {
    return false;
  }
}

const modelInfo = new WhisperCppBackend().getModelInfo();
const hasWhisper = Boolean(modelInfo.binary && modelInfo.model);
const hasSay = whichOk("say");
const hasSox = whichOk("sox");
const toolsReady = hasWhisper && hasSay && hasSox;
const live = toolsReady ? test : test.skip;

if (!toolsReady) {
  // eslint-disable-next-line no-console
  console.error(
    `[golden-eval] SKIPPING live golden-WAV suite — missing: ${[
      hasWhisper ? null : "whisper",
      hasSay ? null : "say",
      hasSox ? null : "sox",
    ]
      .filter(Boolean)
      .join(", ")}. Detector RED→GREEN still runs in stt-golden-eval.test.ts.`,
  );
}

const CACHE_DIR = join(tmpdir(), "voicelayer-golden-fixtures");

// A pool of natural, varied sentences. Synthetic formulaic sentences make TTS
// monotone and induce whisper to LOOP (a false fabricated-append); natural prose
// decodes cleanly. For longer fixtures the pool repeats at a distance of
// POOL.length sentences, so identical sentences are never ADJACENT — the
// adjacent-duplicate detector stays a true hallucination signal, and content is
// varied within any single ~28s chunk so whisper has no monotony to loop on.
const POOL = [
  "The morning train left the station a few minutes behind schedule today.",
  "She poured the coffee slowly and watched the steam rise toward the ceiling.",
  "Our team shipped the new release after a long and careful review.",
  "A gentle rain fell across the valley while the farmers finished their work.",
  "He fixed the broken fence before the storm arrived from the west.",
  "The children played in the park until the streetlights flickered on.",
  "We measured the room twice and ordered the lumber the next morning.",
  "The orchestra tuned their instruments as the audience found their seats.",
  "A small fishing boat returned to the harbor just before sunset.",
  "The librarian shelved the returned books and dimmed the reading lamps.",
  "They hiked along the ridge and stopped to eat near a cold spring.",
  "The bakery sold out of fresh bread well before the lunch rush.",
  "An old clock ticked steadily in the quiet corner of the study.",
  "The pilot announced a smooth descent into the bright coastal city.",
  "We planted tomatoes and herbs along the fence behind the garage.",
  "The painter mixed a deep blue and stepped back to judge the wall.",
  "A long line formed outside the theater for the evening show.",
  "The technician traced the faulty wire and replaced the cracked switch.",
  "Snow covered the trail, so we turned back toward the warm cabin.",
  "The market buzzed with vendors selling fruit, flowers, and fresh fish.",
  "She wrote three pages, made tea, and read them aloud to herself.",
  "The dog chased the ball across the yard and dropped it at my feet.",
  "A bright comet appeared low in the sky for several clear nights.",
  "The carpenter sanded the table until the surface felt perfectly smooth.",
  "We drove past the river and parked near the old stone bridge.",
  "The teacher handed back the essays and praised the careful arguments.",
  "A warm wind carried the smell of pine across the open meadow.",
  "The shop owner counted the register and locked the front door.",
  "They repaired the roof, cleaned the gutters, and painted the trim.",
  "The runners gathered at the start line as the fog began to lift.",
];

const ANCHOR_SENTENCES = [
  "Near the start, the telescope rests on the heavy wooden table.",
  "Halfway through, the umbrella stays dry beneath the open roof.",
  "Finally, near the very end, the volcano is calm tonight.",
];

function withAnchors(sentences: string[]): string {
  // Inject distinctive anchors at start / middle / end to prove no large drop.
  // Guard tiny scripts where the three indices would collide (all callers use
  // >= 10 sentences today, but keep the helper honest).
  if (sentences.length < 3) {
    throw new Error("golden fixture needs >= 3 sentences for anchor injection");
  }
  sentences[0] = ANCHOR_SENTENCES[0];
  sentences[Math.floor(sentences.length / 2)] = ANCHOR_SENTENCES[1];
  sentences[sentences.length - 1] = ANCHOR_SENTENCES[2];
  return sentences.join(" ");
}

// Short/medium fixtures (<= POOL.length) use the natural pool verbatim — natural
// prose is what keeps single-shot whisper from looping.
function makeScript(sentenceCount: number): string {
  const sentences: string[] = [];
  for (let i = 0; i < sentenceCount; i++) sentences.push(POOL[i % POOL.length]);
  return withAnchors(sentences);
}

// Long fixture: GENUINELY DISTINCT sentences. Reusing a finite pool over a
// 20-minute fixture inevitably repeats a contiguous block adjacently (which a
// faithful decode reproduces and the dup detector then flags). Compose from
// pairwise-coprime word slots so the first thousands of sentences are unique
// (CRT) — varied, no script-level repeats, and chunked decode handles the
// per-28s-chunk content cleanly.
const C_ADJ = [
  "bright",
  "quiet",
  "narrow",
  "ancient",
  "golden",
  "distant",
  "gentle",
  "busy",
  "frozen",
  "hollow",
  "crimson",
  "silver",
  "weary",
]; // 13
const C_NOUN = [
  "harbor",
  "engine",
  "garden",
  "lantern",
  "meadow",
  "ledger",
  "canvas",
  "signal",
  "orchard",
  "tunnel",
  "cottage",
]; // 11
const C_VERB = [
  "circled",
  "measured",
  "repaired",
  "painted",
  "guarded",
  "watched",
  "carried",
  "lifted",
  "polished",
]; // 9
const C_TAIL = [
  "before the storm",
  "near the river",
  "without any delay",
  "under the bright lights",
  "over the long weekend",
  "with great focus",
  "beside the old gate",
]; // 7

function makeDistinctScript(sentenceCount: number): string {
  const sentences: string[] = [];
  for (let i = 0; i < sentenceCount; i++) {
    sentences.push(
      `A ${C_ADJ[i % 13]} ${C_NOUN[i % 11]} was ${C_VERB[i % 9]} ${C_TAIL[i % 7]}.`,
    );
  }
  return withAnchors(sentences);
}

const ANCHORS = ["telescope", "umbrella", "volcano"];

/** Build (and cache) a 16kHz mono WAV of a spoken script; return its path. */
function buildGoldenWav(script: string): string {
  mkdirSync(CACHE_DIR, { recursive: true });
  const key = createHash("sha1").update(script).digest("hex").slice(0, 16);
  const wavPath = join(CACHE_DIR, `golden-${key}.wav`);
  if (existsSync(wavPath)) return wavPath;

  const txtPath = join(CACHE_DIR, `golden-${key}.txt`);
  const aiffPath = join(CACHE_DIR, `golden-${key}.aiff`);
  writeFileSync(txtPath, script);
  const say = Bun.spawnSync(["say", "-f", txtPath, "-o", aiffPath]);
  if (say.exitCode !== 0) {
    throw new Error(`say failed: ${say.stderr?.toString() ?? ""}`);
  }
  const sox = Bun.spawnSync([
    "sox",
    aiffPath,
    "-r",
    String(SAMPLE_RATE),
    "-c",
    "1",
    "-b",
    "16",
    wavPath,
  ]);
  if (sox.exitCode !== 0) {
    throw new Error(`sox failed: ${sox.stderr?.toString() ?? ""}`);
  }
  try {
    unlinkSync(aiffPath);
  } catch {}
  return wavPath;
}

// Read PCM from a canonical 44-byte-header WAV. We control the sox invocation
// (`-r 16000 -c 1 -b 16`) which emits exactly that, but validate the `data`
// chunk is at offset 36 so a non-canonical header fails loudly instead of
// silently feeding garbage PCM into the decoder.
function readWavPcm(wavPath: string): Uint8Array {
  const buf = readFileSync(wavPath);
  if (
    buf.byteLength < 44 ||
    buf.subarray(36, 40).toString("ascii") !== "data"
  ) {
    throw new Error(
      `golden WAV ${wavPath} is not a canonical 44-byte-header PCM file`,
    );
  }
  return new Uint8Array(buf.subarray(44));
}

function wavDurationSeconds(wavPath: string): number {
  return readWavPcm(wavPath).byteLength / (SAMPLE_RATE * 2);
}

function readPcm(wavPath: string): Uint8Array {
  return readWavPcm(wavPath);
}

async function transcribeSingleShot(wavPath: string): Promise<string> {
  const backend = new WhisperCppBackend();
  const result = await backend.transcribe(wavPath);
  return finalizeTranscriptionText(result.text);
}

async function transcribeChunked(wavPath: string): Promise<string> {
  const session = new ChunkedRecordingSession(SAMPLE_RATE, "standard");
  session.replaceWithPCM(readPcm(wavPath), true);
  session.finalize();
  const segments = session.consumeSegments();
  expect(segments.length).toBeGreaterThan(1); // multi-chunk merge is exercised
  const backend = new WhisperCppBackend();
  return transcribeChunkSequence(segments, async (chunk, prompt) => {
    const chunkPath = join(
      CACHE_DIR,
      `chunk-${createHash("sha1").update(chunk).digest("hex").slice(0, 12)}.wav`,
    );
    try {
      writeFileSync(chunkPath, createWavBuffer(chunk));
      const result = await backend.transcribe(chunkPath, {
        promptOverride: prompt,
      });
      return result.text;
    } finally {
      try {
        unlinkSync(chunkPath);
      } catch {}
    }
  });
}

// Decode runs many× faster than realtime on Apple silicon; allow 3× audio + 45s
// headroom for a slow box. Capped at 600s so the ceiling always stays BELOW each
// case's Bun per-test timeout — the timing ASSERTION must be what fails a slow
// decode, never the test-runner timeout firing first.
const MAX_DECODE_CEILING_MS = 600_000;
function boundedTimeCeilingMs(audioSeconds: number): number {
  return Math.min(
    Math.round(audioSeconds * 3 * 1000) + 45_000,
    MAX_DECODE_CEILING_MS,
  );
}

describe("golden-WAV STT eval suite", () => {
  // Pin the decode + finalize env so the gate is judged independently of ambient
  // config: English decode (anchors transcribe reliably) and corrector=off (the
  // deterministic punctuation floor runs; `identity` mode would skip it). Both
  // are read at call time from process.env, so set them around the suite.
  const savedCorrector = process.env.QA_VOICE_CORRECTOR;
  const savedLang = process.env.QA_VOICE_WHISPER_LANG;
  beforeAll(() => {
    process.env.QA_VOICE_CORRECTOR = "off";
    process.env.QA_VOICE_WHISPER_LANG = "english";
  });
  afterAll(() => {
    if (savedCorrector === undefined) delete process.env.QA_VOICE_CORRECTOR;
    else process.env.QA_VOICE_CORRECTOR = savedCorrector;
    if (savedLang === undefined) delete process.env.QA_VOICE_WHISPER_LANG;
    else process.env.QA_VOICE_WHISPER_LANG = savedLang;
  });

  live(
    "sub-90s short-tail — single-shot, punctuation + no append",
    async () => {
      const script = makeScript(10);
      const wav = buildGoldenWav(script);
      const seconds = wavDurationSeconds(wav);
      expect(seconds).toBeLessThan(90);

      const started = Date.now();
      const text = await transcribeSingleShot(wav);
      const elapsed = Date.now() - started;

      const a = assessGoldenTranscript(script, text, {
        anchors: ANCHORS,
        maxMissingAnchors: 1,
      });
      expect(a.reasons).toEqual([]);
      expect(a.ok).toBe(true);
      expect(elapsed).toBeLessThan(boundedTimeCeilingMs(seconds));
    },
    180_000,
  );

  live(
    ">60s timestamped — single-shot, punctuation + bounded time",
    async () => {
      const script = makeScript(17);
      const wav = buildGoldenWav(script);
      const seconds = wavDurationSeconds(wav);
      expect(seconds).toBeGreaterThan(60);

      const started = Date.now();
      const text = await transcribeSingleShot(wav);
      const elapsed = Date.now() - started;

      const a = assessGoldenTranscript(script, text, {
        anchors: ANCHORS,
        maxMissingAnchors: 1,
      });
      expect(a.reasons).toEqual([]);
      expect(elapsed).toBeLessThan(boundedTimeCeilingMs(seconds));
    },
    300_000,
  );

  live(
    "108s chunked — multi-chunk merge, no non-overlapping append",
    async () => {
      const script = makeScript(26);
      const wav = buildGoldenWav(script);
      const seconds = wavDurationSeconds(wav);
      expect(seconds).toBeGreaterThan(90);

      const started = Date.now();
      const text = await transcribeChunked(wav);
      const elapsed = Date.now() - started;

      const a = assessGoldenTranscript(script, text, {
        anchors: ANCHORS,
        maxMissingAnchors: 1,
      });
      // The headline assertion: chunk merge must not fabricate a repeated tail.
      expect(a.fabricatedAppend).toBeNull();
      expect(a.reasons).toEqual([]);
      expect(elapsed).toBeLessThan(boundedTimeCeilingMs(seconds));
    },
    420_000,
  );

  const longEnabled = process.env.QA_VOICE_GOLDEN_LONG === "1";
  if (toolsReady && !longEnabled) {
    // eslint-disable-next-line no-console
    console.error(
      "[golden-eval] 20-minute fixture is opt-in — set QA_VOICE_GOLDEN_LONG=1 to run it (heavy decode).",
    );
  }
  (toolsReady && longEnabled ? test : test.skip)(
    "20-minute long recording — chunked, bounded time + no runaway append",
    async () => {
      const script = makeDistinctScript(560);
      const wav = buildGoldenWav(script);
      const seconds = wavDurationSeconds(wav);
      expect(seconds).toBeGreaterThan(15 * 60);

      const started = Date.now();
      const text = await transcribeChunked(wav);
      const elapsed = Date.now() - started;

      // The long-recording contract is "bounded time + no runaway/looped append
      // + punctuation + roughly-intact content" — tolerant of the small per-chunk
      // drift and incidental short whisper repeats a 20-min decode accumulates.
      const a = assessGoldenTranscript(script, text, {
        anchors: ANCHORS,
        maxDriftRatio: 1.4,
        minDriftRatio: 0.5,
        minDupRun: 10,
        maxMissingAnchors: 1,
      });
      // Assert the FULL gate (with the long-fixture-tolerant options above) so
      // missing-anchor / not-terminated failures aren't silently skipped.
      expect(a.ok, a.reasons.join("; ")).toBe(true);
      expect(a.fabricatedAppend).toBeNull(); // no large looped/non-overlapping block
      expect(elapsed).toBeLessThan(boundedTimeCeilingMs(seconds));
    },
    900_000,
  );
});
