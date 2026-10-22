import { describe, expect, test } from "bun:test";
import { mergeChunkTranscripts, mergeChunkTranscriptsWithSegments, type TimedChunkTranscript } from "../stt";

const earlier = "Several violet robots near the orchard will build a wooden bridge.";
const later = "Several violet robots near the orchard we'll build a wooden bridge.";
const continuation = "Then the lanterns lit.";

function fixture(startS = 0, endS = 4.96): TimedChunkTranscript[] {
  return [
    { text: `We agreed. ${earlier}`, startSeconds: 0, segments: [
      { text: "We agreed.", startS: 10, endS: 11 },
      { text: "Several violet robots near the orchard", startS: 24.72, endS: 26.52 },
      { text: "will build a wooden bridge.", startS: 26.52, endS: 30 },
    ] },
    { text: `${later} ${continuation}`, startSeconds: 25, segments: [
      { text: later, startS, endS },
      { text: continuation, startS: Math.max(6, endS), endS: Math.max(8, endS + 2) },
    ] },
  ];
}

describe("timestamp-supported near-repeat seams", () => {
  test("folds a near-repeat fully covered by the shared audio, retaining the earlier reading", () => {
    const result = mergeChunkTranscriptsWithSegments(fixture());
    expect(result.text).toBe(`We agreed. ${earlier} ${continuation}`);
    expect(result.segments.map(s => s.text).join(" ")).toBe(result.text);
    expect(result.segments.at(-1)).toEqual({ text: continuation, startS: 31, endS: 33 });
  });

  test.each([[5, 9.96], [0, 5.01], [3, 4.96]])("keeps a copy with separate or crossing acoustic support (%s,%s)", (start, end) => {
    const chunks = fixture(start, end);
    if (start === 3) {
      chunks[0]!.segments[1]!.startS = 25;
      chunks[0]!.segments[1]!.endS = 26;
      chunks[0]!.segments[2]!.startS = 26;
      chunks[0]!.segments[2]!.endS = 27;
    }
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toContain(later);
  });

  test("keeps the untimed merge unchanged", () => {
    const chunks = fixture();
    expect(mergeChunkTranscripts(chunks.map(c => c.text))).toContain(later);
    chunks[1]!.segments = [];
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toContain(later);
  });

  test.each(["fu…", "er-", "wait—", "fu…,", "er-,", "wait—)"])("keeps raw fragments and retractions: %s", fragment => {
    const chunks = fixture();
    chunks[1]!.text = chunks[1]!.text.replace("we'll", fragment);
    chunks[1]!.segments[0]!.text = chunks[1]!.segments[0]!.text.replace("we'll", fragment);
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toContain(fragment);
  });

  test("keeps stale segment text", () => {
    const chunks = fixture();
    chunks[1]!.segments[0]!.text = "A different statement.";
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toContain(later);
  });

  test("does not equate operators or numbers even inside the overlap", () => {
    for (const [a, b] of [["C++", "C#"], ["12", "13"]]) {
      const chunks = fixture();
      chunks[0]!.text = chunks[0]!.text.replace("will", a!);
      chunks[0]!.segments[2]!.text = chunks[0]!.segments[2]!.text.replace("will", a!);
      chunks[1]!.text = chunks[1]!.text.replace("we'll", b!);
      chunks[1]!.segments[0]!.text = chunks[1]!.segments[0]!.text.replace("we'll", b!);
      expect(mergeChunkTranscriptsWithSegments(chunks).text).toContain(b!);
    }
  });

  test("never reconciles a silence seam", () => {
    expect(mergeChunkTranscriptsWithSegments(fixture(), ["anchor", "silence"]).text).toContain(later);
  });

  test("does not infer a word boundary inside a segment", () => {
    const chunks = fixture();
    chunks[1]!.segments = [{ text: chunks[1]!.text, startS: 0, endS: 8 }];
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toContain(later);
  });

  test("preserves the existing merge's token preference when its anchor succeeds", () => {
    const chunks = fixture();
    chunks[0]!.text = chunks[0]!.text.replace("will", "record");
    chunks[0]!.segments[2]!.text = chunks[0]!.segments[2]!.text.replace("will", "record");
    chunks[1]!.text = chunks[1]!.text.replace("we'll", "records");
    chunks[1]!.segments[0]!.text = chunks[1]!.segments[0]!.text.replace("we'll", "records");
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(mergeChunkTranscripts(chunks.map(c => c.text)));
  });
});
