/**
 * Centralized path constants for VoiceLayer temp files.
 *
 * Uses /tmp (standard on macOS + Linux) — NOT os.tmpdir() which returns
 * /var/folders/... on macOS. We need /tmp because:
 *   1. MCP tool descriptions tell users: "touch /tmp/voicelayer-stop"
 *   2. All docs reference /tmp paths
 *   3. /tmp exists on both macOS and Linux
 *
 * All modules import paths from here to prevent drift.
 */

const TMP = "/tmp";

// Simple path join — avoids importing node:path just for concatenation
function tmpPath(name: string): string {
  return `${TMP}/${name}`;
}

/** Session lock file — prevents mic conflicts between Claude sessions. */
export const LOCK_FILE = tmpPath("voicelayer-session.lock");

/** Stop signal file — touch to end current recording or playback. */
export const STOP_FILE = tmpPath("voicelayer-stop");

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

/** Unix domain socket for Flow Bar IPC — VoiceLayer creates, Flow Bar connects. */
export const SOCKET_PATH = tmpPath("voicelayer.sock");
