/**
 * Remove a distinctive Whisper caption only when its whole trailing segment run
 * sits over Silero non-speech. The ordinary closer gate deliberately does not
 * handle unpunctuated captions or noisy recordings.
 */
import { createVADSession, VAD_CHUNK_SAMPLES } from "./vad";
import { parseWavAudioInfo, WAVE_FORMAT_PCM } from "./stt-pause-map";
import { measureSpan, measureWavWindows, normalizeOutroKey, SPEECH_LEVEL_GUARD_DB, SPEECH_OVER_FLOOR_DB } from "./stt-outro-gate";
import type { TranscriptSegment } from "./stt-sentence-boundaries";

const CAPTION_PREFIXES = [
  { key: "the american pronunciation guide presents", class: "american-pronunciation-guide" },
  { key: "how to pronounce", class: "how-to-pronounce" },
  { key: "subtitles by the amara org community", class: "amara-subtitles" },
  { key: "thanks for watching", class: "thanks-for-watching" },
  { key: "please subscribe", class: "please-subscribe" },
  { key: "transcribed by", class: "transcribed-by" },
  { key: "subtitles by rev com", class: "rev-subtitles" },
] as const;

/** One 32 ms VAD-positive blip is tolerated; two may already be a spoken word. */
const MAX_SPEECH_CHUNKS = 1;
/** Require measurable audio under the claimed span; no extrapolation from timestamps alone. */
const MIN_OBSERVED_CHUNKS = 8;
/** Keep captions within a short trailing run, not a long untrusted continuation. */
const MAX_TRAILING_SEGMENTS = 3;
const MAX_TRAILING_SECONDS = 8;
const MAX_TRAILING_WORDS = 20;
const CLEAR_BEFORE_SECONDS = 0.3;
/** Whisper can timestamp the caption beyond EOF; the pinned case exceeds EOF by 4.69 s. */
const MAX_TIMESTAMP_OVERRUN_SECONDS = 5;

export interface CaptionGateOptions {
  segments?: TranscriptSegment[];
  segmentsText?: string;
  /** Deterministic VAD evidence for tests; production computes it from the WAV. */
  speechProbabilities?: number[];
}

export interface CaptionGateDecision {
  text: string;
  removed: { class: string; startS: number; endS: number } | null;
  reason: "no-candidate" | "no-segments" | "segments-stale" | "no-audio" | "speech-present" | "removed";
}

function words(text: string): string[] {
  return normalizeOutroKey(text).split(" ").filter(Boolean);
}

async function probabilitiesForWav(wav: Uint8Array, dataOffset: number, dataSize: number): Promise<number[]> {
  const chunkBytes = VAD_CHUNK_SAMPLES * 2;
  const count = Math.floor(dataSize / chunkBytes);
  const vad = await createVADSession();
  const probabilities: number[] = [];
  for (let index = 0; index < count; index++) {
    const start = dataOffset + index * chunkBytes;
    probabilities.push(await vad.process(wav.subarray(start, start + chunkBytes)));
  }
  return probabilities;
}

/**
 * A caption match must start at a segment boundary and run to transcript end.
 * Segment and full-text word streams must agree before their offsets are used.
 */
export async function stripHallucinatedCaption(
  text: string,
  wavData: Uint8Array,
  options: CaptionGateOptions = {},
): Promise<CaptionGateDecision> {
  const untouched = (reason: CaptionGateDecision["reason"]): CaptionGateDecision =>
    ({ text, removed: null, reason });
  const segments = options.segments;
  if (!segments?.length) return untouched("no-segments");
  if (options.segmentsText !== undefined && options.segmentsText !== text) return untouched("segments-stale");

  const fullWords = words(text);
  const segmentWords = segments.map((segment) => words(segment.text));
  if (fullWords.join(" ") !== segmentWords.flat().join(" ")) return untouched("segments-stale");
  if (segments.some((segment, index) =>
    !Number.isFinite(segment.startS) || !Number.isFinite(segment.endS) ||
    segment.startS < 0 || segment.endS <= segment.startS ||
    (index > 0 && segment.startS < segments[index - 1]!.startS)
  )) return untouched("no-segments");

  let candidate: { index: number; class: string; startS: number; endS: number; wordOffset: number } | null = null;
  let wordOffset = 0;
  for (let index = 0; index < segments.length; index++) {
    const run = segments.slice(index);
    const runWords = segmentWords.slice(index).flat();
    if (run.length > MAX_TRAILING_SEGMENTS || runWords.length > MAX_TRAILING_WORDS ||
        run[run.length - 1]!.endS - run[0]!.startS > MAX_TRAILING_SECONDS) {
      wordOffset += segmentWords[index]!.length;
      continue;
    }
    const key = runWords.join(" ");
    const phrase = CAPTION_PREFIXES.find((entry) => key === entry.key || key.startsWith(`${entry.key} `));
    if (phrase) {
      candidate = { index, class: phrase.class, startS: run[0]!.startS,
        endS: run[run.length - 1]!.endS, wordOffset };
      break;
    }
    wordOffset += segmentWords[index]!.length;
  }
  if (!candidate) return untouched("no-candidate");

  const info = parseWavAudioInfo(wavData);
  if (!info || info.audioFormat !== WAVE_FORMAT_PCM || info.sampleRate !== 16_000 ||
      info.channels !== 1 || info.bitsPerSample !== 16) return untouched("no-audio");
  const count = Math.floor(info.dataSize / (VAD_CHUNK_SAMPLES * 2));
  const chunkSeconds = VAD_CHUNK_SAMPLES / info.sampleRate;
  const durationSeconds = info.dataSize / (info.sampleRate * info.channels * 2);
  if (candidate.startS < CLEAR_BEFORE_SECONDS ||
      candidate.endS > durationSeconds + MAX_TIMESTAMP_OVERRUN_SECONDS) return untouched("no-audio");
  const first = Math.floor(candidate.startS / chunkSeconds);
  const last = Math.min(count, Math.ceil(candidate.endS / chunkSeconds));
  if (first < 0 || first >= count || last - first < MIN_OBSERVED_CHUNKS) return untouched("no-audio");

  let probabilities: number[];
  try {
    probabilities = options.speechProbabilities ??
      await probabilitiesForWav(wavData, info.dataOffset, info.dataSize);
  } catch {
    return untouched("no-audio");
  }
  if (probabilities.length < count || probabilities.some((value) => !Number.isFinite(value) || value < 0 || value > 1)) {
    return untouched("no-audio");
  }
  const speech = (value: number) => value >= 0.5;
  const beforeStart = Math.max(0, Math.ceil((candidate.startS - CLEAR_BEFORE_SECONDS) / chunkSeconds));
  // Exclude the chunk crossing the segment boundary from the leading clearance;
  // the candidate check below includes it.
  const beforeEnd = Math.floor(candidate.startS / chunkSeconds);
  if (probabilities.slice(beforeStart, beforeEnd).some(speech) ||
      probabilities.slice(first, last).filter(speech).length > MAX_SPEECH_CHUNKS) {
    return untouched("speech-present");
  }
  // Silero alone can miss very soft speech. Keep the existing outro gate's
  // independent sustained-energy and near-recorded-speech-level protections;
  // neither changes the reverted sparse-speech policy.
  const windows = measureWavWindows(wavData);
  const measured = windows && measureSpan(windows, candidate.startS, candidate.endS);
  if (!windows || !measured) return untouched("no-audio");
  const flat = windows.speechLevelDbfs - windows.floorDbfs < SPEECH_OVER_FLOOR_DB &&
    probabilities.filter(speech).length <= MAX_SPEECH_CHUNKS;
  if (measured.hasSpeech ||
      (!flat && measured.peakDbfs >= windows.speechLevelDbfs - SPEECH_LEVEL_GUARD_DB)) {
    return untouched("speech-present");
  }

  const wordMatches = [...text.matchAll(/[\p{L}\p{N}]+/gu)];
  const startWord = wordMatches[candidate.wordOffset];
  if (!startWord || startWord.index === undefined) return untouched("segments-stale");
  let cut = startWord.index;
  const before = text.slice(0, cut);
  if (/^\s*-\s*/u.test(segments[candidate.index]!.text)) {
    const dash = before.match(/\s*-\s*$/u);
    if (dash) cut -= dash[0].length;
  }
  const kept = text.slice(0, cut).trimEnd();
  return {
    text: kept,
    removed: { class: candidate.class, startS: candidate.startS, endS: candidate.endS },
    reason: "removed",
  };
}
