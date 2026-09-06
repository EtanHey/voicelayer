/**
 * Loader for the golden clip-B fixture used by the smart-chunking suites.
 *
 * The fixture itself is GITIGNORED on purpose: its anchors are Etan's own
 * speech and this repo is public (AGENTS.md — "whatever ships publicly from
 * here gets a private-data pass first"). Only this loader lives in git, so both
 * suites skip cleanly and loudly wherever the fixture is absent, which includes
 * every CI runner.
 *
 * To enable locally, write `docs.local/goldens/smart-chunking-clip-b.json`:
 *
 *   {
 *     "recordingId":  "<recordings dir id>",
 *     "wav":          "<absolute path to that recording's audio.wav>",
 *     "audioSha256":  "<shasum -a 256 of the WAV>",
 *     "durationSeconds": 109.31,
 *     "minPauses": 20,
 *     "anchors": ["phrase that must survive", ...],
 *     "forbiddenBreaks": [{ "name": "...", "pattern": "<regex>" }]
 *   }
 *
 * Source material for clip B: docs.local/recon-2026-09-05/m2-repro/B/.
 */

import { existsSync, readFileSync } from "fs";
import { join } from "path";

export interface SmartChunkGolden {
  recordingId: string;
  wav: string;
  audioSha256: string;
  durationSeconds: number;
  minPauses: number;
  anchors: string[];
  forbiddenBreaks: Array<{ name: string; pattern: string }>;
}

export const GOLDEN_FIXTURE_PATH = join(
  import.meta.dir,
  "../../docs.local/goldens/smart-chunking-clip-b.json",
);

export function loadSmartChunkGolden(): SmartChunkGolden | null {
  if (!existsSync(GOLDEN_FIXTURE_PATH)) return null;
  const golden = JSON.parse(
    readFileSync(GOLDEN_FIXTURE_PATH, "utf8"),
  ) as SmartChunkGolden;
  return existsSync(golden.wav) ? golden : null;
}
