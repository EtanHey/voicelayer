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

import { isSpeech, processVADChunk, resetVAD, VAD_CHUNK_SAMPLES } from "./vad";

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

export interface ChunkEndWindow {
  min: number;
  max: number;
}

interface WavAudioInfo {
  sampleRate: number;
  channels: number;
  bitsPerSample: number;
  dataOffset: number;
  dataSize: number;
}

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
  return { sampleRate, channels, bitsPerSample, dataOffset, dataSize };
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
 * Throws on a format the VAD cannot read rather than returning `[]`, so a caller
 * cannot mistake "unreadable" for "no pauses" and cut blind.
 */
export async function computePauseMap(
  wavData: Uint8Array,
  options?: { minPauseSeconds?: number },
): Promise<PauseSpan[]> {
  const info = parseWavAudioInfo(wavData);
  if (!info) throw new Error("computePauseMap: not a readable PCM WAV");
  if (info.sampleRate !== 16000 || info.channels !== 1 || info.bitsPerSample !== 16) {
    throw new Error(
      `computePauseMap: expected 16 kHz mono 16-bit PCM, got ${info.sampleRate} Hz / ` +
        `${info.channels} ch / ${info.bitsPerSample}-bit`,
    );
  }

  const chunkBytes = VAD_CHUNK_SAMPLES * 2;
  const usableChunks = Math.floor(info.dataSize / chunkBytes);
  const probabilities: number[] = [];

  await resetVAD();
  try {
    for (let chunk = 0; chunk < usableChunks; chunk++) {
      const start = info.dataOffset + chunk * chunkBytes;
      probabilities.push(
        await processVADChunk(wavData.subarray(start, start + chunkBytes)),
      );
    }
  } finally {
    // The VAD session is a module-level singleton shared with live recording;
    // leaving this recording's RNN state behind would bias the next caller.
    await resetVAD();
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
 * Prefers the END of the last pause landing inside `[startS+min, startS+max]` —
 * the latest legal boundary that is still silence, so the next chunk opens on a
 * word start. With no pause in the window it falls back to `startS + max`, i.e.
 * exactly today's fixed cut: smart chunking never makes a boundary worse than
 * the wall clock, it only takes a better one when the audio offers it.
 */
export function chooseChunkEnd(
  startS: number,
  pauseMap: PauseSpan[],
  window: ChunkEndWindow = {
    min: SMART_CHUNK_MIN_SECONDS,
    max: SMART_CHUNK_MAX_SECONDS,
  },
): number {
  const fallback = startS + window.max;
  if (window.min >= window.max) return fallback;

  const earliest = startS + window.min;
  let best: number | null = null;
  for (const span of pauseMap) {
    if (span.endS < earliest || span.endS > fallback) continue;
    if (best === null || span.endS > best) best = span.endS;
  }
  return best ?? fallback;
}
