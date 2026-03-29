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
import type { WordBoundary } from "./socket-protocol";
import { applyPronunciation } from "./pronunciation";
import { synthesizeWithRetry } from "./tts-health";

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
  options?: { waitForPlayback?: boolean },
): Promise<void> {
  addToHistory(text, ttsFile, voiceLabel);
  const proc = playAudioNonBlocking(ttsFile, {
    text: speakingText,
    voice: resolvedVoice,
    priority: playbackPriorityForMode(options?.mode),
  });
  proc.exited.then(() => {
    try {
      unlinkSync(ttsFile);
    } catch {}
  });
  if (options?.waitForPlayback) await proc.exited;
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
type PlaybackPriority =
  | "critical"
  | "high"
  | "normal"
  | "low"
  | "background";

/** Metadata for deferred broadcasting — fires when playback actually starts. */
export interface PlaybackMetadata {
  text: string;
  voice: string;
  wordBoundaries?: WordBoundary[];
  priority?: PlaybackPriority;
}

interface PlaybackJob {
  audioFile: string;
  metadata?: PlaybackMetadata;
  priority: PlaybackPriority;
  enqueuedAt: number;
  expiresAt: number;
  resolveExited: () => void;
  completed: boolean;
  exited: Promise<void>;
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

function completeJob(job: PlaybackJob) {
  if (job.completed) return;
  job.completed = true;
  job.resolveExited();
}

class PlaybackQueueManager {
  private pending: PlaybackJob[] = [];
  private current: { job: PlaybackJob; proc: ReturnType<typeof Bun.spawn> } | null =
    null;
  private drainWaiters = new Set<() => void>();

  enqueue(audioFile: string, metadata?: PlaybackMetadata): { exited: Promise<void> } {
    const priority = metadata?.priority ?? "normal";
    let resolveExited!: () => void;
    const exited = new Promise<void>((resolve) => {
      resolveExited = resolve;
    });

    const job: PlaybackJob = {
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
      return { exited };
    }

    this.evictExpired();
    this.collapseBurstyLowPriority(job);
    this.insert(job);
    this.emitQueueDepth();
    this.processNext();
    return { exited };
  }

  async awaitDrained(): Promise<void> {
    if (this.depth() === 0) return;
    await new Promise<void>((resolve) => {
      this.drainWaiters.add(resolve);
    });
  }

  stop(): boolean {
    const hadActivity = this.depth() > 0;
    const active = this.current;
    this.current = null;

    for (const job of this.pending.splice(0)) {
      completeJob(job);
    }

    if (active) {
      try {
        active.proc.kill("SIGTERM");
      } catch {}
      completeJob(active.job);
    }

    if (hadActivity) {
      broadcast({ type: "state", state: "idle", source: "playback" });
      this.emitQueueDepth();
      this.resolveIfIdle();
    }

    return hadActivity;
  }

  private processNext() {
    if (this.current) return;

    while (this.pending.length > 0) {
      const next = this.pending.shift()!;
      if (next.expiresAt <= Date.now()) {
        completeJob(next);
        continue;
      }

      if (next.metadata?.wordBoundaries?.length) {
        broadcast({ type: "subtitle", words: next.metadata.wordBoundaries });
      }
      if (next.metadata) {
        broadcast({
          type: "state",
          state: "speaking",
          text: next.metadata.text,
          voice: next.metadata.voice,
        });
      }

      let proc: ReturnType<typeof Bun.spawn>;
      try {
        proc = Bun.spawn([getAudioPlayer(), next.audioFile], {
          stdout: "ignore",
          stderr: "ignore",
        });
      } catch {
        if (this.depth() === 0) {
          broadcast({ type: "state", state: "idle", source: "playback" });
        }
        this.emitQueueDepth();
        completeJob(next);
        this.resolveIfIdle();
        this.processNext();
        return;
      }

      this.current = { job: next, proc };
      this.emitQueueDepth();

      proc.exited
        .then(() => {
          this.finish(next, proc.pid);
        })
        .catch(() => {
          this.finish(next, proc.pid);
        });
      return;
    }

    if (this.depth() === 0) {
      this.emitQueueDepth();
      this.resolveIfIdle();
    }
  }

  private finish(job: PlaybackJob, pid: number) {
    if (this.current?.proc.pid === pid) {
      this.current = null;
      if (this.depth() === 0) {
        broadcast({ type: "state", state: "idle", source: "playback" });
      }
      this.emitQueueDepth();
      this.resolveIfIdle();
      this.processNext();
    }
    completeJob(job);
  }

  private bargeIn(job: PlaybackJob) {
    const active = this.current;
    this.current = null;

    for (const queued of this.pending.splice(0)) {
      completeJob(queued);
    }

    if (active) {
      try {
        active.proc.kill("SIGTERM");
      } catch {}
      completeJob(active.job);
    }

    this.pending = [job];
    this.emitQueueDepth();
    this.processNext();
  }

  private collapseBurstyLowPriority(job: PlaybackJob) {
    if (job.priority !== "low" && job.priority !== "background") return;

    this.pending = this.pending.filter((queued) => {
      const isCollapsible =
        queued.priority === job.priority || queued.priority === "background";
      if (isCollapsible) {
        completeJob(queued);
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

  private emitQueueDepth() {
    broadcast({ type: "queue", depth: this.depth() });
  }

  private evictExpired() {
    const now = Date.now();
    this.pending = this.pending.filter((job) => {
      if (job.expiresAt <= now) {
        completeJob(job);
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
    return this.pending.length + (this.current ? 1 : 0);
  }
}

const playbackQueueManager = new PlaybackQueueManager();

/** Play an audio file, queued after any currently playing audio. */
export function playAudioNonBlocking(
  audioFile: string,
  metadata?: PlaybackMetadata,
): {
  exited: Promise<void>;
} {
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

/** Stop current playback if any. */
export function stopPlayback(): boolean {
  return playbackQueueManager.stop();
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

  // Truncate for IPC — keep generous limit for teleprompter scrolling.
  // Voice Bar's ScrollView + FlowLayout handles long text fine.
  const speakingText = text.slice(0, 2000);

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

    // Tier 0: XTTS-v2 fine-tuned (best quality -- captures cadence + timbre)
    if (isXTTSAvailable(resolved.voice) && profile?.reference_clip) {
      const wavPath = await synthesizeXTTS(
        text,
        resolved.voice,
        profile.reference_clip,
      );
      const mp3Path = wavPath ? convertWavToMp3(wavPath) : null;
      if (mp3Path) {
        await playClonedAudio(
          mp3Path,
          text,
          `xtts:${resolved.voice}`,
          speakingText,
          resolved.voice,
          options,
        );
        return { warning: resolved.warning };
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
        text,
        profile.reference_clip,
        profile.reference_text,
      );
      const mp3Path = wavPath ? convertWavToMp3(wavPath) : null;
      if (mp3Path) {
        await playClonedAudio(
          mp3Path,
          text,
          `f5tts:${resolved.voice}`,
          speakingText,
          resolved.voice,
          options,
        );
        return { warning: resolved.warning };
      }
      console.error(
        `[voicelayer] F5-TTS synthesis failed for "${resolved.voice}" -- trying Qwen3 daemon`,
      );
    }

    // Tier 1b: Qwen3-TTS daemon (HTTP-based zero-shot)
    const audioBuffer = await synthesizeCloned(text, resolved.voice);
    if (audioBuffer) {
      const ttsFile = ttsFilePath(process.pid, ttsCounter++);
      writeFileSync(ttsFile, audioBuffer);
      await playClonedAudio(
        ttsFile,
        text,
        `cloned:${resolved.voice}`,
        speakingText,
        resolved.voice,
        options,
      );
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
  const scriptPath = new URL("../scripts/edge-tts-words.py", import.meta.url)
    .pathname;
  const tempChunkFiles: string[] = [];
  let wordBoundaries: WordBoundary[] = [];

  try {
    const textChunks = chunkTextForTTS(text);

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
    broadcast({ type: "state", state: "idle", source: "playback" });
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

  addToHistory(text, ttsFile, voice);

  // Pass metadata to queue — broadcasting happens when audio actually starts
  const proc = playAudioNonBlocking(ttsFile, {
    text: text.slice(0, 2000),
    voice,
    wordBoundaries: wordBoundaries.length > 0 ? wordBoundaries : undefined,
    priority: playbackPriorityForMode(options?.mode),
  });
  proc.exited.then(() => {
    try {
      unlinkSync(ttsFile);
    } catch {}
  });

  if (options?.waitForPlayback) {
    await proc.exited;
  }

  return { warning };
}
