/**
 * The ephemeral root for test scratch files.
 *
 * AIDEV-NOTE: R-014. Deliberately does NOT import ../paths: several suites
 * `mock.module("../paths", …)`, and those mocks leak across files in a bun run,
 * so a helper built on the mocked module would answer differently depending on
 * file order. Reads the env the preload set, and falls back to /tmp for a run
 * that bypassed the preload entirely.
 *
 * Self-binding sockets use testSocket() directly under the preload run root.
 * Short basenames leave room for deep worktree paths within macOS sun_path.
 */

import { join, basename } from "path";

export const TEST_TMP: string =
  process.env.VOICELAYER_TMP_ROOT?.trim() || "/tmp";

export function testTmp(...parts: string[]): string {
  return join(TEST_TMP, ...parts);
}

// Independent of ../paths and its cross-suite mocks, like testTmp above.
export function testSocket(name: string): string {
  const root = process.env.VOICELAYER_TEST_RUN_ROOT;
  if (!root || process.env.VOICELAYER_TEST_ISOLATED !== "1") {
    throw new Error("testSocket requires the isolated test preload");
  }
  if (basename(name) !== name || !/^[a-z0-9-]+\.sock$/.test(name)) {
    throw new Error("testSocket requires a short socket basename");
  }
  const socket = join(root, name);
  // Reserve one byte for the terminating NUL in macOS's 104-byte sun_path.
  if (Buffer.byteLength(socket) >= 104) {
    throw new Error(`Test socket path exceeds macOS sun_path: ${socket}; use a shallower worktree`);
  }
  return socket;
}
