/**
 * Internal-window speech coverage for chunked Parakeet decodes (V34, 2.2.62).
 *
 * The worker decodes long input in fixed windows (`PARAKEET_PRIMARY_GEOMETRY`)
 * and the provider merges overlapping windows. Before this guard only the
 * FINAL tail had a coverage check, so words near the end of an INTERNAL window
 * could vanish while VAD still heard speech there.
 *
 * Detection is timing-only: a gap between two consecutive decoded tokens, near
 * an internal window end, inside which complete Silero evidence hears speech.
 * No text is compared, matched, trimmed or deduplicated. The trailing gap after
 * the last token is deliberately excluded: the existing final-tail check owns it.
 *
 * Remedy (in parakeet-backend.ts): at most ONE whole-input re-decode with a
 * wider-context window geometry. A hypothesis is delivered as decoded, never
 * spliced; every attempt is retained with its windows and token times.
 */
import { VAD_CHUNK_SAMPLES } from "./vad-constants";

export interface ParakeetWindowGeometry { chunkSeconds: number; overlapSeconds: number }

/** What the worker has always used; unchanged for every first attempt. */
export const PARAKEET_PRIMARY_GEOMETRY: ParakeetWindowGeometry = Object.freeze({ chunkSeconds: 30, overlapSeconds: 2 });
/**
 * The only geometries a coverage retry may request (the worker refuses any
 * other). Each gives every window more source context and more overlap than
 * the primary 30 s / 2 s geometry; the backend picks the one whose internal
 * window ends sit furthest from the flagged gaps.
 */
export const PARAKEET_COVERAGE_RETRY_GEOMETRIES: readonly ParakeetWindowGeometry[] = Object.freeze([
  Object.freeze({ chunkSeconds: 45, overlapSeconds: 10 }),
  Object.freeze({ chunkSeconds: 50, overlapSeconds: 12 }),
  Object.freeze({ chunkSeconds: 60, overlapSeconds: 15 }),
]);
/** Hard bound: one extra decode per request. There is no loop. */
export const PARAKEET_COVERAGE_MAX_RETRIES = 1;
/** A gap is examined when it intersects [windowEnd - BEFORE, windowEnd + overlap]. */
export const PARAKEET_COVERAGE_NEIGHBORHOOD_BEFORE_S = 8;
/** Speech within this distance of a bounding token is attributed to that token (VAD hangover). */
export const PARAKEET_COVERAGE_TOKEN_PAD_S = 0.25;
/** Minimum VAD speech inside one token gap that counts as missing words. */
export const PARAKEET_COVERAGE_MIN_SPEECH_S = 0.75;
/** Retry needs at least this much of the overall request budget left. */
export const PARAKEET_COVERAGE_RETRY_MIN_BUDGET_MS = 5_000;

export interface ParakeetTokenSpan { start: number; end: number }
export interface ParakeetCoverageGap {
  /** End of the token before the gap / start of the token after it (seconds, absolute). */
  afterTokenEndS: number;
  beforeTokenStartS: number;
  /** The internal window end whose neighbourhood the gap intersects, when any. */
  windowEndS: number | null;
  /** VAD speech seconds strictly inside the padded gap. Absent before VAD runs. */
  speechS?: number;
}
export type ParakeetCoverageUnknownReason =
  | "missing-window-boundaries" | "invalid-window-boundaries"
  | "missing-token-times" | "invalid-token-times" | "speech-evidence-unavailable";
export type ParakeetTimingScan =
  | { status: "OK"; tokens: ParakeetTokenSpan[]; internalWindowEndsS: number[]; candidates: ParakeetCoverageGap[] }
  | { status: "UNKNOWN"; reason: ParakeetCoverageUnknownReason };

export interface ParakeetCoverageInput {
  text?: unknown;
  input_frames: number;
  sample_rate: number;
  raw_token_times?: unknown[];
  window_end_frames?: unknown;
}

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

/** Internal window ends only (the final window ends at the input end). */
export function internalWindowEnds(result: ParakeetCoverageInput): number[] | ParakeetCoverageUnknownReason {
  const ends = result.window_end_frames;
  if (!Array.isArray(ends) || ends.length === 0) return "missing-window-boundaries";
  let previous = 0;
  for (const end of ends) {
    if (!Number.isSafeInteger(end) || end <= previous || end > result.input_frames) return "invalid-window-boundaries";
    previous = end;
  }
  if (previous !== result.input_frames) return "invalid-window-boundaries";
  return ends.slice(0, -1).map(end => end / result.sample_rate);
}

/** Token spans in emission order. Out-of-order or malformed times are not guessed at. */
export function tokenSpans(result: ParakeetCoverageInput): ParakeetTokenSpan[] | ParakeetCoverageUnknownReason {
  const raw = result.raw_token_times;
  if (!Array.isArray(raw)) return "missing-token-times";
  const duration = result.input_frames / result.sample_rate;
  const spans: ParakeetTokenSpan[] = [];
  for (const item of raw) {
    const start = (item as { start?: unknown } | null)?.start, end = (item as { end?: unknown } | null)?.end;
    if (!finite(start) || !finite(end) || start < 0 || end < start || end > duration) return "invalid-token-times";
    if (spans.length && start < spans[spans.length - 1]!.start) return "invalid-token-times";
    spans.push({ start, end });
  }
  if (!spans.length && typeof result.text === "string" && result.text.trim()) return "missing-token-times";
  return spans;
}

function regionsFor(windowEnds: number[], overlapSeconds: number): { from: number; to: number; windowEndS: number | null }[] {
  return windowEnds.map(end => ({ from: end - PARAKEET_COVERAGE_NEIGHBORHOOD_BEFORE_S, to: end + overlapSeconds, windowEndS: end }));
}

/**
 * Timing-only pre-scan: token gaps wide enough to hide missing words near an
 * internal window end (or inside an explicitly supplied region). No VAD yet,
 * so the common fully-covered request never pays for a speech probe.
 */
export function scanInternalWindowGaps(result: ParakeetCoverageInput, geometry: ParakeetWindowGeometry,
  extraRegions: { from: number; to: number }[] = []): ParakeetTimingScan {
  const windows = internalWindowEnds(result);
  if (typeof windows === "string") return { status: "UNKNOWN", reason: windows };
  const tokens = tokenSpans(result);
  if (typeof tokens === "string") return { status: "UNKNOWN", reason: tokens };
  const regions = [...regionsFor(windows, geometry.overlapSeconds), ...extraRegions.map(r => ({ ...r, windowEndS: null }))];
  const candidates: ParakeetCoverageGap[] = [];
  const minimumGap = PARAKEET_COVERAGE_MIN_SPEECH_S + 2 * PARAKEET_COVERAGE_TOKEN_PAD_S;
  // Only gaps BETWEEN two tokens. Leading silence is not a window seam and the
  // trailing gap belongs to the existing final-tail check.
  let reach = tokens.length ? tokens[0]!.end : 0;
  for (let i = 1; i < tokens.length; i++) {
    const next = tokens[i]!;
    if (next.start - reach >= minimumGap) {
      const region = regions.find(r => reach < r.to && next.start > r.from);
      if (region) candidates.push({ afterTokenEndS: reach, beforeTokenStartS: next.start, windowEndS: region.windowEndS });
    }
    reach = Math.max(reach, next.end);
  }
  return { status: "OK", tokens, internalWindowEndsS: windows, candidates };
}

/** VAD speech seconds inside a gap, padded away from both bounding tokens. */
export function gapSpeechSeconds(gap: ParakeetCoverageGap, probabilities: readonly number[], threshold: number, sampleRate: number): number {
  const from = gap.afterTokenEndS + PARAKEET_COVERAGE_TOKEN_PAD_S, to = gap.beforeTokenStartS - PARAKEET_COVERAGE_TOKEN_PAD_S;
  if (to <= from) return 0;
  const window = VAD_CHUNK_SAMPLES / sampleRate;
  let speech = 0;
  for (let i = Math.floor(from / window); i < probabilities.length && i * window < to; i++) {
    if (probabilities[i]! < threshold) continue;
    speech += Math.max(0, Math.min(to, (i + 1) * window) - Math.max(from, i * window));
  }
  return speech;
}

/** Gaps where complete VAD evidence hears at least PARAKEET_COVERAGE_MIN_SPEECH_S of speech. */
export function uncoveredGaps(candidates: readonly ParakeetCoverageGap[], probabilities: readonly number[], threshold: number, sampleRate: number): ParakeetCoverageGap[] {
  return candidates.map(gap => ({ ...gap, speechS: gapSpeechSeconds(gap, probabilities, threshold, sampleRate) }))
    .filter(gap => gap.speechS! >= PARAKEET_COVERAGE_MIN_SPEECH_S);
}

/** Internal window ends a geometry would produce over `frames` (mirrors the provider's fixed stride). */
export function geometryInternalEnds(geometry: ParakeetWindowGeometry, frames: number, sampleRate: number): number[] {
  const duration = frames / sampleRate, step = geometry.chunkSeconds - geometry.overlapSeconds, ends: number[] = [];
  if (duration <= geometry.chunkSeconds) return ends;
  for (let start = 0; start + geometry.chunkSeconds < duration; start += step) ends.push(start + geometry.chunkSeconds);
  return ends;
}

/** Deterministic: the candidate whose internal window ends are furthest from every flagged gap. */
export function chooseRetryGeometry(gaps: readonly ParakeetCoverageGap[], frames: number, sampleRate: number): ParakeetWindowGeometry {
  let best = PARAKEET_COVERAGE_RETRY_GEOMETRIES[0]!, bestDistance = -Infinity;
  for (const geometry of PARAKEET_COVERAGE_RETRY_GEOMETRIES) {
    const ends = geometryInternalEnds(geometry, frames, sampleRate);
    let distance = Infinity;
    for (const gap of gaps) for (const end of ends) {
      const d = end < gap.afterTokenEndS ? gap.afterTokenEndS - end : end > gap.beforeTokenStartS ? end - gap.beforeTokenStartS : 0;
      distance = Math.min(distance, d);
    }
    if (distance > bestDistance) { best = geometry; bestDistance = distance; }
  }
  return best;
}

export interface ParakeetCoverageAttempt {
  /** 1 = primary decode, 2 = the single bounded retry. */
  attempt: number;
  geometry: ParakeetWindowGeometry;
  /** Provider-reported source windows; null when the attempt returned none. */
  windowEndFrames: number[] | null;
  status: "COVERED" | "UNCOVERED" | "UNKNOWN" | "FAILED";
  gaps: ParakeetCoverageGap[];
  reason?: string;
}

/** Request-scoped coverage provenance, surfaced on the STT result and retained diagnostics. */
export interface ParakeetInternalCoverage {
  status:
    | "NO_INTERNAL_WINDOW" | "COVERED" | "UNKNOWN" | "RETRY_COVERED"
    | "UNCOVERED_RETRY_PENDING" | "UNCOVERED_RETRY_PARTIAL" | "UNCOVERED_RETRY_FAILED" | "UNCOVERED_BUDGET_EXHAUSTED";
  reason?: string;
  retries: number;
  maxRetries: number;
  budgetMs?: number;
  elapsedMsAtRetry?: number;
  requiredMs?: number;
  attempts: ParakeetCoverageAttempt[];
}
