/**
 * The ephemeral root for test scratch files.
 *
 * AIDEV-NOTE: R-014. Deliberately does NOT import ../paths: several suites
 * `mock.module("../paths", …)`, and those mocks leak across files in a bun run,
 * so a helper built on the mocked module would answer differently depending on
 * file order. Reads the env the preload set, and falls back to /tmp for a run
 * that bypassed the preload entirely.
 *
 * Unix domain sockets that a suite binds itself still live under `/tmp`:
 * macOS caps sun_path at 104 bytes and this worktree's own path already spends
 * 68 of them, so a long fixture under the run root cannot bind. Those fixtures
 * are named `*-test-*.sock` and never collide with the live `/tmp/voicelayer.sock`.
 * The preload's own VoiceBar/MCP sockets are short (`v.sock`/`m.sock`) under
 * `.test-tmp/<pid>/`.
 */

import { join } from "path";

export const TEST_TMP: string =
  process.env.VOICELAYER_TMP_ROOT?.trim() || "/tmp";

export function testTmp(...parts: string[]): string {
  return join(TEST_TMP, ...parts);
}
