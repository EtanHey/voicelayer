import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync } from "fs";
import { join } from "path";
import {
  GOLDEN_FIXTURE_PATH,
  loadSmartChunkGolden,
  type SmartChunkGolden,
} from "./smart-chunk-golden-fixture";
import { isSmartWavChunkingEnabled } from "../stt";
import {
  chooseChunkEnd,
  computePauseMap,
  MIN_PAUSE_SECONDS,
  parseWavAudioInfo,
  pauseSpansFromProbabilities,
  SMART_CHUNK_MAX_SECONDS,
  SMART_CHUNK_MIN_SECONDS,
  type PauseSpan,
} from "../stt-pause-map";

// Pause map + chunk-boundary policy for the ≥90 s saved-WAV decode path.
//
// Three layers, deliberately separated so the policy is testable without a
// model: the span/boundary maths is pure and always runs; the real Silero VAD
// runs against a `say`+`sox` fixture when those tools exist; the personal
// golden clip runs only when its gitignored fixture is present. Every skip is
// logged, never silent.
//
// AIDEV-NOTE: a tone/silence/tone WAV cannot test this. Silero is a SPEECH
// detector — a pure sine and a harmonic buzz both score below threshold, so a
// tone fixture reports the whole file as one pause and asserts nothing. The
// synthetic fixture is therefore real synthesized SPEECH with a silent gap.

const SAMPLE_RATE = 16000;
const VAD_FRAME_SECONDS = 512 / SAMPLE_RATE; // 0.032

function whichOk(bin: string): boolean {
  try {
    return Bun.spawnSync(["which", bin]).exitCode === 0;
  } catch {
    return false;
  }
}

function wavHeader(
  pcmBytes: number,
  {
    sampleRate = SAMPLE_RATE,
    channels = 1,
    bitsPerSample = 16,
  }: { sampleRate?: number; channels?: number; bitsPerSample?: number } = {},
): Uint8Array {
  const out = new Uint8Array(44 + pcmBytes);
  const view = new DataView(out.buffer);
  const ascii = (offset: number, text: string): void => {
    for (let i = 0; i < text.length; i++) {
      view.setUint8(offset + i, text.charCodeAt(i));
    }
  };
  const blockAlign = (channels * bitsPerSample) / 8;
  ascii(0, "RIFF");
  view.setUint32(4, 36 + pcmBytes, true);
  ascii(8, "WAVE");
  ascii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, bitsPerSample, true);
  ascii(36, "data");
  view.setUint32(40, pcmBytes, true);
  return out;
}

describe("pauseSpansFromProbabilities", () => {
  const S = 0.9; // speech
  const Q = 0.1; // quiet

  // frameIndex * frameSeconds is float arithmetic; compare at millisecond scale.
  const ms = (spans: PauseSpan[]): PauseSpan[] =>
    spans.map((span) => ({
      startS: Math.round(span.startS * 1000) / 1000,
      endS: Math.round(span.endS * 1000) / 1000,
    }));

  test("returns nothing for an empty sequence", () => {
    expect(ms(pauseSpansFromProbabilities([], 0.032))).toEqual([]);
  });

  test("returns nothing when every frame is speech", () => {
    expect(ms(pauseSpansFromProbabilities([S, S, S, S], 0.1))).toEqual([]);
  });

  test("drops a gap shorter than the minimum pause", () => {
    // 2 frames × 0.1 s = 0.2 s < 0.3 s floor.
    expect(ms(pauseSpansFromProbabilities([S, Q, Q, S], 0.1))).toEqual([]);
  });

  test("keeps a gap at exactly the minimum pause", () => {
    expect(ms(pauseSpansFromProbabilities([S, Q, Q, Q, S], 0.1))).toEqual([
      { startS: 0.1, endS: 0.4 },
    ]);
  });

  test("reports a leading silence run", () => {
    expect(ms(pauseSpansFromProbabilities([Q, Q, Q, Q, S], 0.1))).toEqual([
      { startS: 0, endS: 0.4 },
    ]);
  });

  test("reports a trailing silence run (the tail is a legal cut)", () => {
    expect(ms(pauseSpansFromProbabilities([S, S, Q, Q, Q, Q], 0.1))).toEqual([
      { startS: 0.2, endS: 0.6 },
    ]);
  });

  test("reports every qualifying run in order", () => {
    const spans = pauseSpansFromProbabilities(
      [S, Q, Q, Q, S, S, Q, S, Q, Q, Q, Q],
      0.1,
    );
    expect(ms(spans)).toEqual([
      { startS: 0.1, endS: 0.4 },
      { startS: 0.8, endS: 1.2 },
    ]);
  });

  test("honours a caller-supplied minimum", () => {
    expect(ms(pauseSpansFromProbabilities([S, Q, S], 0.1, 0.05))).toEqual([
      { startS: 0.1, endS: 0.2 },
    ]);
  });

  test("refuses a non-positive frame duration instead of dividing by it", () => {
    expect(ms(pauseSpansFromProbabilities([S, Q, Q, Q, S], 0))).toEqual([]);
  });

  test("splits on the 0.5 speech threshold, not on 0", () => {
    // 0.49 is silence, 0.5 is speech — matches isSpeech() in src/vad.ts.
    expect(
      ms(pauseSpansFromProbabilities([0.5, 0.49, 0.49, 0.49, 0.5], 0.1)),
    ).toEqual([{ startS: 0.1, endS: 0.4 }]);
  });
});

describe("chooseChunkEnd", () => {
  const window = { min: SMART_CHUNK_MIN_SECONDS, max: SMART_CHUNK_MAX_SECONDS };

  const cases: Array<{
    name: string;
    startS: number;
    pauses: PauseSpan[];
    expected: number;
  }> = [
    {
      name: "falls back to the fixed cut when there is no pause map at all",
      startS: 0,
      pauses: [],
      expected: 30,
    },
    {
      name: "ignores a pause that ends before the window opens",
      startS: 0,
      pauses: [{ startS: 18, endS: 19.5 }],
      expected: 30,
    },
    {
      name: "ignores a pause that ends after the window closes",
      startS: 0,
      pauses: [{ startS: 30.5, endS: 32 }],
      expected: 30,
    },
    {
      name: "cuts at the END of the pause, not its start",
      startS: 0,
      pauses: [{ startS: 22.5, endS: 24.25 }],
      expected: 24.25,
    },
    {
      name: "prefers the LAST pause in the window",
      startS: 0,
      pauses: [
        { startS: 21, endS: 22 },
        { startS: 26, endS: 27.5 },
        { startS: 28.9, endS: 29.4 },
      ],
      expected: 29.4,
    },
    {
      name: "accepts a pause ending exactly at the window floor",
      startS: 0,
      pauses: [{ startS: 19, endS: 20 }],
      expected: 20,
    },
    {
      name: "accepts a pause ending exactly at the window ceiling",
      startS: 0,
      pauses: [{ startS: 29, endS: 30 }],
      expected: 30,
    },
    {
      name: "works from a non-zero start offset",
      startS: 24.09,
      pauses: [
        { startS: 22.176, endS: 29.088 },
        { startS: 52.096, endS: 53.344 },
      ],
      expected: 53.344,
    },
    {
      name: "is unordered-input safe — takes the latest, not the last listed",
      startS: 0,
      pauses: [
        { startS: 28, endS: 29 },
        { startS: 21, endS: 22 },
      ],
      expected: 29,
    },
  ];

  for (const testCase of cases) {
    test(testCase.name, () => {
      expect(chooseChunkEnd(testCase.startS, testCase.pauses, window)).toBeCloseTo(
        testCase.expected,
        6,
      );
    });
  }

  test("falls back when the window is empty or inverted", () => {
    const pauses = [{ startS: 21, endS: 22 }];
    expect(chooseChunkEnd(0, pauses, { min: 30, max: 30 })).toBe(30);
    expect(chooseChunkEnd(0, pauses, { min: 31, max: 30 })).toBe(30);
  });

  test("defaults to the 20-30 s window", () => {
    expect(chooseChunkEnd(0, [])).toBe(SMART_CHUNK_MAX_SECONDS);
    expect(chooseChunkEnd(0, [{ startS: 24, endS: 25 }])).toBe(25);
  });

  test("never returns a boundary outside the window", () => {
    const pauses: PauseSpan[] = [];
    for (let s = 0; s < 120; s += 3.7) pauses.push({ startS: s, endS: s + 0.4 });
    for (let start = 0; start < 90; start += 7) {
      const end = chooseChunkEnd(start, pauses, window);
      expect(end).toBeGreaterThanOrEqual(start + window.min);
      expect(end).toBeLessThanOrEqual(start + window.max);
    }
  });
});

describe("isSmartWavChunkingEnabled", () => {
  // Default OFF is the contract of this PR: with the flag unset the saved-WAV
  // decode is byte-for-byte the shipped fixed-30 s one.
  test("is off when unset, empty, or anything but an opt-in", () => {
    for (const value of [undefined, "", "  ", "0", "off", "no", "false", "maybe"]) {
      expect(isSmartWavChunkingEnabled({ VOICELAYER_STT_SMART_CHUNKS: value })).toBe(
        false,
      );
    }
    expect(isSmartWavChunkingEnabled({})).toBe(false);
  });

  test("accepts the same opt-in spellings as QA_VOICE_CHUNKED_STT", () => {
    for (const value of ["1", "true", "yes", "on", " ON ", "True"]) {
      expect(isSmartWavChunkingEnabled({ VOICELAYER_STT_SMART_CHUNKS: value })).toBe(
        true,
      );
    }
  });
});

describe("parseWavAudioInfo", () => {
  test("reads a 16 kHz mono 16-bit header", () => {
    expect(parseWavAudioInfo(wavHeader(320))).toEqual({
      sampleRate: 16000,
      channels: 1,
      bitsPerSample: 16,
      dataOffset: 44,
      dataSize: 320,
    });
  });

  test("rejects a buffer that is not RIFF/WAVE", () => {
    expect(parseWavAudioInfo(new Uint8Array(64))).toBeNull();
  });

  test("rejects a truncated buffer", () => {
    expect(parseWavAudioInfo(new Uint8Array(10))).toBeNull();
  });
});

describe("computePauseMap format guard", () => {
  // Fails loudly rather than returning [] — an empty map would read as
  // "no pauses anywhere", and the caller would then cut blind on the clock.
  test("rejects a sample rate the VAD was not trained for", async () => {
    const wav = wavHeader(320, { sampleRate: 8000 });
    await expect(computePauseMap(wav)).rejects.toThrow(/16 kHz mono/);
  });

  test("rejects stereo", async () => {
    const wav = wavHeader(640, { channels: 2 });
    await expect(computePauseMap(wav)).rejects.toThrow(/16 kHz mono/);
  });

  test("rejects a non-WAV buffer", async () => {
    await expect(computePauseMap(new Uint8Array(64))).rejects.toThrow(
      /readable PCM WAV/,
    );
  });
});

// --- Live Silero VAD over a synthesized speech / silence / speech WAV ---

const FIXTURE_DIR = join(import.meta.dir, "../../docs.local/test-fixtures/pause-map");
const SYNTH_WAV = join(FIXTURE_DIR, "speech-silence-speech.wav");
const SYNTH_GAP_SECONDS = 1.2;
const hasSay = whichOk("say");
const hasSox = whichOk("sox");
const synthReady = hasSay && hasSox;

if (!synthReady) {
  console.error(
    `[pause-map] SKIPPING synthetic-WAV VAD test — missing: ${[
      hasSay ? null : "say",
      hasSox ? null : "sox",
    ]
      .filter(Boolean)
      .join(", ")}. The pure span/boundary tests above still run.`,
  );
}

function buildSynthFixture(): void {
  if (existsSync(SYNTH_WAV)) return;
  mkdirSync(FIXTURE_DIR, { recursive: true });
  const run = (cmd: string[]): void => {
    const proc = Bun.spawnSync(cmd, { cwd: FIXTURE_DIR });
    if (proc.exitCode !== 0) {
      throw new Error(
        `${cmd.join(" ")} failed: ${new TextDecoder().decode(proc.stderr)}`,
      );
    }
  };
  run(["say", "-o", "a.aiff", "The morning train left the station a few minutes behind schedule."]);
  run(["say", "-o", "b.aiff", "She poured the coffee slowly and watched the steam rise."]);
  run(["sox", "a.aiff", "-r", "16000", "-c", "1", "-b", "16", "a.wav"]);
  run(["sox", "b.aiff", "-r", "16000", "-c", "1", "-b", "16", "b.wav"]);
  run([
    "sox", "-n", "-r", "16000", "-c", "1", "-b", "16", "gap.wav",
    "trim", "0.0", String(SYNTH_GAP_SECONDS),
  ]);
  run([
    "sox", "a.wav", "gap.wav", "b.wav",
    "-r", "16000", "-c", "1", "-b", "16", SYNTH_WAV,
  ]);
}

const synthTest = synthReady ? test : test.skip;

describe("computePauseMap over synthesized speech", () => {
  synthTest(
    "finds the inserted gap and nothing else",
    async () => {
      buildSynthFixture();
      const wav = new Uint8Array(readFileSync(SYNTH_WAV));
      const info = parseWavAudioInfo(wav);
      expect(info?.sampleRate).toBe(16000);
      const totalSeconds = (info?.dataSize ?? 0) / (16000 * 2);

      const spans = await computePauseMap(wav);
      expect(spans.length).toBe(1);

      const gap = spans[0];
      // The gap is 1.2 s of true digital silence; the VAD's decay adds at most a
      // couple of frames either side, so allow a frame-scale tolerance.
      expect(gap.endS - gap.startS).toBeGreaterThanOrEqual(
        SYNTH_GAP_SECONDS - 8 * VAD_FRAME_SECONDS,
      );
      expect(gap.endS - gap.startS).toBeLessThanOrEqual(
        SYNTH_GAP_SECONDS + 8 * VAD_FRAME_SECONDS,
      );
      // It is in the middle, with speech on both sides.
      expect(gap.startS).toBeGreaterThan(1);
      expect(gap.endS).toBeLessThan(totalSeconds - 1);
      for (const span of spans) expect(span.endS).toBeGreaterThan(span.startS);
    },
    120_000,
  );

  synthTest(
    "a sub-minimum gap is not a pause",
    async () => {
      buildSynthFixture();
      const wav = new Uint8Array(readFileSync(SYNTH_WAV));
      // Raise the floor above the inserted gap: the same audio now has no cut point.
      const spans = await computePauseMap(wav, {
        minPauseSeconds: SYNTH_GAP_SECONDS + 1,
      });
      expect(spans).toEqual([]);
    },
    120_000,
  );

  synthTest(
    "chooseChunkEnd falls back to the clock when the only pause is outside the window",
    async () => {
      buildSynthFixture();
      const spans = await computePauseMap(new Uint8Array(readFileSync(SYNTH_WAV)));
      // The fixture is ~7.6 s long, so its single pause is far below a 20 s floor.
      expect(chooseChunkEnd(0, spans)).toBe(SMART_CHUNK_MAX_SECONDS);
    },
    120_000,
  );

  test("the minimum-pause constant is the documented 300 ms", () => {
    expect(MIN_PAUSE_SECONDS).toBe(0.3);
  });
});

// --- The golden clip: a real 109 s recording that the fixed 30 s cut damages ---
//
// The fixture is GITIGNORED on purpose. Its anchors are Etan's own speech and
// this repo is public (AGENTS.md: "whatever ships publicly from here gets a
// private-data pass first"), so only the loader lives in git. Build
// `docs.local/goldens/smart-chunking-clip-b.json` from
// `docs.local/recon-2026-09-05/m2-repro/B/` to enable this block.

const golden = loadSmartChunkGolden();
if (!golden) {
  console.error(
    `[pause-map] SKIPPING golden-clip pause map — no fixture at ${GOLDEN_FIXTURE_PATH} ` +
      "(or its WAV is missing). This is expected in CI: the fixture is gitignored.",
  );
}
const goldenTest = golden ? test : test.skip;

/** The fixed schedule today: 30 s chunks stepping 25 s (30 − 5 s overlap). */
function fixedChunkEnds(durationSeconds: number): number[] {
  const ends: number[] = [];
  for (let start = 0; start < durationSeconds; start += 25) {
    ends.push(Math.min(start + 30, durationSeconds));
    if (start + 30 >= durationSeconds) break;
  }
  return ends;
}

function smartChunkEnds(
  durationSeconds: number,
  pauseMap: PauseSpan[],
): number[] {
  const ends: number[] = [];
  let start = 0;
  while (start < durationSeconds) {
    const end = Math.min(
      chooseChunkEnd(start, pauseMap, {
        min: SMART_CHUNK_MIN_SECONDS,
        max: SMART_CHUNK_MAX_SECONDS,
      }),
      durationSeconds,
    );
    ends.push(end);
    if (end >= durationSeconds) break;
    start = end - 5;
  }
  return ends;
}

function insidePause(seconds: number, pauseMap: PauseSpan[]): boolean {
  return pauseMap.some(
    (span) => seconds >= span.startS && seconds <= span.endS,
  );
}

describe("computePauseMap over golden clip B", () => {
  goldenTest(
    "finds the pauses in a real 109 s recording",
    async () => {
      const fixture = golden as SmartChunkGolden;
      const wav = new Uint8Array(readFileSync(fixture.wav));
      const info = parseWavAudioInfo(wav);
      expect(info).not.toBeNull();
      expect(info?.sampleRate).toBe(16000);
      expect(info?.channels).toBe(1);

      const pauseMap = await computePauseMap(wav);
      expect(pauseMap.length).toBeGreaterThanOrEqual(fixture.minPauses);
      for (const span of pauseMap) {
        expect(span.endS - span.startS).toBeGreaterThanOrEqual(
          MIN_PAUSE_SECONDS - 1e-9,
        );
        expect(span.endS).toBeLessThanOrEqual(fixture.durationSeconds + 0.05);
      }
      // Spans are disjoint and ordered — a boundary can never be in two of them.
      for (let i = 1; i < pauseMap.length; i++) {
        expect(pauseMap[i].startS).toBeGreaterThan(pauseMap[i - 1].endS);
      }
    },
    120_000,
  );

  goldenTest(
    "every smart boundary lands in silence; the fixed 30 s schedule does not",
    async () => {
      const fixture = golden as SmartChunkGolden;
      const pauseMap = await computePauseMap(
        new Uint8Array(readFileSync(fixture.wav)),
      );

      // AIDEV-NOTE: "not inside a word" is measured here as "inside a VAD
      // non-speech span", not by forced alignment. That is the same signal the
      // LIVE path already cuts on (evaluateChunkBoundary, src/vad.ts) — it is
      // the property this module can actually guarantee, and the claim is
      // deliberately not stronger than the evidence.
      const smart = smartChunkEnds(fixture.durationSeconds, pauseMap);
      const interiorSmart = smart.filter((end) => end < fixture.durationSeconds);
      expect(interiorSmart.length).toBeGreaterThan(0);
      for (const end of interiorSmart) {
        expect({ end, inSilence: insidePause(end, pauseMap) }).toEqual({
          end,
          inSilence: true,
        });
      }

      // This is the damage the lane exists to remove: today's clock-driven
      // boundaries cut mid-speech on this very clip.
      const fixed = fixedChunkEnds(fixture.durationSeconds).filter(
        (end) => end < fixture.durationSeconds,
      );
      const fixedInSpeech = fixed.filter((end) => !insidePause(end, pauseMap));
      expect(fixedInSpeech.length).toBeGreaterThan(0);
    },
    120_000,
  );
});
