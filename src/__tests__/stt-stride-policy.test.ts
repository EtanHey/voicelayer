import { createHash } from "crypto";
import { expect, test } from "bun:test";
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


import { readFileSync, existsSync } from "fs";
import { join } from "path";
import { getStateDir } from "../paths";
import { chooseSeamVariant } from "../stt-seam-stride";

test("recorded 11-word 2-to-1 shape selects later by segment centre", () => {
  const chunks = fixture(0, 4.88);
  chunks[0]!.startSeconds = 75;
  chunks[1]!.startSeconds = 100;
  expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`We agreed. ${later} ${continuation}`);
});
test("second half later, first half earlier, missing timestamps earlier", () => {
  expect(chooseSeamVariant({startS:28,endS:29}, {startS:28,endS:29},25,30).winner).toBe("later");
  expect(chooseSeamVariant({startS:25,endS:26}, {startS:25,endS:26},25,30).winner).toBe("earlier");
  expect(chooseSeamVariant(null,null,25,30)).toMatchObject({winner:"earlier",reason:"missing-timestamps"});
});
test("appends every disagreement with hashes only to isolated state", () => {
  expect(process.env.VOICELAYER_TEST_ISOLATED).toBe("1");
  const file = join(getStateDir(), "seam-audit.jsonl");
  const before = existsSync(file) ? readFileSync(file,"utf8") : "";
  mergeChunkTranscriptsWithSegments(fixture(0,4.88));
  mergeChunkTranscriptsWithSegments(fixture(0,4.88));
  const added = readFileSync(file,"utf8").slice(before.length);
  const records = added.trim().split("\n").map(line => JSON.parse(line));
  expect(records).toHaveLength(2);
  expect(records[0]).toMatchObject({position:6,winner:"later",reason:"stride-midpoint",
    earlierTokenHash:createHash("sha256").update("will").digest("hex"),
    laterTokenHash:createHash("sha256").update("we'll").digest("hex")});
  expect(records[0].earlierDistanceFromEdgeS).toBeCloseTo(1.74);
  expect(records[0].laterDistanceFromEdgeS).toBeCloseTo(2.44);
  expect(Number.isNaN(Date.parse(records[0].ts))).toBe(false);
  expect(added).not.toContain("will");
  expect(added).not.toContain("we'll");
  expect(file).toContain(process.env.VOICELAYER_STATE_DIR!);
});

test("first-half disputed word retains the earlier variant in the complete merge", () => {
  const chunks = fixture();
  chunks[0]!.segments[1] = {text: "Several violet robots near the orchard will", startS:24.72,endS:26};
  chunks[0]!.segments[2] = {text: "build a wooden bridge.", startS:26,endS:30};
  chunks[1]!.segments = [
    {text: "Several violet robots near the orchard we'll",startS:0,endS:1},
    {text: "build a wooden bridge.",startS:1,endS:4.96},
    {text:continuation,startS:6,endS:8},
  ];
  expect(mergeChunkTranscriptsWithSegments(chunks).text).toBe(`We agreed. ${earlier} ${continuation}`);
});

test("invalid timestamps and midpoint ties retain earlier", () => {
  expect(chooseSeamVariant({startS:NaN,endS:29},{startS:28,endS:29},25,30).reason).toBe("missing-timestamps");
  expect(chooseSeamVariant({startS:29,endS:28},{startS:28,endS:29},25,30).winner).toBe("earlier");
  expect(chooseSeamVariant({startS:27,endS:28},{startS:27,endS:28},25,30)).toMatchObject({winner:"earlier",reason:"midpoint-tie"});
});
