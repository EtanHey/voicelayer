import { describe, expect, test } from "bun:test";
import { stripHallucinatedOutro } from "../stt-outro-gate";
import type { TranscriptSegment } from "../stt-sentence-boundaries";

// Generated PCM only: no recordings, decoder calls, microphone or TTS.
const RATE = 16000;
const TEXT = "Show an example. Okay.";
const segments = (startS: number, endS = 4): TranscriptSegment[] => [
  { text: "Show an example.", startS: 0, endS: 2.9 },
  { text: "Okay.", startS, endS },
];

interface Fixture {
  clickS?: number;
  clickLengthS?: number;
  voicedClick?: boolean;
  softOnset?: boolean;
  quietOkay?: boolean;
  speechThroughClick?: boolean;
  pitchHz?: number;
  decayS?: number;
  noClick?: boolean;
}

function wavFixture(options: Fixture = {}): Uint8Array {
  const frames = RATE * 4;
  const wav = new Uint8Array(44 + frames * 2);
  const view = new DataView(wav.buffer);
  const ascii = (offset: number, text: string) => {
    for (let i = 0; i < text.length; i++) wav[offset + i] = text.charCodeAt(i);
  };
  ascii(0, "RIFF"); view.setUint32(4, wav.length - 8, true);
  ascii(8, "WAVE"); ascii(12, "fmt "); view.setUint32(16, 16, true);
  view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, RATE, true); view.setUint32(28, RATE * 2, true);
  view.setUint16(32, 2, true); view.setUint16(34, 16, true);
  ascii(36, "data"); view.setUint32(40, frames * 2, true);
  let seed = 42;
  const noise = () => {
    seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0;
    return 2 * seed / 0xffffffff - 1;
  };
  for (let i = 0; i < frames; i++) {
    const t = i / RATE;
    let sample = 25 * noise();
    // Periodic voiced energy, including harmonics, rather than a noise burst.
    const voiced = Math.sin(2 * Math.PI * (options.pitchHz ?? 180) * t) + 0.3 * Math.sin(4 * Math.PI * (options.pitchHz ?? 180) * t);
    if (t < 2.9 || (options.speechThroughClick && t > 3.2)) sample += 2500 * voiced;
    if (options.quietOkay && t >= 3.3 && t < 3.6) sample += 180 * voiced;
    const elapsed = t - (options.clickS ?? 3.75);
    if (!options.noClick && elapsed >= 0 && elapsed < (options.clickLengthS ?? 0.06)) {
      const onset = options.softOnset ? Math.min(1, elapsed / 0.025) : 1;
      const carrier = options.voicedClick ? voiced : noise();
      sample += 9000 * onset * Math.exp(-elapsed / (options.decayS ?? 0.018)) * carrier;
    }
    view.setInt16(44 + i * 2, Math.max(-32768, Math.min(32767, Math.round(sample))), true);
  }
  return wav;
}

describe("outro gate — push-to-end stop click evidence", () => {
  for (const [name, start, end] of [
    ["covering the click", 3.3, 4],
    ["before the click (clearance)", 3.4, 3.7],
    ["after the click (clearance)", 3.83, 4],
  ] as const) {
    test(`drops an invented closer ${name}`, () => {
      const decision = stripHallucinatedOutro(TEXT, wavFixture(), { segments: segments(start, end) });
      expect(decision.text).toBe("Show an example.");
      expect(decision.reason).toBe("removed");
      expect(decision.removed.map(r => r.phrase)).toEqual(["Okay."]);
    });
  }

  test("keeps a genuinely voiced quiet okay followed by the stop click", () => {
    const decision = stripHallucinatedOutro(TEXT, wavFixture({ quietOkay: true }), { segments: segments(3.3) });
    expect(decision.text).toBe(TEXT);
    expect(decision.removed).toEqual([]);
  });

  test("keeps a short decaying voiced syllable at the stop offset", () => {
    const decision = stripHallucinatedOutro(TEXT, wavFixture({ voicedClick: true }), { segments: segments(3.3) });
    expect(decision.text).toBe(TEXT);
    expect(decision.removed).toEqual([]);
  });

  for (const pitchHz of [60, 90, 300, 450]) {
    test(`keeps a short voiced syllable at ${pitchHz} Hz`, () => {
      expect(stripHallucinatedOutro(TEXT, wavFixture({ voicedClick: true, pitchHz }), { segments: segments(3.3) }).text).toBe(TEXT);
    });
  }

  test("keeps a longer aperiodic event", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture({ clickLengthS: 0.15, decayS: 0.05 }), { segments: segments(3.3) }).text).toBe(TEXT);
  });

  test("without an impulse the original silent-tail rule still applies", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture({ noClick: true }), { segments: segments(3.3) }).text).toBe("Show an example.");
  });

  test("keeps quiet voiced okay when its attribution drifts into the click", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture({ quietOkay: true }), { segments: segments(3.73) }).text).toBe(TEXT);
  });

  test("does not apply the exception to an internal candidate at the stop offset", () => {
    const text = `${TEXT} Continue.`;
    expect(stripHallucinatedOutro(text, wavFixture(), { segments: [
      ...segments(3.3, 3.9), { text: "Continue.", startS: 3.9, endS: 4 },
    ] }).text).toBe(text);
  });

  test("keeps an uncertain soft-onset event", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture({ softOnset: true }), { segments: segments(3.3) }).text).toBe(TEXT);
  });

  test("keeps speech overlapping a click", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture({ speechThroughClick: true }), { segments: segments(3.3) }).text).toBe(TEXT);
  });

  test("does not exempt an internal click", () => {
    const text = "Show an example. Okay. Continue speaking.";
    const decision = stripHallucinatedOutro(text, wavFixture({ clickS: 3.3 }), {
      segments: [
        { text: "Show an example.", startS: 0, endS: 2.9 },
        { text: "Okay.", startS: 3.3, endS: 3.4 },
        { text: "Continue speaking.", startS: 3.5, endS: 4 },
      ],
    });
    expect(decision.text).toBe(text);
    expect(decision.reason).toBe("energy-present");
  });

  test("does not exempt a click at an unrelated tail offset", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture({ clickS: 3.5 }), { segments: segments(3.3) }).text).toBe(TEXT);
  });

  test("keeps a merged segment that also covers genuine speech", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture(), {
      segments: [{ text: TEXT, startS: 2.5, endS: 4 }],
    }).text).toBe(TEXT);
  });

  for (const closer of ["okay?", "fu…", "okay…", "okay, no, thank you."]) {
    test(`preserves ${closer}`, () => {
      const text = `Show an example. ${closer}`;
      const spans = segments(3.3); spans[1]!.text = closer;
      expect(stripHallucinatedOutro(text, wavFixture(), { segments: spans }).text).toBe(text);
    });
  }

  test("does not enable a no-segments fallback", () => {
    expect(stripHallucinatedOutro(TEXT, wavFixture()).text).toBe(TEXT);
    expect(stripHallucinatedOutro(TEXT, wavFixture(), { segments: segments(3.3), segmentsMatchAudio: false }).text).toBe(TEXT);
    expect(stripHallucinatedOutro(TEXT, wavFixture(), { segments: segments(3.3), segmentsText: "Other text." }).text).toBe(TEXT);
  });
});
