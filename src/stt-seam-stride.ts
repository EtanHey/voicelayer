import type { TranscriptSegment } from "./stt-transcript-alignment";

type Span = Pick<TranscriptSegment, "startS" | "endS">;
export function chooseSeamVariant(earlier: Span | null, later: Span | null, startS: number, endS: number): {
  winner: "earlier" | "later";
  reason: "stride-midpoint" | "missing-timestamps" | "midpoint-tie";
  earlierDistanceFromEdgeS: number | null;
  laterDistanceFromEdgeS: number | null;
} {
  const usable = (span: Span | null): span is Span => span !== null &&
    Number.isFinite(span.startS) && Number.isFinite(span.endS) && span.endS > span.startS;
  if (usable(earlier) && usable(later) && Number.isFinite(startS) && Number.isFinite(endS) && endS > startS) {
    // Segment centres are the available timestamp proxy; never interpolate words.
    // At a common word time, comparing edge distances is exactly a midpoint split.
    const earlierDistanceFromEdgeS = endS - (earlier.startS + earlier.endS) / 2;
    const laterDistanceFromEdgeS = (later.startS + later.endS) / 2 - startS;
    return {
      winner: laterDistanceFromEdgeS > earlierDistanceFromEdgeS ? "later" : "earlier",
      reason: laterDistanceFromEdgeS === earlierDistanceFromEdgeS ? "midpoint-tie" : "stride-midpoint",
      earlierDistanceFromEdgeS, laterDistanceFromEdgeS,
    };
  }
  return { winner: "earlier", reason: "missing-timestamps", earlierDistanceFromEdgeS: null, laterDistanceFromEdgeS: null };
}
