import { expect, test } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";
import { mergeChunkTranscriptsWithSegments, type TimedChunkTranscript } from "../stt";
import { privateCorpusPaths } from "./setup/private-specimens";

// Production mode requires timing; legacy text-only callers retain their API.
const merge = (chunks: TimedChunkTranscript[]) => mergeChunkTranscriptsWithSegments(chunks, [], { requireAcousticOverlap: true }).text;
const phrase = "Keep the same paragraph because I actually said it again.";
test("equal text outside the shared audio window is genuine repeated speech", () => {
  const chunks = [
    { text: phrase, startSeconds: 0, segments: [{ text: phrase, startS: 5, endS: 12 }] },
    { text: phrase + " Continue.", startSeconds: 25, segments: [
      { text: phrase, startS: 6, endS: 13 }, { text: "Continue.", startS: 13, endS: 14 },
    ] },
  ];
  expect(merge(chunks)).toBe(phrase + " " + phrase + " Continue.");
});
test("equal words covering the same audio inside the shared window fold once", () => {
  expect(merge([
    { text: "before same words", startSeconds: 0, segments: [
      { text: "before", startS: 10, endS: 11 }, { text: "same", startS: 26, endS: 27 }, { text: "words", startS: 27, endS: 28 },
    ] },
    { text: "same words after", startSeconds: 25, segments: [
      { text: "same", startS: 1.1, endS: 2.1 }, { text: "words", startS: 2.1, endS: 3.1 }, { text: "after", startS: 7, endS: 8 },
    ] },
  ])).toBe("before same words after");
});
test.each(["missing", "crossing", "stale"])("%s timing uses the lead-authorized bounded edge fallback", mode => {
  const chunks = [
    { text: phrase, startSeconds: 0, segments: [{ text: phrase, startS: 25, endS: 29 }] },
    { text: phrase, startSeconds: 25, segments: [{ text: phrase, startS: 0, endS: 4 }] },
  ];
  if (mode === "missing") chunks[1]!.segments = [];
  if (mode === "crossing") chunks[1]!.segments[0]!.endS = 12;
  if (mode === "stale") chunks[1]!.segments[0]!.text = "some other words";
  expect(merge(chunks)).toBe(phrase);
});
test("positive timing evidence of distinct speech vetoes the text fallback", () => {
  expect(merge([
    { text: phrase, startSeconds: 0, segments: [{ text: phrase, startS: 25, endS: 29 }] },
    { text: phrase, startSeconds: 25, segments: [{ text: phrase, startS: 4.1, endS: 4.9 }] },
  ])).toBe(phrase + " " + phrase);
});
test("a whole-chunk envelope cannot pretend a repeated paragraph belongs to the overlap", () => {
  const paragraph = Array.from({ length: 46 }, (_, i) => `word${i}`).join(" ");
  expect(merge([
    { text: paragraph, startSeconds: 0, segments: [{ text: paragraph, startS: 0, endS: 30 }] },
    { text: paragraph, startSeconds: 25, segments: [{ text: paragraph, startS: 0, endS: 30 }] },
  ])).toBe(paragraph + " " + paragraph);
});

const privatePaths = privateCorpusPaths("stt-acoustic-overlap");
test.skipIf(!privatePaths)("row6 first seam never folds a real extra paragraph; Alice keeps every previously retained word", () => {
  const root = privatePaths!.recordings;
  const repeated: TimedChunkTranscript[] = JSON.parse(readFileSync(join(root, "repeated-chunks.json"), "utf8"));
  const varied: TimedChunkTranscript[] = JSON.parse(readFileSync(join(root, "varied-chunks.json"), "utf8"));
  const first = merge(repeated.slice(0, 2));
  // Raw 83 + 80 words. The baseline folds 61 words to 102, consuming a whole
  // additional real paragraph. The bounded anchor removes 15 here, never the old 61.
  expect(first.split(/\s+/).length).toBeGreaterThanOrEqual(143);
  const baseline = readFileSync(join(root, "varied-baseline.txt"), "utf8").match(/[\p{L}\p{N}]+/gu)!.map(w => w.toLowerCase());
  const actual = merge(varied).match(/[\p{L}\p{N}]+/gu)!.map(w => w.toLowerCase());
  let index = 0;
  for (const word of actual) if (word === baseline[index]) index++;
  expect(index).toBe(baseline.length);
  expect(actual.length).toBeLessThanOrEqual(baseline.length + 2);
});

for (const name of ["R2", "R3", "R4", "R5"]) {
  test.skipIf(!privatePaths)(`${name}: bounded fallback preserves the real audit's ordinary seams`, () => {
    const chunks: TimedChunkTranscript[] = JSON.parse(readFileSync(join(privatePaths!.recordings, `${name}-chunks.json`), "utf8"));
    // Same captured decodes on both arms. These sparse real recordings exposed
    // the rejected containment rule's extra repeated overlap at ordinary seams.
    expect(merge(chunks)).toBe(mergeChunkTranscriptsWithSegments(chunks).text);
  });
}

test.each([true, false])("the bounded anchor cannot reach through a one-word previous chunk (timing=%s)", timing => {
  const chunks = [
    { text: "ancient words", startSeconds: 0, segments: [{ text: "ancient words", startS: 1, endS: 2 }] },
    { text: "boundary", startSeconds: 25, segments: [{ text: "boundary", startS: 20, endS: 21 }] },
    { text: "ancient words boundary after", startSeconds: 50, segments: [{ text: "ancient words boundary after", startS: 0, endS: 3 }] },
  ];
  if (!timing) for (const chunk of chunks) chunk.segments = [];
  expect(merge(chunks)).toBe("ancient words boundary ancient words boundary after");
});
