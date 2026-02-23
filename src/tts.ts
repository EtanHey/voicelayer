/**
 * TTS module — three-tier voice synthesis with ring buffer replay.
 *
 * Tier 1: Cloned voices → Qwen3-TTS daemon (localhost:8880)
 * Tier 2: Preset/default → edge-tts (Python CLI)
 * Tier 3: Text-only fallback (when no audio output possible)
 *
 * Plays via afplay (macOS) or mpv/ffplay/mpg123 (Linux).
 * Supports per-call rate override, auto-slowdown for long text,
 * and non-blocking playback (returns immediately after synthesis).
 *
 * Ring buffer: last 20 synthesized audio files are cached for replay.
 */

// AIDEV-NOTE: Barge-in (interrupting TTS to start recording) explicitly not implemented.
// skhd hotkey (ctrl+alt-s → pkill afplay) is the stop UX. See Phase 2 spec.

import {
  existsSync,
  readFileSync,
  writeFileSync,
  copyFileSync,
  unlinkSync,
} from "fs";
import { platform } from "os";
import {
  STOP_FILE,
  ttsFilePath,
  TTS_HISTORY_FILE,
  ttsHistoryFilePath,
  TTS_DISABLED_FILE,
} from "./paths";
import { hasClonedProfile, synthesizeCloned, loadProfile } from "./tts/qwen3";

const DEFAULT_VOICE = process.env.QA_VOICE_TTS_VOICE || "en-US-JennyNeural";
const DEFAULT_RATE = process.env.QA_VOICE_TTS_RATE || "+0%";
const RING_BUFFER_SIZE = 20;

// --- Voice Profiles ---

interface VoiceProfile {
  engine: string; // "edge-tts" | "kokoro" | future engines
  voice: string; // edge-tts voice name (e.g., "en-US-JennyNeural")
}

const VOICES_FILE = `${process.env.HOME}/.voicelayer/voices.json`;

let voiceProfilesCache: Record<string, VoiceProfile> | null = null;

function loadVoiceProfiles(): Record<string, VoiceProfile> {
  if (voiceProfilesCache) return voiceProfilesCache;
  try {
    if (!existsSync(VOICES_FILE)) return {};
    const raw: unknown = JSON.parse(readFileSync(VOICES_FILE, "utf-8"));
    if (!raw || typeof raw !== "object") return {};
    voiceProfilesCache = raw as Record<string, VoiceProfile>;
    return voiceProfilesCache;
  } catch {
    return {};
  }
}

/**
 * Resolve a voice name for TTS synthesis.
 *
 * Three-tier resolution:
 *   1. Cloned voice profile (profile.yaml in ~/.voicelayer/voices/{name}/) → engine: "cloned"
 *   2. Preset voice profile (voices.json) or raw edge-tts name → engine: "edge-tts"
 *   3. Unknown → default edge-tts with warning
 *
 * Returns { voice, engine, warning?, fallbackVoice? }.
 */
export function resolveVoice(name?: string): {
  voice: string;
  engine: "cloned" | "edge-tts";
  warning?: string;
  fallbackVoice?: string;
} {
  if (!name) return { voice: DEFAULT_VOICE, engine: "edge-tts" };

  // Tier 1: Check for cloned voice profile (profile.yaml)
  if (hasClonedProfile(name)) {
    const profile = loadProfile(name);
    return {
      voice: name,
      engine: "cloned",
      fallbackVoice: profile?.fallback || DEFAULT_VOICE,
    };
  }

  // Tier 2: Check preset profiles (voices.json)
  const profiles = loadVoiceProfiles();
  const profile = profiles[name.toLowerCase()];
  if (profile) {
    if (profile.engine !== "edge-tts") {
      return {
        voice: DEFAULT_VOICE,
        engine: "edge-tts",
        warning: `Voice profile "${name}" uses engine "${profile.engine}" which is not yet supported. Using default.`,
      };
    }
    return { voice: profile.voice, engine: "edge-tts" };
  }

  // Tier 2b: Raw edge-tts voice name (e.g., "en-US-AndrewNeural")
  if (/^[a-z]{2}-[A-Z]{2}-/i.test(name)) {
    return { voice: name, engine: "edge-tts" };
  }

  // Unknown name — fallback with warning
  return {
    voice: DEFAULT_VOICE,
    engine: "edge-tts",
    warning: `Unknown voice "${name}". Using default (${DEFAULT_VOICE}). Add it to ~/.voicelayer/voices.json or use a raw edge-tts voice name.`,
  };
}

let ttsCounter = 0;

/** Currently playing audio process — stored for stop/cleanup. */
let currentPlayback: {
  proc: ReturnType<typeof Bun.spawn>;
  pid: number;
} | null = null;

/** Get platform-appropriate audio player command for MP3 files. */
function getAudioPlayer(): string {
  if (platform() === "darwin") return "afplay";
  // Linux: aplay only supports WAV — need mpv, ffplay, or mpg123 for MP3
  for (const player of ["mpv", "ffplay", "mpg123"]) {
    const check = Bun.spawnSync(["which", player]);
    if (check.exitCode === 0) return player;
  }
  return "mpg123"; // fallback — will give clear error if missing
}

/** Per-mode default rates. Announce is snappy, brief is slow for digestion. */
export const MODE_RATES: Record<string, string> = {
  announce: "+10%",
  brief: "-10%",
  consult: "+5%",
  converse: "+0%",
};

/**
 * Auto-adjust rate for long text. Subtracts percentage points for longer content.
 * Returns the adjusted rate string (e.g., "-10%" → "-20%" for 800-char text).
 */
function adjustRateForLength(baseRate: string, textLength: number): string {
  if (textLength < 300) return baseRate;

  const base = parseInt(baseRate, 10) || 0;
  let adjustment = 0;
  if (textLength >= 1000) adjustment = -15;
  else if (textLength >= 600) adjustment = -10;
  else adjustment = -5;

  const final = base + adjustment;
  return `${final >= 0 ? "+" : ""}${final}%`;
}

// --- Ring Buffer ---

export interface TTSHistoryEntry {
  id: number; // 0-19 circular
  file: string; // /tmp/voicelayer-history-N.mp3
  text: string; // original message
  voice: string; // which voice was used
  timestamp: number; // Date.now()
}

let ringIndex = 0;

/** Load ring buffer from disk. Returns empty array if file missing/corrupt. */
export function loadHistory(): TTSHistoryEntry[] {
  if (!existsSync(TTS_HISTORY_FILE)) return [];
  try {
    const raw: unknown = JSON.parse(readFileSync(TTS_HISTORY_FILE, "utf-8"));
    if (!Array.isArray(raw)) return [];
    return raw as TTSHistoryEntry[];
  } catch {
    return [];
  }
}

/** Save ring buffer to disk. */
function saveHistory(entries: TTSHistoryEntry[]): void {
  writeFileSync(TTS_HISTORY_FILE, JSON.stringify(entries, null, 2));
}

/** Add an entry to the ring buffer. Overwrites oldest when full. */
function addToHistory(text: string, audioFile: string, voice: string): void {
  const entries = loadHistory();
  const id = ringIndex % RING_BUFFER_SIZE;
  const historyFile = ttsHistoryFilePath(id);

  // Copy audio file to persistent ring buffer slot
  try {
    copyFileSync(audioFile, historyFile);
  } catch {
    return; // If copy fails, skip history entry
  }

  const entry: TTSHistoryEntry = {
    id,
    file: historyFile,
    text,
    voice,
    timestamp: Date.now(),
  };

  // Find existing entry with same id and replace, or push new
  const existingIdx = entries.findIndex((e) => e.id === id);
  if (existingIdx >= 0) {
    entries[existingIdx] = entry;
  } else {
    entries.push(entry);
  }

  saveHistory(entries);
  ringIndex++;
}

/** Get a history entry by recency index (0 = most recent). */
export function getHistoryEntry(index: number = 0): TTSHistoryEntry | null {
  const entries = loadHistory();
  if (entries.length === 0) return null;

  // Sort by timestamp descending (most recent first)
  const sorted = [...entries].sort((a, b) => b.timestamp - a.timestamp);
  if (index < 0 || index >= sorted.length) return null;
  return sorted[index];
}

/** Check if TTS is disabled via flag file. */
export function isTTSDisabled(): boolean {
  return existsSync(TTS_DISABLED_FILE);
}

/** Play an audio file non-blocking. Returns the spawned process. */
export function playAudioNonBlocking(
  audioFile: string,
): ReturnType<typeof Bun.spawn> {
  const player = getAudioPlayer();
  const proc = Bun.spawn([player, audioFile], {
    stdout: "ignore",
    stderr: "ignore",
  });
  currentPlayback = { proc, pid: proc.pid };

  // Clean up reference when playback finishes
  proc.exited.then(() => {
    if (currentPlayback?.pid === proc.pid) {
      currentPlayback = null;
    }
  });

  return proc;
}

/** Stop current playback if any. */
export function stopPlayback(): boolean {
  if (currentPlayback) {
    try {
      currentPlayback.proc.kill("SIGTERM");
      currentPlayback = null;
      return true;
    } catch {
      currentPlayback = null;
    }
  }
  return false;
}

/**
 * Speak text aloud via three-tier TTS:
 *   1. Cloned voice → Qwen3-TTS daemon (localhost:8880)
 *   2. Preset/default → edge-tts (Python CLI)
 *   3. Text-only (on failure)
 *
 * NON-BLOCKING: Returns as soon as synthesis is done. Audio plays in background.
 * The audio file is saved to the ring buffer for replay.
 *
 * @param text - Text to speak
 * @param options.rate - Rate override (e.g., "-10%", "+5%"). If omitted, uses DEFAULT_RATE.
 * @param options.mode - Voice mode name for auto-rate selection (announce/brief/consult/converse).
 * @param options.voice - Voice name (profile name or raw edge-tts voice). If omitted, uses default.
 * @param options.waitForPlayback - If true, wait for audio playback to finish (used in converse mode before recording).
 */
export async function speak(
  text: string,
  options?: {
    rate?: string;
    mode?: string;
    voice?: string;
    waitForPlayback?: boolean;
  },
): Promise<{ warning?: string }> {
  if (!text?.trim()) return {};

  // Check if TTS is disabled
  if (isTTSDisabled()) {
    console.error("[voicelayer] TTS disabled via flag file — skipping speech");
    return {};
  }

  // Resolve voice — determines engine (cloned vs edge-tts)
  const resolved = resolveVoice(options?.voice);

  // Tier 1: Cloned voice → try Qwen3-TTS daemon
  if (resolved.engine === "cloned") {
    const audioBuffer = await synthesizeCloned(text, resolved.voice);
    if (audioBuffer) {
      // Write MP3 buffer to temp file for playback
      const ttsFile = ttsFilePath(process.pid, ttsCounter++);
      writeFileSync(ttsFile, audioBuffer);

      addToHistory(text, ttsFile, `cloned:${resolved.voice}`);
      const proc = playAudioNonBlocking(ttsFile);
      proc.exited.then(() => {
        try {
          unlinkSync(ttsFile);
        } catch {}
      });
      if (options?.waitForPlayback) await proc.exited;
      return { warning: resolved.warning };
    }

    // Daemon unavailable — fall back to edge-tts with profile's fallback voice
    console.error(
      `[voicelayer] Cloned voice "${resolved.voice}" daemon unavailable — falling back to edge-tts (${resolved.fallbackVoice})`,
    );
    return speakWithEdgeTTS(
      text,
      resolved.fallbackVoice || DEFAULT_VOICE,
      options,
    );
  }

  // Tier 2: Preset/default → edge-tts
  return speakWithEdgeTTS(text, resolved.voice, options, resolved.warning);
}

/**
 * Synthesize and play via edge-tts (Python CLI).
 * Extracted from speak() to allow fallback from cloned voice failure.
 */
async function speakWithEdgeTTS(
  text: string,
  voice: string,
  options?: { rate?: string; mode?: string; waitForPlayback?: boolean },
  warning?: string,
): Promise<{ warning?: string }> {
  // Determine rate: explicit > mode default > env default
  let rate =
    options?.rate ??
    (options?.mode ? MODE_RATES[options.mode] : undefined) ??
    DEFAULT_RATE;

  // Auto-slow for long text
  rate = adjustRateForLength(rate, text.length);

  const ttsFile = ttsFilePath(process.pid, ttsCounter++);

  // Generate speech via Python edge-tts CLI (must complete — we need the file)
  const synth = Bun.spawn([
    "python3",
    "-m",
    "edge_tts",
    "--text",
    text,
    "--voice",
    voice,
    "--rate",
    rate,
    "--write-media",
    ttsFile,
  ]);
  const synthExit = await synth.exited;
  if (synthExit !== 0) {
    throw new Error(
      `edge-tts failed with exit code ${synthExit}. Is edge-tts installed? Run: pip3 install edge-tts`,
    );
  }

  // Save to ring buffer before playback
  addToHistory(text, ttsFile, voice);

  // Play audio — NON-BLOCKING (returns immediately)
  const proc = playAudioNonBlocking(ttsFile);

  // Clean up TTS temp file after playback finishes (not blocking)
  proc.exited.then(() => {
    try {
      unlinkSync(ttsFile);
    } catch {}
  });

  // For converse mode: wait for playback to finish before recording starts
  if (options?.waitForPlayback) {
    await proc.exited;
  }

  return { warning };
}
