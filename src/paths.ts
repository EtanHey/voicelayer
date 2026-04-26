/**
 * Centralized path constants for VoiceLayer temp files.
 *
 * Uses /tmp for ephemeral runtime files (audio, sockets, history).
 * Uses ~/.local/state/voicelayer/ for security-sensitive files (stop/cancel
 * signals, session locks) — /tmp is world-writable and vulnerable to symlink
 * attacks even with safeWriteFileSync guards.
 *
 * AIDEV-NOTE: Architecture inversion (Phase 0): SOCKET_PATH is now a fixed
 * well-known path. VoiceBar listens on it as a persistent server. MCP servers
 * connect as clients. No more discovery file.
 *
 * Per-session random token is still used for STOP_FILE and LOCK_FILE to
 * prevent cross-process spoofing of stop signals.
 *
 * All modules import paths from here to prevent drift.
 */

import { writeFileSync, existsSync, lstatSync, mkdirSync } from "fs";
import { randomBytes } from "crypto";
import { homedir } from "os";
import { join } from "path";

const TMP = "/tmp";
const VOICE_DISABLED_OVERRIDE_ENV = "QA_VOICE_DISABLE_FLAG_PATH";
const MCP_SOCKET_OVERRIDE_ENV = "QA_VOICE_MCP_SOCKET_PATH";
const RETAINED_RECORDING_OVERRIDE_ENV = "QA_VOICE_RETAINED_RECORDING_PATH";
export const DISABLE_VOICELAYER = "DISABLE_VOICELAYER";

/**
 * User-owned state directory for security-sensitive files.
 * ~/.local/state/voicelayer/ — only writable by the current user,
 * unlike /tmp which is world-writable.
 */
export const STATE_DIR = join(homedir(), ".local", "state", "voicelayer");

// Ensure state directory exists on module load
mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });

// Simple path join — avoids importing node:path just for concatenation
function tmpPath(name: string): string {
  return `${TMP}/${name}`;
}

function readOverride(
  name: string,
  fallback: string,
  env: NodeJS.ProcessEnv = process.env,
): string {
  const value = env[name]?.trim();
  return value ? value : fallback;
}

/**
 * Per-session random token (16 hex chars = 8 random bytes).
 * Generated once at module load time. Used for stop/lock files.
 */
export const SESSION_TOKEN: string = randomBytes(8).toString("hex");

/** Session lock file — prevents mic conflicts between Claude sessions. */
export const LOCK_FILE = tmpPath(`voicelayer-session-${SESSION_TOKEN}.lock`);

/** Stop signal file — touch to end current recording or playback. In STATE_DIR (not /tmp) to prevent symlink attacks. */
export const STOP_FILE = join(STATE_DIR, `stop-${SESSION_TOKEN}`);

/** Cancel signal file — set alongside STOP_FILE to discard recording (skip transcription). */
export const CANCEL_FILE = join(STATE_DIR, `cancel-${SESSION_TOKEN}`);

/** TTS audio file prefix — each speak() call generates a unique file. */
export function ttsFilePath(pid: number, counter: number): string {
  return tmpPath(`voicelayer-tts-${pid}-${counter}.mp3`);
}

/** Recording audio file — temporary WAV for STT transcription. */
export function recordingFilePath(pid: number, timestamp: number): string {
  return tmpPath(`voicelayer-recording-${pid}-${timestamp}.wav`);
}

/** Retained WAV for "retranscribe last capture". */
export function retainedRecordingFilePath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  return readOverride(
    RETAINED_RECORDING_OVERRIDE_ENV,
    tmpPath("voicelayer-last-recording.wav"),
    env,
  );
}

/** Ring buffer history file — JSON array of last 20 TTS entries. */
export const TTS_HISTORY_FILE = tmpPath("voicelayer-history.json");

/** Ring buffer audio file — persistent MP3 for replay. */
export function ttsHistoryFilePath(index: number): string {
  return tmpPath(`voicelayer-history-${index}.mp3`);
}

/** TTS disabled flag file — when present, TTS output is suppressed. */
export const TTS_DISABLED_FILE = tmpPath(".claude_tts_disabled");

/** Mic disabled flag file — when present, mic recording is suppressed. */
export const MIC_DISABLED_FILE = tmpPath(".claude_mic_disabled");

/** Combined voice disabled flag — checked by CC PreToolUse hook to block all voice tools. */
export const VOICE_DISABLED_FILE = tmpPath(".claude_voice_disabled");

/** Dedicated daemon disable flag — polled by the MCP daemon to exit cleanly. */
export function getVoiceDisabledFilePath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  return readOverride(
    VOICE_DISABLED_OVERRIDE_ENV,
    tmpPath(".voicelayer-daemon-disabled"),
    env,
  );
}

export function isVoicelayerDisabled(options?: {
  env?: NodeJS.ProcessEnv;
  flagFilePath?: string;
}): boolean {
  const env = options?.env ?? process.env;
  if (env[DISABLE_VOICELAYER]?.trim() === "1") {
    return true;
  }
  const flagFilePath = options?.flagFilePath ?? getVoiceDisabledFilePath(env);
  return existsSync(flagFilePath);
}

/**
 * Fixed Unix domain socket path for VoiceBar IPC.
 * VoiceBar listens here as a persistent server. MCP servers connect as clients.
 */
export const SOCKET_PATH = tmpPath("voicelayer.sock");

/**
 * MCP daemon socket path.
 * The daemon listens here for MCP clients (via socat).
 * Separate from SOCKET_PATH so Voice Bar can keep serving on voicelayer.sock.
 */
export function getMcpSocketPath(env: NodeJS.ProcessEnv = process.env): string {
  return readOverride(MCP_SOCKET_OVERRIDE_ENV, tmpPath("voicelayer-mcp.sock"), env);
}

export const MCP_SOCKET_PATH = getMcpSocketPath();

/**
 * Standalone daemon PID file.
 * Separate from MCP_PID_FILE so daemon and MCP can coexist.
 */
export const DAEMON_PID_FILE = tmpPath("voicelayer-daemon.pid");

/**
 * Safe write that refuses to follow symlinks.
 * Prevents symlink attacks on predictable /tmp paths (S1 security fix).
 */
export function safeWriteFileSync(filePath: string, content: string): void {
  if (existsSync(filePath)) {
    try {
      const stat = lstatSync(filePath);
      if (stat.isSymbolicLink()) {
        console.error(
          `[voicelayer] Refusing to write: ${filePath} is a symlink`,
        );
        return;
      }
    } catch {}
  }
  writeFileSync(filePath, content, { mode: 0o600 });
}
