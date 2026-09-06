/**
 * The gold specimen, through the real path: real WAV -> Silero pause map ->
 * whisper segments from an isolated whisper-server -> the boundary stage.
 *
 * Recording `2026-09-06T12-56-44-855Z-28f3916c` (40.4 s). Etan said
 * "...i'm thinking [2.3 s] of the next couple of words i guess [2.7 s] like i
 * just did now" and VoiceLayer shipped the period BEFORE "I guess", where he
 * never stopped.
 *
 * The fixture is gitignored (`pause-boundary-golden-fixture.ts` explains why),
 * so this suite skips loudly wherever it is absent, including CI.
 *
 * AIDEV-NOTE: this suite allocates its OWN whisper port and asserts the live
 * :8178 listener is untouched. On 8178 whisper-server's stale-orphan branch
 * SIGKILLs the daily driver's resident server — that happened on 2026-09-05
 * (docs.local/recon-2026-09-05/m2-repro/SURPRISE-whisper-server-killed.md).
 */

import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { createHash } from "crypto";
import { readFileSync } from "fs";
import { allocateFreeLocalhostPort } from "../corpus-replay-verify";
import { WhisperCppBackend } from "../stt";
import { computePauseMap } from "../stt-pause-map";
import {
  applyPauseAwareBoundaries,
  type TranscriptSegment,
} from "../stt-sentence-boundaries";
import { stopServer, transcribeViaServer } from "../whisper-server";
import {
  loadPauseBoundaryGolden,
  PAUSE_BOUNDARY_FIXTURE_PATH,
  type PauseBoundaryGolden,
} from "./pause-boundary-golden-fixture";

const optedIn = process.env.VOICELAYER_PAUSE_BOUNDARY_GOLDEN === "1";
const golden = loadPauseBoundaryGolden();
const modelInfo = new WhisperCppBackend().getModelInfo();
const hasWhisper = Boolean(modelInfo.binary && modelInfo.model);
const ready = optedIn && Boolean(golden) && hasWhisper;

if (!ready) {
  console.error(
    `[pause-boundary-golden] SKIPPING — ${[
      optedIn ? null : "VOICELAYER_PAUSE_BOUNDARY_GOLDEN=1 not set",
      golden ? null : `no fixture at ${PAUSE_BOUNDARY_FIXTURE_PATH}`,
      hasWhisper ? null : "no whisper binary/model",
    ]
      .filter(Boolean)
      .join("; ")}.`,
  );
}
const goldenTest = ready ? test : test.skip;

function liveWhisperListenerPids(): string {
  const probe = Bun.spawnSync(
    ["lsof", "-nP", "-iTCP:8178", "-sTCP:LISTEN", "-t"],
    { stdout: "pipe", stderr: "ignore" },
  );
  return probe.stdout
    .toString()
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .sort()
    .join(",");
}

/** True when a terminal mark directly follows `word` in `text`. */
function breaksAfter(text: string, word: string): boolean {
  return new RegExp(`\\b${word}\\b\\s*[.!?]`, "iu").test(text);
}

let livePidsBefore = "";
let corrected: {
  text: string;
  demotions: Array<{ word: string; reason: string }>;
};
let pauseCount = 0;
let segmentCount = 0;

beforeAll(async () => {
  if (!ready) return;
  const fixture = golden as PauseBoundaryGolden;

  livePidsBefore = liveWhisperListenerPids();
  const port = await allocateFreeLocalhostPort();
  if (port === 8178)
    throw new Error("refusing to run on the live whisper port");
  process.env.QA_VOICE_WHISPER_SERVER_PORT = String(port);
  console.error(
    `[pause-boundary-golden] isolated whisper-server port ${port}; live :8178 = ${
      livePidsBefore || "none"
    }`,
  );

  const wav = new Uint8Array(readFileSync(fixture.wav));
  const digest = createHash("sha256").update(wav).digest("hex");
  if (digest !== fixture.audioSha256) {
    throw new Error(
      `golden WAV changed: expected ${fixture.audioSha256}, got ${digest}`,
    );
  }

  const pauses = await computePauseMap(wav);
  pauseCount = pauses.length;

  let segments: TranscriptSegment[] = [];
  await transcribeViaServer(wav, port, {
    onSegments: (found) => {
      segments = found;
    },
  });
  segmentCount = segments.length;

  corrected = applyPauseAwareBoundaries(fixture.shippedText, segments, pauses);
  console.error(
    `[pause-boundary-golden] ${pauseCount} pauses, ${segmentCount} segments, ` +
      `${corrected.demotions.length} demotions\n  IN:  ${fixture.shippedText}\n  OUT: ${corrected.text}`,
  );
}, 600_000);

afterAll(() => {
  if (!ready) return;
  stopServer();
  const after = liveWhisperListenerPids();
  console.error(
    `[pause-boundary-golden] live :8178 after = ${after || "none"} (before = ${
      livePidsBefore || "none"
    })`,
  );
});

describe("pause-aware boundaries on the gold specimen", () => {
  goldenTest("the pause map and the segments both have content", () => {
    expect(pauseCount).toBeGreaterThan(0);
    expect(segmentCount).toBeGreaterThan(0);
    expect(corrected.skippedReason).toBeUndefined();
  });

  goldenTest("the period Etan never spoke is gone", () => {
    const fixture = golden as PauseBoundaryGolden;
    for (const word of fixture.mustNotBreakAfter) {
      expect(breaksAfter(fixture.shippedText, word)).toBe(true); // RED before
      expect(breaksAfter(corrected.text, word)).toBe(false); // GREEN after
    }
  });

  goldenTest("a break on a real pause survives", () => {
    const fixture = golden as PauseBoundaryGolden;
    for (const word of fixture.mustBreakAfter) {
      expect(breaksAfter(corrected.text, word)).toBe(true);
    }
  });

  goldenTest("the demotions are exactly the expected ones", () => {
    const fixture = golden as PauseBoundaryGolden;
    expect(
      corrected.demotions.map(({ word, reason }) => ({
        word: word.toLowerCase(),
        reason,
      })),
    ).toEqual(
      fixture.expectedDemotions.map(({ word, reason }) => ({
        word: word.toLowerCase(),
        reason,
      })),
    );
  });

  goldenTest("not one of Etan's words is lost", () => {
    const fixture = golden as PauseBoundaryGolden;
    const words = (text: string): string[] =>
      (text.toLowerCase().match(/[\p{L}\p{N}'’]+/gu) ?? []).map((word) =>
        word.replace(/’/g, "'"),
      );
    expect(words(corrected.text)).toEqual(words(fixture.shippedText));
  });

  goldenTest("the isolated run never touched the live :8178 listener", () => {
    expect(liveWhisperListenerPids()).toBe(livePidsBefore);
  });
});
