/**
 * Test preload — runs before any test module is imported.
 *
 * AIDEV-NOTE: R-014 (test isolation on a live host). `src/paths.ts` freezes most
 * of its exports at module load (STOP_FILE, CANCEL_FILE, LOCK_FILE, SOCKET_PATH,
 * the ring-buffer paths), so the redirection has to be in place BEFORE the first
 * import of it — which is exactly what a bun `--preload` guarantees and what a
 * `beforeAll` cannot. Wired from `bunfig.toml`; do not move this into a helper a
 * test imports.
 *
 * Everything lands under <repo>/.test-tmp/<pid>/ — inside the worktree, never
 * /tmp, so a suite can no longer collide with the resident VoiceBar's files.
 */

import { mkdirSync, rmSync } from "fs";
import { join } from "path";

const RUN_ROOT = join(process.cwd(), ".test-tmp", String(process.pid));

/** macOS caps sun_path at 104 bytes; a socket longer than this cannot bind. */
const SUN_PATH_MAX = 104;

function setIfUnset(name: string, value: string): void {
  if (!process.env[name]?.trim()) process.env[name] = value;
}

mkdirSync(RUN_ROOT, { recursive: true, mode: 0o700 });

// Short basenames: the run root is already deep, and sun_path is 104 bytes.
const voiceBarSocket = join(RUN_ROOT, "v.sock");
const mcpSocket = join(RUN_ROOT, "m.sock");

for (const socket of [voiceBarSocket, mcpSocket]) {
  if (Buffer.byteLength(socket) > SUN_PATH_MAX) {
    console.error(
      `[voicelayer] test socket path is ${Buffer.byteLength(socket)} bytes ` +
        `(> ${SUN_PATH_MAX}); binds will fail: ${socket}. ` +
        `Use a shallower worktree path.`,
    );
  }
}

// Declares the isolation to the live-host guard.
setIfUnset("VOICELAYER_TEST_ISOLATED", "1");

// The two roots every path in src/paths.ts is built from.
setIfUnset("VOICELAYER_TMP_ROOT", join(RUN_ROOT, "tmp"));
setIfUnset("VOICELAYER_STATE_DIR", join(RUN_ROOT, "state"));

// Sockets: redirected explicitly as well as via the root, because
// isDefaultVoiceBarSocketPath()/isDefaultMcpSocketPath() key off these names —
// and shouldAcceptVoiceBarCommands() needs both sides to agree.
setIfUnset("VOICELAYER_SOCKET_PATH", voiceBarSocket);
setIfUnset("VOICELAYER_MCP_SOCKET_PATH", mcpSocket);

// The recordings archive (src/input.ts:767) resolves from $HOME, not from the
// roots above, so it needs its own redirect.
setIfUnset("QA_VOICE_RECORDINGS_DIR", join(RUN_ROOT, "recordings"));

// Thinking-mode log (src/handlers.ts) — same reason.
setIfUnset("QA_VOICE_THINK_FILE", join(RUN_ROOT, "thinking.md"));

// No test opens the real microphone unless it asks for it by name.
setIfUnset("VOICELAYER_TEST_FAKE_REC", "1");
setIfUnset(
  "VOICELAYER_TEST_FAKE_REC_BIN",
  join(process.cwd(), "src", "__tests__", "setup", "fake-rec.sh"),
);

for (const dir of [
  process.env.VOICELAYER_TMP_ROOT,
  process.env.VOICELAYER_STATE_DIR,
  process.env.QA_VOICE_RECORDINGS_DIR,
]) {
  if (dir) mkdirSync(dir, { recursive: true, mode: 0o700 });
}

process.on("exit", () => {
  if (process.env.VOICELAYER_TEST_KEEP_TMP?.trim() === "1") return;
  try {
    rmSync(RUN_ROOT, { recursive: true, force: true });
  } catch {}
});
