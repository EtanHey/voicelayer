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

import {
  existsSync,
  readFileSync,
  writeFileSync,
  copyFileSync,
  unlinkSync,
} from "fs";
import { platform } from "os";
import {
  ttsFilePath,
  TTS_HISTORY_FILE,
  ttsHistoryFilePath,
  TTS_DISABLED_FILE,
} from "./paths";
import { hasClonedProfile, synthesizeCloned, loadProfile } from "./tts/qwen3";
import { isF5TTSAvailable, synthesizeF5TTS } from "./tts/f5tts";
import { isXTTSAvailable, synthesizeXTTS } from "./tts/xtts";
import { broadcast } from "./socket-client";
import type {
  PlaybackOutcomeEvent,
  PlaybackOutcomeReason,
  PlaybackOutcomeStatus,
  PlaybackPriority,
  QueueItemSnapshot,
  WordBoundary,
} from "./socket-protocol";
import type {
  PlaybackController,
  PlaybackHandle,
  PlaybackMetadata as SoundLayerPlaybackMetadata,
  TextToSpeechBackend,
  TextToSpeechOptions,
  TextToSpeechResult,
} from "./soundlayer";
import { applyPronunciation } from "./pronunciation";
import { synthesizeWithRetry } from "./tts-health";
import { sanitizeTtsText } from "./sanitize";
import { getEffectiveRecordingState } from "./recording-state";
import {
  startPlaybackAmplitudeEnvelopeExtraction,
  type PlaybackAmplitudeEnvelope,
} from "./playback-amplitude";

const DEFAULT_VOICE = process.env.QA_VOICE_TTS_VOICE || "en-US-JennyNeural";
const DEFAULT_RATE = process.env.QA_VOICE_TTS_RATE || "+0%";
const RING_BUFFER_SIZE = 20;
export const SPEAKER_OUTPUT_REFUSED_MESSAGE =
  "user is recording — speaker output refused";

export function assertSpeakerClear(): void {
  if (getEffectiveRecordingState() === "idle") return;
  throw new Error(SPEAKER_OUTPUT_REFUSED_MESSAGE);
}

export function isSpeakerOutputRefusedError(error: unknown): boolean {
  return (
    error instanceof Error && error.message === SPEAKER_OUTPUT_REFUSED_MESSAGE
  );
}

function broadcastPlaybackIdleIfSpeakerClear(nextState?: "recording"): void {
  if (getEffectiveRecordingState() !== "idle") return;
  broadcast({
    type: "state",
    state: "idle",
    source: "playback",
    ...(nextState ? { next_state: nextState } : {}),
  });
}

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
/**
 * Raised when a MANDATED cloned voice cannot be produced — the profile is not
 * registered (missing) or every cloned synthesis tier failed. The render/
 * narration path treats this as BLOCKED rather than silently speaking in a
 * preset/system voice.
 */
export class VoiceProfileUnavailableError extends Error {
  constructor(
    public readonly voice: string,
    public readonly reason: "missing-profile" | "synthesis-failed",
  ) {
    super(
      reason === "missing-profile"
        ? `Voice "${voice}" is not a registered clone profile (~/.voicelayer/voices/${voice}/profile.yaml missing). Refusing to fall back to a preset/system voice.`
        : `Cloned voice "${voice}" failed every synthesis tier. Refusing to fall back to a preset/system voice.`,
    );
    this.name = "VoiceProfileUnavailableError";
  }
}

/** True when the caller mandates a cloned voice (option or global env switch). */
export function requireClonedVoiceEnabled(
  options?: { requireClonedVoice?: boolean },
  env: Record<string, string | undefined> = process.env,
): boolean {
  if (options?.requireClonedVoice) return true;
  const raw = env.QA_VOICE_TTS_REQUIRE_CLONE?.trim().toLowerCase();
  return raw === "1" || raw === "true" || raw === "yes" || raw === "on";
}

/**
 * Fail-closed assertion that a voice name resolves to a registered clone
 * profile. Throws VoiceProfileUnavailableError("missing-profile") otherwise.
 * The profile predicate is injectable for testing.
 */
export function assertRegisteredClone(
  name: string,
  hasProfile: (n: string) => boolean = hasClonedProfile,
): void {
  if (!hasProfile(name)) {
    throw new VoiceProfileUnavailableError(name, "missing-profile");
  }
}

export function resolveVoice(name?: string): {
  voice: string;
  engine: "cloned" | "edge-tts";
  warning?: string;
  fallbackVoice?: string;
} {
  const requestedName = name || DEFAULT_VOICE;

  // Tier 1: Check for cloned voice profile (profile.yaml)
  const clonedProfile = loadProfile(requestedName);
  if (clonedProfile) {
    return {
      voice: clonedProfile.profile_id || clonedProfile.name || requestedName,
      engine: "cloned",
      fallbackVoice: clonedProfile.fallback || DEFAULT_VOICE,
    };
  }

  // Tier 2: Check preset profiles (voices.json)
  const profiles = loadVoiceProfiles();
  const profile = profiles[requestedName.toLowerCase()];
  if (profile) {
    if (profile.engine !== "edge-tts") {
      return {
        voice: DEFAULT_VOICE,
        engine: "edge-tts",
        warning: `Voice profile "${requestedName}" uses engine "${profile.engine}" which is not yet supported. Using default.`,
      };
    }
    return { voice: profile.voice, engine: "edge-tts" };
  }

  // Tier 2b: Raw edge-tts voice name (e.g., "en-US-AndrewNeural")
  if (/^[a-z]{2}-[A-Z]{2}-/i.test(requestedName)) {
    return { voice: requestedName, engine: "edge-tts" };
  }

  // Unknown name — fallback with warning
  return {
    voice: DEFAULT_VOICE,
    engine: "edge-tts",
    warning: `Unknown voice "${requestedName}". Using default (${DEFAULT_VOICE}). Add it to ~/.voicelayer/voices.json or use a raw edge-tts voice name.`,
  };
}

let ttsCounter = 0;

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

function splitIntoSentences(text: string): string[] {
  try {
    const segmenter = new Intl.Segmenter(undefined, {
      granularity: "sentence",
    });
    const segments = Array.from(
      segmenter.segment(text),
      ({ segment }) => segment,
    );
    if (segments.length > 0) return segments;
  } catch {
    // Fall through to regex segmentation on runtimes without Intl.Segmenter.
  }

  return (
    text.match(/[^.!?…。！？]+[.!?…。！？]+(?:\s+|$)|[^.!?…。！？]+$/gu) ?? [
      text,
    ]
  );
}

function splitLongSegment(segment: string, maxLen: number): string[] {
  const trimmed = segment.trim();
  if (!trimmed) return [];
  if (trimmed.length <= maxLen) return [trimmed];

  const parts: string[] = [];
  let current = "";

  for (const token of trimmed.match(/\S+/gu) ?? [trimmed]) {
    if (token.length > maxLen) {
      if (current) {
        parts.push(current);
        current = "";
      }
      for (let i = 0; i < token.length; i += maxLen) {
        parts.push(token.slice(i, i + maxLen));
      }
      continue;
    }

    const candidate = current ? `${current} ${token}` : token;
    if (candidate.length <= maxLen) {
      current = candidate;
      continue;
    }

    parts.push(current);
    current = token;
  }

  if (current) parts.push(current);
  return parts;
}

/**
 * Split text into chunks that edge-tts can handle.
 * edge-tts fails with exit code 2 on very long text (roughly >500 chars).
 * Prefer sentence boundaries, then fall back to word boundaries, then hard cuts.
 */
export function chunkTextForTTS(text: string, maxLen = 400): string[] {
  if (text.length <= maxLen) return [text];

  const chunks: string[] = [];
  let current = "";

  for (const sentence of splitIntoSentences(text)) {
    for (const piece of splitLongSegment(sentence, maxLen)) {
      const candidate = current ? `${current} ${piece}` : piece;
      if (candidate.length <= maxLen) {
        current = candidate;
        continue;
      }

      if (current) chunks.push(current);
      current = piece;
    }
  }

  if (current) chunks.push(current);
  return chunks.length > 0 ? chunks : [text];
}

function inferBoundaryEndMs(wordBoundaries: WordBoundary[]): number {
  return wordBoundaries.reduce(
    (max, word) => Math.max(max, word.offset_ms + word.duration_ms),
    0,
  );
}

function probeAudioDurationMs(audioFile: string): number | null {
  try {
    const probe = Bun.spawnSync([
      "ffprobe",
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      audioFile,
    ]);
    if (probe.exitCode !== 0) return null;

    const durationSeconds = Number(
      Buffer.from(probe.stdout).toString("utf8").trim(),
    );
    if (!Number.isFinite(durationSeconds)) return null;
    return Math.round(durationSeconds * 1000);
  } catch {
    return null;
  }
}

function concatenateMp3Files(inputFiles: string[], outputFile: string): void {
  const buffers = inputFiles.map((file) => readFileSync(file));
  writeFileSync(outputFile, Buffer.concat(buffers));
}

interface SynthesizedChunk {
  audioFile: string;
  wordBoundaries: WordBoundary[];
  durationMs: number;
}

async function synthesizeEdgeChunk(
  text: string,
  voice: string,
  rate: string,
  audioFile: string,
  scriptPath: string,
): Promise<SynthesizedChunk> {
  const result = await synthesizeWithRetry(
    text,
    voice,
    rate,
    audioFile,
    scriptPath,
  );

  if (!result.success) {
    throw new Error(result.error || "edge-tts synthesis failed after retries");
  }

  const durationMs = Math.max(
    probeAudioDurationMs(audioFile) ?? 0,
    inferBoundaryEndMs(result.wordBoundaries || []),
  );

  return {
    audioFile,
    wordBoundaries: result.wordBoundaries || [],
    durationMs,
  };
}

export function mergeWordBoundaryChunks(
  chunks: SynthesizedChunk[],
): WordBoundary[] {
  const merged: WordBoundary[] = [];
  let chunkOffsetMs = 0;

  for (const chunk of chunks) {
    for (const word of chunk.wordBoundaries) {
      merged.push({
        ...word,
        offset_ms: word.offset_ms + chunkOffsetMs,
      });
    }
    chunkOffsetMs += Math.max(
      chunk.durationMs,
      inferBoundaryEndMs(chunk.wordBoundaries),
    );
  }

  return merged;
}

/**
 * Re-label engine word timings with the text shown in VoiceBar.
 *
 * Pronunciation substitutions can expand one display token into several spoken
 * tokens (for example, "Etan" -> "Eh tahn"). In that case the original token
 * owns the complete timing span of its spoken replacement.
 */
export function alignWordBoundariesToDisplayText(
  displayText: string,
  spokenText: string,
  wordBoundaries: WordBoundary[],
): WordBoundary[] {
  if (displayText === spokenText || wordBoundaries.length === 0) {
    return wordBoundaries;
  }

  const displayTokens = displayText.match(/\S+/gu) ?? [];
  const spokenTokens = spokenText.match(/\S+/gu) ?? [];
  if (displayTokens.length === 0) return wordBoundaries;

  const collapseToDisplayText = (): WordBoundary[] => {
    const first = wordBoundaries[0];
    const last = wordBoundaries[wordBoundaries.length - 1];
    return [{
      offset_ms: first.offset_ms,
      duration_ms: last.offset_ms + last.duration_ms - first.offset_ms,
      text: displayText,
    }];
  };
  if (spokenTokens.length !== wordBoundaries.length) {
    return collapseToDisplayText();
  }

  const aligned: WordBoundary[] = [];
  let boundaryIndex = 0;

  for (const displayToken of displayTokens) {
    const replacementTokenCount =
      applyPronunciation(displayToken).match(/\S+/gu)?.length ?? 1;
    const replacementBoundaries = wordBoundaries.slice(
      boundaryIndex,
      boundaryIndex + replacementTokenCount,
    );
    if (replacementBoundaries.length !== replacementTokenCount) {
      return collapseToDisplayText();
    }

    const first = replacementBoundaries[0];
    const last = replacementBoundaries[replacementBoundaries.length - 1];
    aligned.push({
      offset_ms: first.offset_ms,
      duration_ms:
        last.offset_ms + last.duration_ms - first.offset_ms,
      text: displayToken,
    });
    boundaryIndex += replacementTokenCount;
  }

  return boundaryIndex === wordBoundaries.length
    ? aligned
    : collapseToDisplayText();
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

function captureAudioArtifact(
  audioFile: string,
  enabled: boolean | undefined,
): TextToSpeechResult["audioArtifact"] {
  if (!enabled) return undefined;
  return { bytes: readFileSync(audioFile), format: "mp3" };
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

/** Convert a WAV file to MP3 via ffmpeg. Returns the MP3 path, or null on failure. */
function convertWavToMp3(wavPath: string): string | null {
  const mp3Path = ttsFilePath(process.pid, ttsCounter++);
  const result = Bun.spawnSync([
    "ffmpeg",
    "-y",
    "-i",
    wavPath,
    "-codec:a",
    "libmp3lame",
    "-q:a",
    "2",
    mp3Path,
  ]);
  try {
    unlinkSync(wavPath);
  } catch {}
  return result.exitCode === 0 ? mp3Path : null;
}

/**
 * Broadcast speaking state, play audio, add to history, and clean up.
 * Shared by all cloned voice engine tiers.
 */
async function playClonedAudio(
  ttsFile: string,
  text: string,
  voiceLabel: string,
  speakingText: string,
  resolvedVoice: string,
  options?: {
    mode?: string;
    waitForPlayback?: boolean;
    onPlaybackStart?: (startedAtMs: number) => void;
    onPlaybackComplete?: (outcome: PlaybackOutcomeEvent) => void;
    captureAudioArtifact?: boolean;
  },
): Promise<
  Pick<
    TextToSpeechResult,
    "audioArtifact" | "playbackId" | "playbackOutcome"
  >
> {
  let proc: PlaybackHandle;
  let audioArtifact: TextToSpeechResult["audioArtifact"];
  try {
    assertSpeakerClear();
    audioArtifact = captureAudioArtifact(
      ttsFile,
      options?.captureAudioArtifact,
    );
    addToHistory(text, ttsFile, voiceLabel);
    const durationMs = probeAudioDurationMs(ttsFile) ?? undefined;
    proc = playAudioNonBlocking(ttsFile, {
      text: speakingText,
      voice: resolvedVoice,
      priority: playbackPriorityForMode(options?.mode),
      durationMs,
      nextState: options?.mode === "converse" ? "recording" : undefined,
      onStarted: options?.onPlaybackStart,
      onCompleted: options?.onPlaybackComplete,
    });
  } catch (err) {
    try {
      unlinkSync(ttsFile);
    } catch {}
    throw err;
  }
  proc.exited.then(() => {
    try {
      unlinkSync(ttsFile);
    } catch {}
  });
  const playbackOutcome = options?.waitForPlayback
    ? await proc.exited
    : undefined;
  return {
    audioArtifact,
    playbackId: proc.id,
    ...(playbackOutcome ? { playbackOutcome } : {}),
  };
}

/**
 * Playback queue — serializes audio playback to prevent overlapping afplay
 * processes when multiple voice_speak calls arrive concurrently.
 *
 * Phase 8 queue semantics:
 * 1. Speaking/subtitle broadcasts happen INSIDE the queue when playback starts.
 * 2. Queue depth is broadcast to VoiceBar for visible state.
 * 3. Critical items barge in: kill current playback and discard stale pending speech.
 * 4. Low/background chatter collapses so bursts do not create an audio backlog.
 */
/** Metadata for deferred broadcasting — fires when playback actually starts. */
export interface PlaybackMetadata extends SoundLayerPlaybackMetadata {
  text: string;
  voice: string;
  wordBoundaries?: WordBoundary[];
  priority?: PlaybackPriority;
  durationMs?: number;
  collapseKey?: string;
  clipMarker?: {
    id: string;
    label: string;
    source?: "tts" | "command";
  };
}

interface PlaybackJob {
  id: string;
  audioFile: string;
  metadata?: PlaybackMetadata;
  playbackAmplitude?: PlaybackAmplitudeEnvelope;
  priority: PlaybackPriority;
  enqueuedAt: number;
  expiresAt: number;
  resolveExited: (outcome: PlaybackOutcomeEvent) => void;
  completed: boolean;
  exited: Promise<PlaybackOutcomeEvent>;
}

interface ActivePlayback {
  job: PlaybackJob;
  proc: ReturnType<typeof Bun.spawn>;
  startedAt: number;
}

const PRIORITY_ORDER: Record<PlaybackPriority, number> = {
  critical: 0,
  high: 1,
  normal: 2,
  low: 3,
  background: 4,
};

const LOW_PRIORITY_TTL_MS = 10_000;
const NORMAL_PRIORITY_TTL_MS = 30_000;
let playbackIdCounter = 0;

function nextPlaybackId(): string {
  playbackIdCounter += 1;
  return `playback-${process.pid}-${Date.now()}-${playbackIdCounter}`;
}

function playbackPriorityForMode(mode?: string): PlaybackPriority {
  switch (mode) {
    case "converse":
      return "critical";
    case "consult":
      return "high";
    case "brief":
      return "low";
    case "think":
      return "background";
    default:
      return "normal";
  }
}

function ttlForPriority(priority: PlaybackPriority): number {
  switch (priority) {
    case "critical":
    case "high":
      return 120_000;
    case "normal":
      return NORMAL_PRIORITY_TTL_MS;
    case "low":
      return LOW_PRIORITY_TTL_MS;
    case "background":
      return 5_000;
  }
}

function buildPlaybackOutcome(
  job: PlaybackJob,
  status: PlaybackOutcomeStatus,
  reason?: PlaybackOutcomeReason,
  elapsedMs = 0,
): PlaybackOutcomeEvent {
  const durationMs = job.metadata?.durationMs;
  const stoppedAtMs =
    status === "completed" && durationMs !== undefined
      ? durationMs
      : Math.max(0, elapsedMs);
  const progress =
    status === "completed"
      ? 1
      : durationMs && durationMs > 0
        ? Math.max(0, Math.min(1, stoppedAtMs / durationMs))
        : 0;
  const boundaries = job.metadata?.wordBoundaries ?? [];
  const words =
    boundaries.length > 0
      ? boundaries.map((boundary) => boundary.text)
      : (job.metadata?.text.trim().split(/\s+/).filter(Boolean) ?? []);
  let wordIndex: number | undefined;
  if (words.length > 0 && progress > 0) {
    if (boundaries.length > 0) {
      const lastStarted = boundaries.findLastIndex(
        (boundary) => boundary.offset_ms <= stoppedAtMs,
      );
      if (lastStarted >= 0) wordIndex = lastStarted;
    } else {
      wordIndex = Math.min(words.length - 1, Math.floor(progress * words.length));
    }
  }

  return {
    type: "playback_outcome",
    playback_id: job.id,
    status,
    ...(reason ? { reason } : {}),
    stopped_at_ms: stoppedAtMs,
    ...(durationMs !== undefined ? { duration_ms: durationMs } : {}),
    progress,
    ...(wordIndex !== undefined ? { word_index: wordIndex } : {}),
    ...(words.length > 0 ? { word_count: words.length } : {}),
  };
}

function completeJob(job: PlaybackJob, outcome: PlaybackOutcomeEvent) {
  if (job.completed) return;
  job.completed = true;
  broadcast(outcome);
  try {
    job.metadata?.onCompleted?.(outcome);
  } catch (error) {
    console.error(
      `[voicelayer] Playback outcome observer failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  job.resolveExited(outcome);
}

class PlaybackQueueManager {
  private pending: PlaybackJob[] = [];
  private preparing: { job: PlaybackJob; cancel: () => void } | null = null;
  private current: ActivePlayback | null = null;
  private terminating = new Map<number, ActivePlayback>();
  private restartAfterTermination: PlaybackJob | null = null;
  private replayPreparingJob: PlaybackJob | null = null;
  private drainWaiters = new Set<() => void>();
  private progressTimer: ReturnType<typeof setInterval> | null = null;

  enqueue(
    audioFile: string,
    metadata?: PlaybackMetadata,
  ): PlaybackHandle {
    const priority = metadata?.priority ?? "normal";
    let resolveExited!: (outcome: PlaybackOutcomeEvent) => void;
    const exited = new Promise<PlaybackOutcomeEvent>((resolve) => {
      resolveExited = resolve;
    });

    const job: PlaybackJob = {
      id: nextPlaybackId(),
      audioFile,
      metadata,
      priority,
      enqueuedAt: Date.now(),
      expiresAt: Date.now() + ttlForPriority(priority),
      resolveExited,
      completed: false,
      exited,
    };

    if (priority === "critical") {
      this.bargeIn(job);
      return { id: job.id, exited };
    }

    this.evictExpired();
    this.collapseBurstyLowPriority(job);
    this.insert(job);
    this.emitQueueSnapshot();
    this.processNext();
    return { id: job.id, exited };
  }

  async awaitDrained(): Promise<void> {
    if (this.depth() === 0) return;
    await new Promise<void>((resolve) => {
      this.drainWaiters.add(resolve);
    });
  }

  stop(playbackElapsedMs?: number): boolean {
    const active = this.current;
    const preparing = this.preparing;
    const restarting = this.restartAfterTermination;
    const hadActivity =
      this.pending.length > 0 ||
      preparing !== null ||
      active !== null ||
      restarting !== null;
    this.current = null;
    this.preparing = null;
    this.restartAfterTermination = null;
    this.replayPreparingJob = null;
    preparing?.cancel();

    for (const job of this.pending.splice(0)) {
      completeJob(job, buildPlaybackOutcome(job, "skipped", "stopped"));
    }
    if (preparing) {
      completeJob(
        preparing.job,
        buildPlaybackOutcome(preparing.job, "skipped", "stopped"),
      );
    }

    if (active) {
      const outcome = buildPlaybackOutcome(
        active.job,
        "interrupted",
        "stopped",
        this.normalizedPlaybackElapsed(playbackElapsedMs) ??
          Date.now() - active.startedAt,
      );
      this.terminate(active);
      completeJob(active.job, outcome);
    }
    if (restarting) {
      const terminatingActive = Array.from(this.terminating.values()).find(
        (candidate) => candidate.job === restarting,
      );
      completeJob(
        restarting,
        buildPlaybackOutcome(
          restarting,
          "interrupted",
          "stopped",
          this.normalizedPlaybackElapsed(playbackElapsedMs) ??
            (terminatingActive
              ? Date.now() - terminatingActive.startedAt
              : 0),
        ),
      );
    }

    if (hadActivity) {
      this.stopProgressTimer();
      broadcastPlaybackIdleIfSpeakerClear();
      this.emitQueueSnapshot();
      this.resolveIfIdle();
    }

    return hadActivity;
  }

  restart(): boolean {
    if (this.restartAfterTermination) return true;
    // The replacement has already reset to the beginning once it reaches
    // preparation. Collapse another rapid Replay into that same job so a
    // blocking voice_ask cannot resolve while a duplicate replay stays queued.
    if (this.preparing) {
      return this.preparing.job === this.replayPreparingJob;
    }
    const active = this.current;
    if (!active) return false;

    this.current = null;
    for (const job of this.pending.splice(0)) {
      completeJob(job, buildPlaybackOutcome(job, "skipped", "collapsed"));
    }

    this.restartAfterTermination = active.job;
    this.stopProgressTimer();
    this.terminate(active);
    this.emitQueueSnapshot();
    return true;
  }

  private refuseQueuedPlayback(job: PlaybackJob, error: unknown): void {
    if (this.replayPreparingJob === job) {
      this.replayPreparingJob = null;
    }
    broadcast({
      type: "error",
      message: error instanceof Error ? error.message : String(error),
      recoverable: true,
    });
    if (this.depth() === 0) {
      broadcastPlaybackIdleIfSpeakerClear();
    }
    this.emitQueueSnapshot();
    completeJob(job, buildPlaybackOutcome(job, "failed", "refused"));
    this.resolveIfIdle();
  }

  private processNext() {
    if (this.current || this.preparing || this.terminating.size > 0) return;

    while (this.pending.length > 0) {
      const next = this.pending.shift()!;
      if (next.expiresAt <= Date.now()) {
        completeJob(next, buildPlaybackOutcome(next, "skipped", "expired"));
        continue;
      }

      try {
        assertSpeakerClear();
      } catch (err) {
        this.refuseQueuedPlayback(next, err);
        continue;
      }

      if (!next.metadata) {
        this.preparing = { job: next, cancel: () => {} };
        this.emitQueueSnapshot();
        this.startPreparedPlayback(next, undefined);
        return;
      }
      const extraction = startPlaybackAmplitudeEnvelopeExtraction(
        next.audioFile,
      );
      this.preparing = { job: next, cancel: extraction.cancel };
      this.emitQueueSnapshot();
      void extraction.result.then(
        (playbackAmplitude) => {
          this.startPreparedPlayback(next, playbackAmplitude);
        },
      );
      return;
    }

    if (this.depth() === 0) {
      this.emitQueueSnapshot();
      this.resolveIfIdle();
    }
  }

  private startPreparedPlayback(
    next: PlaybackJob,
    playbackAmplitude: PlaybackAmplitudeEnvelope | undefined,
  ) {
    if (this.preparing?.job !== next) return;
    this.preparing = null;
    if (this.replayPreparingJob === next) {
      this.replayPreparingJob = null;
    }
    if (next.completed) {
      this.processNext();
      return;
    }
    // TTL bounds pending queue staleness. Once a still-valid job becomes the
    // owned preparation, decoder time must not silently consume that promise;
    // timeout/failure starts playback with the explicit unavailable envelope.

    try {
      assertSpeakerClear();
    } catch (err) {
      this.refuseQueuedPlayback(next, err);
      this.processNext();
      return;
    }
    if (next.metadata?.wordBoundaries?.length) {
      broadcast({ type: "subtitle", words: next.metadata.wordBoundaries });
    }
    if (next.metadata?.clipMarker) {
      broadcast({
        type: "clip_marker",
        marker_id: next.metadata.clipMarker.id,
        label: next.metadata.clipMarker.label,
        source: next.metadata.clipMarker.source ?? "tts",
        status: "marked",
      });
    }
    try {
      assertSpeakerClear();
    } catch (err) {
      this.refuseQueuedPlayback(next, err);
      this.processNext();
      return;
    }
    next.playbackAmplitude = playbackAmplitude;
    let proc: ReturnType<typeof Bun.spawn>;
    try {
      proc = Bun.spawn([getAudioPlayer(), next.audioFile], {
        stdout: "ignore",
        stderr: "ignore",
      });
    } catch {
      if (this.depth() === 0) {
        broadcastPlaybackIdleIfSpeakerClear();
      }
      this.emitQueueSnapshot();
      completeJob(
        next,
        buildPlaybackOutcome(next, "failed", "player-error"),
      );
      this.resolveIfIdle();
      this.processNext();
      return;
    }

    this.current = { job: next, proc, startedAt: Date.now() };
    if (next.metadata) {
      broadcast({
        type: "state",
        state: "speaking",
        text: next.metadata.text,
        voice: next.metadata.voice,
        playback_amplitude: next.playbackAmplitude,
      });
    }
    next.metadata?.onStarted?.(this.current.startedAt);
    this.startProgressTimer();
    this.emitQueueSnapshot();

    proc.exited
      .then((exitCode) => {
        this.finish(next, proc.pid, exitCode === 0);
      })
      .catch(() => {
        this.finish(next, proc.pid, false);
      });
  }

  private finish(job: PlaybackJob, pid: number, succeeded: boolean) {
    if (this.current?.proc.pid !== pid) return;
    const elapsedMs = Date.now() - this.current.startedAt;
    this.stopProgressTimer();
    this.current = null;
    if (this.depth() === 0) {
      broadcastPlaybackIdleIfSpeakerClear(
        succeeded ? job.metadata?.nextState : undefined,
      );
    }
    this.emitQueueSnapshot();
    this.resolveIfIdle();
    this.processNext();
    completeJob(
      job,
      succeeded
        ? buildPlaybackOutcome(job, "completed", undefined, elapsedMs)
        : buildPlaybackOutcome(job, "failed", "player-error", elapsedMs),
    );
  }

  private bargeIn(job: PlaybackJob) {
    // ASYNC SAFETY: Cancel the decoder and clear its ownership before any late
    // result can attempt to start playback.
    const active = this.current;
    const preparing = this.preparing;
    const restarting = this.restartAfterTermination;
    this.current = null;
    this.preparing = null;
    this.restartAfterTermination = null;
    this.replayPreparingJob = null;
    preparing?.cancel();

    for (const queued of this.pending.splice(0)) {
      completeJob(
        queued,
        buildPlaybackOutcome(queued, "skipped", "barge-in"),
      );
    }
    if (preparing) {
      completeJob(
        preparing.job,
        buildPlaybackOutcome(preparing.job, "skipped", "barge-in"),
      );
    }

    if (active) {
      const outcome = buildPlaybackOutcome(
        active.job,
        "interrupted",
        "barge-in",
        Date.now() - active.startedAt,
      );
      this.terminate(active);
      completeJob(active.job, outcome);
    }
    if (restarting) {
      const terminatingActive = Array.from(this.terminating.values()).find(
        (candidate) => candidate.job === restarting,
      );
      completeJob(
        restarting,
        buildPlaybackOutcome(
          restarting,
          "interrupted",
          "barge-in",
          terminatingActive ? Date.now() - terminatingActive.startedAt : 0,
        ),
      );
    }

    this.pending = [job];
    this.stopProgressTimer();
    this.emitQueueSnapshot();
    this.processNext();
  }

  private collapseBurstyLowPriority(job: PlaybackJob) {
    if (job.priority !== "low" && job.priority !== "background") return;

    this.pending = this.pending.filter((queued) => {
      const sameCollapseKey =
        (queued.metadata?.collapseKey ?? null) ===
        (job.metadata?.collapseKey ?? null);
      const isCollapsible =
        sameCollapseKey &&
        (queued.priority === job.priority || queued.priority === "background");
      if (isCollapsible) {
        completeJob(
          queued,
          buildPlaybackOutcome(queued, "skipped", "collapsed"),
        );
        return false;
      }
      return true;
    });
  }

  private insert(job: PlaybackJob) {
    const index = this.pending.findIndex((queued) => {
      return PRIORITY_ORDER[job.priority] < PRIORITY_ORDER[queued.priority];
    });
    if (index === -1) {
      this.pending.push(job);
    } else {
      this.pending.splice(index, 0, job);
    }
  }

  private emitQueueSnapshot() {
    const items: QueueItemSnapshot[] = [];

    for (const active of this.terminating.values()) {
      items.push({
        text: active.job.metadata?.text ?? "",
        voice: active.job.metadata?.voice ?? "",
        priority: active.job.priority,
        is_current: true,
        progress: this.playbackProgress(active),
      });
    }

    if (this.current) {
      items.push({
        text: this.current.job.metadata?.text ?? "",
        voice: this.current.job.metadata?.voice ?? "",
        priority: this.current.job.priority,
        is_current: true,
        progress: this.playbackProgress(this.current),
      });
    }

    if (this.preparing) {
      items.push({
        text: this.preparing.job.metadata?.text ?? "",
        voice: this.preparing.job.metadata?.voice ?? "",
        priority: this.preparing.job.priority,
        is_current: false,
        progress: 0,
      });
    }

    for (const job of this.pending) {
      items.push({
        text: job.metadata?.text ?? "",
        voice: job.metadata?.voice ?? "",
        priority: job.priority,
        is_current: false,
        progress: 0,
      });
    }

    broadcast({ type: "queue", depth: this.depth(), items });
  }

  private evictExpired() {
    const now = Date.now();
    this.pending = this.pending.filter((job) => {
      if (job.expiresAt <= now) {
        completeJob(job, buildPlaybackOutcome(job, "skipped", "expired"));
        return false;
      }
      return true;
    });
  }

  private resolveIfIdle() {
    if (this.depth() !== 0) return;
    for (const resolve of this.drainWaiters) {
      resolve();
    }
    this.drainWaiters.clear();
  }

  private depth() {
    return (
      this.pending.length +
      (this.preparing ? 1 : 0) +
      (this.current ? 1 : 0) +
      this.terminating.size
    );
  }

  getDepthForHealth() {
    return this.depth();
  }

  private startProgressTimer() {
    this.stopProgressTimer();
    this.progressTimer = setInterval(() => {
      if (!this.current) return;
      if ((this.current.job.metadata?.durationMs ?? 0) <= 0) return;
      this.emitQueueSnapshot();
    }, 100);
  }

  private stopProgressTimer() {
    if (!this.progressTimer) return;
    clearInterval(this.progressTimer);
    this.progressTimer = null;
  }

  private playbackProgress(active: ActivePlayback): number {
    const durationMs = active.job.metadata?.durationMs ?? 0;
    if (durationMs <= 0) return 0;
    const elapsedMs = Date.now() - active.startedAt;
    return Math.max(0, Math.min(1, elapsedMs / durationMs));
  }

  private terminate(active: ActivePlayback): void {
    const pid = active.proc.pid;
    this.terminating.set(pid, active);
    try {
      active.proc.kill("SIGTERM");
    } catch {}
    void active.proc.exited.then(
      () => this.finishTermination(pid, active),
      () => this.finishTermination(pid, active),
    );
  }

  private finishTermination(pid: number, active: ActivePlayback): void {
    if (this.terminating.get(pid) !== active) return;
    this.terminating.delete(pid);
    if (this.restartAfterTermination === active.job && !active.job.completed) {
      this.restartAfterTermination = null;
      this.replayPreparingJob = active.job;
      active.job.enqueuedAt = Date.now();
      active.job.expiresAt = Date.now() + ttlForPriority(active.job.priority);
      this.pending.unshift(active.job);
    }
    this.emitQueueSnapshot();
    this.resolveIfIdle();
    this.processNext();
  }

  private normalizedPlaybackElapsed(value?: number): number | undefined {
    if (value === undefined || !Number.isFinite(value)) return undefined;
    return Math.max(0, Math.round(value));
  }
}

const playbackQueueManager = new PlaybackQueueManager();

/** Play an audio file, queued after any currently playing audio. */
export function playAudioNonBlocking(
  audioFile: string,
  metadata?: PlaybackMetadata,
): PlaybackHandle {
  assertSpeakerClear();
  return playbackQueueManager.enqueue(audioFile, metadata);
}

/**
 * Wait for all queued playback to finish. Resolves immediately if queue is empty.
 *
 * AIDEV-NOTE: Name kept as `awaitCurrentPlayback` for backward compat (handlers.ts
 * imports it). Semantically it now awaits the full queue, not just the current proc.
 * P0-2 fix — voice_ask uses this to ensure all pending audio finishes before
 * starting recording. Previously only awaited currentPlayback.proc.exited, which
 * returned immediately if the queue hadn't started processing.
 */
export async function awaitCurrentPlayback(): Promise<void> {
  await playbackQueueManager.awaitDrained();
}

export function getPlaybackQueueDepth(): number {
  return playbackQueueManager.getDepthForHealth();
}

/** Stop current playback if any. */
export function stopPlayback(playbackElapsedMs?: number): boolean {
  return playbackQueueManager.stop(playbackElapsedMs);
}

/** Restart the active audio job without resolving its blocking playback handle. */
export function restartPlayback(): boolean {
  return playbackQueueManager.restart();
}

export class QueuedPlaybackController implements PlaybackController {
  play(audioFile: string, metadata?: PlaybackMetadata): PlaybackHandle {
    return playAudioNonBlocking(audioFile, metadata);
  }

  waitForIdle(): Promise<void> {
    return awaitCurrentPlayback();
  }

  stop(): boolean {
    return stopPlayback();
  }

  getQueueDepth(): number {
    return getPlaybackQueueDepth();
  }
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
  options?: TextToSpeechOptions,
): Promise<TextToSpeechResult> {
  if (!text?.trim()) return {};
  assertSpeakerClear();

  // SSML injection defense — strip tags before any TTS engine
  text = sanitizeTtsText(text);

  // VoiceBar must show the caller's text, while engines receive the phonetic
  // form. Keep these values separate for the remainder of the pipeline.
  const displayText = text;

  // Apply pronunciation corrections before any TTS engine
  const spokenText = applyPronunciation(displayText);

  // Check if TTS is disabled
  if (isTTSDisabled()) {
    console.error("[voicelayer] TTS disabled via flag file — skipping speech");
    return {};
  }

  // Resolve voice — determines engine (cloned vs edge-tts)
  const resolved = resolveVoice(options?.voice);

  // Fail-closed gate: when a cloned voice is MANDATED, an unregistered profile
  // must BLOCK rather than silently downgrade to a preset/system voice.
  // resolved.engine === "cloned" iff resolveVoice's Tier 1 hasClonedProfile()
  // matched, so this is the inline equivalent of assertRegisteredClone() (the
  // standalone export callers can use to pre-validate a reference before speak).
  const requireClone = requireClonedVoiceEnabled(options);
  if (requireClone && resolved.engine !== "cloned") {
    throw new VoiceProfileUnavailableError(
      options?.voice || DEFAULT_VOICE,
      "missing-profile",
    );
  }

  // Truncate for IPC — keep generous limit for teleprompter scrolling.
  // Voice Bar's ScrollView + FlowLayout handles long text fine.
  const speakingText = displayText.slice(0, 2000);

  // Context-aware shortcut: short announcements use edge-tts for speed.
  // Skipped when a clone is mandated — a required clone must not be downgraded.
  if (
    resolved.engine === "cloned" &&
    !requireClone &&
    options?.mode === "announce" &&
    spokenText.length < 50
  ) {
    return speakWithEdgeTTS(
      spokenText,
      resolved.fallbackVoice || DEFAULT_VOICE,
      options,
      resolved.warning,
      displayText,
    );
  }

  // Cloned voice → multi-engine synthesis cascade
  if (resolved.engine === "cloned") {
    const profile = loadProfile(resolved.voice);
    const profileAssetVoice = profile?.directory_name || resolved.voice;

    // Tier 0: XTTS-v2 fine-tuned (best quality -- captures cadence + timbre)
    if (isXTTSAvailable(profileAssetVoice) && profile?.reference_clip) {
      const wavPath = await synthesizeXTTS(
        spokenText,
        profileAssetVoice,
        profile.reference_clip,
      );
      const mp3Path = wavPath ? convertWavToMp3(wavPath) : null;
      if (mp3Path) {
        const playback = await playClonedAudio(
          mp3Path,
          displayText,
          `xtts:${resolved.voice}`,
          speakingText,
          resolved.voice,
          options,
        );
        return {
          warning: resolved.warning,
          displayText,
          engine: "xtts-v2",
          voice: resolved.voice,
          ...playback,
        };
      }
      console.error(
        `[voicelayer] XTTS inference failed for "${resolved.voice}" -- trying F5-TTS`,
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
        spokenText,
        profile.reference_clip,
        profile.reference_text,
      );
      const mp3Path = wavPath ? convertWavToMp3(wavPath) : null;
      if (mp3Path) {
        const playback = await playClonedAudio(
          mp3Path,
          displayText,
          `f5tts:${resolved.voice}`,
          speakingText,
          resolved.voice,
          options,
        );
        return {
          warning: resolved.warning,
          displayText,
          engine: "f5-tts-mlx",
          voice: resolved.voice,
          ...playback,
        };
      }
      console.error(
        `[voicelayer] F5-TTS synthesis failed for "${resolved.voice}" -- trying Qwen3 daemon`,
      );
    }

    // Tier 1b: Qwen3-TTS daemon (HTTP-based zero-shot)
    const audioBuffer = await synthesizeCloned(spokenText, resolved.voice);
    if (audioBuffer) {
      const ttsFile = ttsFilePath(process.pid, ttsCounter++);
      writeFileSync(ttsFile, audioBuffer);
      const playback = await playClonedAudio(
        ttsFile,
        displayText,
        `cloned:${resolved.voice}`,
        speakingText,
        resolved.voice,
        options,
      );
      return {
        warning: resolved.warning,
        displayText,
        engine: "qwen3-tts",
        voice: resolved.voice,
        ...playback,
      };
    }

    // All cloned engines failed. Fail-closed when the clone is mandated;
    // otherwise keep the resilient edge-tts fallback.
    if (requireClone) {
      throw new VoiceProfileUnavailableError(
        resolved.voice,
        "synthesis-failed",
      );
    }
    console.error(
      `[voicelayer] Cloned voice "${resolved.voice}" unavailable — falling back to edge-tts (${resolved.fallbackVoice})`,
    );
    return speakWithEdgeTTS(
      spokenText,
      resolved.fallbackVoice || DEFAULT_VOICE,
      options,
      undefined,
      displayText,
    );
  }

  // Tier 2: Preset/default → edge-tts
  return speakWithEdgeTTS(
    spokenText,
    resolved.voice,
    options,
    resolved.warning,
    displayText,
  );
}

/**
 * Synthesize and play via edge-tts (Python CLI).
 * Extracted from speak() to allow fallback from cloned voice failure.
 */
async function speakWithEdgeTTS(
  spokenText: string,
  voice: string,
  options?: {
    rate?: string;
    mode?: string;
    waitForPlayback?: boolean;
    onPlaybackStart?: (startedAtMs: number) => void;
    onPlaybackComplete?: (outcome: PlaybackOutcomeEvent) => void;
    captureAudioArtifact?: boolean;
  },
  warning?: string,
  displayText: string = spokenText,
): Promise<TextToSpeechResult> {
  // Determine rate: explicit > mode default > env default
  let rate =
    options?.rate ??
    (options?.mode ? MODE_RATES[options.mode] : undefined) ??
    DEFAULT_RATE;

  // Auto-slow for long text
  rate = adjustRateForLength(rate, spokenText.length);

  const ttsFile = ttsFilePath(process.pid, ttsCounter++);
  const scriptPath = new URL("../scripts/edge-tts-words.py", import.meta.url)
    .pathname;
  const tempChunkFiles: string[] = [];
  let wordBoundaries: WordBoundary[] = [];

  try {
    const textChunks = chunkTextForTTS(spokenText);

    if (textChunks.length === 1) {
      const synthesized = await synthesizeEdgeChunk(
        textChunks[0],
        voice,
        rate,
        ttsFile,
        scriptPath,
      );
      wordBoundaries = synthesized.wordBoundaries;
    } else {
      const synthesizedChunks: SynthesizedChunk[] = [];

      for (const [index, chunk] of textChunks.entries()) {
        const chunkFile = ttsFile.replace(".mp3", `.chunk${index}.mp3`);
        tempChunkFiles.push(chunkFile);
        synthesizedChunks.push(
          await synthesizeEdgeChunk(chunk, voice, rate, chunkFile, scriptPath),
        );
      }

      concatenateMp3Files(
        synthesizedChunks.map((chunk) => chunk.audioFile),
        ttsFile,
      );
      wordBoundaries = mergeWordBoundaryChunks(synthesizedChunks);
    }
  } catch (error) {
    broadcast({
      type: "error",
      message: "TTS synthesis failed (edge-tts)",
      recoverable: true,
    });
    broadcastPlaybackIdleIfSpeakerClear();
    for (const file of tempChunkFiles) {
      try {
        unlinkSync(file);
      } catch {}
      try {
        unlinkSync(file.replace(".mp3", ".meta.ndjson"));
      } catch {}
    }
    try {
      unlinkSync(ttsFile);
    } catch {}
    throw error;
  }

  for (const file of tempChunkFiles) {
    try {
      unlinkSync(file);
    } catch {}
  }

  wordBoundaries = alignWordBoundariesToDisplayText(
    displayText,
    spokenText,
    wordBoundaries,
  );

  // Pass metadata to queue — broadcasting happens when audio actually starts
  let proc: PlaybackHandle;
  let audioArtifact: TextToSpeechResult["audioArtifact"];
  try {
    assertSpeakerClear();
    audioArtifact = captureAudioArtifact(
      ttsFile,
      options?.captureAudioArtifact,
    );
    addToHistory(displayText, ttsFile, voice);
    proc = playAudioNonBlocking(ttsFile, {
      text: displayText.slice(0, 2000),
      voice,
      wordBoundaries: wordBoundaries.length > 0 ? wordBoundaries : undefined,
      priority: playbackPriorityForMode(options?.mode),
      durationMs:
        wordBoundaries.length > 0
          ? inferBoundaryEndMs(wordBoundaries)
          : undefined,
      nextState: options?.mode === "converse" ? "recording" : undefined,
      onStarted: options?.onPlaybackStart,
      onCompleted: options?.onPlaybackComplete,
    });
  } catch (err) {
    try {
      unlinkSync(ttsFile);
    } catch {}
    throw err;
  }
  proc.exited.then(() => {
    try {
      unlinkSync(ttsFile);
    } catch {}
  });

  const playbackOutcome = options?.waitForPlayback
    ? await proc.exited
    : undefined;

  return {
    warning,
    displayText,
    engine: "edge-tts",
    voice,
    audioArtifact,
    playbackId: proc.id,
    ...(playbackOutcome ? { playbackOutcome } : {}),
  };
}

export class VoiceLayerTextToSpeechBackend implements TextToSpeechBackend {
  speak(
    text: string,
    options?: TextToSpeechOptions,
  ): Promise<TextToSpeechResult> {
    return speak(text, options);
  }
}
