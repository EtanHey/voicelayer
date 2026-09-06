/**
 * Loader for the pause-aware-boundary golden clip.
 *
 * The fixture is GITIGNORED on purpose: it points at Etan's own speech and this
 * repo is public (AGENTS.md — "whatever ships publicly from here gets a
 * private-data pass first"). Only this loader lives in git, so the suite skips
 * cleanly and loudly wherever the fixture is absent, including every CI runner.
 * Same pattern as `smart-chunk-golden-fixture.ts` (PR #21).
 *
 * To enable locally, write `docs.local/goldens/pause-aware-boundaries.json`:
 *
 *   {
 *     "recordingId": "2026-09-06T12-56-44-855Z-28f3916c",
 *     "wav": "<absolute path to that recording's audio.wav>",
 *     "audioSha256": "<shasum -a 256 of the WAV>",
 *     "durationSeconds": 40.45,
 *     "shippedText": "<the polished text VoiceLayer actually delivered>",
 *     "mustNotBreakAfter": ["words"],
 *     "mustBreakAfter": ["on", "itself"],
 *     "expectedDemotions": [
 *       { "word": "words", "reason": "continues-clause" }
 *     ]
 *   }
 *
 * Source material: docs.local/recon-2026-09-06/ and the shadow row at
 * ~/.voicelayer/eval/polish-shadow.jsonl created_at 2026-09-06T12:56:44.761Z.
 */

import { existsSync, readFileSync } from "fs";
import { join } from "path";

export interface PauseBoundaryGolden {
  recordingId: string;
  wav: string;
  audioSha256: string;
  durationSeconds: number;
  /** The text VoiceLayer shipped, i.e. the input this stage has to correct. */
  shippedText: string;
  /** Words that must NOT be followed by a terminal mark in the output. */
  mustNotBreakAfter: string[];
  /** Words whose terminal mark must survive — the pause is really there. */
  mustBreakAfter: string[];
  expectedDemotions: Array<{ word: string; reason: string }>;
}

export const PAUSE_BOUNDARY_FIXTURE_PATH = join(
  import.meta.dir,
  "../../docs.local/goldens/pause-aware-boundaries.json",
);

export function loadPauseBoundaryGolden(): PauseBoundaryGolden | null {
  if (!existsSync(PAUSE_BOUNDARY_FIXTURE_PATH)) return null;
  const golden = JSON.parse(
    readFileSync(PAUSE_BOUNDARY_FIXTURE_PATH, "utf8"),
  ) as PauseBoundaryGolden;
  return existsSync(golden.wav) ? golden : null;
}
