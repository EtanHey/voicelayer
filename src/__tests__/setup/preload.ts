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
 * Everything lands under <repo>/.test-tmp/<pid>-<nonce>/ — inside the worktree, never
 * /tmp, so a suite can no longer collide with the resident VoiceBar's files.
 */

import { spawnSync } from "child_process";
import { existsSync, lstatSync, mkdirSync, readdirSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { randomBytes } from "crypto";

const TEST_ROOT = join(process.cwd(), ".test-tmp");
// Four hex characters leave room for TEST1 sockets on deep worktree paths.
// Exclusive mkdir below makes nonce collisions fail safely: never adopt a run.
const RUN_ROOT = join(TEST_ROOT, `${process.pid}-${randomBytes(2).toString("hex")}`);

// Bun 1.3.9 skips exit/beforeExit during `bun test`. Bound abandoned data at
// startup instead: preserve the two newest dead runs for failure investigation.
// Never follow a symlink out of the worktree's test root.
function assertDirectory(path: string): void {
  try {
    const stat = lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error(`[voicelayer] refusing non-directory test root: ${path}`);
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

function isDead(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return false;
  } catch (error) {
    // EPERM and any unknown error are not proof of death.
    return (error as NodeJS.ErrnoException).code === "ESRCH";
  }
}

assertDirectory(TEST_ROOT);
mkdirSync(TEST_ROOT, { recursive: true, mode: 0o700 });
mkdirSync(RUN_ROOT, { mode: 0o700 });
const dead: { path: string; pid: number; modified: number }[] = [];
for (const entry of readdirSync(TEST_ROOT, { withFileTypes: true })) {
  // Also reclaim legacy PID-only directories left by older preloads.
  const match = /^([1-9]\d*)(?:-[a-f0-9]{4,6})?$/.exec(entry.name);
  if (!entry.isDirectory() || !match) continue;
  const pid = Number(match[1]);
  if (!Number.isSafeInteger(pid) || pid > 2147483647 || !isDead(pid)) continue;
  const path = join(TEST_ROOT, entry.name);
  try {
    const stat = lstatSync(path);
    if (stat.isDirectory() && !stat.isSymbolicLink()) {
      dead.push({ path, pid, modified: stat.mtimeMs });
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}
// A dead run's hook-fixture index can still point at live setsid fixtures.
// Reap them through the registry's identity-verified sweep FIRST; a run whose
// index cannot be settled keeps its directory as recovery evidence.
function fixturesSettled(path: string): boolean {
  const index = join(path, "hook-fixtures");
  const pending = () => existsSync(index) && readdirSync(index).some((name) => name.endsWith(".json"));
  if (!pending()) return true;
  const sweeper = join(process.cwd(), "tests", "hook_fixture_registry.py");
  if (!existsSync(sweeper)) return false;
  const result = spawnSync("python3", [sweeper, "--sweep-index", index, process.cwd()], {
    env: process.env, stdio: "ignore", timeout: 30_000,
  });
  return result.status === 0 && !pending();
}

dead.sort((a, b) => b.modified - a.modified || b.pid - a.pid);
const settled = new Set(dead.filter((entry) => fixturesSettled(entry.path)).map((entry) => entry.path));
for (const entry of dead.slice(2)) {
  if (!settled.has(entry.path)) continue;
  try {
    // Recheck liveness/type, but never rely on this to prevent PID reuse:
    // a new generation exclusively creates a different directory, so this
    // deletion can only target the old run. rmSync does not traverse links.
    const stat = lstatSync(entry.path);
    if (stat.isDirectory() && !stat.isSymbolicLink() && isDead(entry.pid)) {
      rmSync(entry.path, { recursive: true, force: true });
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

/** macOS caps sun_path at 104 bytes; a socket longer than this cannot bind. */
const SUN_PATH_MAX = 104;

function setIfUnset(name: string, value: string): void {
  if (!process.env[name]?.trim()) process.env[name] = value;
}

// Always use this process, even when a child inherits its parent preload env.
process.env.VOICELAYER_TEST_RUN_ROOT = RUN_ROOT;
// Never inherit another run's PID lock or honor a resident-path override.
process.env.QA_VOICE_MCP_PID_PATH = join(RUN_ROOT, "voicelayer-mcp.pid");
process.env.VOICELAYER_LOG_ROTATION_DIR = join(RUN_ROOT, "logs");

// Git's repository selectors (GIT_DIR, GIT_COMMON_DIR, GIT_CONFIG, GIT_WORK_TREE,
// GIT_INDEX_FILE, ...) are exported by git hooks and `rebase --exec`. A test
// inheriting them runs its fake-repo `git config` / `git commit` against another
// repository: that is how a "Test User" identity reached the real .git/config
// (2026-09-24). No test needs them, so none inherits them.
for (const key of Object.keys(process.env)) {
  if (key.startsWith("GIT_")) delete process.env[key];
}

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

// Declares the isolation to the live-host guard; an inherited 0 cannot disable it.
process.env.VOICELAYER_TEST_ISOLATED = "1";

// Bun defaults to its STARTUP environment, not process.env after this preload.
// Explicit subset envs must retain the test paths too; caller values cannot
// disable the preload contract. Read current values when each child is spawned.
const isolationKeys = [
  "VOICELAYER_UPDATE_GATE_PATH",
  "VOICELAYER_TEST_ISOLATED", "VOICELAYER_TEST_RUN_ROOT", "QA_VOICE_MCP_PID_PATH",
  "VOICELAYER_LOG_ROTATION_DIR",
  "VOICELAYER_TMP_ROOT", "VOICELAYER_STATE_DIR", "VOICELAYER_CONTROL_LAYER_BASE",
  "VOICELAYER_SOCKET_PATH", "VOICELAYER_MCP_SOCKET_PATH", "QA_VOICE_RECORDINGS_DIR",
  "QA_VOICE_THINK_FILE", "QA_VOICE_STT_VOCABULARY_PATH", "QA_VOICE_STT_COMMANDS_DIR",
  "VOICELAYER_WHISPER_OWNERSHIP_DIR", "QA_VOICE_STT_POLISH_LOG_PATH",
  "QA_VOICE_STT_POLISH_SOCKET", "QA_VOICE_WISPR_DB_PATH", "VOICELAYER_TEST_FAKE_REC",
  "VOICELAYER_TEST_FAKE_REC_BIN", "VOICELAYER_TEST_REAL_MIC", "VOICELAYER_TEST_REAL_ARCHIVE",
] as const;
for (const api of ["spawn", "spawnSync"] as const) {
  const original = Bun[api];
  (Bun[api] as unknown) = ((command: unknown, options?: Record<string, unknown>) => {
    const arrayForm = Array.isArray(command);
    const requested = (arrayForm ? options : command) as { env?: NodeJS.ProcessEnv } | undefined;
    const env = { ...(requested?.env ?? process.env) };
    if (process.env.VOICELAYER_TEST_ISOLATED === "1") {
      for (const key of isolationKeys) env[key] = process.env[key];
    }
    const isolatedOptions = { ...requested, env };
    return arrayForm ? (original as Function)(command, isolatedOptions) : (original as Function)(isolatedOptions);
  }) as unknown;
}

// The two roots every path in src/paths.ts is built from.
setIfUnset("VOICELAYER_TMP_ROOT", join(RUN_ROOT, "tmp"));
setIfUnset("VOICELAYER_STATE_DIR", join(RUN_ROOT, "state"));
// Always replace inherited gates, including a hostile resident-path override.
process.env.VOICELAYER_UPDATE_GATE_PATH = join(RUN_ROOT, "update-gate.json");
// Synthetic quiescent bootstrap for isolated tests only. Production has no fallback.
writeFileSync(process.env.VOICELAYER_UPDATE_GATE_PATH, JSON.stringify({ version: 1, kind: "OPEN", generation: 0, released: null }));
mkdirSync(process.env.VOICELAYER_UPDATE_GATE_PATH + ".admissions", { mode: 0o700 });

// Fleet journal DB and markers must not fall back to ~/.local/share/orc.
setIfUnset("VOICELAYER_CONTROL_LAYER_BASE", join(RUN_ROOT, "orc"));

// Sockets: redirected explicitly as well as via the root, because
// isDefaultVoiceBarSocketPath()/isDefaultMcpSocketPath() key off these names —
// and shouldAcceptVoiceBarCommands() needs both sides to agree.
// Canonical names win over QA_VOICE_* aliases in src/paths.ts. Filling them
// here is deliberate: a leftover QA_VOICE_SOCKET_PATH pointing at the live
// VoiceBar must not win. A caller who already set VOICELAYER_SOCKET_PATH keeps
// it (setIfUnset). To isolate via the alias alone, also set the canonical name.
setIfUnset("VOICELAYER_SOCKET_PATH", voiceBarSocket);
setIfUnset("VOICELAYER_MCP_SOCKET_PATH", mcpSocket);

// The recordings archive (src/input.ts:767) resolves from $HOME, not from the
// roots above, so it needs its own redirect.
setIfUnset("QA_VOICE_RECORDINGS_DIR", join(RUN_ROOT, "recordings"));

// Thinking-mode log (src/handlers.ts) — same reason.
setIfUnset("QA_VOICE_THINK_FILE", join(RUN_ROOT, "thinking.md"));

// These modules resolve their own home-directory defaults instead of paths.ts.
setIfUnset("QA_VOICE_STT_VOCABULARY_PATH", join(RUN_ROOT, "vocabulary.json"));
setIfUnset("QA_VOICE_STT_COMMANDS_DIR", join(RUN_ROOT, "commands"));
setIfUnset("VOICELAYER_WHISPER_OWNERSHIP_DIR", join(RUN_ROOT, "state"));
setIfUnset("QA_VOICE_STT_POLISH_LOG_PATH", join(RUN_ROOT, "polish-shadow.jsonl"));
setIfUnset("QA_VOICE_STT_POLISH_SOCKET", join(RUN_ROOT, "p.sock"));
setIfUnset("QA_VOICE_WISPR_DB_PATH", join(RUN_ROOT, "wispr.sqlite"));

// No test opens the real microphone unless it asks for it by name.
// REAL_MIC is the only opt-in; a leftover VOICELAYER_TEST_FAKE_REC=0 must not
// disable the stub (that would be setIfUnset swallowing the isolation contract).
if (process.env.VOICELAYER_TEST_REAL_MIC?.trim() !== "1") {
  process.env.VOICELAYER_TEST_FAKE_REC = "1";
}
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
