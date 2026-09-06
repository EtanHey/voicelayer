/**
 * Pause map for saved-WAV decoding — where a recording is safe to cut.
 *
 * The ≥90 s saved-WAV path in `src/stt.ts` cuts on a wall clock (fixed 30 s,
 * `WAV_CHUNK_SECONDS`), so a boundary lands wherever it lands — including the
 * middle of a word. A 30.0 s cut through "machine-like" decoded as "Michelle"
 * (BrainLayer `rt-rollout--2174ebfc5a053324`, 2026-08-12). The LIVE capture path
 * already avoids this by closing chunks on VAD silence
 * (`evaluateChunkBoundary`, `src/vad.ts`); this module gives the saved-WAV path
 * the same information after the fact, by running the same Silero VAD over the
 * finished file.
 *
 * AIDEV-NOTE: `computePauseMap` is I/O + model; `pauseSpansFromProbabilities`
 * and `chooseChunkEnd` are pure so the boundary policy is table-testable without
 * a model, a WAV, or a whisper server.
 */

import { createVADSession, isSpeech, VAD_CHUNK_SAMPLES } from "./vad";

/** A span of non-speech, in seconds from the start of the recording. */
export interface PauseSpan {
  startS: number;
  endS: number;
}

/** Shortest gap that counts as a pause. Below this it is inter-word coarticulation. */
export const MIN_PAUSE_SECONDS = 0.3;

/** Smart-chunk window: never cut before `min`, never after `max`. */
export const SMART_CHUNK_MIN_SECONDS = 20;
export const SMART_CHUNK_MAX_SECONDS = 30;

/** Mirrors `WAV_CHUNK_OVERLAP_SECONDS` in `src/stt.ts`; overridable per call. */
export const SMART_CHUNK_OVERLAP_SECONDS = 5;

/**
 * How far into a pause a boundary may land.
 *
 * The next chunk starts `overlap` seconds BEFORE the cut, and that overlap is
 * the only anchor the merge has for stitching two chunks together. Cutting at
 * the far end of a long pause puts the whole overlap inside the silence: no
 * shared words, no anchor, and the seam falls into the dropped-overlap /
 * witness fallback path — the failure this lane exists to remove. So a cut goes
 * at most half an overlap into a pause, which leaves at least half of it
 * carrying speech. Short pauses are unaffected: the cut is still their end.
 */
export function maxSecondsIntoPause(
  overlapSeconds: number = SMART_CHUNK_OVERLAP_SECONDS,
): number {
  return Math.max(MIN_PAUSE_SECONDS, overlapSeconds / 2);
}

export interface ChunkEndWindow {
  min: number;
  max: number;
  /** Chunk overlap in seconds; sets how deep into a pause a cut may go. */
  overlapSeconds?: number;
}

interface WavAudioInfo {
  audioFormat: number;
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  dataOffset: number;
  dataSize: number;
}

/**
 * WAVE_FORMAT_PCM. Anything else — 3 (IEEE float), 6/7 (A-law/mu-law),
 * 0xFFFE (extensible) — is not the integer PCM this module decodes by hand,
 * even when its rate, channel count and bit depth happen to match.
 */
const WAVE_FORMAT_PCM = 1;

function readAscii(bytes: Uint8Array, offset: number, length: number): string {
  return String.fromCharCode(...bytes.slice(offset, offset + length));
}

/**
 * Parse the fields the VAD needs. Deliberately separate from `stt.ts`'s
 * `parseWavPcmInfo` (which reports byteRate/blockAlign for slicing, not format),
 * and kept here so `stt.ts` depends on this module and never the reverse.
 */
export function parseWavAudioInfo(wavData: Uint8Array): WavAudioInfo | null {
  if (wavData.byteLength < 44) return null;
  const view = new DataView(
    wavData.buffer,
    wavData.byteOffset,
    wavData.byteLength,
  );
  if (
    readAscii(wavData, 0, 4) !== "RIFF" ||
    readAscii(wavData, 8, 4) !== "WAVE"
  ) {
    return null;
  }

  let audioFormat = 0;
  let sampleRate = 0;
  let channels = 0;
  let bitsPerSample = 0;
  let dataOffset = -1;
  let dataSize = 0;

  for (let offset = 12; offset + 8 <= wavData.byteLength; ) {
    const chunkId = readAscii(wavData, offset, 4);
    const chunkSize = view.getUint32(offset + 4, true);
    const chunkDataOffset = offset + 8;
    if (chunkDataOffset + chunkSize > wavData.byteLength) return null;

    if (chunkId === "fmt " && chunkSize >= 16) {
      audioFormat = view.getUint16(chunkDataOffset, true);
      channels = view.getUint16(chunkDataOffset + 2, true);
      sampleRate = view.getUint32(chunkDataOffset + 4, true);
      bitsPerSample = view.getUint16(chunkDataOffset + 14, true);
    } else if (chunkId === "data") {
      dataOffset = chunkDataOffset;
      dataSize = chunkSize;
      break;
    }

    offset = chunkDataOffset + chunkSize + (chunkSize % 2);
  }

  if (dataOffset < 0 || dataSize <= 0 || sampleRate <= 0 || channels <= 0) {
    return null;
  }
  return {
    audioFormat,
    sampleRate,
    channels,
    bitsPerSample,
    dataOffset,
    dataSize,
  };
}

/**
 * Coalesce a per-chunk VAD speech/silence decision sequence into pause spans.
 *
 * Pure: `probabilities[i]` covers `[i * chunkSeconds, (i + 1) * chunkSeconds)`.
 * A trailing silence run is reported too — the tail of a recording is a legal
 * place to cut.
 */
export function pauseSpansFromProbabilities(
  probabilities: number[],
  chunkSeconds: number,
  minPauseSeconds: number = MIN_PAUSE_SECONDS,
): PauseSpan[] {
  if (chunkSeconds <= 0) return [];
  const spans: PauseSpan[] = [];
  let runStart: number | null = null;

  const closeRun = (endIndex: number): void => {
    if (runStart === null) return;
    const startS = runStart * chunkSeconds;
    const endS = endIndex * chunkSeconds;
    if (endS - startS >= minPauseSeconds) spans.push({ startS, endS });
    runStart = null;
  };

  for (let index = 0; index < probabilities.length; index++) {
    if (isSpeech(probabilities[index])) {
      closeRun(index);
    } else if (runStart === null) {
      runStart = index;
    }
  }
  closeRun(probabilities.length);

  return spans;
}

/**
 * Run Silero VAD over a saved 16 kHz mono PCM16 WAV and return its silence spans.
 *
 * Returns `[]` — never throws — when the audio cannot be analysed. `[]` is the
 * documented "no smart boundaries available" answer and every caller must read
 * it that way: `src/stt.ts` keeps the fixed 30 s cut, i.e. today's behaviour.
 * The reason is always logged, so an unanalysable recording is visible rather
 * than silently decoded as if it had no pauses.
 *
 * Runs on its OWN VAD session (`createVADSession`), never the module-global one
 * that belongs to whatever recording is live.
 */
export async function computePauseMap(
  wavData: Uint8Array,
  options?: { minPauseSeconds?: number },
): Promise<PauseSpan[]> {
  const info = parseWavAudioInfo(wavData);
  if (!info) {
    console.error(
      "[voicelayer] pause map unavailable: not a readable PCM WAV; keeping fixed cuts",
    );
    return [];
  }
  if (
    info.audioFormat !== WAVE_FORMAT_PCM ||
    info.sampleRate !== 16000 ||
    info.channels !== 1 ||
    info.bitsPerSample !== 16
  ) {
    console.error(
      "[voicelayer] pause map unavailable: expected 16 kHz mono 16-bit integer PCM, got " +
        `format ${info.audioFormat} / ${info.sampleRate} Hz / ${info.channels} ch / ` +
        `${info.bitsPerSample}-bit; keeping fixed cuts`,
    );
    return [];
  }

  const chunkBytes = VAD_CHUNK_SAMPLES * 2;
  const usableChunks = Math.floor(info.dataSize / chunkBytes);
  const probabilities: number[] = [];

  const vad = await createVADSession();
  for (let chunk = 0; chunk < usableChunks; chunk++) {
    const start = info.dataOffset + chunk * chunkBytes;
    probabilities.push(
      await vad.process(wavData.subarray(start, start + chunkBytes)),
    );
  }

  return pauseSpansFromProbabilities(
    probabilities,
    VAD_CHUNK_SAMPLES / info.sampleRate,
    options?.minPauseSeconds,
  );
}

/**
 * Where the chunk starting at `startS` should end.
 *
 * Prefers the LATEST boundary that is still inside a pause, so the next chunk
 * opens on a word start. Two rules shape the choice:
 *  - never more than `maxSecondsIntoPause()` past a pause's start, so the next
 *    chunk's overlap still carries speech and the merge keeps its anchor;
 *  - never outside `[startS+min, startS+max]`.
 * With no usable pause it falls back to `startS + max` — exactly today's fixed
 * cut. Smart chunking never makes a boundary worse than the wall clock; it only
 * takes a better one when the audio offers one.
 */
export function chooseChunkEnd(
  startS: number,
  pauseMap: PauseSpan[],
  window: ChunkEndWindow = {
    min: SMART_CHUNK_MIN_SECONDS,
    max: SMART_CHUNK_MAX_SECONDS,
  },
): number {
  const ceiling = startS + window.max;
  if (window.min >= window.max) return ceiling;

  const floor = startS + window.min;
  const maxIntoPause = maxSecondsIntoPause(window.overlapSeconds);
  let best: number | null = null;

  for (const span of pauseMap) {
    // The latest point in this pause we are allowed to cut at...
    const latest = Math.min(span.endS, span.startS + maxIntoPause, ceiling);
    // ...and the earliest. A pause that reaches the window only by cutting
    // deeper than maxIntoPause is rejected, not clamped into a silent overlap.
    const earliest = Math.max(span.startS, floor);
    if (latest < earliest) continue;
    if (best === null || latest > best) best = latest;
  }
  return best ?? ceiling;
}
