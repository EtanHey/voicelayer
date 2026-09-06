import { describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import {
  findCandidateSpan,
  findOutroCandidates,
  findTrailingOutroCandidate,
  measureWavWindows,
  normalizeOutroKey,
  outroGateEnabled,
  splitSentences,
  stripHallucinatedOutro,
} from "../stt-outro-gate";
import { WhisperServerBackend } from "../stt";
import type { TranscriptSegment } from "../stt-sentence-boundaries";

/**
 * The hallucinated-closer gate, against the four real specimens plus synthetic
 * audio.
 *
 * The whole point of this gate is that it decides on the AUDIO, so the cases
 * that matter feed it real WAVs from Etan's recordings archive (gitignored and
 * machine-local, like the #21 and #30 fixtures) and skip loudly when the
 * archive is absent. The synthetic cases always run: a `say`-spoken clip padded
 * with silence when `say` and `ffmpeg` are available, and hand-built tone
 * fixtures that need nothing at all.
 *
 * The archived clips are fed whisper's CLAIMED span for the phrase rather than
 * a live decode — the spans come from the energy maps measured on those exact
 * files (recon, 2026-09-06), and each case asserts the measured acoustics it
 * relies on alongside the gate's verdict. A live decode against an isolated
 * whisper port is the follow-up, not a substitute: what these cases pin down is
 * the DECISION, given a span.
 */

const RECORDINGS = join(homedir(), ".local/share/voicelayer/recordings");

/** Specimen 1 — English tail. `…on Slack. Thank you.` He did not say it. */
const CLIP_SLACK = join(
  RECORDINGS,
  "2026-09-06/2026-09-06T14-45-42-649Z-25ed3b89/audio.wav",
);
/** Specimen 2 — 15 s of `voice_ask` with no speech at all, decoded as `Thank you.` */
const CLIP_SILENT = join(
  RECORDINGS,
  "2026-09-05/2026-09-05T17-29-04-531Z-0056bd81/audio.wav",
);
/** Specimen 3 — Hebrew tail. 80.8 s ending `תודה.` he never said. */
const CLIP_HEBREW_TAIL = join(
  RECORDINGS,
  "2026-09-06/2026-09-06T15-16-33-682Z-ff770b47/audio.wav",
);
/** Specimen 4 — Hebrew MID-utterance `תודה רבה.` at an internal pause, 142.5 s. */
const CLIP_HEBREW_MID = join(
  RECORDINGS,
  "2026-09-06/2026-09-06T15-20-11-471Z-a6aa28aa/audio.wav",
);
/** Specimen 5 — English tail `Okay.` after a complete sentence, 25.6 s. */
const CLIP_OKAY = join(
  RECORDINGS,
  "2026-09-06/2026-09-06T15-25-56-152Z-ac389f08/audio.wav",
);

const FIXTURE_DIR = join(
  import.meta.dir,
  "../../docs.local/test-fixtures/outro-gate",
);
const SAY_WAV = join(FIXTURE_DIR, "spoken-tail.wav");

const SAMPLE_RATE = 16000;

function whichOk(bin: string): boolean {
  try {
    return Bun.spawnSync(["which", bin]).exitCode === 0;
  } catch {
    return false;
  }
}

function readWav(path: string): Uint8Array {
  return new Uint8Array(readFileSync(path));
}

interface ToneBurst {
  startS: number;
  endS: number;
  peak?: number;
}

/**
 * A 16-bit mono WAV with a tone in each of `bursts` and silence elsewhere.
 *
 * The tone stands in for speech only as far as energy goes, which is all the
 * gate measures. `noisePeak` puts a low hiss under the whole thing so the
 * measured noise floor is realistic rather than digital zero.
 */
function makeWav(
  totalSeconds: number,
  bursts: ToneBurst[],
  noisePeak = 0,
): Uint8Array {
  const frameCount = Math.round(totalSeconds * SAMPLE_RATE);
  const dataBytes = frameCount * 2;
  const wav = new Uint8Array(44 + dataBytes);
  const view = new DataView(wav.buffer);
  const writeAscii = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i++)
      wav[offset + i] = value.charCodeAt(i);
  };

  writeAscii(0, "RIFF");
  view.setUint32(4, 36 + dataBytes, true);
  writeAscii(8, "WAVE");
  writeAscii(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, SAMPLE_RATE, true);
  view.setUint32(28, SAMPLE_RATE * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeAscii(36, "data");
  view.setUint32(40, dataBytes, true);

  // Deterministic pseudo-noise: a real recording never has a digital-zero floor.
  let seed = 12345;
  const nextNoise = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return ((seed / 0x7fffffff) * 2 - 1) * noisePeak;
  };

  for (let i = 0; i < frameCount; i++) {
    let sample = noisePeak > 0 ? nextNoise() : 0;
    const t = i / SAMPLE_RATE;
    for (const burst of bursts) {
      if (t >= burst.startS && t < burst.endS) {
        sample +=
          (burst.peak ?? 2000) *
          Math.sin((2 * Math.PI * 180 * i) / SAMPLE_RATE);
        break;
      }
    }
    view.setInt16(
      44 + i * 2,
      Math.max(-32768, Math.min(32767, Math.round(sample))),
      true,
    );
  }
  return wav;
}

function segment(
  text: string,
  startS: number,
  endS: number,
): TranscriptSegment {
  return { text, startS, endS };
}

/**
 * Duration via the module's own parser.
 *
 * NOT by reading the size at byte 40: ffmpeg writes a LIST/INFO chunk ahead of
 * `data`, so that offset holds metadata rather than the sample count, and the
 * bogus duration put every synthesized span outside the audio.
 */
function wavDurationSeconds(wav: Uint8Array): number {
  const windows = measureWavWindows(wav);
  if (!windows) throw new Error("unparseable WAV fixture");
  return windows.durationSeconds;
}

// --- (a) which sentences the gate is even willing to look at ---

describe("findOutroCandidates", () => {
  test("offers the invented tail on the Slack specimen's transcript", () => {
    const text =
      "Merge the pull requests and notify the engineering team on Slack. Thank you.";
    const candidate = findTrailingOutroCandidate(text);
    expect(candidate?.phrase).toBe("Thank you.");
    expect(candidate?.isTail).toBe(true);
  });

  test("offers every 1-5 token tail the corpus actually produced", () => {
    const cases: Array<[string, string]> = [
      ["...pause? And that's a little not so clear to me still. So.", "So."],
      ["...give you the post from earlier: Okay.", "Okay."],
      ["...thus making it much slower? Thank you.", "Thank you."],
      ["...on a new read. You.", "You."],
      ["Are we actually utilizing it? I.", "I."],
      ["...where's that coming from, man? and.", "and."],
      [
        "...not really getting anything outside of LinkedIn, though. So, so, so, so, so.",
        "So, so, so, so, so.",
      ],
    ];
    for (const [text, expected] of cases) {
      expect(findTrailingOutroCandidate(text)?.phrase).toBe(expected);
    }
  });

  test("offers the Hebrew closers, tail and mid-utterance alike", () => {
    expect(
      findTrailingOutroCandidate("כמו התחליף וויספר פלו שבניתי לעצמי. תודה.")
        ?.phrase,
    ).toBe("תודה.");

    // Specimen 4's shape: the invented phrase sits between two real sentences.
    const mid = findOutroCandidates(
      "בעיקר בגלל שהבחור של הבקן שלנו עזב. תודה רבה. הבחור של הבקן שלנו עזב.",
    );
    expect(mid).toHaveLength(1);
    expect(mid[0]?.phrase).toBe("תודה רבה.");
    expect(mid[0]?.isTail).toBe(false);
  });

  test("offers specimen 5's English tail after a complete sentence", () => {
    const text =
      "I mean, we'll have Astra—we shouldn't use it everywhere, just like we're not using Fable everywhere. Okay.";
    expect(findTrailingOutroCandidate(text)?.phrase).toBe("Okay.");
  });

  test("never offers a word Etan kept in the corpus", () => {
    const kept = [
      // He said "Yeah." — the invented token in that row was "And...".
      "...there were, like, 10 seats in all together. Yeah.",
      // stt.test.ts requires this survive; "All right." is a thing he says.
      "Should we ship the plan now? All right.",
      "...we'll be done with run 8? Cool.",
      "...sometimes might happen. Here.",
      // Retractions keep their fragment: ratified "raw accurate".
      "...that's crazy. It should be...",
      "Oh, and now you have 7, crazy...",
      // A farewell inside a sentence is not a standalone farewell.
      "I want to thank you for that.",
      "So I told him okay and then left.",
      "אני רוצה להגיד תודה על העזרה.",
    ];
    for (const text of kept) {
      expect(findOutroCandidates(text)).toEqual([]);
    }
  });

  test("a question is never a candidate — he kept two `okay?` rows", () => {
    expect(findOutroCandidates("So we push it tomorrow, okay?")).toEqual([]);
    expect(findOutroCandidates("Right, okay?")).toEqual([]);
    expect(findOutroCandidates("Ship it. Thank you!")).toEqual([]);
  });

  test("mixed terminal punctuation is never a candidate", () => {
    // `normalizeOutroKey` strips punctuation, so a trailing-dot-only check let
    // these reach the lexicon as plain "thank you" / "okay". (Macroscope #3.)
    expect(findOutroCandidates("Ship it. Thank you?.")).toEqual([]);
    expect(findOutroCandidates("Ship it. Okay!.")).toEqual([]);
    expect(findOutroCandidates("Ship it. Thank you!?.")).toEqual([]);
  });

  test("the six-word subtitles credit is actually reachable", () => {
    // It sits in the lexicon but the 5-word cap ran first, so it was dead
    // code that read as covered. (Macroscope #4.)
    expect(
      findTrailingOutroCandidate(
        "And that is the whole plan. Subtitles by the Amara.org community.",
      )?.phrase,
    ).toBe("Subtitles by the Amara.org community.");
  });

  test("a cut-off fragment is never a candidate, whatever its words", () => {
    expect(findOutroCandidates("Say it again. Thank you…")).toEqual([]);
    expect(findOutroCandidates("Say it again. Thank you...")).toEqual([]);
    expect(findOutroCandidates("Say it again. So...")).toEqual([]);
    expect(
      findOutroCandidates("ואז שנה וחצי שנתיים כבר אני במה... תודה..."),
    ).toEqual([]);
  });

  test("keeps the fragment and still offers the farewell after it", () => {
    const candidate = findTrailingOutroCandidate("It should be... Thank you.");
    expect(candidate?.phrase).toBe("Thank you.");
  });

  test("splitSentences does not break a decimal or a domain", () => {
    expect(
      splitSentences("Transfer by 8.45am tomorrow.").map((s) => s.text),
    ).toEqual(["Transfer by 8.45am tomorrow."]);
    expect(
      splitSentences("It should be... Thank you.").map((s) => s.text),
    ).toEqual(["It should be...", "Thank you."]);
  });

  test("normalizeOutroKey strips punctuation and folds the stutter", () => {
    expect(normalizeOutroKey("So, so, so, so, so.")).toBe("so so so so so");
    expect(normalizeOutroKey("Thank you!")).toBe("thank you");
    expect(normalizeOutroKey("תודה רבה.")).toBe("תודה רבה");
  });
});

// --- (b)+(c) the acoustic decision, on synthetic audio ---

describe("stripHallucinatedOutro — the audio decides", () => {
  test("drops a farewell whisper attributed to the trailing silence", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship the release today. Thank you.",
      wav,
      {
        segments: [
          segment(" Ship the release today.", 0, 3),
          segment(" Thank you.", 4.2, 4.6),
        ],
      },
    );

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe("Ship the release today.");
    expect(decision.removed.map((entry) => entry.phrase)).toEqual([
      "Thank you.",
    ]);
  });

  test("keeps a farewell that has speech under it", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 5 }], 40);
    const text = "Ship the release today. Thank you.";
    const decision = stripHallucinatedOutro(text, wav, {
      segments: [
        segment(" Ship the release today.", 0, 4.2),
        segment(" Thank you.", 4.2, 4.9),
      ],
    });

    // Either acoustic condition is a legitimate keep here. This fixture is
    // tone wall to wall, so its 10th-percentile "floor" is measured INSIDE the
    // speech and the relative threshold lands above it — the exact case the
    // dropped -35 dBFS upper clamp used to paper over, now caught by the
    // speech-level backstop instead. What matters is that nothing is cut.
    expect(["energy-present", "near-speech-level"]).toContain(decision.reason);
    expect(decision.text).toBe(text);
    expect(decision.removed).toEqual([]);
  });

  test("keeps a closer in a recording that is speech wall to wall", () => {
    // No pauses at all, so the measured floor sits inside speech and the
    // relative threshold is meaningless. `speechLevelDbfs` is what protects
    // the words here. (Macroscope HIGH #1, PR #34.)
    const wav = makeWav(6, [{ startS: 0, endS: 6 }]);
    const windows = measureWavWindows(wav)!;
    expect(windows.speechThresholdDbfs).toBeGreaterThan(
      windows.speechLevelDbfs,
    );

    const text = "Ship the release today. Thank you.";
    const decision = stripHallucinatedOutro(text, wav, {
      segments: [
        segment(" Ship the release today.", 0, 5.2),
        segment(" Thank you.", 5.2, 5.9),
      ],
    });
    expect(decision.reason).toBe("near-speech-level");
    expect(decision.text).toBe(text);
  });

  test("keeps a closer in a LOW-GAIN recording whose speech is near its floor", () => {
    // Speech at roughly -42 dBFS over a -48 dBFS floor. Under the old -35 dBFS
    // upper clamp this recording's own speech scored as silence and a real
    // closer was deletable. (Macroscope HIGH #1, PR #34.)
    const quiet = makeWav(
      6,
      [
        { startS: 0, endS: 3.6, peak: 260 },
        { startS: 3.8, endS: 4.4, peak: 260 },
      ],
      130,
    );
    const windows = measureWavWindows(quiet)!;
    expect(windows.floorDbfs).toBeLessThan(-40);
    expect(windows.speechLevelDbfs).toBeLessThan(-35);

    const text = "Ship the release today. Thank you.";
    const decision = stripHallucinatedOutro(text, quiet, {
      segments: [
        segment(" Ship the release today.", 0, 3.6),
        // On the quiet second burst — he said it, softly.
        segment(" Thank you.", 3.8, 4.4),
      ],
    });
    expect(decision.removed).toEqual([]);
    expect(decision.text).toBe(text);
  });

  test("refuses when the text is no longer the text the segments describe", () => {
    // `verifyLeadingPunctuation` swapped in a retry decode that added leading
    // words; every later word position has shifted. (Macroscope HIGH #2.)
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    const decoded = "Ship the release today. Thank you.";
    const repaired = `So, look. ${decoded}`;
    const decision = stripHallucinatedOutro(repaired, wav, {
      segments: [
        segment(" Ship the release today.", 0, 3),
        segment(" Thank you.", 4.2, 4.6),
      ],
      segmentsText: decoded,
    });
    expect(decision.reason).toBe("segments-stale");
    expect(decision.text).toBe(repaired);
    expect(decision.removed).toEqual([]);
  });

  test("still runs when the text is byte-identical to the decode", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    const decoded = "Ship the release today. Thank you.";
    const decision = stripHallucinatedOutro(decoded, wav, {
      segments: [
        segment(" Ship the release today.", 0, 3),
        segment(" Thank you.", 4.2, 4.6),
      ],
      segmentsText: decoded,
    });
    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe("Ship the release today.");
  });

  test("keeps a farewell spoken just before the VAD's trailing silence", () => {
    // The false positive a "last N ms of the WAV" rule would cause: he really
    // said it, and the recorder then waited out 1.5 s of silence before
    // stopping. Every VAD recording ends this way.
    const wav = makeWav(6, [{ startS: 0, endS: 4.5 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship the release today. Thank you.",
      wav,
      {
        segments: [
          segment(" Ship the release today.", 0, 3.8),
          segment(" Thank you.", 3.8, 4.5),
        ],
      },
    );

    expect(decision.removed).toEqual([]);
    expect(decision.text).toBe("Ship the release today. Thank you.");
  });

  test("keeps it when a span's mean reads quiet but a word is inside it", () => {
    const wav = makeWav(8, [{ startS: 0, endS: 4 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship the release today. Thank you.",
      wav,
      {
        // Starts inside the spoken region and runs long into the silence, so
        // the mean is dragged down while real speech sits in it.
        segments: [
          segment(" Ship the release today.", 0, 3),
          segment(" Thank you.", 3.0, 7.9),
        ],
      },
    );

    expect(decision.reason).toBe("energy-present");
    expect(decision.removed).toEqual([]);
  });

  test("an isolated click in the silence does not save the hallucination", () => {
    // A 20 ms breath spike, the shape both real specimens carry in their tails.
    const wav = makeWav(
      5,
      [
        { startS: 0, endS: 3 },
        { startS: 4.3, endS: 4.32, peak: 400 },
      ],
      40,
    );
    const decision = stripHallucinatedOutro(
      "Ship the release today. Thank you.",
      wav,
      {
        segments: [
          segment(" Ship the release today.", 0, 3),
          segment(" Thank you.", 4.2, 4.6),
        ],
      },
    );

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe("Ship the release today.");
  });

  test("drops a farewell sitting in an INTERNAL pause", () => {
    // Speech, a 2.5 s pause, then more speech — specimen 4's shape.
    const wav = makeWav(
      12,
      [
        { startS: 0, endS: 4 },
        { startS: 6.5, endS: 11.5 },
      ],
      40,
    );
    const decision = stripHallucinatedOutro(
      "The backend guy left. Thank you. He learned a lot there.",
      wav,
      {
        segments: [
          segment(" The backend guy left.", 0, 4),
          segment(" Thank you.", 5.0, 5.4),
          segment(" He learned a lot there.", 6.5, 11.5),
        ],
      },
    );

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe("The backend guy left. He learned a lot there.");
    expect(decision.removed[0]?.isTail).toBe(false);
  });

  test("keeps an internal farewell whose span is only just inside the pause", () => {
    // Segment ends are good to ~0.15 s, so a real word's span can drift into
    // the pause beside it. A span that close to speech is never deleted.
    const wav = makeWav(
      12,
      [
        { startS: 0, endS: 4 },
        { startS: 6.5, endS: 11.5 },
      ],
      40,
    );
    const decision = stripHallucinatedOutro(
      "The backend guy left. Thank you. He learned a lot there.",
      wav,
      {
        segments: [
          segment(" The backend guy left.", 0, 3.95),
          segment(" Thank you.", 4.02, 4.3),
          segment(" He learned a lot there.", 6.5, 11.5),
        ],
      },
    );

    expect(decision.reason).toBe("not-clear-of-speech");
    expect(decision.removed).toEqual([]);
  });

  test("drops both an internal and a trailing closer in one pass", () => {
    const wav = makeWav(
      14,
      [
        { startS: 0, endS: 4 },
        { startS: 6.5, endS: 10.5 },
      ],
      40,
    );
    const decision = stripHallucinatedOutro(
      "The backend guy left. Thank you. He learned a lot there. Okay.",
      wav,
      {
        segments: [
          segment(" The backend guy left.", 0, 4),
          segment(" Thank you.", 5.0, 5.4),
          segment(" He learned a lot there.", 6.5, 10.5),
          segment(" Okay.", 12.0, 12.4),
        ],
      },
    );

    expect(decision.text).toBe("The backend guy left. He learned a lot there.");
    expect(decision.removed.map((entry) => entry.phrase)).toEqual([
      "Thank you.",
      "Okay.",
    ]);
  });

  test("picks the right one of two identical tails", () => {
    // He said "Thank you." at 3.4 s; whisper then invented a second one in the
    // silence. Only the invented one may go.
    const wav = makeWav(6, [{ startS: 0, endS: 3.4 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship it. Thank you. Thank you.",
      wav,
      {
        segments: [
          segment(" Ship it.", 0, 2.4),
          segment(" Thank you.", 2.6, 3.4),
          segment(" Thank you.", 4.5, 4.9),
        ],
      },
    );

    expect(decision.text).toBe("Ship it. Thank you.");
    expect(decision.removed).toHaveLength(1);
  });

  test("empties a transcript that is only the farewell over silent audio", () => {
    const wav = makeWav(15, [], 40);
    const decision = stripHallucinatedOutro("Thank you.", wav, {});
    expect(decision.text).toBe("");
    expect(decision.removed.map((entry) => entry.phrase)).toEqual([
      "Thank you.",
    ]);
  });

  test("is inert on a WAV whose format tag is not integer PCM", () => {
    // A 16-bit, 1-channel, 16 kHz header that claims A-law (format 6). Bit
    // depth and channel count match, so only the format check stops it being
    // read as integer PCM and measured into a meaningless energy figure —
    // which is what would authorise a deletion. (CodeRabbit, PR #34.)
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    new DataView(wav.buffer, wav.byteOffset, wav.byteLength).setUint16(
      20,
      6,
      true,
    );

    expect(measureWavWindows(wav)).toBeNull();

    const text = "Ship the release today. Thank you.";
    const decision = stripHallucinatedOutro(text, wav, {
      segments: [
        segment(" Ship the release today.", 0, 3),
        segment(" Thank you.", 4.2, 4.6),
      ],
    });
    expect(decision.reason).toBe("no-audio");
    expect(decision.text).toBe(text);
    expect(decision.removed).toEqual([]);
  });

  test("is inert on a truncated WAV whose data chunk is not there", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40).slice(0, 40);
    expect(measureWavWindows(wav)).toBeNull();
    const text = "Ship the release today. Thank you.";
    expect(stripHallucinatedOutro(text, wav, {}).text).toBe(text);
  });

  test("is inert without segments — a silent tail alone never justifies a cut", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship the release today. Thank you.",
      wav,
      {},
    );
    expect(decision.reason).toBe("no-segments");
    expect(decision.text).toBe("Ship the release today. Thank you.");
  });

  test("refuses segments that came from a different decode", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship the release today. Thank you.",
      wav,
      {
        segments: [
          segment(" Ship the release today.", 0, 3),
          segment(" Thank you.", 4.2, 4.6),
        ],
        segmentsMatchAudio: false,
      },
    );
    expect(decision.reason).toBe("no-segments");
    expect(decision.text).toBe("Ship the release today. Thank you.");
  });

  test("drops both tails when whisper attributed both to the silence", () => {
    const wav = makeWav(6, [{ startS: 0, endS: 3.4 }], 40);
    const decision = stripHallucinatedOutro(
      "Ship it. Thank you. Thank you.",
      wav,
      {
        segments: [
          segment(" Ship it.", 0, 2.4),
          segment(" Thank you.", 4.4, 4.7),
          segment(" Thank you.", 4.7, 4.9),
        ],
      },
    );
    // Neither was spoken — there is no speech under either span. Keeping one
    // "because he probably said it once" would be inventing a word, which is
    // the same class of mistake the gate exists to undo.
    expect(decision.text).toBe("Ship it.");
    expect(decision.removed).toHaveLength(2);
  });

  test("leaves a text with no candidate sentence completely alone", () => {
    const wav = makeWav(5, [{ startS: 0, endS: 3 }], 40);
    const text = "Ship the release today. All right.";
    expect(stripHallucinatedOutro(text, wav, {}).text).toBe(text);
  });

  test("findCandidateSpan will not guess when the words do not line up", () => {
    const candidate = findTrailingOutroCandidate("Ship it. Thank you.");
    expect(candidate).not.toBeNull();
    expect(
      findCandidateSpan(
        [segment(" Ship it and go somewhere else.", 0, 3)],
        candidate!,
        "Ship it. Thank you.",
      ),
    ).toBeNull();
  });

  test("will not measure a closer against a span from a rewritten transcript", () => {
    // Head repair / echo trim dropped a leading hallucinated closer that the
    // segments still describe. The remaining "Thank you." is the one he said
    // (speech at 2.6–3.4 s). Word-count lookup into the original segments
    // would land on the LEADING silent copy and delete the spoken one.
    const wav = makeWav(6, [{ startS: 0.5, endS: 3.4 }], 40);
    const decision = stripHallucinatedOutro("Thank you.", wav, {
      segments: [
        segment(" Thank you.", 0.0, 0.3),
        segment(" Ship it.", 0.5, 2.4),
        segment(" Thank you.", 2.6, 3.4),
      ],
    });
    expect(decision.reason).toBe("segments-stale");
    expect(decision.text).toBe("Thank you.");
    expect(decision.removed).toEqual([]);
  });
});

describe("measureWavWindows", () => {
  test("refuses IEEE float PCM even when rate/channels/bits look like ours", () => {
    const pcmBytes = 320;
    const wav = new Uint8Array(44 + pcmBytes);
    const view = new DataView(wav.buffer);
    const ascii = (offset: number, text: string) => {
      for (let i = 0; i < text.length; i++)
        wav[offset + i] = text.charCodeAt(i);
    };
    ascii(0, "RIFF");
    view.setUint32(4, 36 + pcmBytes, true);
    ascii(8, "WAVE");
    ascii(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 3, true); // IEEE float
    view.setUint16(22, 1, true);
    view.setUint32(24, SAMPLE_RATE, true);
    view.setUint32(28, SAMPLE_RATE * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    ascii(36, "data");
    view.setUint32(40, pcmBytes, true);
    expect(measureWavWindows(wav)).toBeNull();
  });

  test("refuses 24-bit PCM rather than mis-reading it as int16", () => {
    const pcmBytes = 480;
    const wav = new Uint8Array(44 + pcmBytes);
    const view = new DataView(wav.buffer);
    const ascii = (offset: number, text: string) => {
      for (let i = 0; i < text.length; i++)
        wav[offset + i] = text.charCodeAt(i);
    };
    ascii(0, "RIFF");
    view.setUint32(4, 36 + pcmBytes, true);
    ascii(8, "WAVE");
    ascii(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, SAMPLE_RATE, true);
    view.setUint32(28, SAMPLE_RATE * 3, true);
    view.setUint16(32, 3, true);
    view.setUint16(34, 24, true);
    ascii(36, "data");
    view.setUint32(40, pcmBytes, true);
    expect(measureWavWindows(wav)).toBeNull();
  });

  test("averages stereo frames instead of reading one channel as two samples", () => {
    // Left channel has a tone, right is digital zero. Frame size is 4 bytes.
    // The RMS of (tone, 0) is tone/sqrt(2) — still well above the silence floor.
    const seconds = 1;
    const frames = SAMPLE_RATE * seconds;
    const dataBytes = frames * 4;
    const wav = new Uint8Array(44 + dataBytes);
    const view = new DataView(wav.buffer);
    const ascii = (offset: number, text: string) => {
      for (let i = 0; i < text.length; i++)
        wav[offset + i] = text.charCodeAt(i);
    };
    ascii(0, "RIFF");
    view.setUint32(4, 36 + dataBytes, true);
    ascii(8, "WAVE");
    ascii(12, "fmt ");
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 2, true);
    view.setUint32(24, SAMPLE_RATE, true);
    view.setUint32(28, SAMPLE_RATE * 4, true);
    view.setUint16(32, 4, true);
    view.setUint16(34, 16, true);
    ascii(36, "data");
    view.setUint32(40, dataBytes, true);
    for (let i = 0; i < frames; i++) {
      const tone = Math.round(
        4000 * Math.sin((2 * Math.PI * 180 * i) / SAMPLE_RATE),
      );
      view.setInt16(44 + i * 4, tone, true);
      view.setInt16(44 + i * 4 + 2, 0, true);
    }
    const windows = measureWavWindows(wav);
    expect(windows).not.toBeNull();
    expect(windows!.durationSeconds).toBeCloseTo(1, 2);
    expect(windows!.dbfs.some((level) => level > -30)).toBe(true);
  });
});

describe("outroGateEnabled", () => {
  test("only an explicit opt-in turns it on", () => {
    expect(outroGateEnabled({})).toBe(false);
    expect(outroGateEnabled({ VOICELAYER_STT_OUTRO_GATE: "0" })).toBe(false);
    expect(outroGateEnabled({ VOICELAYER_STT_OUTRO_GATE: "" })).toBe(false);
    expect(outroGateEnabled({ VOICELAYER_STT_OUTRO_GATE: "1" })).toBe(true);
    expect(outroGateEnabled({ VOICELAYER_STT_OUTRO_GATE: "true" })).toBe(true);
  });
});

// --- real speech: `say` a sentence, then pad it with silence ---

const hasSay = whichOk("say");
const hasFfmpeg = whichOk("ffmpeg");
const sayReady = hasSay && hasFfmpeg;
if (!sayReady) {
  console.error(
    `[outro-gate] SKIPPING the spoken-tail cases — missing: ${[
      hasSay ? null : "say",
      hasFfmpeg ? null : "ffmpeg",
    ]
      .filter(Boolean)
      .join(", ")}. The synthetic and pure-text cases still run.`,
  );
}
const sayTest = sayReady ? test : test.skip;

function buildSayFixture(): Uint8Array {
  if (existsSync(SAY_WAV)) return readWav(SAY_WAV);
  mkdirSync(FIXTURE_DIR, { recursive: true });
  const aiff = join(FIXTURE_DIR, "spoken-tail.aiff");
  const spoken = Bun.spawnSync([
    "say",
    "-o",
    aiff,
    "Merge the pull requests and notify the engineering team on Slack",
  ]);
  if (spoken.exitCode !== 0) throw new Error("say failed");
  // 16 kHz mono, then 2 s of silence appended — the shape of a recording the
  // VAD stopped after the last word.
  const padded = Bun.spawnSync([
    "ffmpeg",
    "-y",
    "-i",
    aiff,
    "-af",
    "apad=pad_dur=2",
    "-ar",
    String(SAMPLE_RATE),
    "-ac",
    "1",
    "-c:a",
    "pcm_s16le",
    SAY_WAV,
  ]);
  if (padded.exitCode !== 0) throw new Error("ffmpeg failed");
  return readWav(SAY_WAV);
}

describe("stripHallucinatedOutro — real speech plus 2 s of silence", () => {
  sayTest("drops a farewell a fake decoder glued into the silent pad", () => {
    const wav = buildSayFixture();
    const durationS = wavDurationSeconds(wav);
    const spoken =
      "Merge the pull requests and notify the engineering team on Slack.";

    const decision = stripHallucinatedOutro(`${spoken} Thank you.`, wav, {
      segments: [
        segment(` ${spoken}`, 0, durationS - 2),
        // Inside the appended silence, which is where whisper put it on the
        // real specimen too.
        segment(" Thank you.", durationS - 0.6, durationS - 0.2),
      ],
    });

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe(spoken);
  });

  sayTest("keeps the same farewell when it is inside the spoken region", () => {
    const wav = buildSayFixture();
    const speechEndS = wavDurationSeconds(wav) - 2;
    const spoken = "Merge the pull requests and notify the engineering team";

    const decision = stripHallucinatedOutro(`${spoken}. Thank you.`, wav, {
      segments: [
        segment(` ${spoken}.`, 0, speechEndS - 0.8),
        segment(" Thank you.", speechEndS - 0.8, speechEndS - 0.05),
      ],
    });

    expect(decision.removed).toEqual([]);
    expect(decision.text).toBe(`${spoken}. Thank you.`);
  });
});

// --- the archived specimens ---

const specimens = [
  { path: CLIP_SLACK, name: "25ed3b89" },
  { path: CLIP_SILENT, name: "0056bd81" },
  { path: CLIP_HEBREW_TAIL, name: "ff770b47" },
  { path: CLIP_HEBREW_MID, name: "a6aa28aa" },
  { path: CLIP_OKAY, name: "ac389f08" },
];
const missing = specimens.filter((entry) => !existsSync(entry.path));
if (missing.length > 0) {
  console.error(
    `[outro-gate] SKIPPING archived specimens (machine-local recordings archive): ${missing
      .map((entry) => entry.name)
      .join(", ")}`,
  );
}
const has = (path: string) => existsSync(path);
const clipTest = (path: string) => (has(path) ? test : test.skip);

describe("stripHallucinatedOutro — specimen 1, the Slack dictation", () => {
  clipTest(CLIP_SLACK)("drops the invented English tail", () => {
    const wav = readWav(CLIP_SLACK);
    const windows = measureWavWindows(wav);
    expect(windows).not.toBeNull();
    // The measurement this case rests on: quiet floor, loud speech.
    expect(windows!.floorDbfs).toBeLessThan(-50);
    expect(windows!.durationSeconds).toBeGreaterThan(30);

    const spoken =
      "Merge the pull requests and notify the engineering team on Slack.";
    // Whisper's own span for the phrase on this clip: 30.000-30.360 s, RMS
    // 45-124 against a 31.9 floor (lead's measurement, 2026-09-06).
    const decision = stripHallucinatedOutro(`${spoken} Thank you.`, wav, {
      segments: [
        segment(` ${spoken}`, 0, 29.75),
        segment(" Thank you.", 30.0, 30.36),
      ],
    });

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe(spoken);
    expect(decision.removed[0]?.spanDbfs).toBeLessThan(
      windows!.speechThresholdDbfs,
    );
  });

  clipTest(CLIP_SLACK)("keeps it when whisper blames the real speech", () => {
    const wav = readWav(CLIP_SLACK);
    const spoken = "Merge the pull requests and notify the engineering team";
    const decision = stripHallucinatedOutro(`${spoken}. Thank you.`, wav, {
      segments: [
        segment(` ${spoken}.`, 0, 28.9),
        segment(" Thank you.", 28.9, 29.7),
      ],
    });
    expect(decision.removed).toEqual([]);
  });
});

describe("stripHallucinatedOutro — specimen 2, the silent voice_ask", () => {
  clipTest(CLIP_SILENT)(
    "empties the 15 s clip that came back 'Thank you.'",
    () => {
      const wav = readWav(CLIP_SILENT);
      const windows = measureWavWindows(wav);
      expect(windows!.durationSeconds).toBeGreaterThan(14);

      const decision = stripHallucinatedOutro("Thank you.", wav, {});
      expect(decision.text).toBe("");
      expect(decision.removed.map((entry) => entry.phrase)).toEqual([
        "Thank you.",
      ]);
    },
  );
});

describe("stripHallucinatedOutro — specimen 3, the Hebrew tail", () => {
  /** The transcript's real last sentence, verbatim from the archive. */
  const HEBREW_LAST =
    "ובזמן החופשי אני גם בונה מערכות בשילוב AI, כמו התחליף וויספר פלו שבניתי לעצמי.";

  clipTest(CLIP_HEBREW_TAIL)(
    "drops the invented תודה. over the trailing silence",
    () => {
      const wav = readWav(CLIP_HEBREW_TAIL);
      const windows = measureWavWindows(wav);
      expect(windows!.durationSeconds).toBeGreaterThan(80);
      // Measured: floor -58.9 dBFS, real speech to ~78.0 s, then 2.8 s of silence
      // holding one isolated 20 ms spike at 78.32 s (RMS 252 vs a 37 floor).
      expect(windows!.floorDbfs).toBeLessThan(-55);

      const decision = stripHallucinatedOutro(`${HEBREW_LAST} תודה.`, wav, {
        segments: [
          segment(` ${HEBREW_LAST}`, 70.0, 77.9),
          segment(" תודה.", 79.2, 79.8),
        ],
      });

      expect(decision.reason).toBe("removed");
      expect(decision.text).toBe(HEBREW_LAST);
    },
  );

  clipTest(CLIP_HEBREW_TAIL)(
    "keeps תודה. when it sits on the real speech",
    () => {
      const wav = readWav(CLIP_HEBREW_TAIL);
      const decision = stripHallucinatedOutro(`${HEBREW_LAST} תודה.`, wav, {
        segments: [
          segment(` ${HEBREW_LAST}`, 70.0, 77.0),
          segment(" תודה.", 77.0, 77.9),
        ],
      });
      expect(decision.removed).toEqual([]);
    },
  );
});

describe("stripHallucinatedOutro — specimen 4, Hebrew mid-utterance", () => {
  const BEFORE =
    "לאט לאט תפסתי את הבקן גם, בעיקר בגלל שהבחור של הבקן שלנו עזב.";
  const AFTER = "שם למדתי הרבה טכנולוגיות חדשות כמו סופה בייס.";

  clipTest(CLIP_HEBREW_MID)("drops תודה רבה. from the internal pause", () => {
    const wav = readWav(CLIP_HEBREW_MID);
    const windows = measureWavWindows(wav);
    expect(windows!.durationSeconds).toBeGreaterThan(140);

    // Measured: the longest internal pause is 85.74-88.44 s (2.70 s, max RMS
    // 128 against a 32.8 floor). The invented phrase is attributed inside it.
    const decision = stripHallucinatedOutro(
      `${BEFORE} תודה רבה. ${AFTER}`,
      wav,
      {
        segments: [
          segment(` ${BEFORE}`, 80.0, 85.7),
          segment(" תודה רבה.", 86.6, 87.4),
          segment(` ${AFTER}`, 88.5, 93.0),
        ],
      },
    );

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe(`${BEFORE} ${AFTER}`);
    expect(decision.removed[0]?.isTail).toBe(false);
  });

  clipTest(CLIP_HEBREW_MID)(
    "keeps תודה רבה. when it has speech under it",
    () => {
      const wav = readWav(CLIP_HEBREW_MID);
      const decision = stripHallucinatedOutro(
        `${BEFORE} תודה רבה. ${AFTER}`,
        wav,
        {
          segments: [
            segment(` ${BEFORE}`, 80.0, 84.5),
            // Inside the speech that runs up to the 85.74 s pause.
            segment(" תודה רבה.", 84.5, 85.6),
            segment(` ${AFTER}`, 88.5, 93.0),
          ],
        },
      );
      expect(decision.removed).toEqual([]);
    },
  );
});

describe("stripHallucinatedOutro — specimen 5, the Okay. tail", () => {
  const SPOKEN =
    "I mean, we'll have Astra—we shouldn't use it everywhere, just like we're not using Fable everywhere.";

  clipTest(CLIP_OKAY)("drops the invented Okay. despite a noisy floor", () => {
    const wav = readWav(CLIP_OKAY);
    const windows = measureWavWindows(wav);
    expect(windows!.durationSeconds).toBeGreaterThan(25);
    // This is the clip that killed the brief's fixed -45 dBFS line: its floor
    // is -53.2 dBFS and its silence carries windows up to -43.7 dBFS.
    expect(windows!.floorDbfs).toBeGreaterThan(-56);
    expect(windows!.speechThresholdDbfs).toBeGreaterThan(-45);

    // Measured: real speech ends ~22.52 s; 22.58-25.60 s is silence holding two
    // isolated spikes (RMS 370 at 23.94 s, 178 at 25.54 s).
    const decision = stripHallucinatedOutro(`${SPOKEN} Okay.`, wav, {
      segments: [
        segment(` ${SPOKEN}`, 3.5, 22.5),
        segment(" Okay.", 23.2, 23.7),
      ],
    });

    expect(decision.reason).toBe("removed");
    expect(decision.text).toBe(SPOKEN);
  });

  clipTest(CLIP_OKAY)("keeps Okay. when whisper puts it on the speech", () => {
    const wav = readWav(CLIP_OKAY);
    const decision = stripHallucinatedOutro(`${SPOKEN} Okay.`, wav, {
      segments: [
        segment(` ${SPOKEN}`, 3.5, 21.8),
        segment(" Okay.", 21.8, 22.5),
      ],
    });
    expect(decision.removed).toEqual([]);
  });
});

/**
 * Specimen 6 — the discriminating pair, in one recording.
 *
 * Corpus row `2026-08-25T15-03-38-825Z-bc42f7f7`: Etan KEPT the internal
 * `Thank you.` and DELETED the trailing `Okay.` Measured on the file here:
 * 126.976 s long, floor -61.6 dBFS, speech threshold -45.6 dBFS, and the last
 * sustained speech run ends at **105.40 s** — leaving 21.6 s of trailing
 * silence broken only by one 60 ms blip at 118.26 s (-39.6 dBFS). A held-down
 * PTT key, and an enormous window for whisper to invent into.
 *
 * Nothing in the text separates the two phrases. This is the case that says
 * the acoustics do.
 */
const CLIP_PAIR = join(
  RECORDINGS,
  "2026-08-25/2026-08-25T15-03-38-825Z-bc42f7f7/audio.wav",
);

describe("stripHallucinatedOutro — specimen 6, one real closer and one invented", () => {
  const SPOKEN = "I didn't give you the posts from earlier.";

  clipTest(CLIP_PAIR)("cuts the invented tail and keeps the spoken one", () => {
    const wav = readWav(CLIP_PAIR);
    const windows = measureWavWindows(wav);
    expect(windows!.durationSeconds).toBeGreaterThan(126);
    expect(windows!.floorDbfs).toBeLessThan(-58);

    const decision = stripHallucinatedOutro(`${SPOKEN} Thank you. Okay.`, wav, {
      segments: [
        segment(` ${SPOKEN}`, 90.0, 104.9),
        // On the clip's last real speech run — he said this.
        segment(" Thank you.", 104.92, 105.4),
        // Out in the 21.6 s of trailing silence — whisper invented this.
        segment(" Okay.", 110.0, 110.5),
      ],
    });

    expect(decision.text).toBe(`${SPOKEN} Thank you.`);
    expect(decision.removed.map((entry) => entry.phrase)).toEqual(["Okay."]);
  });

  clipTest(CLIP_PAIR)("keeps both when whisper puts both on the speech", () => {
    const wav = readWav(CLIP_PAIR);
    const decision = stripHallucinatedOutro(`${SPOKEN} Thank you. Okay.`, wav, {
      segments: [
        segment(` ${SPOKEN}`, 90.0, 104.5),
        segment(" Thank you.", 104.54, 104.9),
        segment(" Okay.", 104.92, 105.4),
      ],
    });

    expect(decision.removed).toEqual([]);
  });
});

// --- end to end, through the real backend ---

const OUTRO_FLAG = "VOICELAYER_STT_OUTRO_GATE";

const SMART_BOUNDARIES_FLAG = "VOICELAYER_STT_SMART_BOUNDARIES";

/** Run `body` with the flag pinned, restoring whatever the caller had. */
async function withOutroGate<T>(
  value: string | undefined,
  body: () => Promise<T>,
): Promise<T> {
  const saved = process.env[OUTRO_FLAG];
  const savedBoundaries = process.env[SMART_BOUNDARIES_FLAG];
  if (value === undefined) delete process.env[OUTRO_FLAG];
  else process.env[OUTRO_FLAG] = value;
  // Either flag requests verbose_json. Pin this off so "outro flag unset"
  // actually means the request stays `json`.
  delete process.env[SMART_BOUNDARIES_FLAG];
  try {
    return await body();
  } finally {
    if (saved === undefined) delete process.env[OUTRO_FLAG];
    else process.env[OUTRO_FLAG] = saved;
    if (savedBoundaries === undefined) delete process.env[SMART_BOUNDARIES_FLAG];
    else process.env[SMART_BOUNDARIES_FLAG] = savedBoundaries;
  }
}

describe("WhisperServerBackend with the outro gate", () => {
  const wavPath = join(
    FIXTURE_DIR,
    "backend-outro-gate.wav",
  );
  const SPOKEN = "Ship the release today.";

  async function transcribeWith(flag: string | undefined) {
    mkdirSync(FIXTURE_DIR, { recursive: true });
    // 3 s of tone then 2 s of silence, and a decoder that glues the closer on.
    await Bun.write(wavPath, makeWav(5, [{ startS: 0, endS: 3 }], 40));
    let sawVerboseRequest = false;
    const backend = new WhisperServerBackend({
      isServerAvailable: () => true,
      transcribeViaServer: async (_wavData, options) => {
        if (options?.onSegments) {
          sawVerboseRequest = true;
          options.onSegments([
            { text: ` ${SPOKEN}`, startS: 0, endS: 3 },
            { text: " Thank you.", startS: 4.2, endS: 4.6 },
          ]);
        }
        return `${SPOKEN} Thank you.`;
      },
    });
    const result = await withOutroGate(flag, () =>
      backend.transcribe(wavPath),
    );
    return { result, sawVerboseRequest };
  }

  test("drops the invented closer and says so in the backend string", async () => {
    const { result, sawVerboseRequest } = await transcribeWith("1");
    expect(sawVerboseRequest).toBe(true);
    expect(result.text).toBe(SPOKEN);
    expect(result.backend).toContain("outro");
  });

  test("skips the gate when head repair rewrote the transcript", async () => {
    mkdirSync(FIXTURE_DIR, { recursive: true });
    await Bun.write(wavPath, makeWav(5, [{ startS: 0, endS: 3 }], 40));
    // First decode starts with punctuation, so `verifyLeadingPunctuation`
    // retries and replaces the whole text — the segments then describe a
    // transcript that no longer exists. (Macroscope HIGH #2, PR #34.)
    //
    // This asserts the END-TO-END behaviour: a repaired transcript keeps its
    // closer. It is not by itself proof the staleness check fires — on this
    // particular shift the word verification in `findCandidateSpan` also
    // catches the misalignment. The unit case "refuses when the text is no
    // longer the text the segments describe" is what pins `segments-stale`.
    let call = 0;
    const backend = new WhisperServerBackend({
      isServerAvailable: () => true,
      transcribeViaServer: async (_wavData, options) => {
        call++;
        if (call === 1) {
          options?.onSegments?.([
            { text: ", ship the release today.", startS: 0, endS: 3 },
            { text: " Thank you.", startS: 4.2, endS: 4.6 },
          ]);
          return `, ship the release today. Thank you.`;
        }
        return `Well, ship the release today. Thank you.`;
      },
    });

    const result = await withOutroGate("1", () => backend.transcribe(wavPath));

    expect(call).toBeGreaterThan(1);
    // The closer survives — deliberately. Skipping a hallucination is
    // recoverable; deleting a real word on a misaligned span is not.
    expect(result.text).toContain("Thank you.");
    expect(result.backend).not.toContain("outro");
  });

  test("with the flag off the text and the request are untouched", async () => {
    const { result, sawVerboseRequest } = await transcribeWith(undefined);
    // No `onSegments` means the request stays the shipped `json` shape.
    expect(sawVerboseRequest).toBe(false);
    expect(result.text).toBe(`${SPOKEN} Thank you.`);
    expect(result.backend).not.toContain("outro");
  });
});

// --- the corpus gate ---

const CORPUS_TSV = join(
  homedir(),
  "Gits/voicelayer/docs.local/recon-2026-09-06/correction-corpus.tsv",
);
const hasCorpus = existsSync(CORPUS_TSV);
if (!hasCorpus) {
  console.error(
    `[outro-gate] SKIPPING the corpus gate — ${CORPUS_TSV} absent (docs.local is gitignored).`,
  );
}
const corpusTest = hasCorpus ? test : test.skip;

interface CorpusRow {
  id: string;
  class: string;
  realEdit: boolean;
  /** What the pipeline shipped. */
  ours: string;
  /** What Etan corrected it to — the ground truth. */
  his: string;
}

function readCorpus(): CorpusRow[] {
  const lines = readFileSync(CORPUS_TSV, "utf8").split("\n").filter(Boolean);
  const header = (lines.shift() ?? "").split("\t");
  const at = (cells: string[], name: string) =>
    cells[header.indexOf(name)] ?? "";
  return lines.map((line) => {
    const cells = line.split("\t");
    return {
      id: at(cells, "id"),
      class: at(cells, "class"),
      realEdit: at(cells, "real_edit").toLowerCase() === "true",
      ours: at(cells, "ours"),
      his: at(cells, "his"),
    };
  });
}

describe("outro gate over the 2026-09-06 correction corpus", () => {
  corpusTest(
    "never proposes cutting a TAIL Etan kept, across all 86 raws",
    () => {
      const rows = readCorpus().filter((row) => row.realEdit);
      expect(rows.length).toBeGreaterThanOrEqual(80);

      // His corrected text is the ground truth: every word in it is a word he
      // said and wanted. Not one of the 86 ends in a phrase this gate offers.
      const wrong = rows
        .flatMap((row) =>
          findOutroCandidates(row.his)
            .filter((candidate) => candidate.isTail)
            .map(
              (candidate) => `${row.id}: would cut tail "${candidate.phrase}"`,
            ),
        )
        .sort();

      expect(wrong).toEqual([]);
    },
  );

  corpusTest(
    "the only phrases it flags in a corrected text are internal",
    () => {
      const rows = readCorpus().filter((row) => row.realEdit);
      const flagged = rows
        .flatMap((row) =>
          findOutroCandidates(row.his).map(
            (candidate) => `${row.id}:${candidate.phrase}`,
          ),
        )
        .sort();

      // All three are real: he thanked an agent mid-dictation and kept it.
      // `…bc42f7f7` is the discriminating pair inside one row — this internal
      // `Thank you.` stayed, while that row's trailing `Okay.` was deleted.
      //
      // Nothing in the TEXT separates them from an invented phrase; conditions
      // (b) and (c) do, on the audio, which is what the specimen cases above
      // prove. This assertion is the alarm that fires if the lexicon ever grows
      // to put more of Etan's own sentences at that same risk.
      expect(flagged).toEqual([
        "2026-08-25T12-57-01-904Z-a28eab5f:Thank you.",
        "2026-08-25T15-03-38-825Z-bc42f7f7:Thank you.",
        "2026-09-06T08-25-24-672Z-ba12d56e:Thank you.",
      ]);
    },
  );

  corpusTest("catches the hallucinated tails in the word-added rows", () => {
    const rows = readCorpus().filter(
      (row) => row.realEdit && row.class === "word-added",
    );
    const caught = rows.filter(
      (row) => findOutroCandidates(row.ours).length > 0,
    );

    console.error(
      `[outro-gate] corpus: ${caught.length}/${rows.length} word-added rows offer a gated phrase — ${caught
        .map(
          (row) =>
            `${row.id}=${findOutroCandidates(row.ours)
              .map((entry) => entry.phrase)
              .join("|")}`,
        )
        .join(", ")}`,
    );

    // The brief's tally: `Thank you.` x4, `So.`, `Okay.`, `You.`, `I.`, `and.`,
    // `So, so, so, so, so.` The remaining word-added rows are tails outside the
    // lexicon (`here.`, `1-8?`, `mine.`, `messages.`, `And...`) or
    // mid-transcript block edits, which this gate is not for.
    expect(caught.length).toBeGreaterThanOrEqual(9);
  });
});
