/**
 * Centralized path constants for VoiceLayer temp files.
 *
 * Uses /tmp (standard on macOS + Linux) — NOT os.tmpdir() which returns
 * /var/folders/... on macOS. We need /tmp because:
 *   1. /tmp exists on both macOS and Linux
 *   2. All legacy docs reference /tmp paths
 *   3. Discovery file at well-known /tmp/voicelayer-session.json lets
 *      Voice Bar find the per-session socket/stop paths.
 *
 * AIDEV-NOTE: Per-session random token prevents cross-process spoofing of
 * stop signals and socket connections. Voice Bar reads the discovery file
 * to find the correct session paths.
 *
 * All modules import paths from here to prevent drift.
 */

import { writeFileSync, unlinkSync, existsSync } from "fs";
import { randomBytes } from "crypto";

const TMP = "/tmp";

// Simple path join — avoids importing node:path just for concatenation
function tmpPath(name: string): string {
  return `${TMP}/${name}`;
}

/**
 * Per-session random token (16 hex chars = 8 random bytes).
 * Generated once at module load time. All session-specific paths use this.
 */
export const SESSION_TOKEN: string = randomBytes(8).toString("hex");

/** Session lock file — prevents mic conflicts between Claude sessions. */
export const LOCK_FILE = tmpPath(`voicelayer-session-${SESSION_TOKEN}.lock`);

/** Stop signal file — touch to end current recording or playback. */
export const STOP_FILE = tmpPath(`voicelayer-stop-${SESSION_TOKEN}`);

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

/** Unix domain socket for Voice Bar IPC — per-session to prevent spoofing. */
export const SOCKET_PATH = tmpPath(`voicelayer-${SESSION_TOKEN}.sock`);

/**
 * Well-known discovery file — Voice Bar reads this to find the current
 * session's socket path, stop file path, and token.
 */
export const DISCOVERY_FILE = tmpPath("voicelayer-session.json");

/** Write the discovery file so Voice Bar can find this session. */
export function writeDiscoveryFile(): void {
  writeFileSync(
    DISCOVERY_FILE,
    JSON.stringify(
      {
        socketPath: SOCKET_PATH,
        stopFile: STOP_FILE,
        sessionToken: SESSION_TOKEN,
        pid: process.pid,
        startedAt: new Date().toISOString(),
      },
      null,
      2,
    ),
  );
}

/** Remove the discovery file on shutdown. */
export function removeDiscoveryFile(): void {
  if (existsSync(DISCOVERY_FILE)) {
    try {
      unlinkSync(DISCOVERY_FILE);
    } catch {}
  }
}
