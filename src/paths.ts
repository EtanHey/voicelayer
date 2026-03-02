/**
 * Centralized path constants for VoiceLayer temp files.
 *
 * Uses /tmp (standard on macOS + Linux) — NOT os.tmpdir() which returns
 * /var/folders/... on macOS. We need /tmp because:
 *   1. /tmp exists on both macOS and Linux
 *   2. All legacy docs reference /tmp paths
 *
 * AIDEV-NOTE: Architecture inversion (Phase 0): SOCKET_PATH is now a fixed
 * well-known path. FlowBar listens on it as a persistent server. MCP servers
 * connect as clients. No more discovery file.
 *
 * Per-session random token is still used for STOP_FILE and LOCK_FILE to
 * prevent cross-process spoofing of stop signals.
 *
 * All modules import paths from here to prevent drift.
 */

import { writeFileSync, existsSync, lstatSync } from "fs";
import { randomBytes } from "crypto";

const TMP = "/tmp";

// Simple path join — avoids importing node:path just for concatenation
function tmpPath(name: string): string {
  return `${TMP}/${name}`;
}

/**
 * Per-session random token (16 hex chars = 8 random bytes).
 * Generated once at module load time. Used for stop/lock files.
 */
export const SESSION_TOKEN: string = randomBytes(8).toString("hex");

/** Session lock file — prevents mic conflicts between Claude sessions. */
export const LOCK_FILE = tmpPath(`voicelayer-session-${SESSION_TOKEN}.lock`);

/** Stop signal file — touch to end current recording or playback. */
export const STOP_FILE = tmpPath(`voicelayer-stop-${SESSION_TOKEN}`);

/** Cancel signal file — set alongside STOP_FILE to discard recording (skip transcription). */
export const CANCEL_FILE = tmpPath(`voicelayer-cancel-${SESSION_TOKEN}`);

/** TTS audio file prefix — each speak() call generates a unique file. */
export function ttsFilePath(pid: number, counter: number): string {
  return tmpPath(`voicelayer-tts-${pid}-${counter}.mp3`);
}

/** Recording audio file — temporary WAV for STT transcription. */
export function recordingFilePath(pid: number, timestamp: number): string {
  return tmpPath(`voicelayer-recording-${pid}-${timestamp}.wav`);
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

/**
 * Fixed Unix domain socket path for FlowBar IPC.
 * FlowBar listens here as a persistent server. MCP servers connect as clients.
 */
export const SOCKET_PATH = tmpPath("voicelayer.sock");

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
