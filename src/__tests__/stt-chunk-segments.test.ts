import { afterEach, describe, expect, test } from "bun:test";
import { existsSync } from "fs";
import { join } from "path";
import {
  mergeChunkTranscripts,
  mergeChunkTranscriptsWithSegments,
  WhisperServerBackend,
} from "../stt";
import { findCandidateSpan, findOutroCandidates } from "../stt-outro-gate";
import type { TranscriptSegment } from "../stt-sentence-boundaries";
import realChunkSegments from "./fixtures/h3-real-chunk-segments.json";
import { TEST_TMP } from "./setup/test-tmp";

const OUTRO_FLAG = "VOICELAYER_STT_OUTRO_GATE";
const BOUNDARIES_FLAG = "VOICELAYER_STT_SMART_BOUNDARIES";
const SMART_CHUNKS_FLAG = "VOICELAYER_STT_SMART_CHUNKS";

const savedEnv = {
  outro: process.env[OUTRO_FLAG],
  boundaries: process.env[BOUNDARIES_FLAG],
  smartChunks: process.env[SMART_CHUNKS_FLAG],
};

afterEach(() => {
  for (const [name, value] of [
    [OUTRO_FLAG, savedEnv.outro],
    [BOUNDARIES_FLAG, savedEnv.boundaries],
    [SMART_CHUNKS_FLAG, savedEnv.smartChunks],
  ] as const) {
    if (value === undefined) delete process.env[name];
    else process.env[name] = value;
  }
});

function segment(text: string, startS: number, endS: number): TranscriptSegment {
  return { text, startS, endS };
}

function makePcm16Wav(durationSeconds: number): Uint8Array {
  const sampleRate = 16_000;
  const dataBytes = durationSeconds * sampleRate * 2;
  const wav = new Uint8Array(44 + dataBytes);
  const view = new DataView(wav.buffer);
  const writeAscii = (offset: number, value: string) => {
    for (let index = 0; index < value.length; index++) {
      wav[offset + index] = value.charCodeAt(index);
    }
  };
  writeAscii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  writeAscii(8, "WAVE");
  writeAscii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(36, "data");
  view.setUint32(40, dataBytes, true);
  for (let sample = 0; sample < durationSeconds * sampleRate; sample++) {
    view.setInt16(
      44 + sample * 2,
      Math.round(2_000 * Math.sin((2 * Math.PI * 180 * sample) / sampleRate)),
      true,
    );
  }
  return wav;
}

describe("chunk transcript segment stitching", () => {
  test("offsets a three-chunk schedule exactly and keeps overlap timing from the earlier chunk", () => {
    const merged = mergeChunkTranscriptsWithSegments(
      [
        {
          text: "alpha bridge",
          startSeconds: 0,
          segments: [segment(" alpha", 1, 2), segment(" bridge", 28, 29)],
        },
        {
          text: "bridge middle seam",
          startSeconds: 25,
          segments: [
            segment(" bridge", 3.2, 4.1),
            segment(" middle", 5.5, 7),
            segment(" seam", 28, 29),
          ],
        },
        {
          text: "seam final",
          startSeconds: 50,
          segments: [segment(" seam", 3.2, 4.1), segment(" final", 4.5, 6)],
        },
      ],
      ["anchor", "anchor", "anchor"],
    );

    expect(merged.text).toBe("alpha bridge middle seam final");
    expect(merged.segments).toEqual([
      segment("alpha", 1, 2),
      segment("bridge", 28, 29),
      segment("middle", 30.5, 32),
      segment("seam", 53, 54),
      segment("final", 54.5, 56),
    ]);
    for (let index = 1; index < merged.segments.length; index++) {
      expect(merged.segments[index]!.startS).toBeGreaterThanOrEqual(
        merged.segments[index - 1]!.endS,
      );
    }
  });

  test("widens a seam segment instead of narrowing its true span", () => {
    const merged = mergeChunkTranscriptsWithSegments([
      {
        text: "alpha bridge",
        startSeconds: 0,
        segments: [segment(" alpha", 1, 2), segment(" bridge", 28, 30)],
      },
      {
        text: "bridge middle",
        startSeconds: 25,
        // Whisper combined the discarded overlap and kept suffix into one
        // segment. Keeping its true start widens the evidence conservatively.
        segments: [segment(" bridge middle", 3, 7)],
      },
    ]);

    expect(merged.text).toBe("alpha bridge middle");
    expect(merged.segments).toEqual([
      segment("alpha", 1, 2),
      segment("bridge middle", 28, 32),
    ]);
  });

  test("pins silence-seam concatenation and its half-second timing bound", () => {
    const repeatedEdge = [
      {
        text: "one two",
        startSeconds: 0,
        segments: [segment(" one", 20, 26), segment(" two", 26, 29)],
      },
      {
        text: "two three",
        startSeconds: 29.5,
        segments: [segment(" two", 0, 3), segment(" three", 3, 6)],
      },
    ];
    expect(
      mergeChunkTranscriptsWithSegments(repeatedEdge, ["anchor", "silence"]),
    ).toEqual({
      text: "one two two three",
      segments: [
        segment("one", 20, 26),
        segment("two", 26, 29),
        segment("two", 29.5, 32.5),
        segment("three", 32.5, 35.5),
      ],
    });
    expect(
      mergeChunkTranscriptsWithSegments(repeatedEdge, ["anchor", "anchor"]),
    ).toEqual({
      text: "one two three",
      segments: [
        segment("one", 20, 26),
        segment("two", 26, 29),
        segment("three", 32.5, 35.5),
      ],
    });

    const overrun = [
      {
        text: "one two",
        startSeconds: 0,
        segments: [segment(" one", 20, 26), segment(" two", 26, 32)],
      },
      {
        text: "three four",
        startSeconds: 29.5,
        segments: [segment(" three four", 0, 6)],
      },
    ];
    expect(
      mergeChunkTranscriptsWithSegments(overrun, ["anchor", "silence"])
        .segments,
    ).toEqual([]);
    expect(
      mergeChunkTranscriptsWithSegments(overrun, ["anchor", "anchor"])
        .segments,
    ).toEqual([
      segment("one", 20, 26),
      segment("two three four", 26, 35.5),
    ]);
  });

  test("still fails closed on an intra-chunk timestamp inversion", () => {
    const merged = mergeChunkTranscriptsWithSegments([
      {
        text: "alpha beta",
        startSeconds: 0,
        segments: [segment(" alpha", 1, 4), segment(" beta", 3, 5)],
      },
    ]);

    expect(merged.text).toBe("alpha beta");
    expect(merged.segments).toEqual([]);
  });

  test("concatenates a silence seam instead of folding the repeated word", () => {
    const chunks = [
      {
        text: "one two",
        startSeconds: 0,
        segments: [segment(" one", 20, 26), segment(" two", 26, 29)],
      },
      {
        text: "two three",
        startSeconds: 29.5,
        segments: [segment(" two", 0, 3), segment(" three", 3, 6)],
      },
    ];

    const silence = mergeChunkTranscriptsWithSegments(chunks, [
      "anchor",
      "silence",
    ]);
    expect(silence.text).toBe("one two two three");
    expect(silence.segments).toEqual([
      segment("one", 20, 26),
      segment("two", 26, 29),
      segment("two", 29.5, 32.5),
      segment("three", 32.5, 35.5),
    ]);

    const anchor = mergeChunkTranscriptsWithSegments(chunks, [
      "anchor",
      "anchor",
    ]);
    expect(anchor.text).toBe("one two three");
    expect(anchor.segments).toEqual([
      segment("one", 20, 26),
      segment("two", 26, 29),
      segment("three", 32.5, 35.5),
    ]);
  });

  test("fails closed when a silence-seam inversion sits outside the 0.5 s window", () => {
    const chunks = [
      {
        text: "one two",
        startSeconds: 0,
        // Overruns the chunk end so the next start falls 2.5 s inside this span:
        // inside the 5 s anchor window, outside the 0.5 s silence window.
        segments: [segment(" one", 20, 26), segment(" two", 26, 32)],
      },
      {
        text: "three four",
        startSeconds: 29.5,
        segments: [segment(" three four", 0, 6)],
      },
    ];

    const silence = mergeChunkTranscriptsWithSegments(chunks, [
      "anchor",
      "silence",
    ]);
    expect(silence.text).toBe("one two three four");
    expect(silence.segments).toEqual([]);

    const anchor = mergeChunkTranscriptsWithSegments(chunks, [
      "anchor",
      "anchor",
    ]);
    expect(anchor.text).toBe("one two three four");
    expect(anchor.segments).toEqual([
      segment("one", 20, 26),
      segment("two three four", 26, 35.5),
    ]);
  });

  test("keeps single-pass segment objects byte-identical", async () => {
    process.env[OUTRO_FLAG] = "1";
    delete process.env[BOUNDARIES_FLAG];
    const wavPath = join(TEST_TMP, "stt-segments-single-pass.wav");
    await Bun.write(wavPath, makePcm16Wav(5));
    const original = [
      segment(" alpha", 0.25, 1.5),
      segment(" beta", 2.25, 3.5),
    ];
    const before = JSON.stringify(original);
    const backend = new WhisperServerBackend({
      isServerAvailable: () => true,
      transcribeViaServer: async (_wav, options) => {
        options?.onSegments?.(original);
        return "alpha beta";
      },
    });

    const result = await backend.transcribe(wavPath);

    expect(JSON.stringify(result.segments)).toBe(before);
    expect(JSON.stringify(original)).toBe(before);
  });

  test("emits monotonic segments for 500 tiled random chunk groupings", () => {
    let seed = 12_345;
    const random = () =>
      ((seed = (seed * 1_103_515_245 + 12_345) & 0x7fffffff) /
        0x7fffffff);
    const word = (index: number) => `w${index}`;
    const buildChunk = (startSeconds: number) => {
      const words = Array.from(
        { length: Math.min(30, 140 - startSeconds) },
        (_, index) => startSeconds + index,
      );
      const segments: TranscriptSegment[] = [];
      for (let index = 0; index < words.length; ) {
        const count = 3 + Math.floor(random() * 7);
        const group = words.slice(index, index + count);
        segments.push(
          segment(
            ` ${group.map(word).join(" ")}`,
            group[0]! - startSeconds,
            group.at(-1)! + 1 - startSeconds,
          ),
        );
        index += count;
      }
      return {
        text: words.map(word).join(" "),
        startSeconds,
        segments,
      };
    };

    for (let trial = 0; trial < 500; trial++) {
      const chunks = [];
      for (let startSeconds = 0; startSeconds < 140; startSeconds += 25) {
        chunks.push(buildChunk(startSeconds));
        if (startSeconds + 30 >= 140) break;
      }
      const merged = mergeChunkTranscriptsWithSegments(chunks);
      expect(merged.text).toBe(
        Array.from({ length: 140 }, (_, index) => word(index)).join(" "),
      );
      expect(merged.segments.length).toBeGreaterThan(0);
      for (let index = 1; index < merged.segments.length; index++) {
        expect(merged.segments[index]!.startS).toBeGreaterThanOrEqual(
          merged.segments[index - 1]!.endS,
        );
      }
    }
  });

  test("replays every captured M1 segment stream through all real seams", () => {
    // The fixture retains the real verbose_json segment grouping and timing,
    // while replacing transcript tokens through an unrecorded random mapping.
    for (const recording of realChunkSegments.recordings) {
      for (const repetition of recording.repetitions) {
        const chunks = repetition.chunks;
        let seamPasses = 0;
        for (let index = 1; index < chunks.length; index++) {
          const pair = mergeChunkTranscriptsWithSegments(
            [chunks[index - 1]!, chunks[index]!],
            ["anchor", "anchor"],
          );
          if (pair.segments.length > 0) seamPasses += 1;
        }

        const merged = mergeChunkTranscriptsWithSegments(chunks);
        expect(seamPasses).toBe(repetition.expected.seamPasses);
        expect(merged.segments).toHaveLength(
          repetition.expected.endToEndSegments,
        );
        for (let index = 1; index < merged.segments.length; index++) {
          expect(merged.segments[index]!.startS).toBeGreaterThanOrEqual(
            merged.segments[index - 1]!.endS,
          );
        }
      }
    }
  });

  test("keeps the chunked escape hatch on json with no returned segments", async () => {
    process.env[OUTRO_FLAG] = "0";
    delete process.env[BOUNDARIES_FLAG];
    delete process.env[SMART_CHUNKS_FLAG];
    const wavPath = join(TEST_TMP, "stt-segments-chunked-off.wav");
    await Bun.write(wavPath, makePcm16Wav(100));
    const texts = [
      "alpha bridge",
      "bridge middle",
      "middle final",
      "final done",
    ];
    const requestedSegments: boolean[] = [];
    const backend = new WhisperServerBackend({
      isServerAvailable: () => true,
      transcribeViaServer: async (_wav, options) => {
        requestedSegments.push(Boolean(options?.onSegments));
        return texts.shift() ?? "";
      },
    });

    const result = await backend.transcribe(wavPath);

    expect(requestedSegments).toEqual([false, false, false, false]);
    expect(result.text).toBe("alpha bridge middle final done");
    expect(result.segments).toBeUndefined();
    expect(result.segmentsAudioSha256).toBeUndefined();
  });
});

const RECORDINGS = join(
  process.env.HOME ?? "",
  ".local/share/voicelayer/recordings/2026-09-07",
);

interface Specimen {
  id: string;
  chunks: Array<{ text: string; segments: TranscriptSegment[] }>;
  candidate: string;
  expectedSpan: { startS: number; endS: number };
  isTail: boolean;
}

const SPECIMENS: Specimen[] = [
  {
    id: "2026-09-07T11-56-34-618Z-e1f67576",
    chunks: [
      {
        text: "alpha bridge",
        segments: [segment(" alpha", 1, 2), segment(" bridge", 28, 29)],
      },
      {
        text: "bridge middle",
        segments: [segment(" bridge", 3, 4), segment(" middle", 28, 29)],
      },
      {
        text: "middle context",
        segments: [segment(" middle", 3, 4), segment(" context", 28, 29)],
      },
      {
        text: "context more",
        segments: [segment(" context", 3, 4), segment(" more", 28, 29)],
      },
      {
        text: "more finish.",
        segments: [segment(" more", 3, 4), segment(" finish.", 28, 29)],
      },
      {
        text: "finish. Thank you.",
        segments: [
          segment(" finish.", 3, 4),
          segment(" Thank you.", 13, 13.5),
        ],
      },
    ],
    candidate: "Thank you.",
    expectedSpan: { startS: 138, endS: 138.5 },
    isTail: true,
  },
  {
    id: "2026-09-07T07-52-38-511Z-08ce4329",
    chunks: [
      {
        text: "אחד גשר",
        segments: [segment(" אחד", 1, 2), segment(" גשר", 28, 29)],
      },
      {
        text: "גשר שתיים",
        segments: [segment(" גשר", 3, 4), segment(" שתיים", 28, 29)],
      },
      {
        text: "שתיים שלוש",
        segments: [segment(" שתיים", 3, 4), segment(" שלוש", 28, 29)],
      },
      {
        text: "שלוש ארבע.",
        segments: [segment(" שלוש", 3, 4), segment(" ארבע.", 28, 29)],
      },
      {
        text: "ארבע. תודה. חמש",
        segments: [
          segment(" ארבע.", 3, 4),
          segment(" תודה.", 7, 7.5),
          segment(" חמש", 28, 29),
        ],
      },
      {
        text: "חמש שש",
        segments: [segment(" חמש", 3, 4), segment(" שש", 28, 29)],
      },
      {
        text: "שש שבע",
        segments: [segment(" שש", 3, 4), segment(" שבע", 13, 14)],
      },
    ],
    candidate: "תודה.",
    expectedSpan: { startS: 107, endS: 107.5 },
    isTail: false,
  },
];

describe("archived long-recording gate input", () => {
  for (const specimen of SPECIMENS) {
    const wavPath = join(RECORDINGS, specimen.id, "audio.wav");
    const specimenTest = existsSync(wavPath) ? test : test.skip;

    specimenTest(`${specimen.id} supplies the gate an absolute candidate span`, async () => {
      process.env[OUTRO_FLAG] = "1";
      delete process.env[BOUNDARIES_FLAG];
      delete process.env[SMART_CHUNKS_FLAG];
      let call = 0;
      const gateLogs: string[] = [];
      const originalError = console.error;
      console.error = (...args: unknown[]) => {
        const line = args.map(String).join(" ");
        gateLogs.push(line);
        if (line.includes("outro gate: decision")) originalError(line);
      };
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_wav, options) => {
          const chunk = specimen.chunks[call++];
          if (!chunk) throw new Error(`unexpected decode call ${call}`);
          options?.onSegments?.(chunk.segments);
          return chunk.text;
        },
      });

      try {
        const result = await backend.transcribe(wavPath);
        expect(call).toBe(specimen.chunks.length);
        const rawText = mergeChunkTranscripts(
          specimen.chunks.map((chunk) => chunk.text),
        );
        const candidate = findOutroCandidates(rawText).find(
          (entry) => entry.phrase === specimen.candidate,
        );
        expect(candidate?.isTail).toBe(specimen.isTail);
        expect(result.segments).toBeDefined();
        expect(
          findCandidateSpan(result.segments ?? [], candidate!, rawText),
        ).toEqual(specimen.expectedSpan);
        const decisionLog = gateLogs.find((line) =>
          line.includes("outro gate: decision"),
        );
        expect(decisionLog).toContain(specimen.candidate);
        expect(decisionLog).toContain(
          `${specimen.expectedSpan.startS.toFixed(2)}-${specimen.expectedSpan.endS.toFixed(2)}s`,
        );
        expect(decisionLog).toMatch(
          /floor -?[\d.]+ dBFS, span -?[\d.]+, peak -?[\d.]+, speech -?[\d.]+/,
        );
      } finally {
        console.error = originalError;
      }
    });
  }
});
