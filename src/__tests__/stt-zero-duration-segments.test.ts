import { expect, test } from "bun:test";
import { mergeChunkTranscripts, mergeChunkTranscriptsWithSegments } from "../stt";

// Real 4:43 recording's chunk at 125s: original timings, synthetic words.
const segments = [
  { text: "alpha beta", startS: 0, endS: 4.34 },
  { text: "gamma delta", startS: 4.34, endS: 7.4 },
  { text: "epsilon", startS: 7.4, endS: 8.74 },
  { text: "zeta eta theta", startS: 21.26, endS: 21.26 },
  { text: "iota kappa", startS: 21.26, endS: 29.38 },
];
const text = segments.map(s => s.text).join(" ");

test("a bounded internal zero-duration segment widens adjacent evidence without changing words", () => {
  const chunks = [{ text, startSeconds: 125, segments }];
  const before = JSON.stringify(chunks);
  const result = mergeChunkTranscriptsWithSegments(chunks);
  expect(result.text).toBe(mergeChunkTranscripts(chunks.map(c => c.text)));
  expect(result.segments).toEqual([
    { text: "alpha beta", startS: 125, endS: 129.34 },
    { text: "gamma delta", startS: 129.34, endS: 132.4 },
    { text: "epsilon zeta eta theta iota kappa", startS: 132.4, endS: 154.38 },
  ]);
  expect(JSON.stringify(chunks)).toBe(before);
});

test("unbounded, reversed or detached zero-duration timings still fail closed", () => {
  for (const bad of [
    segments.slice(3), // no positive-duration predecessor
    segments.slice(0, 4), // no positive-duration successor
    segments.map((s,i) => i === 4 ? {...s,startS:22} : s),
    segments.map((s,i) => i === 3 ? {...s,endS:20} : s),
  ]) {
    const input = bad.map(s => s.text).join(" ");
    const result = mergeChunkTranscriptsWithSegments([{text:input,startSeconds:125,segments:bad}]);
    expect(result.text).toBe(input);
    expect(result.segments).toEqual([]);
  }
});

test("a widened seam carries only its inherited overlap into the next segment", () => {
  const chunks = [
    { text: "alpha bridge", startSeconds:100, segments:[
      {text:"alpha",startS:25,endS:28.08}, {text:"bridge",startS:28.08,endS:30},
    ] },
    { text: "bridge middle final", startSeconds:125, segments:[
      {text:"bridge middle",startS:0,endS:4.34},
      {text:"final",startS:4.34,endS:7.4},
    ] },
  ];
  const result=mergeChunkTranscriptsWithSegments(chunks);
  expect(result.text).toBe("alpha bridge middle final");
  expect(result.segments).toEqual([
    {text:"alpha",startS:125,endS:100+28.08},
    {text:"bridge middle final",startS:100+28.08,endS:132.4},
  ]);
  const inverted=structuredClone(chunks);
  inverted[1]!.segments[1]!.startS=4;
  expect(mergeChunkTranscriptsWithSegments(inverted).segments).toEqual([]);
});
