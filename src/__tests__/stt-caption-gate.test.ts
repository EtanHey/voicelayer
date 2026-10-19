import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { stripHallucinatedCaption } from "../stt-caption-gate";
import { WhisperServerBackend } from "../stt";
import type { TranscriptSegment } from "../stt-transcript-alignment";

function silentWav(seconds: number): Uint8Array {
  const frames = Math.round(seconds * 16_000);
  const wav = new Uint8Array(44 + frames * 2);
  const view = new DataView(wav.buffer);
  for (const [offset, value] of [[0, "RIFF"], [8, "WAVE"], [12, "fmt "], [36, "data"]] as const) {
    for (let i = 0; i < value.length; i++) wav[offset + i] = value.charCodeAt(i);
  }
  view.setUint32(4, 36 + frames * 2, true);
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, 16_000, true);
  view.setUint32(28, 32_000, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  view.setUint32(40, frames * 2, true);
  return wav;
}

function softSpeechWav(): Uint8Array {
  const wav = silentWav(2.5);
  const view = new DataView(wav.buffer);
  for (let frame = Math.round(1.5 * 16_000); frame < Math.round(2.5 * 16_000); frame++) {
    view.setInt16(44 + frame * 2, Math.round(30 * Math.sin(frame * 2 * Math.PI * 220 / 16_000)), true);
  }
  return wav;
}

const text = 'Ship it. - The American Pronunciation Guide Presents "How to Pronounce';
const segments: TranscriptSegment[] = [
  { text: "Ship it.", startS: 0, endS: 1 },
  { text: " - The American Pronunciation Guide Presents", startS: 1.5, endS: 2.1 },
  { text: ' "How to Pronounce', startS: 2.1, endS: 2.6 },
];

function probabilities(speech = false): number[] {
  const values = Array(78).fill(0.01) as number[];
  if (speech) values.fill(0.95, 47, 72);
  return values;
}

describe("caption hallucination gate", () => {
  test("removes an unpunctuated leading-dash caption only over VAD non-speech", async () => {
    const result = await stripHallucinatedCaption(text, silentWav(2.5), {
      segments,
      segmentsText: text,
      speechProbabilities: probabilities(),
    });
    expect(result.text).toBe("Ship it.");
    expect(result.removed?.class).toBe("american-pronunciation-guide");
  });

  test("keeps the same words when Silero marks sustained speech", async () => {
    const result = await stripHallucinatedCaption(text, silentWav(2.5), {
      segments,
      segmentsText: text,
      speechProbabilities: probabilities(true),
    });
    expect(result.text).toBe(text);
    expect(result.removed).toBeNull();
  });

  test("keeps very soft audio even if VAD misses the spoken phrase", async () => {
    const result = await stripHallucinatedCaption(text, softSpeechWav(), {
      segments, segmentsText: text, speechProbabilities: probabilities(),
    });
    expect(result.text).toBe(text);
    const flatAudio = softSpeechWav(), view = new DataView(flatAudio.buffer);
    for (let frame = 0; frame < 1.5 * 16_000; frame++) view.setInt16(44 + frame * 2, Math.round(30 * Math.sin(frame * 2 * Math.PI * 220 / 16_000)), true);
    const withEarlierSpeech = probabilities();
    withEarlierSpeech.fill(0.95, 0, 31);
    const flat = await stripHallucinatedCaption(text, flatAudio, { segments, segmentsText: text, speechProbabilities: withEarlierSpeech });
    expect(flat.text).toBe(text);
  });

  test("tolerates only the single 32 ms VAD blip seen under the pinned caption", async () => {
    const oneBlip = probabilities();
    oneBlip[47] = 0.79;
    const removed = await stripHallucinatedCaption(text, silentWav(2.5), {
      segments, segmentsText: text, speechProbabilities: oneBlip,
    });
    expect(removed.text).toBe("Ship it.");
    const twoBlips = [...oneBlip];
    twoBlips[48] = 0.79;
    const kept = await stripHallucinatedCaption(text, silentWav(2.5), {
      segments, segmentsText: text, speechProbabilities: twoBlips,
    });
    expect(kept.text).toBe(text);
  });

  test("independent fresh-state speech vetoes a continuous-state miss", async () => {
    const fresh = probabilities();
    fresh.fill(0.9, 50, 57);
    const result = await stripHallucinatedCaption(text, silentWav(2.5), {
      segments, segmentsText: text,
      speechProbabilities: probabilities(), freshSpeechProbabilities: fresh,
    });
    expect(result.text).toBe(text);
  });

  test("a real clause after a complete caption key is never swept into its run", async () => {
    const spoken = "Ship it. Thanks for watching, see you tomorrow";
    const result = await stripHallucinatedCaption(spoken, silentWav(2.5), {
      segments: [segments[0]!, { text: " Thanks for watching, see you tomorrow", startS: 1.5, endS: 2.2 }],
      segmentsText: spoken, speechProbabilities: probabilities(),
    });
    expect(result.text).toBe(spoken);
    expect(result.reason).toBe("no-candidate");
  });

  test("retains the pinned American-guide continuation boundary", async () => {
    const caption = "The American Pronunciation Guide Presents How to Pronounce Example in English";
    const candidate = `Ship it. ${caption}`;
    const result = await stripHallucinatedCaption(candidate, silentWav(2.5), {
      segments: [segments[0]!, { text: ` ${caption}`, startS: 1.5, endS: 2.2 }],
      segmentsText: candidate, speechProbabilities: probabilities(),
    });
    expect(result.text).toBe("Ship it.");
  });

  test.each([
    ["How to Pronounce this", "how-to-pronounce"],
    ["Subtitles by the Amara.org community", "amara-subtitles"],
    ["Thanks for watching", "thanks-for-watching"],
    ["Please subscribe", "please-subscribe"],
    ["Transcribed by a volunteer", "transcribed-by"],
    ["Subtitles by rev.com", "rev-subtitles"],
  ])("recognizes the complete trailing caption class %s", async (phrase, expectedClass) => {
    const candidate = `Ship it. - ${phrase}`;
    const result = await stripHallucinatedCaption(candidate, silentWav(2.5), {
      segments: [segments[0]!, { text: ` - ${phrase}`, startS: 1.5, endS: 2.2 }],
      segmentsText: candidate,
      speechProbabilities: probabilities(),
    });
    expect(result.text).toBe("Ship it.");
    expect(result.removed?.class).toBe(expectedClass);
  });

  test("keeps a mid-transcript occurrence over speech", async () => {
    const spoken = "How to Pronounce. Start now.";
    const result = await stripHallucinatedCaption(spoken, silentWav(2.5), {
      segments: [
        { text: "How to Pronounce.", startS: 0.2, endS: 0.8 },
        { text: "Start now.", startS: 1.2, endS: 1.8 },
      ],
      segmentsText: spoken,
      speechProbabilities: Array(78).fill(0.95),
    });
    expect(result.text).toBe(spoken);
    expect(result.removed).toBeNull();
  });

  test("never cuts a caption phrase out of the middle of a segment", async () => {
    const combined = text.replace("Ship it. - ", "Ship it. ");
    const result = await stripHallucinatedCaption(combined, silentWav(2.5), {
      segments: [{ text: combined, startS: 0, endS: 2.5 }],
      segmentsText: combined,
      speechProbabilities: probabilities(),
    });
    expect(result.text).toBe(combined);
  });

  test("keeps a caption-class phrase at the start of the recording", async () => {
    const spoken = "How to Pronounce";
    const result = await stripHallucinatedCaption(spoken, silentWav(1), {
      segments: [{ text: spoken, startS: 0, endS: 0.7 }],
      segmentsText: spoken,
      speechProbabilities: Array(31).fill(0.01),
    });
    expect(result.text).toBe(spoken);
  });

  test("keeps a caption whose claimed timestamp exceeds the bounded WAV overrun", async () => {
    const stretched = [segments[0]!, segments[1]!, { ...segments[2]!, endS: 8 }];
    const result = await stripHallucinatedCaption(text, silentWav(2.5), {
      segments: stretched, segmentsText: text, speechProbabilities: probabilities(),
    });
    expect(result.text).toBe(text);
  });

  test("stays inert without aligned segment timestamps", async () => {
    for (const options of [
      { speechProbabilities: probabilities() },
      { segments, segmentsText: "Different decode", speechProbabilities: probabilities() },
    ]) {
      const result = await stripHallucinatedCaption(text, silentWav(2.5), options);
      expect(result.text).toBe(text);
      expect(result.removed).toBeNull();
    }
  });

  test("the backend reports a removed caption without logging its text", async () => {
    const directory = mkdtempSync(join(tmpdir(), "voicelayer-caption-"));
    const audioPath = join(directory, "synthetic.wav");
    writeFileSync(audioPath, silentWav(2.5));
    const logs: string[] = [];
    const originalError = console.error;
    console.error = (...values: unknown[]) => logs.push(values.map(String).join(" "));
    try {
      const backend = new WhisperServerBackend({
        isServerAvailable: () => true,
        transcribeViaServer: async (_audio, options) => {
          options?.onSegments?.(segments);
          return text;
        },
      });
      const result = await backend.transcribe(audioPath);
      expect(result.text).toBe("Ship it.");
      expect(result.backend).toContain("+caption");
      expect(logs.some((line) => line.includes("caption gate: dropped class american-pronunciation-guide"))).toBe(true);
      expect(logs.some((line) => line.includes("American Pronunciation Guide Presents"))).toBe(false);
    } finally {
      console.error = originalError;
      rmSync(directory, { recursive: true, force: true });
    }
  });
});

/** `fill(frame)` sets each sample; the rest of the header matches `silentWav`. */
function filledWav(seconds: number, fill: (frame: number) => number): Uint8Array {
  const wav = silentWav(seconds);
  const view = new DataView(wav.buffer);
  for (let frame = 0; frame < Math.round(seconds * 16_000); frame++) {
    view.setInt16(44 + frame * 2, fill(frame), true);
  }
  return wav;
}

function quiet(seconds: number): number[] {
  return Array(Math.floor(seconds * 16_000 / 512)).fill(0.01) as number[];
}

describe("HALLU1: caption tail over silence or a dead device", () => {
  test("removes 'Transcription by CastingWords' over non-speech", async () => {
    const tail = "Ship it. Transcription by CastingWords";
    const result = await stripHallucinatedCaption(tail, silentWav(4), {
      segments: [
        { text: "Ship it.", startS: 0, endS: 1 },
        { text: " Transcription by CastingWords", startS: 2, endS: 3.5 },
      ],
      segmentsText: tail,
      speechProbabilities: quiet(4),
    });
    expect(result.text).toBe("Ship it.");
    expect(result.removed?.class).toBe("castingwords");
  });

  test("a stray boundary 'You' glued to the caption goes with it", async () => {
    for (const segments of [
      [{ text: "Ship it.", startS: 0, endS: 1 }, { text: " You", startS: 2, endS: 2.6 },
        { text: " Transcription by CastingWords.", startS: 2.6, endS: 3.5 }],
      [{ text: "Ship it.", startS: 0, endS: 1 },
        { text: " You Transcription by CastingWords.", startS: 2, endS: 3.5 }],
    ]) {
      const tail = segments.map((segment) => segment.text).join("");
      const result = await stripHallucinatedCaption(tail, silentWav(4), {
        segments, segmentsText: tail, speechProbabilities: quiet(4),
      });
      expect(result.text).toBe("Ship it.");
      expect(result.removed?.class).toBe("castingwords");
    }
  });

  test("removes a lone unpunctuated boundary 'you' over non-speech, keeps it over speech", async () => {
    const tail = "there's no further action needed you";
    const segments = [
      { text: "there's no further action needed", startS: 0, endS: 1 },
      { text: " you", startS: 2, endS: 3 },
    ];
    const removed = await stripHallucinatedCaption(tail, silentWav(4), {
      segments, segmentsText: tail, speechProbabilities: quiet(4),
    });
    expect(removed.text).toBe("there's no further action needed");
    expect(removed.removed?.class).toBe("stray-you");
    const spoken = quiet(4);
    spoken.fill(0.95, 63, 90);
    const kept = await stripHallucinatedCaption(tail, silentWav(4), {
      segments, segmentsText: tail, speechProbabilities: spoken,
    });
    expect(kept.text).toBe(tail);
  });

  test("'you' that ends a spoken segment is never a boundary 'you'", async () => {
    const tail = "Ship it. Thank you";
    const result = await stripHallucinatedCaption(tail, silentWav(4), {
      segments: [{ text: "Ship it.", startS: 0, endS: 1 }, { text: " Thank you", startS: 2, endS: 3 }],
      segmentsText: tail,
      speechProbabilities: quiet(4),
    });
    expect(result.text).toBe(tail);
  });

  test("removes a generic 'Subtitles by …' credit over non-speech", async () => {
    const tail = "Ship it. Subtitles by the community";
    const result = await stripHallucinatedCaption(tail, silentWav(4), {
      segments: [{ text: "Ship it.", startS: 0, endS: 1 }, { text: " Subtitles by the community", startS: 2, endS: 3.5 }],
      segmentsText: tail,
      speechProbabilities: quiet(4),
    });
    expect(result.text).toBe("Ship it.");
    expect(result.removed?.class).toBe("subtitles-by");
  });

  // Speech, then a microphone that died: the device keeps delivering samples
  // in {-1, 0, 1}. Whisper attributes its caption to a long stretch of that.
  const longTail = "Ship it. You Transcription by CastingWords.";
  const longSegments = [
    { text: "Ship it.", startS: 0, endS: 1 },
    { text: " You", startS: 2, endS: 4 },
    { text: " Transcription by CastingWords.", startS: 4, endS: 20 },
  ];
  test("a caption spread over a dead-device span longer than 8 s is removable", async () => {
    const dead = filledWav(21, (frame) => (frame % 3) - 1);
    const result = await stripHallucinatedCaption(longTail, dead, {
      segments: longSegments, segmentsText: longTail, speechProbabilities: quiet(21),
    });
    expect(result.text).toBe("Ship it.");
    expect(result.removed?.class).toBe("castingwords");
  });

  test("the same long span over a live room floor keeps the 8 s bound", async () => {
    let seed = 11;
    const room = filledWav(21, () => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return Math.round((seed / 0x7fffffff * 2 - 1) * 20);
    });
    const result = await stripHallucinatedCaption(longTail, room, {
      segments: longSegments, segmentsText: longTail, speechProbabilities: quiet(21),
    });
    expect(result.text).toBe(longTail);
    expect(result.removed).toBeNull();
  });
});

describe("HALLU1: recordings just over one 30 s Whisper window", () => {
  // Loud deterministic noise stands in for speech energy; Silero evidence is injected.
  function shaped(seconds: number, speech: Array<[number, number]>): Uint8Array {
    let seed = 5;
    return filledWav(seconds, (frame) => {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      const t = frame / 16_000;
      const amp = speech.some(([a, b]) => t >= a && t < b) ? 3000 : 20;
      return Math.round((seed / 0x7fffffff * 2 - 1) * amp);
    });
  }
  function vad(seconds: number, speech: Array<[number, number]>): number[] {
    return quiet(seconds).map((_, i) =>
      speech.some(([a, b]) => (i * 512) / 16_000 >= a && (i * 512) / 16_000 < b) ? 0.95 : 0.01);
  }

  test("speech, a 12 s mid gap, speech to 31.3 s: every real segment is kept", async () => {
    const speech: Array<[number, number]> = [[0.5, 9.5], [21.5, 31.2]];
    const segments = [
      { text: "first spoken part", startS: 0.5, endS: 9.5 },
      { text: " second spoken part thanks for watching", startS: 21.5, endS: 31.2 },
    ];
    const text = segments.map((segment) => segment.text).join("");
    const result = await stripHallucinatedCaption(text, shaped(31.3, speech), {
      segments, segmentsText: text, speechProbabilities: vad(31.3, speech),
    });
    expect(result.text).toBe(text);
  });

  test("speech to 31.3 s with no gap: a spoken caption-class ending is kept", async () => {
    const speech: Array<[number, number]> = [[0.3, 31.2]];
    const segments = [
      { text: "one long spoken take", startS: 0.3, endS: 28 },
      { text: " Thanks for watching", startS: 28, endS: 31.2 },
    ];
    const text = segments.map((segment) => segment.text).join("");
    const result = await stripHallucinatedCaption(text, shaped(31.3, speech), {
      segments, segmentsText: text, speechProbabilities: vad(31.3, speech),
    });
    expect(result.text).toBe(text);
  });

  test("a stray 'you' past the last speech span is removed and the real words stay", async () => {
    const speech: Array<[number, number]> = [[0.5, 9.5], [21.5, 29.5]];
    const segments = [
      { text: "first spoken part", startS: 0.5, endS: 9.5 },
      { text: " second spoken part", startS: 21.5, endS: 29.5 },
      { text: " you", startS: 30.2, endS: 31.3 },
    ];
    const text = segments.map((segment) => segment.text).join("");
    const result = await stripHallucinatedCaption(text, shaped(31.3, speech), {
      segments, segmentsText: text, speechProbabilities: vad(31.3, speech),
    });
    expect(result.text).toBe("first spoken part second spoken part");
  });
});
