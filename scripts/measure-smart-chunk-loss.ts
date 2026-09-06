/**
 * Corpus gate for the ≥90 s smart-chunk decode: where do the words go?
 *
 * PR #31's gate said smart chunking (`VOICELAYER_STT_SMART_CHUNKS=1`) removes
 * every looped repeat and runs 1.9× faster but LOSES more content, and the loss
 * concentrates at the HEAD of the chunk that follows a silence seam. This
 * harness is how that claim is re-measured against a fix.
 *
 * Method, and what is measurement vs estimate:
 *  - REFERENCE: one whole-file `verbose_json` request per clip. whisper-server
 *    windows a long file itself, so this is the same decoder with no seam of
 *    ours in it. Its `segments[]` carry real timestamps (segment ENDS are good
 *    to ~0.15 s; per-word times are NOT used — they interpolate across silence,
 *    see `whisper-server.ts:1045`).
 *  - CANDIDATE: `WhisperServerBackend.transcribe()` under each config, with the
 *    decoder wrapped so every request's duration is recorded. The chunk
 *    schedule is therefore OBSERVED, not assumed — a config that silently
 *    reverted to fixed cuts cannot pass as smart.
 *  - LOSS: LCS alignment of candidate against reference; every maximal run of
 *    reference words with no candidate match is a loss run.
 *  - ATTRIBUTION: a loss run is timed from the reference SEGMENT it falls in
 *    (interpolating by word index inside that one segment — seconds of span,
 *    not the whole recording as in PR #31), then classified against the
 *    observed cut schedule: HEAD if it starts within `SEAM_WINDOW_S` after a
 *    cut, TAIL if it ends within `SEAM_WINDOW_S` before one, else MID.
 *
 * Never touches the live stack: it runs its own whisper-server on `--port`
 * (default 51993, never 8178) and writes only where `--out` says.
 *
 * Usage:
 *   bun scripts/measure-smart-chunk-loss.ts \
 *     --clips clips.txt --runs 1 --out docs.local/... --configs off,on
 *
 * Lane C1-c also ran two candidate fixes through it as extra `CONFIGS` rows
 * driven by temporary env knobs — a longer silence-seam lead-in, and dropping
 * the prompt after a silence seam. Both were refuted on this corpus and the
 * knobs were reverted; the patch is kept at
 * `docs.local/c1c/refuted-experiment-knobs.patch` so the run can be repeated.
 */

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "fs";
import { dirname, basename } from "path";
import { WhisperServerBackend } from "../src/stt";
import {
  chooseChunkEnd,
  computePauseMap,
  isSilenceSeam,
  parseWavAudioInfo,
  pauseSpanContaining,
  SMART_CHUNK_MIN_SECONDS,
  SMART_CHUNK_MAX_SECONDS,
  type PauseSpan,
} from "../src/stt-pause-map";
import { stopServer, transcribeViaServer } from "../src/whisper-server";
import { allocateFreeLocalhostPort } from "../src/corpus-replay-verify";
import type { TranscriptSegment } from "../src/stt-sentence-boundaries";
import {
  findAdjacentDuplicateRun,
  findNearRepeat,
} from "../src/__tests__/transcript-defects";

const SILENCE_SEAM_OVERLAP_SECONDS = 0.5;
const WAV_CHUNK_OVERLAP_SECONDS = 5;
/** How near a cut a loss run must start/end to be called seam-attributable. */
const SEAM_WINDOW_S = 3.0;
const MIN_SMART_CHUNK_SPEECH_RATIO = 0.05;

// --- args ---------------------------------------------------------------

function arg(name: string, fallback?: string): string {
  const index = process.argv.indexOf(`--${name}`);
  if (index >= 0 && process.argv[index + 1]) return process.argv[index + 1];
  if (fallback !== undefined) return fallback;
  throw new Error(`missing --${name}`);
}

const requestedPort = process.argv.includes("--port")
  ? Number(arg("port"))
  : await allocateFreeLocalhostPort();
if (requestedPort === 8178) throw new Error("refusing to run on the live port 8178");
// Every decode below goes through `ensureServer()`, which reads this. Setting
// it (rather than passing the port per call) is what makes the harness LAUNCH
// its own server instead of silently declining to.
process.env.QA_VOICE_WHISPER_SERVER_PORT = String(requestedPort);
console.error(`[gate] isolated whisper port ${requestedPort}`);
const RUNS = Number(arg("runs", "1"));
const OUT = arg("out");
const CONFIG_NAMES = arg("configs", "off,on").split(",").map((s) => s.trim());
const CLIPS = readFileSync(arg("clips"), "utf8")
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line && !line.startsWith("#"));

// --- config matrix ------------------------------------------------------

/**
 * Env each config pins. `off` is the shipped fixed-cut decode; every other
 * config turns smart chunking on and varies exactly one seam knob, so a
 * difference between two rows is attributable to that knob.
 */
const CONFIGS: Record<string, Record<string, string | undefined>> = {
  off: { VOICELAYER_STT_SMART_CHUNKS: "0" },
  on: { VOICELAYER_STT_SMART_CHUNKS: "1" },
};

// --- word alignment -----------------------------------------------------

/** Comparison form: case- and punctuation-insensitive, digits and ' kept. */
function key(word: string): string {
  const stripped = word
    .toLowerCase()
    .replace(/^[^\p{L}\p{N}]+/gu, "")
    .replace(/[^\p{L}\p{N}]+$/gu, "");
  return stripped || word.toLowerCase();
}

function words(text: string): string[] {
  return text.trim().split(/\s+/).filter(Boolean);
}

/**
 * Indices of `reference` words that have no counterpart in `candidate`.
 *
 * Standard LCS over the key forms. Recordings here are ≤ ~700 words, so the
 * O(n·m) table is a few hundred thousand cells — fine, and exact beats a
 * heuristic when the number it produces is the ship criterion.
 */
function missingReferenceIndices(
  reference: string[],
  candidate: string[],
): number[] {
  const a = reference.map(key);
  const b = candidate.map(key);
  const n = a.length;
  const m = b.length;
  // lengths[i][j] = LCS of a[i..] and b[j..]
  const lengths: Uint16Array[] = Array.from(
    { length: n + 1 },
    () => new Uint16Array(m + 1),
  );
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      lengths[i][j] =
        a[i] === b[j]
          ? lengths[i + 1][j + 1] + 1
          : Math.max(lengths[i + 1][j], lengths[i][j + 1]);
    }
  }
  const missing: number[] = [];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      i++;
      j++;
    } else if (lengths[i + 1][j] >= lengths[i][j + 1]) {
      missing.push(i++);
    } else {
      j++;
    }
  }
  while (i < n) missing.push(i++);
  return missing;
}

interface LossRun {
  startIndex: number;
  wordCount: number;
  text: string;
  startS: number;
  endS: number;
  klass: "HEAD" | "TAIL" | "MID";
  cutS: number | null;
  offsetS: number | null;
}

/** Contiguous groups of missing indices. */
function groupRuns(indices: number[]): Array<{ start: number; length: number }> {
  const runs: Array<{ start: number; length: number }> = [];
  for (const index of indices) {
    const last = runs[runs.length - 1];
    if (last && last.start + last.length === index) last.length++;
    else runs.push({ start: index, length: 1 });
  }
  return runs;
}

/**
 * Seconds for reference word `index`, from the segment that contains it.
 *
 * Segment text is re-tokenised so a word index maps to a segment, then to a
 * position inside it. Interpolation is inside ONE segment (typically 2-6 s), so
 * the error is bounded by that segment's length rather than by the recording's.
 */
function buildWordTimes(
  segments: TranscriptSegment[],
  referenceWords: string[],
): number[] {
  const times = new Array<number>(referenceWords.length).fill(NaN);
  let cursor = 0;
  for (const segment of segments) {
    const segmentWords = words(segment.text);
    if (segmentWords.length === 0) continue;
    const span = Math.max(0, segment.endS - segment.startS);
    for (let offset = 0; offset < segmentWords.length; offset++) {
      const index = cursor + offset;
      if (index >= times.length) break;
      times[index] =
        segment.startS + (span * offset) / Math.max(1, segmentWords.length);
    }
    cursor += segmentWords.length;
  }
  // Segment tokenisation can drift from the joined text by a word or two; fill
  // any gap by carrying the last known time forward rather than dropping the
  // run from the count.
  let last = 0;
  for (let index = 0; index < times.length; index++) {
    if (Number.isNaN(times[index])) times[index] = last;
    else last = times[index];
  }
  return times;
}

// --- schedule -----------------------------------------------------------

interface Chunk {
  startS: number;
  endS: number;
  silence: boolean;
}

/** The schedule the production functions dictate for this pause map. */
function plannedSchedule(
  pauseMap: PauseSpan[],
  duration: number,
  leadInSeconds: number,
): Chunk[] {
  const chunks: Chunk[] = [];
  let start = 0;
  while (start < duration) {
    const end = Math.min(
      pauseMap.length > 0
        ? chooseChunkEnd(start, pauseMap, {
            min: SMART_CHUNK_MIN_SECONDS,
            max: SMART_CHUNK_MAX_SECONDS,
          })
        : start + SMART_CHUNK_MAX_SECONDS,
      duration,
    );
    const silence =
      pauseMap.length > 0 &&
      isSilenceSeam(end, pauseMap, SILENCE_SEAM_OVERLAP_SECONDS);
    chunks.push({ startS: start, endS: end, silence });
    if (end >= duration) break;
    // Mirrors production: a silence seam may reach back for lead-in, but never
    // past the pause's own start, or the re-read stops being silence.
    const span = silence ? pauseSpanContaining(end, pauseMap) : null;
    const overlap = silence
      ? Math.min(
          Math.max(SILENCE_SEAM_OVERLAP_SECONDS, leadInSeconds),
          span ? end - span.startS : SILENCE_SEAM_OVERLAP_SECONDS,
        )
      : WAV_CHUNK_OVERLAP_SECONDS;
    start = end - overlap;
  }
  return chunks;
}

// --- per-clip run -------------------------------------------------------

interface ClipResult {
  clip: string;
  durationS: number;
  speechRatio: number;
  pauses: number;
  referenceWords: number;
  /** Kept so a loop in the REFERENCE can be told from a loss in a candidate. */
  referenceText: string;
  referenceAdjacentDuplicate: string | null;
  referenceNearRepeat: string | null;
  configs: Record<string, ConfigResult>;
}

interface ConfigResult {
  runs: RunResult[];
}

interface RunResult {
  text: string;
  wordCount: number;
  decodeMs: number;
  requestSeconds: number[];
  backend: string;
  lostWords: number;
  headWords: number;
  tailWords: number;
  midWords: number;
  runs: LossRun[];
  adjacentDuplicate: string | null;
  nearRepeat: string | null;
}

function withEnv<T>(
  pins: Record<string, string | undefined>,
  body: () => Promise<T>,
): Promise<T> {
  const saved: Record<string, string | undefined> = {};
  for (const [name, value] of Object.entries(pins)) {
    saved[name] = process.env[name];
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
  return body().finally(() => {
    for (const [name, value] of Object.entries(saved)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });
}

function wavSeconds(bytes: number): number {
  return (bytes - 44) / (16000 * 2);
}

async function measureClip(path: string): Promise<ClipResult> {
  const wav = new Uint8Array(readFileSync(path));
  const info = parseWavAudioInfo(wav);
  if (!info) throw new Error(`${path}: not a readable PCM WAV`);
  const durationS =
    info.dataSize / (info.sampleRate * info.channels * (info.bitsPerSample / 8));

  const pauseMap = await computePauseMap(wav);
  const pauseSeconds = pauseMap.reduce((t, s) => t + (s.endS - s.startS), 0);
  const speechRatio = (durationS - pauseSeconds) / durationS;
  const trustedPauseMap =
    speechRatio >= MIN_SMART_CHUNK_SPEECH_RATIO ? pauseMap : [];

  // Reference: whole file, one request, real segment timestamps.
  let referenceSegments: TranscriptSegment[] = [];
  const referenceText = await transcribeViaServer(wav, undefined, {
    onSegments: (found) => {
      referenceSegments = found;
    },
  });
  const referenceWords = words(referenceText);
  const wordTimes = buildWordTimes(referenceSegments, referenceWords);

  const configs: Record<string, ConfigResult> = {};
  for (const name of CONFIG_NAMES) {
    const pins = CONFIGS[name];
    if (!pins) throw new Error(`unknown config ${name}`);
    const leadIn = Number(pins.VOICELAYER_STT_SEAM_LEADIN_SECONDS ?? "0.5");
    const smart = pins.VOICELAYER_STT_SMART_CHUNKS === "1";
    const schedule = plannedSchedule(
      smart ? trustedPauseMap : [],
      durationS,
      smart ? leadIn : SILENCE_SEAM_OVERLAP_SECONDS,
    );
    const runResults: RunResult[] = [];
    for (let attempt = 0; attempt < RUNS; attempt++) {
      const requestSeconds: number[] = [];
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (wavData, options) => {
          requestSeconds.push(wavSeconds(wavData.byteLength));
          return transcribeViaServer(wavData, undefined, options);
        },
      });
      const started = Date.now();
      const result = await withEnv(pins, () => backend.transcribe(path));
      const decodeMs = Date.now() - started;
      const candidate = words(result.text);
      const missing = missingReferenceIndices(referenceWords, candidate);
      const lossRuns: LossRun[] = groupRuns(missing).map((run) => {
        const startS = wordTimes[run.start] ?? 0;
        const endS = wordTimes[Math.min(run.start + run.length - 1, wordTimes.length - 1)] ?? startS;
        let klass: LossRun["klass"] = "MID";
        let cutS: number | null = null;
        let offsetS: number | null = null;
        for (const chunk of schedule.slice(0, -1)) {
          const afterCut = startS - chunk.endS;
          const beforeCut = chunk.endS - endS;
          if (afterCut >= 0 && afterCut <= SEAM_WINDOW_S) {
            klass = "HEAD";
            cutS = chunk.endS;
            offsetS = afterCut;
            break;
          }
          if (beforeCut >= 0 && beforeCut <= SEAM_WINDOW_S) {
            klass = "TAIL";
            cutS = chunk.endS;
            offsetS = -beforeCut;
            break;
          }
        }
        return {
          startIndex: run.start,
          wordCount: run.length,
          text: referenceWords.slice(run.start, run.start + run.length).join(" "),
          startS: +startS.toFixed(2),
          endS: +endS.toFixed(2),
          klass,
          cutS: cutS === null ? null : +cutS.toFixed(2),
          offsetS: offsetS === null ? null : +offsetS.toFixed(2),
        };
      });
      const sum = (k: LossRun["klass"]) =>
        lossRuns.filter((r) => r.klass === k).reduce((t, r) => t + r.wordCount, 0);
      runResults.push({
        text: result.text,
        wordCount: candidate.length,
        decodeMs,
        requestSeconds: requestSeconds.map((s) => +s.toFixed(2)),
        backend: result.backend,
        lostWords: missing.length,
        headWords: sum("HEAD"),
        tailWords: sum("TAIL"),
        midWords: sum("MID"),
        runs: lossRuns,
        adjacentDuplicate: findAdjacentDuplicateRun(result.text),
        nearRepeat: findNearRepeat(result.text),
      });
      console.error(
        `[gate] ${basename(path)} ${name} run${attempt + 1}: ` +
          `lost ${missing.length} (head ${sum("HEAD")} / tail ${sum("TAIL")} / mid ${sum("MID")}) ` +
          `in ${(decodeMs / 1000).toFixed(1)}s, backend=${result.backend}`,
      );
    }
    configs[name] = { runs: runResults };
  }

  return {
    clip: path,
    durationS: +durationS.toFixed(1),
    speechRatio: +speechRatio.toFixed(3),
    pauses: pauseMap.length,
    referenceWords: referenceWords.length,
    referenceText,
    referenceAdjacentDuplicate: findAdjacentDuplicateRun(referenceText),
    referenceNearRepeat: findNearRepeat(referenceText),
    configs,
  };
}

// --- main ---------------------------------------------------------------

const results: ClipResult[] = [];
for (const clip of CLIPS) {
  if (!existsSync(clip)) {
    console.error(`[gate] SKIP missing ${clip}`);
    continue;
  }
  try {
    results.push(await measureClip(clip));
  } catch (err) {
    console.error(`[gate] FAILED ${clip}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

stopServer();
mkdirSync(dirname(OUT), { recursive: true });
writeFileSync(OUT, JSON.stringify({ configs: CONFIG_NAMES, runs: RUNS, results }, null, 2));

// Totals per config, summed over clips and averaged over runs.
console.error("\n=== totals ===");
for (const name of CONFIG_NAMES) {
  let lost = 0;
  let head = 0;
  let tail = 0;
  let mid = 0;
  let dups = 0;
  let nears = 0;
  let ms = 0;
  for (const clip of results) {
    const runs = clip.configs[name]?.runs ?? [];
    if (runs.length === 0) continue;
    lost += runs.reduce((t, r) => t + r.lostWords, 0) / runs.length;
    head += runs.reduce((t, r) => t + r.headWords, 0) / runs.length;
    tail += runs.reduce((t, r) => t + r.tailWords, 0) / runs.length;
    mid += runs.reduce((t, r) => t + r.midWords, 0) / runs.length;
    dups += runs.filter((r) => r.adjacentDuplicate).length / runs.length;
    nears += runs.filter((r) => r.nearRepeat).length / runs.length;
    ms += runs.reduce((t, r) => t + r.decodeMs, 0) / runs.length;
  }
  console.error(
    `${name.padEnd(20)} lost ${lost.toFixed(1)} (head ${head.toFixed(1)} / tail ${tail.toFixed(1)} / mid ${mid.toFixed(1)})  ` +
      `dup ${dups.toFixed(1)}/${results.length}  near ${nears.toFixed(1)}/${results.length}  ${(ms / 1000).toFixed(1)}s`,
  );
}
console.error(`\nwrote ${OUT}`);
