import { beginSpeechArchive, unlinkSpeechAudio, type LiveSpeechArchive } from "./speech-archive-live";
import { truncateAtWordBoundary } from "./tts/truncate";
import { displayTokens } from "./tts/display-tokens";
import { structuredReadDisplay } from "./tts/structured-display";
import type { StructuredSpeech } from "./tts/structured-speech";
import { randomUUID } from "node:crypto";
import { normalizedSpeechHash } from "./speech-identity";
import type { SpeakArchiveContext } from "./speak-archive";
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
import { resolveBinary } from "./resolve-binary";
import { throwIfAbortedSafe } from "./abort";
import { platform } from "os";
import {
  ttsFilePath,
  TTS_HISTORY_FILE,
  ttsHistoryFilePath,
  TTS_DISABLED_FILE,
  isDefaultVoiceBarSocketPath,
} from "./paths";
import { hasClonedProfile, synthesizeCloned, loadProfile } from "./tts/qwen3";
import { isF5TTSAvailable, synthesizeF5TTS } from "./tts/f5tts";
import { isXTTSAvailable, synthesizeXTTS } from "./tts/xtts";
import { broadcast, setCommandTelemetrySnapshot, type CommandTelemetrySnapshot } from "./socket-client";
import type {
  AlignedWordBoundary,
  PlaybackOutcomeEvent,
  PlaybackOutcomeReason,
  PlaybackOutcomeStatus,
  PlaybackPriority,
  PlaybackStateEvent,
  QueueItemSnapshot,
  WordBoundary,
  StateEvent,
} from "./socket-protocol";
import type {
  PlaybackController,
  PlaybackMetadata as SoundLayerPlaybackMetadata,
  TextToSpeechBackend,
  TextToSpeechOptions,
  TextToSpeechResult,
} from "./soundlayer";
import { pronunciationRules } from "./pronunciation";
import { projectSpeakableText } from "./speakable-text";
import type { ProjectionRange } from "./tts/structured-speech";
import { synthesizeWithRetry, type EdgeProsody } from "./tts-health";
import { sanitizeTtsText } from "./sanitize";
import { RetainedReadback } from "./tts/retained-readback";
import { prepareSeekSlice, disposeSeekSlice } from "./tts/seek-audio";
import { PlaybackLifecycle, type PlaybackScope, type QueuedPlaybackHandle } from "./tts/playback-lifecycle";
export type { PlaybackScope, QueuedPlaybackHandle } from "./tts/playback-lifecycle";
import { longReadDocument, runLongRead, type LongReadSeek, type SeekResult } from "./tts/long-read";
import { PreparedReadStart, type PreparedChunk } from "./tts/selection-read-preparation";
import { SPEAK_TEXT_MAX_CHARS } from "./socket-protocol";
import { assembleLongReadHistory, runAudioCommand } from "./tts/long-read-audio";
import { planProsody, type ProsodyPlan } from "./tts/prosody";
import { createProsodyRead, decodeAudioToPCM, encodePCMToMp3, isStructuredPlan, sliceProjection } from "./tts/prosody-read";
import { hasActiveVoiceOperation } from "./voice-operation-reservation";
import { getEffectiveRecordingState } from "./recording-state";
import { startCloneTiming } from "./tts/clone-timing";
import { combineHistoryTimings } from "./tts/history-timings";
import {
  startPlaybackAmplitudeEnvelopeExtraction,
  type PlaybackAmplitudeEnvelope,
  type PlaybackAmplitudeExtraction,
} from "./playback-amplitude";

import { resolveSpeakProfile, TTS_DEFAULTS } from "./tts-settings";
import { recordFirstAudio } from "./tts-controls-status";
export { resolveSpeakProfile } from "./tts-settings";
const defaultVoice = () => process.env.QA_VOICE_TTS_VOICE || TTS_DEFAULTS.voice;
const defaultRate = () => process.env.QA_VOICE_TTS_RATE || TTS_DEFAULTS.rate;
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

function broadcastPlaybackIdleIfSpeakerClear(nextState?: "recording", intent: "completion" | "stop" | "audio-completion" = "completion"): void {
  if (getEffectiveRecordingState() !== "idle") return;
  // Ask owns the idle edge until it validates the handoff or reports an error.
  if (isCaptureAdmissionReserved()) return;
  // Explicit global Stop acknowledges logical cancellation; it is not reap proof.
  if (intent !== "stop" && (intent === "audio-completion"
    ? playbackQueueManager.getAudioDepth() : getPlaybackQueueDepth()) > 0) return;
  // A parked item is not idle; only Stop/replacement settles it first.
  if (playbackQueueManager.isPaused()) return;
  if (activeLongRead && !activeLongRead.controller.signal.aborted && !nextState && intent !== "audio-completion") return;
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

export function resolveVoice(name?: string, engine?: "edge" | "clone"): {
  voice: string;
  engine: "cloned" | "edge-tts";
  warning?: string;
  fallbackVoice?: string;
} {
  const requestedName = name || defaultVoice();

  // Tier 1: Check for cloned voice profile (profile.yaml)
  const clonedProfile = engine === "edge" ? null : loadProfile(requestedName);
  if (clonedProfile) {
    return {
      voice: clonedProfile.profile_id || clonedProfile.name || requestedName,
      engine: "cloned",
      fallbackVoice: clonedProfile.fallback || defaultVoice(),
    };
  }

  if (engine === "clone") throw new VoiceProfileUnavailableError(requestedName, "missing-profile");

  // Tier 2: Check preset profiles (voices.json)
  const profiles = loadVoiceProfiles();
  const profile = profiles[requestedName.toLowerCase()];
  if (profile) {
    if (profile.engine !== "edge-tts") {
      return {
        voice: defaultVoice(),
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
    voice: defaultVoice(),
    engine: "edge-tts",
    warning: `Unknown voice "${requestedName}". Using default (${defaultVoice()}). Add it to ~/.voicelayer/voices.json or use a raw edge-tts voice name.`,
  };
}

let ttsCounter = 0;

/**
 * AIDEV-NOTE: Playback is SILENT whenever this process is not the resident stack.
 *
 * On 2026-09-08 Etan heard the Swift replay fixtures out of his speakers twice in
 * one afternoon — *"finished speech replay must... and the other audio shit is
 * back, wtf?"* — because every harness that spawns a real daemon inherits the
 * real TTS path, which ends in `afplay` at full volume.
 *
 * The discriminator is structural, not a flag somebody has to remember: a harness
 * ALWAYS overrides the socket path (the bun preload redirects it;
 * `corpus-replay-verify.ts:79-82` refuses to run against the live sockets at all).
 * So "socket overridden" means "not the machine's real stack" and playback is
 * muted. A harness cannot make itself audible without pointing at the live
 * socket, which is independently refused — which is what makes this impossible to
 * regress by forgetting an env var in a brief.
 *
 * `afplay -v 0` still spawns a real `afplay` child with the same name and parent,
 * so the Swift assertions that count `afplay` children are unaffected. Muting is
 * an audibility change only; nothing about what is verified changes.
 */
export function buildPlaybackArgv(
  player: string,
  audioFile: string,
  isResidentStack: boolean = isDefaultVoiceBarSocketPath(),
): string[] {
  if (isResidentStack || player !== "afplay") return [player, audioFile];
  return [player, "-v", "0", audioFile];
}

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
export const TTS_CHUNK_MAX_CHARS = 400;
export function chunkTextForTTS(text: string, maxLen = TTS_CHUNK_MAX_CHARS): string[] {
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

/** Natural startup, a 200-character bridge, then throughput-sized body requests. */
export function chunkTextForLongRead(text: string): string[] {
  if (text.length <= 100 || !text.trim()) return [text];
  const prefix = (remaining: string, budget: number): number => {
    const minimum = 40;
    const cap = TTS_CHUNK_MAX_CHARS;
    const unsafeEnd = (end: number) => {
      const ending = remaining.slice(0, end).replace(/["'”’)\]]+$/u, "");
      return /(?:\b(?:dr|mr|mrs|ms|prof|sr|jr|vs|etc)|\b\d+)\.$/iu.test(ending) ||
        /(?:^|[\s"'“‘(])(?:[A-Za-z]\.)+$/u.test(ending) || /\b(?:e\.g|i\.e)\.$/iu.test(ending);
    };
    const sentences = [...remaining.matchAll(/[.!?…]["'”’)]*(?=\s|$)/gu)]
      .map(match => match.index + match[0].length)
      .filter(end => !unsafeEnd(end));
    const sentence = sentences.find(end => end >= minimum) ?? remaining.length;
    if (sentence <= budget) return budget === 200
      ? sentences.filter(end => end >= minimum && end <= budget).at(-1) ?? sentence
      : sentence;
    // Prefer a real clause over a bare word break. Short prefixes need enough speech
    // to cover preparation of the next request, including names and list markers.
    for (const punctuation of [/[;:](?=\s|$)/gu, /[,،，](?=\s|$)/gu]) {
      const boundary = [...remaining.slice(0, Math.min(budget, sentence)).matchAll(punctuation)]
        .map(match => match.index + match[0].length).find(end => end >= minimum);
      if (boundary !== undefined) return boundary;
    }
    if (sentence <= cap) return sentence;
    // Pathological unpunctuated prose still has a bounded engine request.
    const words = [...remaining.slice(0, cap + 1).matchAll(/\s+/gu)]
      .map(match => match.index).filter(end => end >= minimum && end <= cap && !unsafeEnd(end));
    return words.at(-1) ?? cap;
  };
  const chunks: string[] = [];
  let remaining = text.trim();
  for (const budget of [100, 200]) {
    if (!remaining) break;
    const end = prefix(remaining, budget);
    chunks.push(remaining.slice(0, end).trimEnd());
    remaining = remaining.slice(end).trimStart();
  }
  if (remaining) chunks.push(...chunkTextForTTS(remaining));
  return chunks;
}

function inferBoundaryEndMs(wordBoundaries: WordBoundary[]): number {
  return wordBoundaries.reduce(
    (max, word) => Math.max(max, word.offset_ms + word.duration_ms),
    0,
  );
}

function probeAudioDurationMs(audioFile: string, timeoutMs?: number): number | null {
  try {
    const ffprobe = resolveBinary("ffprobe");
    if (!ffprobe) return null;
    const probe = Bun.spawnSync([
      ffprobe,
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      audioFile,
    ], { timeout: timeoutMs });
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
  signal?: AbortSignal,
  maxRetries = 1,
  prosody?: EdgeProsody,
): Promise<SynthesizedChunk> {
  const result = await synthesizeWithRetry(
    text,
    voice,
    rate,
    audioFile,
    scriptPath,
    maxRetries,
    signal,
    prosody,
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
  ranges?: ProjectionRange[],
  force = false,
): WordBoundary[] {
  if ((!force && displayText === spokenText) || !wordBoundaries.length) return wordBoundaries;
  const projection = ranges ? {speechText: spokenText, ranges} : projectSpeakableText(displayText, pronunciationRules(), "edge");
  const tokens = displayTokens(displayText);
  const unknown = (): WordBoundary[] => tokens.length === 1 ? [{
    text: displayText, offset_ms: wordBoundaries[0].offset_ms,
    duration_ms: wordBoundaries.at(-1)!.offset_ms + wordBoundaries.at(-1)!.duration_ms - wordBoundaries[0].offset_ms,
  }] : [];
  if (projection.speechText !== spokenText) return unknown();
  // Engine punctuation tokenization may differ. Match the full letter/number
  // stream before accepting any timings; a partial or stale stream is untimed.
  const canonical = (text: string) => text.replace(/[^\p{L}\p{M}\p{N}]/gu, "").toLowerCase();
  const positions: number[] = [];
  let normalized = "";
  for (let i = 0; i < spokenText.length;) {
    const char = String.fromCodePoint(spokenText.codePointAt(i)!);
    const value = canonical(char);
    for (let j = 0; j < value.length; j++) positions.push(i);
    normalized += value; i += char.length;
  }
  const timing: ({start: number; end: number} | undefined)[] = tokens.map(() => undefined);
  let cursor = 0;
  for (const boundary of wordBoundaries) {
    const value = canonical(boundary.text);
    if (!value) continue;
    if (normalized.slice(cursor, cursor + value.length) !== value) return unknown();
    const start = positions[cursor], final = positions[cursor + value.length - 1];
    const end = final + (spokenText.codePointAt(final)! > 0xffff ? 2 : 1);
    cursor += value.length;
    for (const range of projection.ranges) {
      const left = Math.max(start, range.speech.start), right = Math.min(end, range.speech.end);
      if (left >= right || range.display.start === range.display.end) continue;
      const sourceStart = range.kind === "identity" ? range.display.start + left - range.speech.start : range.display.start;
      const sourceEnd = range.kind === "identity" ? range.display.start + right - range.speech.start : range.display.end;
      for (let i = 0; i < tokens.length; i++) {
        if (tokens[i].index >= sourceEnd || tokens[i].index + tokens[i][0].length <= sourceStart) continue;
        const previous = timing[i];
        timing[i] = {start: Math.min(previous?.start ?? Infinity, boundary.offset_ms),
          end: Math.max(previous?.end ?? 0, boundary.offset_ms + boundary.duration_ms)};
      }
    }
  }
  if (cursor !== normalized.length) return unknown();
  // Keep the existing wire's original whitespace-token identity. Omitted markdown
  // tokens have zero duration at the next measured onset, never fabricated speech.
  return tokens.map((token, i) => {
    const measured = timing[i];
    const offset = measured?.start ?? timing.slice(i + 1).find(Boolean)?.start ??
      timing.slice(0, i).reverse().find(Boolean)?.end ?? 0;
    return {text: token[0], offset_ms: offset, duration_ms: measured ? measured.end - measured.start : 0};
  });
}

/** Edge timings one per display token. Raw engine words (display === spoken) still need the token map. */
export function displayTokenBoundaries(displayText: string, wordBoundaries: WordBoundary[]): WordBoundary[] {
  const tokens = displayTokens(displayText).map(match => match[0]);
  if (wordBoundaries.length === tokens.length && wordBoundaries.every((word, i) => word.text === tokens[i])) return wordBoundaries;
  const whole = { start: 0, end: displayText.length };
  return alignWordBoundariesToDisplayText(displayText, displayText, wordBoundaries,
    [{ kind: "identity", source: whole, display: whole, speech: whole }], true);
}

// --- Ring Buffer ---

export interface TTSHistoryEntry {
  id: number; // 0-19 circular
  file: string; // /tmp/voicelayer-history-N.mp3
  text: string; // original message
  voice: string; // which voice was used
  timestamp: number; // Date.now()
  /** Long-read chunks whose audio was never synthesized (stopped first); their text is still in `text`. */
  audioMissingChunks?: number[];
  /** WORDTIME1: the Edge timings the read used, replayed as-is. */
  wordBoundaries?: WordBoundary[];
  /** WORDTIME1: clone/long-read timings indexed against `text`, on this file's timeline. */
  alignedWords?: AlignedWordBoundary[];
  prosodyIdentity?: string;
}

/** Identifies one history entry; the ring reuses ids, so the timestamp pins the write. */
export type TTSHistoryRef = Pick<TTSHistoryEntry, "id" | "timestamp">;

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
export function addToHistory(text: string, audioFile: string, voice: string, audioMissingChunks: number[] = [],
  timings: Pick<TTSHistoryEntry, "wordBoundaries" | "alignedWords" | "prosodyIdentity"> = {}): TTSHistoryRef | undefined {
  const entries = loadHistory();
  const id = ringIndex % RING_BUFFER_SIZE;
  const historyFile = ttsHistoryFilePath(id);

  // Copy audio file to persistent ring buffer slot
  try {
    copyFileSync(audioFile, historyFile);
  } catch {
    return undefined; // If copy fails, skip history entry
  }

  const entry: TTSHistoryEntry = {
    id,
    file: historyFile,
    text,
    voice,
    timestamp: Date.now(),
    ...(audioMissingChunks.length ? { audioMissingChunks } : {}),
    ...(timings.wordBoundaries?.length ? { wordBoundaries: timings.wordBoundaries } : {}),
    ...(timings.alignedWords?.length ? { alignedWords: timings.alignedWords } : {}),
    ...(timings.prosodyIdentity ? { prosodyIdentity: timings.prosodyIdentity } : {}),
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
  return { id, timestamp: entry.timestamp };
}

/** Clone alignment lands after playback starts; attach it to the entry it measured, never a newer one. */
export function updateHistoryAlignedWords(ref: TTSHistoryRef, alignedWords: AlignedWordBoundary[]): void {
  const entries = loadHistory();
  const entry = entries.find(e => e.id === ref.id && e.timestamp === ref.timestamp);
  if (!entry || !alignedWords.some(word => word.offset_ms !== null)) return;
  entry.alignedWords = alignedWords;
  saveHistory(entries);
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
  const ffmpeg = resolveBinary("ffmpeg");
  if (!ffmpeg) return null;
  const result = Bun.spawnSync([
    ffmpeg,
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
type SpeechOptions = TextToSpeechOptions & { speechArchive?: LiveSpeechArchive; generatedEngine?: string };

async function playClonedAudio(
  ttsFile: string,
  text: string,
  voiceLabel: string,
  speakingText: string,
  resolvedVoice: string,
  projection: ReturnType<typeof projectSpeakableText>,
  options?: SpeechOptions,
  signal?: AbortSignal,
): Promise<
  Pick<
    TextToSpeechResult,
    "audioArtifact" | "playbackId" | "playbackOutcome"
  >
> {
  const percentage = parseInt(options?.rate ?? "+0%", 10);
  if (Number.isFinite(percentage) && percentage !== 0) {
    const adjusted = ttsFile.replace(/\.mp3$/, ".rate.mp3");
    const factor = Math.max(0.01, 1 + percentage / 100);
    const filters: string[] = [];
    let remaining = factor;
    while (remaining < 0.5) { filters.push("atempo=0.5"); remaining /= 0.5; }
    while (remaining > 2) { filters.push("atempo=2"); remaining /= 2; }
    filters.push(`atempo=${remaining}`);
    const ffmpeg = resolveBinary("ffmpeg");
    if (!ffmpeg) throw new Error("ffmpeg unavailable for clone rate conversion");
    const conversion = Bun.spawnSync([ffmpeg, "-y", "-i", ttsFile, "-af", filters.join(","), adjusted], {stdout: "ignore", stderr: "pipe"});
    if (conversion.exitCode !== 0) {
      for (const path of [adjusted, ttsFile]) { try { unlinkSpeechAudio(path); } catch {} }
      throw new Error("Clone rate conversion failed");
    }
    try { unlinkSpeechAudio(ttsFile); } catch {}
    ttsFile = adjusted;
  }
  let proc: QueuedPlaybackHandle;
  let audioArtifact: TextToSpeechResult["audioArtifact"];
  try {
    throwIfAbortedSafe(signal);
    assertSpeakerClear();
    audioArtifact = captureAudioArtifact(
      ttsFile,
      options?.captureAudioArtifact,
    );
    const durationMs = probeAudioDurationMs(ttsFile) ?? undefined;
    options?.speechArchive?.generated(ttsFile, options?.generatedEngine === "xtts-v2" ? truncateAtWordBoundary(projection.speechText, 240) : options?.generatedEngine === "f5-tts-mlx" ? truncateAtWordBoundary(projection.speechText, 300) : projection.speechText, resolvedVoice, options?.profile ?? "short", options?.generatedEngine ?? "qwen3-tts", 0, durationMs ?? null);
    const historyRef = addToHistory(text, ttsFile, voiceLabel);
    proc = playAudioNonBlocking(ttsFile, {
      speechArchive: options?.speechArchive,
      text: speakingText,
      voice: resolvedVoice,
      priority: playbackPriorityForMode(options?.mode),
      durationMs,
      cloneProjection: projection,
      onAlignedWords: words => { if (historyRef) updateHistoryAlignedWords(historyRef, words); },
      nextState: options?.mode === "converse" ? "recording" : undefined,
      onStarted: options?.onPlaybackStart,
      onQueued: options?.onPlaybackQueued,
      onCompleted: options?.onPlaybackComplete,
    });
  } catch (err) {
    try {
      unlinkSpeechAudio(ttsFile);
    } catch {}
    throw err;
  }
  void proc.playerExited.then(() => {
    try {
      unlinkSpeechAudio(ttsFile);
    } catch {}
  }, () => {});
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
 * 3. Critical items preempt only the current owner; unrelated pending speech survives.
 * 4. Low/background chatter collapses so bursts do not create an audio backlog.
 */
/** Metadata for deferred broadcasting — fires when playback actually starts. */
export interface PlaybackMetadata extends SoundLayerPlaybackMetadata {
  speechArchive?: LiveSpeechArchive;
  text: string;
  voice: string;
  longRead?: StateEvent["long_read"];
  speechIdentity?: Pick<StateEvent, "request_id" | "text_hash">;
  playbackOffsetMs?: number;
  utteranceDurationMs?: number;
  getUtteranceDurationMs?(): number;
  localOffsetMs?: number;
  seekSliceFile?: string;
  isSeek?: boolean;
  retainedReplay?: boolean;
  readbackID?: string;
  wordBoundaries?: WordBoundary[];
  /** Timings already measured for this file (replay, or a re-played chunk); broadcast at start. */
  preparedAmplitude?: PlaybackAmplitudeExtraction;
  alignedWords?: AlignedWordBoundary[];
  cloneProjection?: ReturnType<typeof projectSpeakableText>;
  prosodyIdentity?: string;
  /** Clone alignment for this playback was published. */
  onAlignedWords?(words: AlignedWordBoundary[]): void;
  priority?: PlaybackPriority;
  /** CLICK2: admit this job already parked at its offset, with no player (Pause landed before it existed). */
  startPaused?: boolean;
  durationMs?: number;
  collapseKey?: string;
  clipMarker?: {
    id: string;
    label: string;
    source?: "tts" | "command";
  };
}

export interface CaptureAdmission {
  admit(handle: QueuedPlaybackHandle): boolean;
  release(): void;
}

interface PlaybackJob {
  id: string;
  lifecycle: PlaybackLifecycle;
  alignments: Set<Promise<void>>;
  audioFile: string;
  sliceFile?: string;
  skipAmplitudeDecode?: boolean;
  metadata?: PlaybackMetadata;
  playbackAmplitude?: PlaybackAmplitudeEnvelope;
  /** The full-file envelope from the first decode; Resume re-sends it from the resume offset. */
  decodedAmplitude?: PlaybackAmplitudeEnvelope;
  priority: PlaybackPriority;
  enqueuedAt: number;
  expiresAt: number;
  resolveExited: (outcome: PlaybackOutcomeEvent) => void;
  completed: boolean;
  exited: Promise<PlaybackOutcomeEvent>;
  /** Announce `resumed` when the next player for this job actually starts. */
  resuming?: boolean;
}

/** One parked utterance: no player, no lease, no TTL; its cursor is frozen until Resume or Stop. */
interface ParkedPlayback {
  job: PlaybackJob;
  offsetMs: number;
  controller: AbortController;
  ready: boolean;
  failed: boolean;
  resumeRequested: boolean;
}
type ControlScope = { id?: string; generation?: number };

interface ActivePlayback {
  job: PlaybackJob;
  proc: ReturnType<typeof Bun.spawn>;
  startedAt: number;
  watchdog?: ReturnType<typeof setTimeout>;
  watchdogTimedOut?: boolean;
  timing?: ReturnType<typeof startCloneTiming>;
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
// Allow player startup/teardown without mistaking synthesis or decoder time for playback.
const PLAYER_WATCHDOG_MARGIN_MS = 5_000;
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

/** VoiceBar indexes an envelope from the speaking edge; drop the samples already heard, never add any. */
function envelopeFromOffset(envelope: PlaybackAmplitudeEnvelope | undefined, offsetMs: number): PlaybackAmplitudeEnvelope | undefined {
  if (envelope?.source !== "decoded-rms") return envelope;
  const samples = envelope.samples.slice(Math.round(offsetMs / envelope.sample_interval_ms));
  return samples.length > 0 ? { ...envelope, samples }
    : { source: "unavailable", sample_interval_ms: envelope.sample_interval_ms, samples: [] };
}

function completeJob(job: PlaybackJob, outcome: PlaybackOutcomeEvent) {
  if (job.completed) return;
  job.completed = true;
  job.lifecycle.complete();
  void job.lifecycle.playerExited.then(() => { disposeSeekSlice(job.sliceFile); job.sliceFile = undefined; }, () => {});
  broadcast(outcome);
  try {
    job.metadata?.speechArchive?.playerEnded();
  } catch { console.error("[speech] player-end archive write failed"); }
  try {
    job.metadata?.onCompleted?.(outcome);
  } catch (error) {
    console.error(
      `[voicelayer] Playback outcome observer failed: ${error instanceof Error ? error.message : String(error)}`,
    );
  }
  job.resolveExited(outcome);
}

const retainedReadback = new RetainedReadback();
process.once("exit", () => retainedReadback.dispose());

class PlaybackQueueManager {
  private captureAdmission?: Set<string>;
  private jobs = new Map<string, PlaybackJob>();
  private pending: PlaybackJob[] = [];
  private preparing: { job: PlaybackJob; cancel: () => void } | null = null;
  private current: ActivePlayback | null = null;
  private terminating = new Map<number, ActivePlayback>();
  private restartAfterTermination: PlaybackJob | null = null;
  private replayPreparingJob: PlaybackJob | null = null;
  private drainWaiters = new Set<() => void>();
  private conversions = new Set<Promise<void>>();
  private alignments = new Set<Promise<void>>();
  private seekPreparation?: { job: PlaybackJob; controller: AbortController };
  private parked?: ParkedPlayback;
  private progressTimer: ReturnType<typeof setInterval> | null = null;

  hasCaptureAdmission(): boolean { return this.captureAdmission !== undefined; }

  reserveCaptureAdmission(): CaptureAdmission | undefined {
    if (this.captureAdmission || this.depth() > 0 || this.conversions.size > 0) return;
    const owned = new Set<string>();
    this.captureAdmission = owned;
    let released = false;
    return {
      admit: handle => {
        if (released || !this.jobs.has(handle.id) || this.jobs.get(handle.id)!.completed) return false;
        // The handler owns this handoff on every completion path, even after release.
        const job = this.jobs.get(handle.id)!;
        if (job.metadata) job.metadata.nextState = undefined;
        owned.add(handle.id); this.processNext(); return true;
      },
      release: () => {
        if (released) return;
        released = true;
        if (this.captureAdmission === owned) this.captureAdmission = undefined;
        this.processNext();
      },
    };
  }

  enqueue(
    audioFile: string,
    metadata?: PlaybackMetadata,
  ): QueuedPlaybackHandle {
    const priority = metadata?.priority ?? "normal";
    let resolveExited!: (outcome: PlaybackOutcomeEvent) => void;
    const exited = new Promise<PlaybackOutcomeEvent>((resolve) => {
      resolveExited = resolve;
    });

    const job: PlaybackJob = {
      id: nextPlaybackId(),
      lifecycle: new PlaybackLifecycle(),
      alignments: new Set(),
      audioFile,
      sliceFile: metadata?.seekSliceFile,
      skipAmplitudeDecode: metadata?.isSeek,
      metadata: metadata ? { ...metadata } : undefined,
      priority,
      enqueuedAt: Date.now(),
      expiresAt: Date.now() + ttlForPriority(priority),
      resolveExited,
      completed: false,
      exited,
    };
    this.jobs.set(job.id, job);
    // Capture/Stop fences include alignment children, never preparation or cleanup.
    const playerExited = job.lifecycle.playerExited.finally(async () => { await Promise.all(job.alignments); });
    void playerExited.then(() => this.jobs.delete(job.id), () => this.jobs.delete(job.id));
    const handle: QueuedPlaybackHandle = { id: job.id, exited,
      get generation() { return job.lifecycle.generation; },
      playerExited,
      waitForPlayerExit: async () => { try { await job.lifecycle.waitForPlayerExit(); } finally { await Promise.all(job.alignments); } } };
    try { metadata?.onQueued?.(handle); }
    catch (error) { console.error(`[voicelayer] Playback queue observer failed: ${String(error)}`); }
    if (job.completed) return handle;
    this.replaceParked();
    if (job.metadata?.startPaused) {
      job.metadata.startPaused = undefined;
      this.park(job, job.metadata.localOffsetMs ?? 0);
      return handle;
    }

    if (priority === "critical" && (!this.captureAdmission || this.captureAdmission.has(job.id))) {
      this.bargeIn(job);
      return handle;
    }

    this.evictExpired();
    this.collapseBurstyLowPriority(job);
    this.insert(job);
    this.emitQueueSnapshot();
    this.processNext();
    return handle;
  }

  cancel(scope: PlaybackScope, elapsedMs?: number, reason: PlaybackOutcomeReason = "stopped"): boolean {
    const job = this.jobs.get(scope.id);
    if (!job || job.completed || !job.lifecycle.matches(scope)) return false;
    if (this.seekPreparation?.job === job) this.cancelSeekPreparation();
    const parked = this.parked?.job === job ? this.parked : undefined;
    if (parked) { this.parked = undefined; parked.controller.abort(); }
    const active = this.current?.job === job ? this.current
      : [...this.terminating.values()].find(candidate => candidate.job === job);
    if (this.current?.job === job) { this.current = null; this.stopProgressTimer(); this.terminate(active!); }
    if (this.preparing?.job === job) {
      const preparation = this.preparing; this.preparing = null; preparation.cancel();
    }
    if (this.restartAfterTermination === job) this.restartAfterTermination = null;
    if (this.replayPreparingJob === job) this.replayPreparingJob = null;
    this.pending = this.pending.filter(candidate => candidate !== job);
    completeJob(job, buildPlaybackOutcome(job, active || parked ? "interrupted" : "skipped", reason, parked?.offsetMs ??
      this.normalizedPlaybackElapsed(elapsedMs) ?? (active ? Date.now() - active.startedAt : 0)));
    this.emitQueueSnapshot(); this.resolveIfIdle(); this.processNext();
    return true;
  }

  cancelUtterance(id: string, elapsedMs?: number): boolean {
    let cancelled = false;
    for (const job of this.jobs.values()) {
      if (job.metadata?.longRead?.id === id) {
        const localMs = elapsedMs === undefined ? undefined : Math.max(0, elapsedMs - job.metadata.longRead.chunk_start_ms);
        cancelled = this.cancel({ id: job.id }, localMs) || cancelled;
      }
    }
    return cancelled;
  }

  async awaitDrained(): Promise<void> {
    while (this.depth() > 0 || this.conversions.size > 0 || this.alignments.size > 0) {
      if (this.depth() > 0) await new Promise<void>((resolve) => { this.drainWaiters.add(resolve); });
      await Promise.all([...this.conversions, ...this.alignments]);
    }
  }

  audioExited(id: string): Promise<void> {
    return this.jobs.get(id)?.lifecycle.playerExited ?? Promise.resolve();
  }

  stop(playbackElapsedMs?: number, cancelled = false): boolean {
    if (cancelled) {
      const jobs = [this.current?.job, this.preparing?.job, this.restartAfterTermination, this.parked?.job, ...this.pending];
      for (const job of jobs) job?.metadata?.speechArchive?.finish("cancelled", "USER_CANCEL");
    }
    const seekJob = this.seekPreparation?.job;
    if (seekJob && (this.current?.job === seekJob || this.preparing?.job === seekJob ||
      this.restartAfterTermination === seekJob || this.pending.includes(seekJob))) this.cancelSeekPreparation();
    const active = this.current;
    if (playbackElapsedMs !== undefined) {
      playbackElapsedMs = Math.max(0, playbackElapsedMs - (active?.job.metadata?.longRead?.chunk_start_ms ?? 0));
    }
    const preparing = this.preparing;
    const restarting = this.restartAfterTermination;
    const parked = this.parked;
    this.parked = undefined;
    parked?.controller.abort();
    const hadActivity =
      parked !== undefined ||
      this.pending.length > 0 ||
      preparing !== null ||
      active !== null ||
      restarting !== null;
    this.current = null;
    this.preparing = null;
    this.restartAfterTermination = null;
    this.replayPreparingJob = null;
    preparing?.cancel();

    if (parked) completeJob(parked.job, buildPlaybackOutcome(parked.job, "interrupted", "stopped", parked.offsetMs));
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
      broadcastPlaybackIdleIfSpeakerClear(undefined, "stop");
      this.emitQueueSnapshot();
      this.resolveIfIdle();
    }

    return hadActivity;
  }

  /** CLICK2 telemetry: the owning job's phase and generation only; never text or metadata. */
  telemetrySnapshot(): { phase: "preparing" | "playing" | "paused"; generation: number } | undefined {
    if (this.parked) return { phase: "paused", generation: this.parked.job.lifecycle.generation };
    if (this.current) return { phase: "playing", generation: this.current.job.lifecycle.generation };
    const job = this.preparing?.job ?? this.restartAfterTermination ?? this.pending[0];
    return job ? { phase: "preparing", generation: job.lifecycle.generation } : undefined;
  }

  isPaused(utteranceId?: string): boolean {
    return this.parked !== undefined && (utteranceId === undefined || this.parked.job.metadata?.longRead?.id === utteranceId);
  }

  replaceParked(): void {
    if (this.parked) this.cancel({ id: this.parked.job.id }, undefined, "replaced");
  }

  private isStale(job: PlaybackJob, scope: ControlScope): boolean {
    return (scope.id !== undefined && scope.id !== job.id) ||
      (scope.generation !== undefined && scope.generation !== job.lifecycle.generation);
  }

  /** Quiesce the owned player (never SIGSTOP) and keep the job, cursor and audio for Resume. */
  pause(scope: ControlScope, elapsedMs?: number): SeekResult {
    const globalOffset = (job: PlaybackJob) => (job.metadata?.longRead?.chunk_start_ms ?? 0) + (job.metadata?.localOffsetMs ?? 0);
    if (this.parked) {
      return this.isStale(this.parked.job, scope) ? { outcome: "reject", reason: "stale" }
        : { outcome: "noop", reason: "already paused", offset_ms: globalOffset(this.parked.job) };
    }
    const active = this.current;
    const job = active?.job ?? this.restartAfterTermination ?? this.preparing?.job;
    if (!job || job.completed) return { outcome: "noop", reason: "nothing playing" };
    if (this.isStale(job, scope)) return { outcome: "reject", reason: "stale" };
    // Ask owns its prompt→answer handoff; it is never parked.
    if (!job.metadata || job.priority === "critical" || this.captureAdmission) return { outcome: "reject", reason: "unsupported" };
    const chunkStart = job.metadata.longRead?.chunk_start_ms ?? 0;
    const elapsed = !active ? job.metadata.localOffsetMs ?? 0
      : elapsedMs !== undefined ? elapsedMs - chunkStart : Date.now() - active.startedAt;
    const offset = Math.min(Math.max(0, Math.round(elapsed)), job.metadata.durationMs ?? Infinity);
    this.cancelSeekPreparation();
    if (active) { this.current = null; this.terminate(active); }
    if (this.preparing?.job === job) { const preparing = this.preparing; this.preparing = null; preparing.cancel(); }
    if (this.restartAfterTermination === job) this.restartAfterTermination = null;
    if (this.replayPreparingJob === job) this.replayPreparingJob = null;
    this.stopProgressTimer();
    this.park(job, offset);
    return { outcome: "accept", offset_ms: chunkStart + offset };
  }

  /** Hold `job` at `offset` with no player: Pause's own park, and a start-paused admission's. */
  private park(job: PlaybackJob, offset: number): void {
    const metadata = job.metadata!;
    job.lifecycle.generation++;
    disposeSeekSlice(job.sliceFile);
    job.sliceFile = undefined;
    // Paused before any decode (during preparation): Resume decodes afresh instead of starting flat.
    job.skipAmplitudeDecode = offset > 0 || job.decodedAmplitude !== undefined;
    metadata.localOffsetMs = offset;
    metadata.playbackOffsetMs = (metadata.longRead?.chunk_start_ms ?? 0) + offset;
    const parked: ParkedPlayback = { job, offsetMs: offset, controller: new AbortController(),
      ready: offset === 0, failed: false, resumeRequested: false };
    this.parked = parked;
    if (offset < (metadata.durationMs ?? Infinity)) metadata.speechArchive?.move("paused");
    // Resume at EOF completes without a new player. Close timing now and keep
    // the legal playing -> completed path, including for a long-read chunk.
    else metadata.speechArchive?.playerEnded();
    if (!parked.ready) this.prepareParked(parked);
    this.broadcastPlaybackState(job, "paused");
    this.emitQueueSnapshot();
  }

  resume(scope: ControlScope): SeekResult {
    const parked = this.parked;
    if (!parked) return { outcome: "noop", reason: "not paused" };
    if (this.isStale(parked.job, scope)) return { outcome: "reject", reason: "stale" };
    const offset_ms = (parked.job.metadata?.longRead?.chunk_start_ms ?? 0) + parked.offsetMs;
    if (parked.resumeRequested) return { outcome: "noop", reason: "resuming", offset_ms };
    parked.resumeRequested = true;
    if (parked.ready) this.releaseParked(parked);
    else if (parked.failed) { parked.failed = false; this.prepareParked(parked); }
    return { outcome: "accept", offset_ms };
  }

  /** Cut the resume slice while paused so Resume is a plain player start. */
  private prepareParked(parked: ParkedPlayback): void {
    const { job } = parked;
    const conversion = (async () => {
      try {
        const slice = await prepareSeekSlice(job.audioFile, parked.offsetMs, parked.controller.signal);
        if (this.parked !== parked || job.completed) { disposeSeekSlice(slice); return; }
        job.sliceFile = slice;
        parked.ready = true;
        if (parked.resumeRequested) this.releaseParked(parked);
      } catch (error) {
        if (this.parked !== parked) return;
        parked.failed = true;
        broadcast({ type: "error", source: "seek", message: error instanceof Error ? error.message : String(error), recoverable: true });
        if (parked.resumeRequested) { parked.resumeRequested = false; this.broadcastPlaybackState(job, "paused"); }
      }
    })();
    job.lifecycle.track(conversion);
    this.conversions.add(conversion);
    void conversion.then(() => {
      this.conversions.delete(conversion); this.emitQueueSnapshot(); this.resolveIfIdle(); this.processNext();
    });
  }

  private releaseParked(parked: ParkedPlayback): boolean {
    if (this.parked !== parked) return false;
    try {
      // A capture that began while the slice was cut keeps the item parked.
      assertSpeakerClear();
      if (getEffectiveRecordingState() !== "idle" || this.captureAdmission) throw new Error("Resume refused: voice is busy");
    } catch (error) {
      parked.resumeRequested = false;
      broadcast({ type: "error", message: error instanceof Error ? error.message : String(error), recoverable: true });
      this.broadcastPlaybackState(parked.job, "paused");
      return false;
    }
    this.parked = undefined;
    const { job } = parked;
    job.lifecycle.generation++;
    job.resuming = true;
    job.enqueuedAt = Date.now();
    job.expiresAt = Date.now() + ttlForPriority(job.priority);
    this.pending.unshift(job);
    this.emitQueueSnapshot();
    this.processNext();
    return true;
  }

  private broadcastPlaybackState(job: PlaybackJob, state: PlaybackStateEvent["state"]): void {
    const local = job.metadata?.localOffsetMs ?? 0;
    const { word_index, word_count } = buildPlaybackOutcome(job, "interrupted", undefined, local);
    const duration = job.metadata?.getUtteranceDurationMs?.() ?? job.metadata?.utteranceDurationMs ?? job.metadata?.durationMs;
    broadcast({ type: "playback_state", state, playback_id: job.id, generation: job.lifecycle.generation,
      offset_ms: (job.metadata?.longRead?.chunk_start_ms ?? 0) + local, chunk_offset_ms: local,
      ...(duration !== undefined ? { duration_ms: duration } : {}),
      ...(word_index !== undefined ? { word_index } : {}), ...(word_count !== undefined ? { word_count } : {}),
      ...(job.metadata?.longRead ? { long_read: job.metadata.longRead } : {}) });
  }

  restart(): boolean {
    this.cancelSeekPreparation();
    const parked = this.parked;
    if (parked) {
      // CLICK2: Replay while paused plays the parked item from its start through the P16 release path.
      // The job (and its blocking handle) is kept; a capture keeps it parked and untouched.
      if (getEffectiveRecordingState() !== "idle" || this.captureAdmission) return false;
      const { job } = parked;
      parked.controller.abort();
      disposeSeekSlice(job.sliceFile);
      job.sliceFile = undefined;
      job.skipAmplitudeDecode = job.decodedAmplitude !== undefined;
      job.metadata!.localOffsetMs = 0;
      job.metadata!.playbackOffsetMs = job.metadata!.longRead?.chunk_start_ms ?? 0;
      const restarted: ParkedPlayback = { job, offsetMs: 0, controller: new AbortController(),
        ready: true, failed: false, resumeRequested: true };
      this.parked = restarted;
      return this.releaseParked(restarted);
    }
    if ((this.current?.job ?? this.restartAfterTermination ?? this.preparing?.job)?.metadata?.localOffsetMs !== undefined) {
      return this.seek(0).outcome === "accept";
    }
    if (this.restartAfterTermination) return true;
    // The replacement has already reset to the beginning once it reaches
    // preparation. Collapse another rapid Replay into that same job so a
    // blocking voice_ask cannot resolve while a duplicate replay stays queued.
    if (this.preparing) {
      return this.preparing.job === this.replayPreparingJob;
    }
    const active = this.current;
    if (!active) return false;

    active.job.lifecycle.generation++;
    this.current = null;
    this.pending = this.pending.filter((job) => {
      const isDuplicateReplay =
        job.audioFile === active.job.audioFile &&
        (job.metadata?.text ?? null) ===
          (active.job.metadata?.text ?? null) &&
        (job.metadata?.voice ?? null) ===
          (active.job.metadata?.voice ?? null);
      if (!isDuplicateReplay) return true;
      completeJob(job, buildPlaybackOutcome(job, "skipped", "collapsed"));
      return false;
    });

    this.restartAfterTermination = active.job;
    this.stopProgressTimer();
    this.terminate(active);
    this.emitQueueSnapshot();
    return true;
  }

  private cancelSeekPreparation(): void {
    this.seekPreparation?.controller.abort();
    this.seekPreparation = undefined;
  }

  seek(offsetMs: number): SeekResult {
    const job = this.current?.job ?? this.restartAfterTermination ?? this.preparing?.job;
    if (!job || job.completed) return { outcome: "noop", reason: "nothing playing" };
    const duration = job.metadata?.durationMs;
    if (!duration || !job.metadata) return { outcome: "noop", reason: "duration unavailable" };
    const offset = Math.min(offsetMs, duration);
    this.cancelSeekPreparation();
    if (offset === 0 || offset === duration) {
      this.commitSeek(job, offset);
    } else {
      const preparation = { job, controller: new AbortController() };
      this.seekPreparation = preparation;
      const conversion = (async () => {
        try {
          const slice = await prepareSeekSlice(job.audioFile, offset, preparation.controller.signal);
          if (this.seekPreparation !== preparation || job.completed) { disposeSeekSlice(slice); return; }
          this.seekPreparation = undefined;
          this.commitSeek(job, offset, slice);
        } catch (error) {
          if (this.seekPreparation === preparation) {
            this.seekPreparation = undefined;
            broadcast({ type: "error", source: "seek", message: error instanceof Error ? error.message : String(error), recoverable: true });
          }
        }
      })();
      job.lifecycle.track(conversion);
      this.conversions.add(conversion);
      void conversion.then(() => {
        this.conversions.delete(conversion); this.emitQueueSnapshot(); this.resolveIfIdle(); this.processNext();
      });
    }
    return { outcome: "accept", offset_ms: offset, clamped: offsetMs > duration };
  }

  private commitSeek(job: PlaybackJob, offset: number, slice?: string): void {
    if (job.completed || (this.current?.job !== job && this.preparing?.job !== job && this.restartAfterTermination !== job)) {
      disposeSeekSlice(slice); return;
    }
    disposeSeekSlice(job.sliceFile);
    job.lifecycle.generation++;
    job.sliceFile = slice;
    job.skipAmplitudeDecode = true;
    job.metadata!.localOffsetMs = offset;
    job.metadata!.playbackOffsetMs = offset;
    if (this.current?.job === job) {
      const active = this.current; this.current = null;
      this.restartAfterTermination = job; this.stopProgressTimer(); this.terminate(active);
    } else if (this.preparing?.job === job) {
      const preparing = this.preparing; this.preparing = null; preparing.cancel();
      this.pending.unshift(job); this.processNext();
    }
  }

  interrupt(id: string): void {
    // Long-read cursor replacement settles this chunk without aborting synthesis.
    this.cancel({ id });
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
    if (this.current || this.preparing || this.terminating.size > 0 || this.orphanedWorkCount() > 0) return;
    // Paused freezes promotion for the whole queue; held items keep their ordinary TTL.
    if (this.parked) {
      if (this.depth() === 0) { this.emitQueueSnapshot(); this.resolveIfIdle(); }
      return;
    }

    while (this.pending.length > 0) {
      const index = this.captureAdmission ? this.pending.findIndex(job => this.captureAdmission!.has(job.id)) : 0;
      if (index < 0) return;
      const [next] = this.pending.splice(index, 1);
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

      if (next.metadata?.localOffsetMs !== undefined && next.metadata.localOffsetMs >= (next.metadata.durationMs ?? Infinity)) {
        completeJob(next, buildPlaybackOutcome(next, "completed"));
        if (this.depth() === 0) broadcastPlaybackIdleIfSpeakerClear(next.metadata.nextState);
        continue;
      }
      if (next.skipAmplitudeDecode) {
        this.preparing = { job: next, cancel: () => {} };
        this.startPreparedPlayback(next, undefined); return;
      }
      if (!next.metadata) {
        this.preparing = { job: next, cancel: () => {} };
        this.emitQueueSnapshot();
        this.startPreparedPlayback(next, undefined);
        return;
      }
      const extraction = next.metadata?.preparedAmplitude ?? startPlaybackAmplitudeEnvelopeExtraction(next.audioFile);
      // Transfer this decode once; a cancelled preparation cannot serve Resume.
      next.metadata.preparedAmplitude = undefined;
      next.lifecycle.track(extraction.result);
      const preparation = { job: next, cancel: extraction.cancel };
      this.preparing = preparation;
      this.emitQueueSnapshot();
      void extraction.result.then(
        (playbackAmplitude) => {
          if (this.preparing === preparation) this.startPreparedPlayback(next, playbackAmplitude);
          else { this.emitQueueSnapshot(); this.resolveIfIdle(); this.processNext(); }
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
    if (next.metadata?.clipMarker) {
      broadcast({
        type: "clip_marker",
        marker_id: next.metadata.clipMarker.id,
        label: next.metadata.clipMarker.label,
        source: next.metadata.clipMarker.source ?? "tts",
        status: "marked",
      });
    }
    const expectedDurationMs = next.metadata?.durationMs;
    const durationMs = expectedDurationMs && Number.isFinite(expectedDurationMs) && expectedDurationMs > 0
      ? expectedDurationMs : probeAudioDurationMs(next.audioFile, 1_000);
    try {
      assertSpeakerClear();
    } catch (err) {
      this.refuseQueuedPlayback(next, err);
      this.processNext();
      return;
    }
    if (playbackAmplitude) next.decodedAmplitude = playbackAmplitude;
    next.playbackAmplitude = playbackAmplitude ?? (next.resuming
      ? envelopeFromOffset(next.decodedAmplitude, next.metadata?.localOffsetMs ?? 0) : undefined);
    let proc: ReturnType<typeof Bun.spawn>;
    try {
      proc = Bun.spawn(buildPlaybackArgv(getAudioPlayer(), next.sliceFile ?? next.audioFile), {
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

    next.lifecycle.track(proc.exited);
    this.current = { job: next, proc, startedAt: Date.now() - (next.metadata?.localOffsetMs ?? 0) };
    this.armPlayerWatchdog(this.current, durationMs);
    // A history Replay carries no metadata duration. The probed file length becomes the job's own,
    // so current seeks, the retained readback and the advertised scrubber all share one truth.
    if (next.metadata && !(next.metadata.durationMs! > 0) && durationMs && durationMs > 0) next.metadata.durationMs = durationMs;
    const readbackID = next.metadata?.retainedReplay ? next.metadata.readbackID
      : next.metadata ? retainedReadback.remember(next.audioFile, next.metadata, next.id) : undefined;
    if (next.metadata) {
      const utteranceMs = next.metadata.getUtteranceDurationMs?.() ?? next.metadata.utteranceDurationMs ??
        next.metadata.durationMs;
      broadcast({
        type: "state",
        state: "speaking",
        text: next.metadata.text,
        voice: next.metadata.voice,
        readback_id: readbackID,
        ...(readbackID ? { readback_duration_ms: retainedReadback.seekableMs(readbackID) } : {}),
        ...next.metadata.speechIdentity,
        playback_id: next.id,
        generation: next.lifecycle.generation,
        ...(next.metadata.longRead ? { long_read: next.metadata.longRead } : {}),
        ...(next.metadata.playbackOffsetMs !== undefined ? { playback_offset_ms: next.metadata.playbackOffsetMs } : {}),
        ...(utteranceMs !== undefined ? { duration_ms: utteranceMs } : {}),
        playback_amplitude: next.playbackAmplitude,
      });
      if (next.metadata.wordBoundaries?.length) {
        broadcast({ type: "subtitle", words: next.metadata.wordBoundaries });
      }
      if (next.metadata.alignedWords?.length) {
        broadcast({ type: "subtitle", words: [], aligned_words: next.metadata.alignedWords,
          ...(durationMs ? { duration_ms: durationMs } : {}) });
      }
    }
    if (next.resuming) { next.resuming = false; this.broadcastPlaybackState(next, "resumed"); }
    try { next.metadata?.speechArchive?.playerStarted(); }
    catch { console.error("[speech] player-start archive write failed"); }
    next.metadata?.onStarted?.(Date.now());
    const active = this.current;
    if (active?.job === next && next.metadata?.cloneProjection && durationMs) {
      const generation = next.lifecycle.generation;
      active.timing = startCloneTiming({ ...next.metadata.cloneProjection,
        audioPath: next.audioFile, durationMs, requestId: next.id,
        chunkId: [next.metadata.prosodyIdentity, next.metadata.longRead?.chunk_index ?? 0].filter(value => value !== undefined).join(":"),
      }, () => this.current === active && !next.completed && next.lifecycle.generation === generation,
      aligned_words => {
        // A seek restarts this job, and an idle word click replays the retained snapshot;
        // both re-broadcast what was measured here at their start.
        next.metadata!.alignedWords = aligned_words;
        if (readbackID) retainedReadback.rememberAlignedWords(readbackID, next.metadata!.longRead?.chunk_index ?? 0, aligned_words);
        broadcast({ type: "subtitle", words: [], aligned_words, duration_ms: durationMs });
        next.metadata!.onAlignedWords?.(aligned_words);
      });
      const childReaped = active.timing.childReaped;
      next.alignments.add(childReaped); this.alignments.add(childReaped);
      const forgetAlignment = () => {
        next.alignments.delete(childReaped); this.alignments.delete(childReaped);
        this.resolveIfIdle(); broadcastPlaybackIdleIfSpeakerClear();
      };
      void childReaped.then(forgetAlignment, forgetAlignment);
    }
    this.startProgressTimer();
    this.emitQueueSnapshot();

    proc.exited
      .then((exitCode) => {
        this.finish(next, proc, exitCode === 0);
      })
      .catch(() => {
        this.finish(next, proc, false);
      });
  }

  private finish(job: PlaybackJob, proc: ActivePlayback["proc"], succeeded: boolean) {
    if (this.current?.proc !== proc || this.current.job !== job) return;
    this.current.timing?.cancel();
    clearTimeout(this.current.watchdog);
    if (this.seekPreparation?.job === job) this.cancelSeekPreparation();
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
    const owner = this.current?.job ?? this.preparing?.job ?? this.restartAfterTermination;
    // Insert first so cancelling preparation cannot promote unrelated pending speech.
    this.insert(job);
    if (owner) this.cancel({ id: owner.id }, undefined, "barge-in");
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
    const parked = this.parked;
    if (parked) {
      const duration = parked.job.metadata?.durationMs ?? 0;
      items.push({ text: parked.job.metadata?.text ?? "", voice: parked.job.metadata?.voice ?? "", priority: parked.job.priority,
        is_current: true, progress: duration > 0 ? Math.min(1, parked.offsetMs / duration) : 0 });
    }

    for (const active of this.terminating.values()) {
      if (active.job === parked?.job) continue;
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

    broadcast({ type: "queue", depth: this.depth() + (parked ? 1 : 0), items });
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
      this.terminating.size + this.orphanedWorkCount()
    );
  }

  private orphanedWorkCount(): number {
    const admitted = new Set([...this.pending, this.current?.job, this.preparing?.job,
      ...[...this.terminating.values()].map(active => active.job)]);
    return [...this.jobs.values()].filter(job => job.completed && job.lifecycle.hasWork && !admitted.has(job)).length;
  }

  getAudioDepth() { return this.depth(); }

  getDepthForHealth() {
    return this.depth() || this.alignments.size;
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

  private armPlayerWatchdog(active: ActivePlayback, durationMs: number | null): void {
    if (!durationMs || !Number.isFinite(durationMs) || durationMs <= 0) return;
    const remainingMs = Math.max(0, durationMs - (active.job.metadata?.localOffsetMs ?? 0));
    const budgetMs = remainingMs + PLAYER_WATCHDOG_MARGIN_MS;
    // Node/Bun overflow very long timers to 1 ms; never turn that into an early kill.
    if (!Number.isFinite(budgetMs) || budgetMs > 2_147_483_647) return;
    const generation = active.job.lifecycle.generation;
    active.watchdog = setTimeout(() => {
      if (active.watchdogTimedOut || (this.current !== active && this.terminating.get(active.proc.pid) !== active)) return;
      active.watchdogTimedOut = true;
      if (this.current === active) {
        if (this.seekPreparation?.job === active.job) this.cancelSeekPreparation();
        this.current = null;
        this.stopProgressTimer();
        this.terminate(active, "SIGKILL");
        completeJob(active.job, buildPlaybackOutcome(active.job, "failed", "player-error", Date.now() - active.startedAt));
      } else {
        // A cancelled/replayed player can ignore SIGTERM. Keep its reap fence held.
        try { active.proc.kill("SIGKILL"); } catch {}
      }
      // A seek decoder can outlive the player; only the terminal work barrier
      // proves quiet. A continuing Replay retains its normal completion edge.
      if (active.job.completed) void active.job.lifecycle.playerExited.then(
        () => broadcastPlaybackIdleIfSpeakerClear(), () => {},
      );
      const message = `Playback watchdog: ${active.job.id} generation ${generation} exceeded ${remainingMs}ms + ${PLAYER_WATCHDOG_MARGIN_MS}ms margin; forcing SIGKILL`;
      console.warn(`[voicelayer] ${message}`);
      broadcast({ type: "error", message, recoverable: true });
      this.emitQueueSnapshot();
      this.resolveIfIdle();
      this.processNext();
    }, budgetMs);
  }

  private terminate(active: ActivePlayback, signal: "SIGTERM" | "SIGKILL" = "SIGTERM"): void {
    active.timing?.cancel();
    const pid = active.proc.pid;
    this.terminating.set(pid, active);
    try {
      active.proc.kill(signal);
    } catch {}
    void active.proc.exited.then(
      () => this.finishTermination(pid, active),
      () => this.finishTermination(pid, active),
    );
  }

  private finishTermination(pid: number, active: ActivePlayback): void {
    if (this.terminating.get(pid) !== active) return;
    clearTimeout(active.watchdog);
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
// Standard speech has no queue job until synthesis finishes. Keep its operation
// identity alive across every preparation await so global Stop can invalidate it.
const speechPreparations = new Set<AbortController>();
const preparationArchives = new Map<AbortController, LiveSpeechArchive>();
const speechPreparationSettlements = new Set<Promise<void>>();

/** Only an owned global Stop creates this reason; generic AbortErrors remain failures. */
export class SpeechPreparationStoppedError extends Error {
  constructor() { super("Stopped by the user before playback."); this.name = "SpeechPreparationStoppedError"; }
}

export function hasPendingSpeechPreparation(): boolean {
  return speechPreparations.size > 0;
}

/** Claim a quiet queue synchronously; a race refuses Ask instead of overlapping capture. */
export function reserveCaptureAdmission(): CaptureAdmission | undefined {
  if (getPlaybackQueueDepth() > 0) return;
  return playbackQueueManager.reserveCaptureAdmission();
}

export function isCaptureAdmissionReserved(): boolean {
  return playbackQueueManager.hasCaptureAdmission();
}

/** Play an audio file, queued after any currently playing audio. */
export function playAudioNonBlocking(
  audioFile: string,
  metadata?: PlaybackMetadata,
): QueuedPlaybackHandle {
  // A start-paused admission holds no player, exactly like a P16 park; Play re-checks the speaker.
  if (!metadata?.startPaused) assertSpeakerClear();
  return playbackQueueManager.enqueue(audioFile, metadata);
}

const PLAYBACK_WAIT_TIMEOUT_MS = 35_000;

/**
 * Wait for all queued playback to finish. Resolves immediately if queue is empty.
 *
 * AIDEV-NOTE: Name kept as `awaitCurrentPlayback` for backward compat (handlers.ts
 * imports it). Semantically it now awaits the full queue, not just the current proc.
 * P0-2 fix — voice_ask uses this to ensure all pending audio finishes before
 * starting recording. Previously only awaited currentPlayback.proc.exited, which
 * returned immediately if the queue hadn't started processing.
 * Rejects after 35 seconds without releasing pending playback/cleanup ownership.
 */
export async function awaitCurrentPlayback(options: { forCaptureAdmission?: boolean } = {}): Promise<void> {
  // Snapshot generation ownership before yielding, including already-aborted cleanup.
  const generations = [...cancelledLongReadTeardowns, ...(options.forCaptureAdmission ? [] : speechPreparationSettlements)];
  if (activeLongRead) generations.push(activeLongRead.done);
  // Capture the queue now; later unrelated speech must not join this acknowledgement.
  const queueDrained = options.forCaptureAdmission ? undefined : playbackQueueManager.awaitDrained();
  const settled = async () => {
    if (options.forCaptureAdmission) {
      await Promise.all(generations);
      await playbackQueueManager.awaitDrained();
    } else {
      // Each captured short-speech settlement includes its own eventual player.
      await Promise.all([...generations, queueDrained]);
    }
  };
  let timeout: ReturnType<typeof setTimeout> | undefined;
  try {
    await Promise.race([
      settled(),
      new Promise<never>((_resolve, reject) => {
        timeout = setTimeout(() => {
          const message = `Playback wait timed out after ${PLAYBACK_WAIT_TIMEOUT_MS}ms`;
          console.warn(`[voicelayer] ${message}; refusing to advance while playback or cleanup remains pending`);
          reject(new Error(message));
        }, PLAYBACK_WAIT_TIMEOUT_MS);
      }),
    ]);
  } finally {
    clearTimeout(timeout);
  }
}

export function getPlaybackQueueDepth(): number {
  // A parked chunk holds no player or lease, so its read does not count as playing.
  return (playbackQueueManager.getDepthForHealth() + cancelledLongReadTeardowns.size) ||
    (activeLongRead && !activeLongRead.controller.signal.aborted && !playbackQueueManager.isPaused(activeLongRead.id) &&
      !activeLongRead.firstAdmission?.paused ? 1 : 0);
}

/** CLICK2: the live read Pause parked before its first chunk existed (no queue job yet). */
function preparationParkedRead(): OwnedLongRead | undefined {
  const read = activeLongRead;
  return read?.firstAdmission?.paused && !read.controller.signal.aborted ? read : undefined;
}

export function isPlaybackPaused(): boolean {
  return playbackQueueManager.isPaused() || preparationParkedRead() !== undefined;
}

/** CLICK2 telemetry: actual phase and owning generation. Never text, selections or queue items. */
export function playbackTelemetrySnapshot(): CommandTelemetrySnapshot {
  const queued = playbackQueueManager.telemetrySnapshot();
  if (queued) return queued;
  const read = activeLongRead;
  if (!read || read.controller.signal.aborted) return { phase: "none", generation: null };
  return { phase: read.firstAdmission?.paused ? "paused" : "preparing", generation: null };
}
setCommandTelemetrySnapshot(playbackTelemetrySnapshot);

/** Idempotent; the scope, when given, must name the current item. `elapsedMs` is the global client clock. */
export function pausePlayback(scope: { id?: string; generation?: number } = {}, playbackElapsedMs?: number): SeekResult {
  const result = playbackQueueManager.pause(scope, playbackElapsedMs);
  const read = activeLongRead;
  if (result.outcome !== "noop" || result.reason !== "nothing playing" || !read?.firstAdmission ||
      read.controller.signal.aborted) return result;
  // CLICK2: Pause before the first chunk exists parks the read; that chunk is admitted already parked at zero.
  // No queue job exists yet, so a scope naming one is stale.
  if (scope.id !== undefined || scope.generation !== undefined) return { outcome: "reject", reason: "stale" };
  if (isCaptureAdmissionReserved()) return { outcome: "reject", reason: "unsupported" };
  if (read.firstAdmission.paused) return { outcome: "noop", reason: "already paused", offset_ms: 0 };
  read.firstAdmission.paused = true;
  read.archive?.move("paused");
  return { outcome: "accept", reason: "parked", offset_ms: 0 };
}

/** Idempotent; never resumes a stopped/replaced item and never while a capture owns the voice. */
export function resumePlayback(scope: { id?: string; generation?: number } = {}): SeekResult {
  const read = playbackQueueManager.isPaused() ? undefined : preparationParkedRead();
  if (!playbackQueueManager.isPaused() && !read) return { outcome: "noop", reason: "not paused" };
  if (getEffectiveRecordingState() !== "idle" || isCaptureAdmissionReserved()) return { outcome: "reject", reason: "busy" };
  if (!read) return playbackQueueManager.resume(scope);
  if (scope.id !== undefined || scope.generation !== undefined) return { outcome: "reject", reason: "stale" };
  // Play before the first chunk exists: it is admitted normally, from zero.
  read.firstAdmission!.paused = false;
  return { outcome: "accept", offset_ms: 0 };
}

/** Current seeks never resurrect a stopped generation; readback is explicit and idle-only. */
export function seekPlayback(offsetMs: number, scope: "current" | "readback" = "current", readbackID?: string): SeekResult {
  if (!Number.isFinite(offsetMs) || offsetMs < 0) return { outcome: "reject", reason: "invalid offset" };
  if (getEffectiveRecordingState() !== "idle") return { outcome: "reject", reason: "busy" };
  // Paused seek (silent cursor move) belongs to P12; never restart a parked item here.
  if (playbackQueueManager.isPaused()) return { outcome: "reject", reason: "paused" };
  if (scope === "readback") {
    if (getPlaybackQueueDepth() > 0 || activeLongRead || hasPendingSpeechPreparation() || hasActiveVoiceOperation()) return { outcome: "reject", reason: "busy" };
    return replayReadback(offsetMs, readbackID);
  }
  if (activeLongRead) {
    if (activeLongRead.controller.signal.aborted) return { outcome: "noop", reason: "nothing playing" };
    if (!activeLongRead.seek) return { outcome: "noop", reason: "not ready" };
    return activeLongRead.seek.seek(offsetMs);
  }
  return playbackQueueManager.seek(offsetMs);
}

/** Resume the exact displayed utterance, without synthesis or a recency-index guess. */
function replayReadback(offsetMs: number, readbackID?: string): SeekResult {
  const retained = retainedReadback.acquire(readbackID);
  if (!retained) return { outcome: "reject", reason: "Replay prefix audio unavailable" };
  const chunks = retained.chunks;
  const duration = chunks.reduce((sum, c) => sum + c.metadata.durationMs!, 0);
  if (offsetMs >= duration) { retained.release(); return { outcome: "reject", reason: "Replay position unavailable" }; }
  const controller = new AbortController(), id = `readback-${process.pid}-${++longReadCounter}`;
  let generation = 1;
  const handle: OwnedLongRead = { id, get generation() { return generation; }, controller,
    done: Promise.resolve(), playerExited: Promise.resolve(), started: Promise.resolve({}), completion: Promise.resolve({}) };
  activeLongRead = handle; longReads.set(id, handle);
  const exits: Promise<void>[] = [];
  handle.done = runLongRead(chunks.map(c => c.metadata.text), id, controller.signal, {
    initialOffsetMs: offsetMs,
    registerSeek: control => {
      const advance = (result: SeekResult) => { if (result.outcome === "accept") generation++; return result; };
      handle.seek = { seek: offset => advance(control.seek(offset)), restart: () => advance(control.restart()) };
    },
    synthesize: async (_text, index) => ({ audioFile: chunks[index].file,
      durationMs: chunks[index].metadata.durationMs!, wordBoundaries: chunks[index].metadata.wordBoundaries ?? [] }),
    canReplay: chunk => existsSync(chunk.audioFile),
    prepareSeek: (chunk, offset, signal) => prepareSeekSlice(chunk.audioFile, offset, signal),
    disposeSeek: disposeSeekSlice,
    seekFailed: error => broadcast({ type: "error", source: "seek", message: String(error), recoverable: true }),
    play: (chunk, _text, info, position) => {
      let resolveStarted!: (value: boolean) => void;
      const started = new Promise<boolean>(resolve => { resolveStarted = resolve; });
      const metadata = chunks[info.chunk_index].metadata;
      const playback = playAudioNonBlocking(chunk.audioFile, { ...metadata, retainedReplay: true, readbackID,
        // Ordinary short speech remains short; long speech keeps its global cursor.
        longRead: metadata.longRead ? { ...info, estimated_total_ms: duration,
          ...(metadata.longRead.display ? { display: metadata.longRead.display } : {}) } : undefined,
        utteranceDurationMs: duration, getUtteranceDurationMs: () => duration,
        playbackOffsetMs: info.chunk_start_ms + position.offsetMs, localOffsetMs: position.offsetMs,
        isSeek: true, seekSliceFile: position.sliceFile,
        onStarted: () => resolveStarted(true), onCompleted: () => resolveStarted(false) });
      exits.push(playback.playerExited);
      const audioExited = playbackQueueManager.audioExited(playback.id);
      return { started, exited: playback.exited.then(async outcome => { await audioExited; return outcome; }),
        interrupt: () => playbackQueueManager.interrupt(playback.id) };
    },
    saveHistory: async () => {}, // Replay does not rewrite original/played-range history.
    dispose: () => {},
  }).catch(error => {
    if (!controller.signal.aborted) broadcast({ type: "error", source: "seek", message: String(error), recoverable: true });
  }).finally(async () => {
    await Promise.all(exits);
    retained.release(); longReads.delete(id);
    if (activeLongRead === handle) { activeLongRead = undefined; broadcastPlaybackIdleIfSpeakerClear(); }
  });
  handle.playerExited = handle.done;
  return { outcome: "accept", offset_ms: offsetMs, clamped: false };
}

/** Stop current playback if any. */
export function stopPlayback(playbackElapsedMs?: number, cancelled = false): boolean {
  if (cancelled) {
    for (const controller of speechPreparations) preparationArchives.get(controller)?.finish("cancelled", "USER_CANCEL");
    activeLongRead?.archive?.finish("cancelled", "USER_CANCEL");
  }
  const hadPreparation = hasPendingSpeechPreparation();
  for (const controller of speechPreparations) controller.abort(new SpeechPreparationStoppedError());
  const hadLongRead = cancelLongRead(playbackElapsedMs);
  const stopped = playbackQueueManager.stop(playbackElapsedMs, cancelled);
  if ((hadPreparation || hadLongRead) && !stopped) broadcastPlaybackIdleIfSpeakerClear(undefined, "stop");
  return hadPreparation || hadLongRead || stopped;
}

/** Internal cancellation is utterance-scoped; foreign, terminal and stale intents are no-ops. */
export function cancelPlayback(scope: PlaybackScope, playbackElapsedMs?: number): boolean {
  const read = longReads.get(scope.id);
  if (read) {
    if (scope.generation !== undefined && scope.generation !== read.generation) return false;
    return cancelLongRead(playbackElapsedMs, read);
  }
  return playbackQueueManager.cancel(scope, playbackElapsedMs);
}

export interface LongReadProfile { requestedClone?: boolean; kind?: "short" | "long"; engine: "edge" | "clone"; voice: string; rate: string; fallbackVoice?: string }
export interface LongReadHandle {
  id: string; done: Promise<void>;
  readonly generation: number;
  playerExited: Promise<void>;
  started: Promise<{ error?: string }>;
  completion: Promise<{ error?: string }>;
}
type OwnedLongRead = LongReadHandle & { archive?: LiveSpeechArchive; controller: AbortController; seek?: LongReadSeek;
  /** CLICK2: present until the first chunk is admitted; `paused` once Pause parked the preparing read. */
  firstAdmission?: { paused: boolean };
  /** QPRE1: the read's request identity, and every chunk synthesized (only playing out from here). */
  requestId?: string; synthesized?: Promise<void> };
let activeLongRead: OwnedLongRead | undefined;
// Retention registry is separate from the audible owner; P12 can detach a parked read.
const longReads = new Map<string, OwnedLongRead>();
const cancelledLongReadTeardowns = new Set<Promise<void>>();
let longReadCounter = 0;

let hasQueuedSelectionRead: (() => boolean) | undefined;
let longReadSettledListener: ((requestId: string, outcome: "completed" | "stopped" | "failed") => void) | undefined;
/** QUEUE1: told when a long read ends; only `completed` (every chunk played to its end) is a natural end. */
export function setLongReadSettledListener(listener: typeof longReadSettledListener, queued?: () => boolean): void {
  longReadSettledListener = listener;
  hasQueuedSelectionRead = queued;
}

let externalSpeechListener: (() => void) | undefined;
/** QUEUE1b: told when agent speech or Ask preempts, so the user's read chain ends even with no read live. */
export function setExternalSpeechPreemptionListener(listener: typeof externalSpeechListener): void {
  externalSpeechListener = listener;
}

/** Preempt only a long read; ordinary short speech retains its existing queue policy.
 * `successor` is a user read replacing the current one; anything else (agent speech, Ask) is external. */
export function preemptLongRead(by: "external" | "successor" = "external"): boolean {
  if (by === "external") externalSpeechListener?.();
  // New accepted speech (and Ask) replaces a parked item so held speech cannot strand a waiter.
  playbackQueueManager.replaceParked();
  activeLongRead?.archive?.finish("stopped", "REPLACED");
  if (!cancelLongRead()) return false;
  if (playbackQueueManager.getDepthForHealth() === 0) broadcastPlaybackIdleIfSpeakerClear();
  return true;
}

function cancelLongRead(playbackElapsedMs?: number, read = activeLongRead): boolean {
  if (!read) return false;
  const done = read.done;
  if (!cancelledLongReadTeardowns.has(done)) {
    cancelledLongReadTeardowns.add(done);
    void done.then(() => cancelledLongReadTeardowns.delete(done));
  }
  if (read.controller.signal.aborted) return false;
  read.controller.abort();
  playbackQueueManager.cancelUtterance(read.id, playbackElapsedMs);
  return true;
}

/** Shared saved-profile and legacy environment precedence with voice_speak. */
export function resolveLongReadProfile(kind: "auto" | "short" | "long", text: string): LongReadProfile {
  const profile = resolveSpeakProfile(kind, text);
  let resolved: ReturnType<typeof resolveVoice>;
  try {
    resolved = resolveVoice(profile.voice, profile.engineSource === "default" ? undefined : profile.engine);
  } catch (error) {
    if (!(error instanceof VoiceProfileUnavailableError) || requireClonedVoiceEnabled()) throw error;
    console.error(`[voicelayer] Cloned voice "${profile.voice}" is missing — falling back to edge-tts (${TTS_DEFAULTS.voice})`);
    return { kind: profile.kind, requestedClone: profile.engine === "clone", engine: "edge", voice: TTS_DEFAULTS.voice, rate: defaultRate() };
  }
  if (requireClonedVoiceEnabled() && resolved.engine !== "cloned") {
    throw new VoiceProfileUnavailableError(profile.voice, "missing-profile");
  }
  if (resolved.warning) console.error(`[voicelayer] ${resolved.warning}`);
  return { kind: profile.kind, requestedClone: profile.engine === "clone" || resolved.engine === "cloned",
    engine: resolved.engine === "cloned" ? "clone" : "edge", voice: resolved.voice,
    rate: profile.rate, fallbackVoice: resolved.fallbackVoice };
}

type SpeechIdentity = Pick<StateEvent, "request_id" | "text_hash"> & { archiveContext?: SpeakArchiveContext; structuredDisplay?: StructuredSpeech };

/** One long-read chunk: pronunciation projection, engine fallback and rate adjustment. Owns the audio
 * file until it resolves; no broadcast, history, playback queue or active-read state. */
interface ChunkSynthesisPolicy { requireClone: boolean; edgeFallbackRate: string }
const chunkSynthesisPolicy = (): ChunkSynthesisPolicy => ({ requireClone: requireClonedVoiceEnabled(), edgeFallbackRate: defaultRate() });

async function synthesizeLongReadChunk(displayChunk: string, profile: LongReadProfile, signal: AbortSignal,
  { requireClone, edgeFallbackRate }: ChunkSynthesisPolicy, edgeRetries = 1, rules = pronunciationRules(),
  projected?: ReturnType<typeof projectSpeakableText>, renderIdentity?: string, probeDuration = true): Promise<PreparedChunk> {
  const audioFile = ttsFilePath(process.pid, ttsCounter++).replace(".mp3", renderIdentity ? `.${renderIdentity}.mp3` : ".mp3");
  const projection = projected ?? projectSpeakableText(displayChunk, rules, profile.engine);
  const spoken = projection.speechText;
  try {
    const synthesizeEdge = async (voice: string, rate: string): Promise<PreparedChunk> => {
      const edge = projected ?? (profile.engine === "edge" ? projection : projectSpeakableText(displayChunk, rules, "edge"));
      const chunk = await synthesizeEdgeChunk(edge.speechText, voice, rate, audioFile,
        new URL("../scripts/edge-tts-words.py", import.meta.url).pathname, signal, edgeRetries);
      chunk.wordBoundaries = alignWordBoundariesToDisplayText(displayChunk, edge.speechText, chunk.wordBoundaries, edge.ranges);
      return { chunk, voice, engine: "edge-tts", spokenText: edge.speechText };
    };
    if (profile.engine === "edge") {
      return await synthesizeEdge(profile.voice, profile.rate);
    }
    const audio = await synthesizeCloned(spoken, profile.voice, signal);
    throwIfAbortedSafe(signal);
    if (!audio) {
      if (requireClone) throw new VoiceProfileUnavailableError(profile.voice, "synthesis-failed");
      const voice = resolveVoice(profile.fallbackVoice || loadProfile(profile.voice)?.fallback || defaultVoice(), "edge").voice;
      console.error(`[voicelayer] Cloned voice "${profile.voice}" unavailable — falling back to edge-tts (${voice})`);
      return await synthesizeEdge(voice, edgeFallbackRate);
    }
    writeFileSync(audioFile, audio);
    const speed = Math.max(0.01, 1 + Number.parseFloat(profile.rate) / 100);
    if (Number.isFinite(speed) && speed !== 1) {
      const filters: string[] = [];
      let remaining = speed;
      while (remaining < 0.5) { filters.push("atempo=0.5"); remaining /= 0.5; }
      while (remaining > 2) { filters.push("atempo=2"); remaining /= 2; }
      filters.push(`atempo=${remaining}`);
      const adjusted = audioFile.replace(".mp3", ".rate.mp3");
      try {
        await runAudioCommand(["ffmpeg", "-nostdin", "-y", "-i", audioFile, "-af", filters.join(","), adjusted], signal);
        copyFileSync(adjusted, audioFile);
      } finally { try { unlinkSync(adjusted); } catch {} }
    }
    throwIfAbortedSafe(signal);
    const durationMs = probeDuration ? probeAudioDurationMs(audioFile) : 0;
    if (probeDuration && (!durationMs || durationMs <= 0)) throw new Error("Cloned audio has no readable duration");
    return { chunk: { audioFile, durationMs: durationMs ?? 0, wordBoundaries: [] }, voice: profile.voice, engine: "qwen3-tts", projection, spokenText: spoken };
  } catch (error) {
    disposeLongReadChunkFiles(audioFile);
    throw error;
  }
}

function disposeLongReadChunkFiles(audioFile: string): void {
  try { unlinkSpeechAudio(audioFile); } catch {}
  try { unlinkSync(audioFile.replace(".mp3", ".meta.ndjson")); } catch {}
}

/** QPRE1: what chunk 0 of a read would synthesize; a prepared start transfers only on an exact match. */
function preparedStartIdentity(displayChunk: string, profile: LongReadProfile, policy: ChunkSynthesisPolicy, rules = pronunciationRules()): string {
  const { requestedClone, kind, engine, voice, rate, fallbackVoice } = profile;
  return JSON.stringify([displayChunk, requestedClone, kind, engine, voice, rate, fallbackVoice ?? null,
    policy.requireClone, policy.edgeFallbackRate, projectSpeakableText(displayChunk, rules, engine).speechText]);
}

function untilAborted(signal: AbortSignal): Promise<never> {
  return new Promise<never>((_, reject) => {
    const abort = () => reject(new Error("Selection read preparation cancelled"));
    if (signal.aborted) abort(); else signal.addEventListener("abort", abort, { once: true });
  });
}

/** QPRE1: prepare a queued read's FIRST chunk in the background. It starts only once the playing owner's
 * synthesis is complete (no contention with it, whatever the engine), and never touches playback,
 * broadcasts, history or the active read. Rejects when the owner is gone or the signal aborts. */
export async function prepareSelectionReadStart(
  text: string, kind: "auto" | "short" | "long", ownerRequestId: string, signal: AbortSignal,
  archiveContext?: SpeakArchiveContext, structuredDisplay?: StructuredSpeech,
): Promise<PreparedReadStart> {
  const owner = [...longReads.values()].find((read) => read.requestId === ownerRequestId);
  if (!owner?.synthesized) throw new Error("No playing read owns this queue");
  const aborted = untilAborted(signal);
  aborted.catch(() => {});
  const synthesized = await Promise.race([
    owner.synthesized.then(() => true), owner.done.then(() => false, () => false), aborted]);
  if (!synthesized) throw new Error("The owning read ended before its synthesis completed");
  throwIfAbortedSafe(signal);
  if (isTTSDisabled()) throw new Error("TTS is disabled");
  if (!text.trim() || text.length > SPEAK_TEXT_MAX_CHARS) throw new Error("Speech text must contain 1–200,000 characters");
  const displayText = sanitizeTtsText(text);
  const profile = resolveLongReadProfile(kind, text);
  const prosody = structuredReadPlan(displayText, profile, structuredDisplay);
  const displayChunk = prosody?.plan.chunks[0]?.text ?? chunkTextForLongRead(displayText)[0];
  if (!displayChunk?.trim()) throw new Error("Speech text is empty after sanitizing");
  const policy = chunkSynthesisPolicy();
  // No retry: the edge retry log quotes the text, and a failed prefetch just synthesizes at the start.
  const rules = pronunciationRules();
  const identity = preparedStartIdentity(displayChunk, profile, policy, rules) + (prosody?.plan.renderIdentity ?? "");
  const archive = archiveContext ? beginSpeechArchive(text, archiveContext) : undefined;
  const prepared = prosody
    ? await synthesizeProsodySegment(prosody.plan, prosody.plan.segments[0], profile, signal, policy, 0)
    : await synthesizeLongReadChunk(displayChunk, profile, signal, policy, 0, rules);
  archive?.generated(prepared.chunk.audioFile, prepared.spokenText ?? displayChunk, prepared.voice, profile.kind ?? "long", prepared.engine, 0, prepared.chunk.durationMs);
  if (signal.aborted) { disposeLongReadChunkFiles(prepared.chunk.audioFile); throwIfAbortedSafe(signal); }
  return new PreparedReadStart(identity, prepared,
    (chunk) => disposeLongReadChunkFiles(chunk.audioFile));
}

/** Spec emphasis for headings and labels: slower, lower, a little louder, as top-level edge prosody. */
const EDGE_EMPHASIS: EdgeProsody = { pitch: "-8Hz", volume: "+10%" };
function emphasisRate(rate: string): string {
  const percent = Number.parseInt(rate, 10);
  const value = (Number.isFinite(percent) ? percent : 0) - 10;
  return `${value >= 0 ? "+" : ""}${value}%`;
}

function structuredReadPlan(displayText: string, profile: LongReadProfile, structure?: StructuredSpeech) {
  if (!resolveBinary("ffmpeg")) return undefined;
  const projection = projectSpeakableText(displayText, pronunciationRules(), profile.engine);
  const plan = planProsody({ readText: displayText, projection, structure, listNumbers: profile.engine === "clone" ? "inline" : "separate",
    ...(profile.engine === "clone" ? { concurrency: 1 } : {}) });
  return isStructuredPlan(plan) ? { plan, projection } : undefined;
}

async function synthesizeProsodySegment(plan: ProsodyPlan, segment: ProsodyPlan["segments"][number], profile: LongReadProfile,
  signal: AbortSignal, policy: ChunkSynthesisPolicy, edgeRetries = 1): Promise<PreparedChunk> {
  if (profile.engine === "clone") {
    const span = { start: 0, end: segment.text.length };
    return synthesizeLongReadChunk(segment.text, profile, signal, policy, edgeRetries, [],
      { displayText: segment.text, speechText: segment.text, ranges: [{ kind: "identity", source: span, display: span, speech: span }] },
      plan.renderIdentity, segment === plan.segments[0]);
  }
  const scriptPath = new URL("../scripts/edge-tts-words.py", import.meta.url).pathname;
  const audioFile = ttsFilePath(process.pid, ttsCounter++).replace(".mp3", `.${plan.renderIdentity}.mp3`);
  try {
    const chunk = await synthesizeEdgeChunk(segment.text, profile.voice, segment.emphasis ? emphasisRate(profile.rate) : profile.rate,
      audioFile, scriptPath, signal, edgeRetries, segment.emphasis ? EDGE_EMPHASIS : undefined);
    return { chunk, voice: profile.voice, engine: "edge-tts", spokenText: segment.text };
  } catch (error) { disposeLongReadChunkFiles(audioFile); throw error; }
}

function createStructuredProsodyRead(plan: ProsodyPlan, profile: LongReadProfile, signal: AbortSignal, policy: ChunkSynthesisPolicy,
  prepared?: PreparedReadStart) {
  const provenance = new Map<ProsodyPlan["segments"][number], Pick<PreparedChunk, "voice" | "engine">>();
  const read = createProsodyRead(plan, {
    synthesize: async (segment, signal) => {
      const cached = segment === plan.segments[0]
        ? prepared?.take(preparedStartIdentity(plan.chunks[0].text, profile, policy) + plan.renderIdentity) : undefined;
      const result = cached ?? await synthesizeProsodySegment(plan, segment, profile, signal, policy);
      provenance.set(segment, { voice: result.voice, engine: result.engine });
      return { audioFile: result.chunk.audioFile, words: result.chunk.wordBoundaries, durationMs: result.chunk.durationMs };
    },
    decode: decodeAudioToPCM,
    encode: async (pcm, signal) => {
      const audioFile = ttsFilePath(process.pid, ttsCounter++).replace(".mp3", `.${plan.renderIdentity}.mp3`);
      try { await encodePCMToMp3(pcm, audioFile, signal); return audioFile; }
      catch (error) { disposeLongReadChunkFiles(audioFile); throw error; }
    },
    unlink: disposeLongReadChunkFiles,
  }, signal, profile.engine === "clone" ? 1 : undefined);
  return { ...read, provenance(index: number) {
    const sources = plan.segments.slice(plan.chunks[index].first, plan.chunks[index].end).map(segment =>
      provenance.get(segment) ?? { voice: profile.voice, engine: profile.engine === "clone" ? "qwen3-tts" : "edge-tts" });
    return { voice: [...new Set(sources.map(source => source.voice))].join(","),
      engine: [...new Set(sources.map(source => source.engine))].join("+") };
  } };
}

export function speakText(text: string, kind: "auto" | "short" | "long" = "auto", identity: SpeechIdentity = {}, prepared?: PreparedReadStart): LongReadHandle {
  const receivedAt = Date.now();
  let profile: LongReadProfile;
  try { profile = resolveLongReadProfile(kind, text); } catch (error) { prepared?.dispose(); throw error; }
  return speakLongRead(text, profile, receivedAt, identity, prepared);
}

/** Long reads bypass XTTS/F5 truncation and call the Qwen3 clone tier directly. */
export function speakLongRead(text: string, profile: LongReadProfile, receivedAt = Date.now(), identity: SpeechIdentity = {}, prepared?: PreparedReadStart): LongReadHandle {
  const speechIdentity = { request_id: identity.request_id ?? randomUUID(), text_hash: identity.text_hash ?? normalizedSpeechHash(text) };
  const chars = text.length;
  const requestedClone = profile.requestedClone ?? (profile.engine === "clone");
  let displayText: string;
  try {
    assertSpeakerClear();
    if (!text.trim() || text.length > SPEAK_TEXT_MAX_CHARS) throw new Error("Speech text must contain 1–200,000 characters");
    if (isTTSDisabled()) throw new Error("TTS is disabled");
    displayText = sanitizeTtsText(text);
    if (!displayText.trim()) throw new Error("Speech text is empty after sanitizing");
  } catch (error) { prepared?.dispose(); throw error; }
  const archive = beginSpeechArchive(text, identity.archiveContext);
  /** QPRE1: a prepared chunk 0 is held until the chunk-0 synthesize callback takes it, or disposed at settle. */
  let preparedStart = prepared;
  preemptLongRead("successor");
  const predecessors = [...cancelledLongReadTeardowns];
  const controller = new AbortController();
  const id = `long-read-${process.pid}-${++longReadCounter}`;
  const prosody = structuredReadPlan(displayText, profile, identity.structuredDisplay);
  const prosodyPlan = prosody?.plan;
  const texts = prosodyPlan ? prosodyPlan.chunks.map((chunk) => chunk.text) : chunkTextForLongRead(displayText);
  // Optional source layout decorates the exact startup/body chunks without changing speech.
  const displays = identity.structuredDisplay?.speechText === displayText
    ? structuredReadDisplay(identity.structuredDisplay, texts, TTS_CHUNK_MAX_CHARS) : [];
  let resolveStarted!: (result: { error?: string }) => void;
  const started = new Promise<{ error?: string }>((resolve) => { resolveStarted = resolve; });
  let failure: string | undefined;
  let audioStarted = false;
  let playedToEnd = false;
  let generation = 1;
  const playerExits: Promise<void>[] = [];
  const handleStarted = () => resolveStarted({});
  let resolveSynthesized!: () => void;
  const synthesized = new Promise<void>((resolve) => { resolveSynthesized = resolve; });
  const handle: OwnedLongRead = { id, get generation() { return generation; }, archive, controller, started, done: Promise.resolve(), playerExited: Promise.resolve(), completion: Promise.resolve({} as { error?: string }),
    requestId: speechIdentity.request_id, synthesized, firstAdmission: { paused: false } };
  activeLongRead = handle;
  longReads.set(id, handle);
  const signal = controller.signal;
  const policy = chunkSynthesisPolicy();
  const prosodyRead = prosodyPlan ? createStructuredProsodyRead(prosodyPlan, profile, signal, policy, preparedStart) : undefined;
  const prosodyChunk = async (displayChunk: string, index: number): Promise<PreparedChunk> => {
    const result = await prosodyRead!.chunk(index);
    const local = sliceProjection(prosody!.projection, prosody!.plan.chunks[index].read);
    const source = prosodyRead!.provenance(index);
    const needsAlignment = profile.engine === "clone" && source.engine !== "edge-tts";
    return { chunk: { audioFile: result.audioFile, durationMs: result.durationMs,
      wordBoundaries: needsAlignment ? [] : alignWordBoundariesToDisplayText(displayChunk, local.speechText, result.words, local.ranges) },
      ...source, spokenText: result.spokenText,
      ...(needsAlignment ? { projection: local } : {}) };
  };
  const chunkVoices = new Map<string, string>();
  const chunkEngines = new Map<string, string>();
  const chunkAmplitudes = new Map<string, PlaybackAmplitudeExtraction>();
  const cloneProjections = new Map<string, ReturnType<typeof projectSpeakableText>>();
  const chunkAlignedWords = new Map<string, AlignedWordBoundary[]>();
  // Swift routes Escape only in active modes. Actual playback resets this clock/text.
  broadcast({ type: "state", state: "speaking", text: "Preparing speech…", voice: profile.voice, ...speechIdentity,
    long_read: { id, chunk_index: 0, chunk_count: texts.length, chunk_start_ms: 0, preparing: true,
      ...longReadDocument(displayText, texts),
      ...(identity.structuredDisplay?.speechText === displayText
        ? { display: structuredReadDisplay(identity.structuredDisplay, [displayText], TTS_CHUNK_MAX_CHARS)[0] } : {}) } });
  const run = async () => {
    if (signal.aborted) return;
    // A recording may have begun while the predecessor was settling.
    assertSpeakerClear();
    // PROSODY: in-flight utterance requests are reaped, and never-delivered files removed, however the read ends.
    try { await runLongRead(texts, id, signal, {
      archiveContext: identity.archiveContext,
      registerSeek: (control) => {
        const advance = (result: SeekResult) => { if (result.outcome === "accept") generation++; return result; };
        handle.seek = { seek: offset => advance(control.seek(offset)), restart: () => advance(control.restart()) };
      },
      canReplay: (chunk) => existsSync(chunk.audioFile),
      prepareSeek: (chunk, offset, seekSignal) => offset < chunk.durationMs
        ? prepareSeekSlice(chunk.audioFile, offset, seekSignal) : Promise.resolve(undefined),
      disposeSeek: disposeSeekSlice,
      seekFailed: (error) => broadcast({ type: "error", source: "seek", message: error instanceof Error ? error.message : String(error), recoverable: true }),
      onDuration: (totalMs, final) => {
        if (final) resolveSynthesized();
        broadcast({ type: "playback_duration", long_read_id: id, duration_ms: totalMs, final });
      },
      synthesize: async (displayChunk, index, signal) => {
        const synthesisStarted = Date.now();
        // QPRE1: chunk 0 takes the prepared audio exactly once, revalidated; otherwise normal synthesis.
        const lease = index === 0 ? preparedStart : undefined;
        if (lease && !prosodyRead) preparedStart = undefined;
        const result = prosodyRead ? await prosodyChunk(displayChunk, index)
          : lease?.take(preparedStartIdentity(displayChunk, profile, policy))
          ?? await synthesizeLongReadChunk(displayChunk, profile, signal, policy);
        const { audioFile } = result.chunk;
        archive.generated(audioFile, result.spokenText ?? result.projection?.speechText ?? displayChunk,
          result.voice, profile.kind ?? "long", result.engine, index, result.chunk.durationMs);
        chunkVoices.set(audioFile, result.voice);
        chunkEngines.set(audioFile, result.engine);
        if (result.projection) cloneProjections.set(audioFile, result.projection);
        const synthesizedAt = Date.now();
        if (index > 0) {
          const decode = startPlaybackAmplitudeEnvelopeExtraction(audioFile);
          signal.addEventListener("abort", decode.cancel, { once: true });
          chunkAmplitudes.set(audioFile, decode);
          void decode.result.then(() => {
            signal.removeEventListener("abort", decode.cancel);
            console.error(`[tts] chunk=${index} chars=${displayChunk.length} engine=${result.engine} synthesis_ms=${synthesizedAt - synthesisStarted} waveform_ms=${Date.now() - synthesizedAt}`);
          });
        } else console.error(`[tts] chunk=0 chars=${displayChunk.length} engine=${result.engine} synthesis_ms=${synthesizedAt - synthesisStarted}`);
        return result.chunk;
      },
      play: (chunk, text, info, position) => {
        throwIfAbortedSafe(signal);
        // CLICK2: a Pause that landed during preparation admits this first chunk parked, before any player.
        const startPaused = handle.firstAdmission?.paused === true;
        handle.firstAdmission = undefined;
        let started = false;
        let resolveStarted!: (value: boolean) => void;
        const start = new Promise<boolean>((resolve) => { resolveStarted = resolve; });
        // PROSODY: chunk 0's tail is measured only once its player starts; a chunk 0 that never plays
        // releases later chunks with a zero tail, so nothing waits on a decode that will not happen.
        const firstAudio = prosodyRead && info.chunk_index === 0 ? prosodyRead : undefined;
        let playback: ReturnType<typeof playAudioNonBlocking>;
        try { playback = playAudioNonBlocking(chunk.audioFile, {
          speechArchive: archive,
          ...(startPaused ? { startPaused: true } : {}),
          text, voice: chunkVoices.get(chunk.audioFile) ?? profile.voice, durationMs: chunk.durationMs,
          longRead: { ...info, ...(displays[info.chunk_index] ? { display: displays[info.chunk_index] } : {}) }, speechIdentity,
          wordBoundaries: chunk.wordBoundaries, priority: "normal",
          preparedAmplitude: chunkAmplitudes.get(chunk.audioFile),
          cloneProjection: cloneProjections.get(chunk.audioFile),
          prosodyIdentity: prosodyPlan?.renderIdentity,
          alignedWords: chunkAlignedWords.get(chunk.audioFile),
          onAlignedWords: words => chunkAlignedWords.set(chunk.audioFile, words),
          playbackOffsetMs: info.chunk_start_ms + position.offsetMs,
          getUtteranceDurationMs: position.getDurationMs,
          ...(position.isSeek ? { localOffsetMs: position.offsetMs, isSeek: true, seekSliceFile: position.sliceFile } : {}),
          onStarted: (startedAt) => {
            if (!audioStarted) {
              const ms = Math.max(0, startedAt - receivedAt);
              const kind = profile.kind ?? "long";
              const engine = chunkEngines.get(chunk.audioFile) ?? "edge-tts";
              const voice = chunkVoices.get(chunk.audioFile) ?? profile.voice;
              recordFirstAudio(kind, ms, {engine, origin: "speak", fallback: requestedClone && engine === "edge-tts"});
              console.error(`[tts] first_audio_ms=${ms} profile=${kind} engine=${engine} voice=${voice} chars=${chars}`);
            }
            started = true; resolveStarted(true); audioStarted = true; handleStarted();
            firstAudio?.firstAudioStarted(chunk.audioFile);
          },
          onCompleted: (outcome) => {
            if (!started) { resolveStarted(false); firstAudio?.firstAudioUnavailable(); }
            if (outcome.status === "failed") failure = `Speech playback failed: ${outcome.reason ?? "player-error"}`;
            // QUEUE1: only a chunk that played to its end counts toward a natural completion.
            playedToEnd = outcome.status === "completed";
          },
        }); } catch (error) { firstAudio?.firstAudioUnavailable(); throw error; }
        playerExits.push(playback.playerExited); void playback.playerExited.catch(() => {});
        const audioExited = playbackQueueManager.audioExited(playback.id);
        return { started: start, exited: playback.exited.then(async outcome => { await audioExited; return outcome; }),
          interrupt: () => playbackQueueManager.interrupt(playback.id) };
      },
      playbackFinished: () => {
        if (activeLongRead === handle && !signal.aborted && playedToEnd && !hasQueuedSelectionRead?.())
          broadcastPlaybackIdleIfSpeakerClear(undefined, "audio-completion");
      },
      saveHistory: async (audio, { text, missingChunks }) => {
        const combined = ttsFilePath(process.pid, ttsCounter++);
        try {
          if (missingChunks.length) console.error(`[voicelayer] Long-read history audio lacks chunks ${missingChunks.join(",")} of ${texts.length} (stopped before synthesis); text is complete`);
          await assembleLongReadHistory(audio, combined);
          const alignedWords = combineHistoryTimings(audio.map(({ chunk, text }) => ({ text, durationMs: chunk.durationMs,
            aligned: chunkAlignedWords.get(chunk.audioFile), words: displayTokenBoundaries(text, chunk.wordBoundaries) })));
          addToHistory(text, combined,
            chunkVoices.get(audio[0]?.chunk.audioFile) ?? profile.voice, missingChunks, { alignedWords, prosodyIdentity: prosodyPlan?.renderIdentity });
        } catch (error) {
          console.error(`[voicelayer] Long-read history could not be saved: ${error instanceof Error ? error.message : String(error)}`);
        } finally { try { unlinkSync(combined); } catch {} }
      },
      dispose: async (chunk, index) => {
        // PROSODY: chunk 0's tail decode reads this file; it settles before the file goes.
        if (index === 0) await prosodyRead?.settleTail();
        const decode = chunkAmplitudes.get(chunk.audioFile);
        decode?.cancel(); await decode?.result;
        chunkAmplitudes.delete(chunk.audioFile); cloneProjections.delete(chunk.audioFile);
        chunkAlignedWords.delete(chunk.audioFile); chunkEngines.delete(chunk.audioFile); chunkVoices.delete(chunk.audioFile);
        try { unlinkSpeechAudio(chunk.audioFile); } catch {}
      },
    }, 1); } finally { await prosodyRead?.close(); }
  };
  // Preserve stopped audio: finish its history/cleanup before a replacement starts.
  handle.done = (predecessors.length ? Promise.all(predecessors).then(run) : run()).catch((error) => {
    if (signal.aborted) return;
    failure = error instanceof Error ? error.message : String(error);
    if (activeLongRead === handle) {
      controller.abort();
      playbackQueueManager.cancelUtterance(id);
      broadcast({ type: "error", message: error instanceof Error ? error.message : String(error), recoverable: true });
    }
  }).finally(() => {
    longReads.delete(id);
    // A prepared start the read never reached (stopped first) is released here, exactly once.
    preparedStart?.dispose(); preparedStart = undefined;
    if (!audioStarted) resolveStarted({ error: failure ?? "Speech stopped before playback" });
    const owned = activeLongRead === handle;
    if (owned) activeLongRead = undefined;
    // QUEUE1: a natural end may start the next queued read before the idle edge, so the pill never blinks idle.
    const outcome = signal.aborted ? "stopped" : failure || !playedToEnd ? "failed" : "completed";
    try { archive.finish(failure ? "failed" : signal.aborted && !audioStarted ? "cancelled" : outcome, failure || !playedToEnd && !signal.aborted ? "SPEECH_FAILED" : signal.aborted ? "USER_STOP" : "PLAYBACK_COMPLETED"); }
    catch { console.error("[speech] terminal archive write failed"); }
    finally {
      try { longReadSettledListener?.(speechIdentity.request_id, outcome); } catch (error) {
        console.error(`[voicelayer] Read queue settle failed: ${error instanceof Error ? error.message : String(error)}`);
      } finally {
        if (owned && !activeLongRead && playbackQueueManager.getDepthForHealth() === 0) broadcastPlaybackIdleIfSpeakerClear();
      }
    }
  });
  handle.completion = handle.done.then(() => failure ? { error: failure } : {});
  handle.playerExited = handle.done.then(async () => { await Promise.all(playerExits); });
  void handle.playerExited.catch(() => {});
  return { id, get generation() { return handle.generation; }, done: handle.done, playerExited: handle.playerExited, started, completion: handle.completion };
}

/** Restart the active audio job without resolving its blocking playback handle. */
export function restartPlayback(): boolean {
  // CLICK2: a read paused before its first chunk is already at zero; Replay means play it.
  const preparing = preparationParkedRead();
  if (preparing) { preparing.firstAdmission!.paused = false; return true; }
  // A paused long read restarts through its runner at global zero, never only its parked chunk.
  if (activeLongRead && (!playbackQueueManager.isPaused() || playbackQueueManager.isPaused(activeLongRead.id))) {
    // Keep the utterance, synthesis, played ranges and physical exit fences owned by
    // the long-read runner. Restarting only its queued chunk loses global zero.
    const result = activeLongRead.seek?.restart();
    if (result?.outcome === "accept") return true;
    broadcast({ type: "error", source: "seek", message: result?.reason ?? "Replay prefix audio unavailable", recoverable: true });
    return false;
  }
  return playbackQueueManager.restart();
}

export class QueuedPlaybackController implements PlaybackController {
  play(audioFile: string, metadata?: PlaybackMetadata): QueuedPlaybackHandle {
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
 * @param options.rate - Rate override (e.g., "-10%", "+5%"). If omitted, uses profile settings, then mode/env defaults.
 * @param options.mode - Voice mode name for auto-rate selection (announce/brief/consult/converse).
 * @param options.voice - Voice name (profile name or raw edge-tts voice). If omitted, uses default.
 * @param options.waitForPlayback - If true, wait for audio playback to finish (used in converse mode before recording).
 */
export async function speak(
  text: string,
  options?: TextToSpeechOptions,
): Promise<TextToSpeechResult> {
  if (!text?.trim()) return {};
  const controller = new AbortController();
  const archive = beginSpeechArchive(text, options?.archiveContext);
  speechPreparations.add(controller);
  preparationArchives.set(controller, archive);
  let settle!: () => void;
  const settlement = new Promise<void>(resolve => { settle = resolve; });
  speechPreparationSettlements.add(settlement);
  let playback: QueuedPlaybackHandle | undefined;
  const onQueued = options?.onPlaybackQueued;
  const onCompleted = options?.onPlaybackComplete;
  try {
    const result = await prepareSpeech(text, { ...options, speechArchive: archive,
      onPlaybackQueued: handle => { playback = handle; onQueued?.(handle); },
      onPlaybackComplete: outcome => {
        try { archive.finish(outcome.status === "completed" ? "completed" : outcome.status === "failed" ? "failed" : "stopped",
          outcome.status === "completed" ? "PLAYBACK_COMPLETED" : outcome.status === "failed" ? "PLAYER_FAILED" : "USER_STOP"); }
        catch { console.error("[speech] terminal archive write failed"); }
        finally { onCompleted?.(outcome); }
      } }, controller.signal);
    if (!result.engine && !result.playbackId) archive.finish("failed", "REJECTED");
    return result;
  } catch (error) {
    // Stop before audio is cancellation, consistently with long-read preparation.
    const stoppedPreparing = controller.signal.aborted || error instanceof SpeechPreparationStoppedError;
    archive.finish(stoppedPreparing ? "cancelled" : "failed",
      stoppedPreparing ? "USER_STOP_PREPARING" : isSpeakerOutputRefusedError(error) ? "REJECTED" : "SYNTH_FAILED");
    throw error;
  } finally {
    speechPreparations.delete(controller);
    preparationArchives.delete(controller);
    const finish = () => { speechPreparationSettlements.delete(settlement); settle(); };
    // Preparation may enqueue after a waiter's queue snapshot has drained. Keep
    // this operation's barrier through its player, without adopting newer speech.
    if (playback) void playback.playerExited.then(finish, finish);
    else finish();
  }
}

async function prepareSpeech(
  text: string,
  options: SpeechOptions | undefined,
  signal: AbortSignal,
): Promise<TextToSpeechResult> {
  const receivedAt = Date.now();
  const chars = text?.length ?? 0;
  if (!text?.trim()) return {};
  assertSpeakerClear();
  preemptLongRead();
  if (cancelledLongReadTeardowns.size) {
    await Promise.all([...cancelledLongReadTeardowns]);
    throwIfAbortedSafe(signal);
    assertSpeakerClear();
  }

  // SSML injection defense — strip tags before any TTS engine
  text = sanitizeTtsText(text);

  // VoiceBar must show the caller's text, while engines receive the phonetic
  // form. Keep these values separate for the remainder of the pipeline.
  const displayText = text;

  // Check if TTS is disabled
  if (isTTSDisabled()) {
    console.error("[voicelayer] TTS disabled via flag file — skipping speech");
    return {};
  }

  // Resolve voice — determines engine (cloned vs edge-tts)
  const profile = resolveSpeakProfile(options?.profile ?? "short", text);
  const selectedVoice = options?.voice ?? profile.voice;
  const requireClone = requireClonedVoiceEnabled(options);
  let resolved: ReturnType<typeof resolveVoice>;
  try {
    resolved = resolveVoice(selectedVoice, options?.voice !== undefined || profile.engineSource === "default" ? undefined : profile.engine);
  } catch (error) {
    if (!(error instanceof VoiceProfileUnavailableError) || requireClone) throw error;
    const warning = `Cloned voice "${selectedVoice}" is missing — falling back to edge-tts (${TTS_DEFAULTS.voice})`;
    console.error(`[voicelayer] ${warning}`);
    resolved = {voice: TTS_DEFAULTS.voice, engine: "edge-tts", warning};
  }
  // Keep engine-specific text and ranges together, including clone→Edge fallback.
  const rules = pronunciationRules();
  const projection = projectSpeakableText(displayText, rules, resolved.engine === "cloned" ? "clone" : "edge");
  const spokenText = projection.speechText;
  const edgeProjection = resolved.engine === "edge-tts" ? projection : projectSpeakableText(displayText, rules, "edge");
  const requestedClone = profile.engine === "clone" || resolved.engine === "cloned";
  const cloneRate = options?.rate ??
    (profile.engine === "clone" || profile.rateSource === "environment" ? profile.rate : undefined);
  const cloneOptions = () => ({...options, rate: cloneRate, generatedEngine: audioEngine});
  let audioEngine = "edge-tts";
  let audioVoice = resolved.voice;
  const onPlaybackStart = options?.onPlaybackStart;
  let firstAudio = false;
  options = {
    ...options,
    profile: profile.kind,
    rate: options?.rate ?? (resolved.engine === "edge-tts" && profile.rateSource === "settings" && profile.engine !== "clone" ? profile.rate : undefined),
    onPlaybackStart: (startedAt) => {
      if (!firstAudio) {
        firstAudio = true;
        const ms = Math.max(0, startedAt - receivedAt);
        recordFirstAudio(profile.kind, ms, {engine: audioEngine,
          origin: options?.measurementOrigin ?? "speak", fallback: requestedClone && audioEngine === "edge-tts"});
        console.error(`[tts] first_audio_ms=${ms} profile=${profile.kind} engine=${audioEngine} voice=${audioVoice} chars=${chars}`);
      }
      onPlaybackStart?.(startedAt);
    },
  };

  // Fail-closed gate: when a cloned voice is MANDATED, an unregistered profile
  // must BLOCK rather than silently downgrade to a preset/system voice.
  // resolved.engine === "cloned" iff resolveVoice's Tier 1 hasClonedProfile()
  // matched, so this is the inline equivalent of assertRegisteredClone() (the
  // standalone export callers can use to pre-validate a reference before speak).
  if (requireClone && resolved.engine !== "cloned") {
    throw new VoiceProfileUnavailableError(
      selectedVoice,
      "missing-profile",
    );
  }

  const speakingText = displayText;

  // Context-aware shortcut: short announcements use edge-tts for speed.
  // Skipped when a clone is mandated — a required clone must not be downgraded.
  if (
    resolved.engine === "cloned" &&
    !requireClone &&
    (options?.voice !== undefined || profile.engineSource !== "settings") &&
    options?.mode === "announce" &&
    spokenText.length < 50
  ) {
    audioVoice = resolved.fallbackVoice || defaultVoice();
    return speakWithEdgeTTS(
      edgeProjection.speechText,
      resolved.fallbackVoice || defaultVoice(),
      options,
      resolved.warning,
      displayText,
      edgeProjection.ranges,
      signal,
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
        signal,
      );
      if (signal.aborted && wavPath) { try { unlinkSync(wavPath); } catch {} }
      throwIfAbortedSafe(signal);
      const mp3Path = wavPath ? convertWavToMp3(wavPath) : null;
      if (mp3Path) {
        audioEngine = "xtts-v2";
        const playback = await playClonedAudio(
          mp3Path,
          displayText,
          `xtts:${resolved.voice}`,
          speakingText,
          resolved.voice,
          projection,
          cloneOptions(),
          signal,
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
        { signal },
      );
      if (signal.aborted && wavPath) { try { unlinkSync(wavPath); } catch {} }
      throwIfAbortedSafe(signal);
      const mp3Path = wavPath ? convertWavToMp3(wavPath) : null;
      if (mp3Path) {
        audioEngine = "f5-tts-mlx";
        const playback = await playClonedAudio(
          mp3Path,
          displayText,
          `f5tts:${resolved.voice}`,
          speakingText,
          resolved.voice,
          projection,
          cloneOptions(),
          signal,
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
    const audioBuffer = await synthesizeCloned(spokenText, resolved.voice, signal);
    throwIfAbortedSafe(signal);
    if (audioBuffer) {
      audioEngine = "qwen3-tts";
      const ttsFile = ttsFilePath(process.pid, ttsCounter++);
      writeFileSync(ttsFile, audioBuffer);
      const playback = await playClonedAudio(
        ttsFile,
        displayText,
        `cloned:${resolved.voice}`,
        speakingText,
        resolved.voice,
        projection,
        cloneOptions(),
        signal,
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
    audioVoice = resolved.fallbackVoice || defaultVoice();
    return speakWithEdgeTTS(
      edgeProjection.speechText,
      resolved.fallbackVoice || defaultVoice(),
      options,
      undefined,
      displayText,
      edgeProjection.ranges,
      signal,
    );
  }

  // Tier 2: Preset/default → edge-tts
  return speakWithEdgeTTS(
    edgeProjection.speechText,
    resolved.voice,
    options,
    resolved.warning,
    displayText,
    edgeProjection.ranges,
    signal,
  );
}

/**
 * Synthesize and play via edge-tts (Python CLI).
 * Extracted from speak() to allow fallback from cloned voice failure.
 */
async function speakWithEdgeTTS(
  spokenText: string,
  voice: string,
  options?: SpeechOptions,
  warning?: string,
  displayText: string = spokenText,
  ranges?: ProjectionRange[],
  signal?: AbortSignal,
): Promise<TextToSpeechResult> {
  // Profile file rates enter as explicit options; otherwise preserve mode > env > default.
  let rate =
    options?.rate ??
    (options?.mode ? MODE_RATES[options.mode] : undefined) ??
    defaultRate();

  // Auto-slow for long text
  rate = adjustRateForLength(rate, spokenText.length);

  const ttsFile = ttsFilePath(process.pid, ttsCounter++);
  const scriptPath = new URL("../scripts/edge-tts-words.py", import.meta.url)
    .pathname;
  const tempChunkFiles: string[] = [];
  let wordBoundaries: WordBoundary[] = [];

  const textChunks = chunkTextForTTS(spokenText);
  try {
    if (textChunks.length === 1) {
      const synthesized = await synthesizeEdgeChunk(
        textChunks[0],
        voice,
        rate,
        ttsFile,
        scriptPath,
        signal,
      );
      throwIfAbortedSafe(signal);
      wordBoundaries = synthesized.wordBoundaries;
    } else {
      const synthesizedChunks: SynthesizedChunk[] = [];

      for (const [index, chunk] of textChunks.entries()) {
        const chunkFile = ttsFile.replace(".mp3", `.chunk${index}.mp3`);
        tempChunkFiles.push(chunkFile);
        synthesizedChunks.push(
          await synthesizeEdgeChunk(chunk, voice, rate, chunkFile, scriptPath, signal),
        );
        throwIfAbortedSafe(signal);
        options?.speechArchive?.generated(chunkFile, chunk, voice, options?.profile ?? "short", "edge-tts", index, synthesizedChunks.at(-1)?.durationMs ?? null);
      }

      concatenateMp3Files(
        synthesizedChunks.map((chunk) => chunk.audioFile),
        ttsFile,
      );
      wordBoundaries = mergeWordBoundaryChunks(synthesizedChunks);
    }
  } catch (error) {
    if (!signal?.aborted) broadcast({
      type: "error",
      message: "TTS synthesis failed (edge-tts)",
      recoverable: true,
    });
    broadcastPlaybackIdleIfSpeakerClear();
    for (const file of tempChunkFiles) {
      try {
        unlinkSpeechAudio(file);
      } catch {}
      try {
        unlinkSync(file.replace(".mp3", ".meta.ndjson"));
      } catch {}
    }
    try {
      unlinkSpeechAudio(ttsFile);
    } catch {}
    throw error;
  }

  for (const file of tempChunkFiles) {
    try {
      unlinkSpeechAudio(file);
    } catch {}
  }

  wordBoundaries = alignWordBoundariesToDisplayText(
    displayText,
    spokenText,
    wordBoundaries,
    ranges,
  );

  // Pass metadata to queue — broadcasting happens when audio actually starts
  let proc: QueuedPlaybackHandle;
  let audioArtifact: TextToSpeechResult["audioArtifact"];
  try {
    throwIfAbortedSafe(signal);
    assertSpeakerClear();
    audioArtifact = captureAudioArtifact(
      ttsFile,
      options?.captureAudioArtifact,
    );
    const durationMs = Math.max(probeAudioDurationMs(ttsFile) ?? 0, inferBoundaryEndMs(wordBoundaries)) || undefined;
    if (textChunks.length === 1) options?.speechArchive?.generated(ttsFile, textChunks[0], voice, options?.profile ?? "short", "edge-tts", 0, durationMs ?? null);
    else options?.speechArchive?.keepAudio(ttsFile, durationMs ?? null);
    addToHistory(displayText, ttsFile, voice, [], { wordBoundaries });
    proc = playAudioNonBlocking(ttsFile, {
      speechArchive: options?.speechArchive,
      text: displayText,
      voice,
      wordBoundaries: wordBoundaries.length > 0 ? wordBoundaries : undefined,
      priority: playbackPriorityForMode(options?.mode),
      durationMs,
      nextState: options?.mode === "converse" ? "recording" : undefined,
      onStarted: options?.onPlaybackStart,
      onQueued: options?.onPlaybackQueued,
      onCompleted: options?.onPlaybackComplete,
    });
  } catch (err) {
    try {
      unlinkSpeechAudio(ttsFile);
    } catch {}
    throw err;
  }
  void proc.playerExited.then(() => {
    try {
      unlinkSpeechAudio(ttsFile);
    } catch {}
  }, () => {});

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
