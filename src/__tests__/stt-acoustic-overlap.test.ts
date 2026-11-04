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
test.each(["missing", "crossing", "disjoint", "stale"])("%s timing cannot authorize deletion", mode => {
  const chunks = [
    { text: phrase, startSeconds: 0, segments: [{ text: phrase, startS: 25, endS: 29 }] },
    { text: phrase, startSeconds: 25, segments: [{ text: phrase, startS: 0, endS: 4 }] },
  ];
  if (mode === "missing") chunks[1]!.segments = [];
  if (mode === "crossing") chunks[1]!.segments[0]!.endS = 12;
  if (mode === "disjoint") { chunks[1]!.segments[0]!.startS = 4.1; chunks[1]!.segments[0]!.endS = 4.9; }
  if (mode === "stale") chunks[1]!.segments[0]!.text = "some other words";
  expect(merge(chunks)).toBe(phrase + " " + phrase);
});
const privatePaths = privateCorpusPaths("stt-acoustic-overlap");
test.skipIf(!privatePaths)("row6 first seam never folds a real extra paragraph; Alice keeps every previously retained word", () => {
  const root = privatePaths!.recordings;
  const repeated: TimedChunkTranscript[] = JSON.parse(readFileSync(join(root, "repeated-chunks.json"), "utf8"));
  const varied: TimedChunkTranscript[] = JSON.parse(readFileSync(join(root, "varied-chunks.json"), "utf8"));
  const first = merge(repeated.slice(0, 2));
  // Raw 83 + 80 words. The baseline folds 61 words to 102, consuming a whole
  // additional real paragraph. Conservative segment bounds permit <= 20 here.
  expect(first.split(/\s+/).length).toBeGreaterThanOrEqual(143);
  const baseline = readFileSync(join(root, "varied-baseline.txt"), "utf8").match(/[\p{L}\p{N}]+/gu)!.map(w => w.toLowerCase());
  const actual = merge(varied).match(/[\p{L}\p{N}]+/gu)!.map(w => w.toLowerCase());
  let index = 0;
  for (const word of actual) if (word === baseline[index]) index++;
  expect(index).toBe(baseline.length);
});
