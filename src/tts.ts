/**
 * TTS module — multi-engine voice synthesis with context-aware routing.
 *
 * Engine priority for cloned voices:
 *   Tier 0: XTTS-v2 fine-tuned (captures cadence + timbre — best quality)
 *   Tier 1a: F5-TTS MLX zero-shot (timbre only, no daemon needed)
 *   Tier 1b: Qwen3-TTS daemon zero-shot (timbre only, HTTP-based)
 *   Tier 2: edge-tts (preset voices — fast, free)
 *
 * Context-aware optimizations:
 *   - Short text (< 50 chars) in announce mode → edge-tts (speed over quality)
 *   - Fine-tuned model available → XTTS-v2 (quality over speed)
 *   - No cloned engine available → edge-tts fallback with configured voice
 *
 * Plays via afplay (macOS) or mpv/ffplay/mpg123 (Linux).
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
import { isF5TTSAvailable, synthesizeF5TTS } from "./tts/f5tts";
import { isXTTSAvailable, synthesizeXTTS } from "./tts/xtts";
import { broadcast } from "./socket-server";
import type { WordBoundary } from "./socket-protocol";
import { applyPronunciation } from "./pronunciation";

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

  // Clean up reference + broadcast idle when playback finishes
  // AIDEV-NOTE: Idle broadcast is here (not in callers) to avoid race conditions —
  // only the LATEST playback should broadcast idle when it finishes.
  proc.exited.then(() => {
    if (currentPlayback?.pid === proc.pid) {
      currentPlayback = null;
      broadcast({ type: "state", state: "idle" });
    }
  });

  return proc;
}

/** Wait for current playback to finish (if any). Resolves immediately if nothing is playing. */
export async function awaitCurrentPlayback(): Promise<void> {
  if (currentPlayback) {
    await currentPlayback.proc.exited;
  }
}

/** Stop current playback if any. */
export function stopPlayback(): boolean {
  if (currentPlayback) {
    try {
      currentPlayback.proc.kill("SIGTERM");
      currentPlayback = null;
      broadcast({ type: "state", state: "idle" });
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

  // Apply pronunciation corrections before any TTS engine
  text = applyPronunciation(text);

  // Check if TTS is disabled
  if (isTTSDisabled()) {
    console.error("[voicelayer] TTS disabled via flag file — skipping speech");
    return {};
  }

  // Resolve voice — determines engine (cloned vs edge-tts)
  const resolved = resolveVoice(options?.voice);

  // AIDEV-NOTE: Speaking state is broadcast AFTER synthesis, right before playback starts.
  // This keeps the teleprompter in sync with actual audio.
  const speakingText = text.slice(0, 200); // Truncate for IPC — Voice Bar only needs preview

  // Context-aware shortcut: short announcements use edge-tts for speed
  if (
    resolved.engine === "cloned" &&
    options?.mode === "announce" &&
    text.length < 50
  ) {
    return speakWithEdgeTTS(
      text,
      resolved.fallbackVoice || DEFAULT_VOICE,
      options,
      resolved.warning,
    );
  }

  // Cloned voice → multi-engine synthesis cascade
  if (resolved.engine === "cloned") {
    const profile = loadProfile(resolved.voice);

    // Tier 0: XTTS-v2 fine-tuned (best quality — captures cadence + timbre)
    if (isXTTSAvailable(resolved.voice) && profile?.reference_clip) {
      const wavPath = await synthesizeXTTS(
        text,
        resolved.voice,
        profile.reference_clip,
      );
      if (wavPath) {
        const ttsFile = ttsFilePath(process.pid, ttsCounter++);
        const conv = Bun.spawnSync([
          "ffmpeg",
          "-y",
          "-i",
          wavPath,
          "-codec:a",
          "libmp3lame",
          "-q:a",
          "2",
          ttsFile,
        ]);
        try {
          unlinkSync(wavPath);
        } catch {}

        if (conv.exitCode === 0) {
          addToHistory(text, ttsFile, `xtts:${resolved.voice}`);
          broadcast({
            type: "state",
            state: "speaking",
            text: speakingText,
            voice: resolved.voice,
          });
          const proc = playAudioNonBlocking(ttsFile);
          proc.exited.then(() => {
            try {
              unlinkSync(ttsFile);
            } catch {}
          });
          if (options?.waitForPlayback) await proc.exited;
          return { warning: resolved.warning };
        }
      }
      console.error(
        `[voicelayer] XTTS inference failed for "${resolved.voice}" — trying F5-TTS`,
      );
    }

    // Tier 1a: F5-TTS MLX (local zero-shot, no daemon needed)
    if (
      profile?.engine === "f5-tts-mlx" &&
      isF5TTSAvailable() &&
      profile.reference_clip &&
      profile.reference_text
    ) {
      const wavPath = await synthesizeF5TTS(
        text,
        profile.reference_clip,
        profile.reference_text,
      );
      if (wavPath) {
        const ttsFile = ttsFilePath(process.pid, ttsCounter++);
        const conv = Bun.spawnSync([
          "ffmpeg",
          "-y",
          "-i",
          wavPath,
          "-codec:a",
          "libmp3lame",
          "-q:a",
          "2",
          ttsFile,
        ]);
        try {
          unlinkSync(wavPath);
        } catch {}

        if (conv.exitCode === 0) {
          addToHistory(text, ttsFile, `f5tts:${resolved.voice}`);
          broadcast({
            type: "state",
            state: "speaking",
            text: speakingText,
            voice: resolved.voice,
          });
          const proc = playAudioNonBlocking(ttsFile);
          proc.exited.then(() => {
            try {
              unlinkSync(ttsFile);
            } catch {}
          });
          if (options?.waitForPlayback) await proc.exited;
          return { warning: resolved.warning };
        }
      }
      console.error(
        `[voicelayer] F5-TTS synthesis failed for "${resolved.voice}" — trying Qwen3 daemon`,
      );
    }

    // Tier 1b: Qwen3-TTS daemon (HTTP-based zero-shot)
    const audioBuffer = await synthesizeCloned(text, resolved.voice);
    if (audioBuffer) {
      const ttsFile = ttsFilePath(process.pid, ttsCounter++);
      writeFileSync(ttsFile, audioBuffer);

      addToHistory(text, ttsFile, `cloned:${resolved.voice}`);
      broadcast({
        type: "state",
        state: "speaking",
        text: speakingText,
        voice: resolved.voice,
      });
      const proc = playAudioNonBlocking(ttsFile);
      proc.exited.then(() => {
        try {
          unlinkSync(ttsFile);
        } catch {}
      });
      if (options?.waitForPlayback) await proc.exited;
      return { warning: resolved.warning };
    }

    // All cloned engines failed — fall back to edge-tts
    console.error(
      `[voicelayer] Cloned voice "${resolved.voice}" unavailable — falling back to edge-tts (${resolved.fallbackVoice})`,
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

  // Generate speech via edge-tts with word boundary metadata.
  // Uses scripts/edge-tts-words.py which captures WordBoundary events
  // for exact karaoke word sync in Voice Bar.
  const metadataFile = ttsFile.replace(".mp3", ".meta.ndjson");
  const scriptPath = new URL("../scripts/edge-tts-words.py", import.meta.url)
    .pathname;

  const synth = Bun.spawn([
    "python3",
    scriptPath,
    "--text",
    text,
    "--voice",
    voice,
    "--rate",
    rate,
    "--write-media",
    ttsFile,
    "--write-metadata",
    metadataFile,
  ]);
  const synthExit = await synth.exited;
  if (synthExit !== 0) {
    broadcast({
      type: "error",
      message: "TTS synthesis failed (edge-tts)",
      recoverable: true,
    });
    broadcast({ type: "state", state: "idle" });
    throw new Error(
      `edge-tts failed with exit code ${synthExit}. Is edge-tts installed? Run: pip3 install edge-tts`,
    );
  }

  // Parse word boundary metadata and broadcast to Voice Bar
  let wordBoundaries: WordBoundary[] = [];
  try {
    const metaRaw = readFileSync(metadataFile, "utf-8");
    wordBoundaries = metaRaw
      .trim()
      .split("\n")
      .filter((l) => l.length > 0)
      .map((line) => {
        const parsed = JSON.parse(line);
        // edge-tts offsets are in 100-nanosecond units — convert to ms
        return {
          offset_ms: Math.round(parsed.offset / 10000),
          duration_ms: Math.round(parsed.duration / 10000),
          text: parsed.text as string,
        };
      });
  } catch {
    // Non-fatal — fall back to client-side estimation if metadata missing
  }

  // Clean up metadata file
  try {
    unlinkSync(metadataFile);
  } catch {}

  // Save to ring buffer before playback
  addToHistory(text, ttsFile, voice);

  // Broadcast word boundaries BEFORE speaking state so Voice Bar has
  // timestamps ready when TeleprompterView starts animating
  if (wordBoundaries.length > 0) {
    broadcast({
      type: "subtitle",
      words: wordBoundaries,
    });
  }

  // Broadcast speaking state with text for Voice Bar teleprompter
  broadcast({
    type: "state",
    state: "speaking",
    text: text.slice(0, 200),
    voice,
  });

  // Play audio — NON-BLOCKING (returns immediately)
  const proc = playAudioNonBlocking(ttsFile);

  // Clean up TTS temp file after playback finishes (idle broadcast is in playAudioNonBlocking)
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
