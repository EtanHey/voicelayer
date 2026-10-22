import { createHash } from "crypto";
import { describe, expect, spyOn, test } from "bun:test";
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
  test("folds a near-repeat fully covered by the shared audio, selecting stride context", () => {
    const result = mergeChunkTranscriptsWithSegments(fixture());
    expect(result.text).toBe(`We agreed. ${later} ${continuation}`);
    expect(result.segments.map(s => s.text).join(" ")).toBe(result.text);
    expect(result.segments.at(-1)).toEqual({ text: continuation, startS: 31, endS: 33 });
  });

  test("logs only hashes and the zero-based disagreement position", () => {
    const log = spyOn(console, "error").mockImplementation(() => {});
    try {
      mergeChunkTranscriptsWithSegments(fixture());
      expect(log).toHaveBeenCalledTimes(1);
      const line = String(log.mock.calls[0]![0]);
      const diagnostic = JSON.parse(line.slice(line.indexOf("{")));
      expect(diagnostic.disagreements).toEqual([{
        position: 6,
        earlierTokenHash: createHash("sha256").update("will").digest("hex"),
        laterTokenHash: createHash("sha256").update("we'll").digest("hex"),
      }]);
      expect(line).not.toContain("will");
      expect(line).not.toContain("we'll");
    } finally {
      log.mockRestore();
    }
  });

  test.each(["earlier", "later"])("restores the untimed merge when %s segments invert outside the seam", side => {
    const chunks = fixture();
    if (side === "earlier") {
      chunks[0]!.text = `Before that. ${chunks[0]!.text}`;
      chunks[0]!.segments.unshift({ text: "Before that.", startS: 15, endS: 16 });
    } else {
      chunks[1]!.text += " Another thought.";
      chunks[1]!.segments.push({ text: "Another thought.", startS: 4, endS: 5 });
    }
    expect(mergeChunkTranscriptsWithSegments(chunks)).toEqual({
      text: mergeChunkTranscripts(chunks.map(c => c.text)), segments: [],
    });
  });

  test("keeps the later terminal question mark on matched words", () => {
    const chunks = fixture();
    chunks[1]!.text = chunks[1]!.text.replace("bridge.", "bridge?");
    chunks[1]!.segments[0]!.text = chunks[1]!.segments[0]!.text.replace("bridge.", "bridge?");
    const result = mergeChunkTranscriptsWithSegments(chunks);
    expect(result.text).toBe(`We agreed. ${later.replace("bridge.", "bridge?")} ${continuation}`);
    expect(result.segments.map(s => s.text).join(" ")).toBe(result.text);
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

  test.each([3.8, 0.000001])("keeps both readings across a retained coverage gap of %s seconds", gap => {
    const chunks = fixture();
    chunks[0]!.segments[1]!.endS = 25.2;
    chunks[0]!.segments[2]!.startS = 25.2 + gap;
    chunks[1]!.text = chunks[1]!.text.replace("we'll", "never");
    chunks[1]!.segments[0]!.text = chunks[1]!.segments[0]!.text.replace("we'll", "never");
    const result = mergeChunkTranscriptsWithSegments(chunks);
    expect(result.text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
    expect(result.segments.map(s => s.text).join(" ")).toBe(result.text);
  });

  test.each([2, 3])("keeps the entire later reading split into %s segments across retained components", count => {
    const chunks = fixture();
    chunks[0]!.segments[1]!.endS = 25.2;
    chunks[0]!.segments[2]!.startS = 29;
    chunks[1]!.text = `Several violet robots near the orchard never build a wooden bridge. ${continuation}`;
    chunks[1]!.segments = [
      { text: "Several violet robots near the orchard", startS: 0, endS: 0.2 },
      ...(count === 2
        ? [{ text: "never build a wooden bridge.", startS: 4, endS: 4.96 }]
        : [
          { text: "never build", startS: 4, endS: 4.4 },
          { text: "a wooden bridge.", startS: 4.4, endS: 4.96 },
        ]),
      { text: continuation, startS: 6, endS: 8 },
    ];
    const result = mergeChunkTranscriptsWithSegments(chunks);
    expect(result.text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
    expect(result.segments.map(s => s.text).join(" ")).toBe(result.text);
  });

  test("keeps all two- and three-segment partitions across retained components", () => {
    const words = later.replace("we'll", "never").split(" ");
    for (let firstCut = 1; firstCut < words.length; firstCut++) {
      for (let secondCut = firstCut; secondCut < words.length; secondCut++) {
        const chunks = fixture();
        chunks[0]!.segments[1]!.endS = 25.2;
        chunks[0]!.segments[2]!.startS = 29;
        const cuts = secondCut === firstCut ? [firstCut] : [firstCut, secondCut];
        const boundaries = [0, ...cuts, words.length];
        chunks[1]!.text = `${words.join(" ")} ${continuation}`;
        chunks[1]!.segments = boundaries.slice(1).map((end, index) => ({
          text: words.slice(boundaries[index]!, end).join(" "),
          startS: index === 0 ? 0 : index === 1 ? 4 : 4.4,
          endS: index === 0 ? 0.2 : index === boundaries.length - 2 ? 4.96 : 4.4,
        }));
        chunks[1]!.segments.push({ text: continuation, startS: 6, endS: 8 });
        expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
      }
    }
  });

  test.each([1, 0.000001])("keeps a later gap of %s seconds even inside one retained component", gap => {
    const chunks = fixture();
    chunks[1]!.segments = [
      { text: "Several violet robots near the orchard", startS: 0, endS: 1 },
      { text: "we'll build a wooden bridge.", startS: 1 + gap, endS: 4.96 },
      { text: continuation, startS: 6, endS: 8 },
    ];
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
  });

  test("keeps a later gap concealed by instantaneous-segment widening", () => {
    const chunks = fixture();
    chunks[1]!.segments = [
      { text: "Several violet robots near the orchard", startS: 0, endS: 0.2 },
      { text: "we'll", startS: 4, endS: 4 },
      { text: "build a wooden bridge.", startS: 4, endS: 4.96 },
      { text: continuation, startS: 6, endS: 8 },
    ];
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
  });

  test("folds a later reading split at touching segment boundaries", () => {
    const chunks = fixture();
    chunks[1]!.segments = [
      { text: "Several violet robots near the orchard", startS: 0, endS: 2 },
      { text: "we'll build a wooden bridge.", startS: 2, endS: 4.96 },
      { text: continuation, startS: 6, endS: 8 },
    ];
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`We agreed. ${later} ${continuation}`);
  });

  test("does not fill a retained gap by widening an instantaneous segment", () => {
    const chunks = fixture();
    chunks[0]!.segments = [
      { text: "We agreed.", startS: 10, endS: 11 },
      { text: "Several violet robots near the orchard", startS: 24.72, endS: 25.2 },
      { text: "will", startS: 29, endS: 29 },
      { text: "build a wooden bridge.", startS: 29, endS: 30 },
    ];
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
  });

  test.each([4.88, 4.80, 4.88])("retains target removal with recorded relative segment timings ending at %s", end => {
    const chunks = fixture(0, end);
    // Recorded requests 6/7 start at 75/100: retained union [99.72,105).
    chunks[0]!.startSeconds = 75;
    chunks[1]!.startSeconds = 100;
    const result = mergeChunkTranscriptsWithSegments(chunks);
    expect(result.text).toBe(`We agreed. ${later} ${continuation}`);
    expect(chunks.map(c => c.text).join(" ").split(/\s+/).length - result.text.split(/\s+/).length).toBe(11);
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

  test.each([Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY])("keeps both readings with non-finite chunk offsets: %s", offset => {
    const chunks = fixture();
    chunks[0]!.startSeconds = offset;
    chunks[1]!.startSeconds = offset;
    expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`${chunks[0]!.text} ${chunks[1]!.text}`);
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
