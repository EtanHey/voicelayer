/**
 * Socket protocol types for VoiceLayer <-> Voice Bar communication.
 *
 * Transport: Unix domain socket at /tmp/voicelayer.sock (Voice Bar is server, MCP is client).
 * Framing: Newline-delimited JSON (NDJSON) -- one JSON object per line, \n terminated.
 *
 * Both the Bun socket client and SwiftUI Voice Bar server must agree on these types.
 */

import type { WhisperPerformanceEffort } from "./whisper-performance";
import {
  PLAYBACK_AMPLITUDE_MAX_EVENT_SAMPLES,
  type PlaybackAmplitudeEnvelope,
} from "./playback-amplitude";

// --- Events: VoiceLayer → Voice Bar ---

export type VoiceLayerState =
  "idle" | "speaking" | "recording" | "transcribing";

export interface StateEvent {
  type: "state";
  state: VoiceLayerState;
  /** Present when state is "speaking" — the text being spoken. */
  text?: string;
  /** Present when state is "speaking" — the voice being used. */
  voice?: string;
  /** Fixed-window RMS truth for the audio file that just started playing. */
  playback_amplitude?: PlaybackAmplitudeEnvelope;
  /** Present when state is "recording" — the recording mode. */
  mode?: "vad" | "ptt";
  /** Present when state is "recording" with VAD — the silence mode. */
  silence_mode?: "quick" | "standard" | "thoughtful";
  /**
   * Source of idle events — lets Voice Bar distinguish playback-end from recording-end.
   * AIDEV-NOTE: Without this, a queued voice_speak audio finishing during a bar-initiated
   * recording resets barInitiatedRecording before the transcription arrives, killing paste.
   */
  source?: "playback" | "recording";
  /** Immediate follow-up after playback completion (voice_ask converse flow). */
  next_state?: "recording";
  /**
   * Present when state is "recording" — true when the capture was started from the Voice Bar
   * (F5/dictation), false when it belongs to a remote MCP caller.
   * AIDEV-NOTE: Voice Bar cannot otherwise distinguish a remote-initiated capture from a
   * dropped-ack F5 press, so its late-record-start recovery claims the remote capture and
   * auto-pastes the answer into the frontmost app instead of returning it to the blocked caller.
   * The 10s recovery window makes that a race, which is why the symptom was intermittent.
   * Sent as a derived boolean, not the raw source token, to keep the UI layer presentation-only
   * (see BoundaryContractTests). Live repro 2026-07-26 12:55:30 (466 chars pasted into Preview).
   */
  bar_owned?: boolean;
}

export interface SpeechEvent {
  type: "speech";
  /** true = voice activity detected, false = silence detected. */
  detected: boolean;
}

export interface TranscriptionEvent {
  type: "transcription";
  text: string;
  /** true = partial/streaming result, false = final result. */
  partial?: boolean;
  /** Archived VoiceBar recording audio used to produce this transcript. */
  recording_path?: string;
  /** Whether the optional LLM polish layer produced the final candidate. */
  polished?: boolean;
  /** Outcome of the polish attempt; rejected means the safety gate kept cleaned text. */
  polish_status?:
    "skipped" | "unavailable" | "shadowed" | "applied" | "rejected" | "failed";
  /** Why the cleaned fallback was used when polished is false. */
  polish_reason?: string;
}

export interface TranscriptionStatusEvent {
  type: "transcription_status";
  status: "warming" | "transcribing";
  message: string;
}

export interface PolishDegradedEvent {
  type: "polish_degraded";
  reason: "missing-binary" | "launch-timeout" | "launch-failed";
  hint: string;
}

export interface PolishReadyEvent {
  type: "polish_ready";
}

export interface AudioLevelEvent {
  type: "audio_level";
  /** RMS audio level 0.0–1.0. */
  rms: number;
}

export interface ErrorEvent {
  type: "error";
  message: string;
  /** true = transient error (will recover), false = needs user action. */
  recoverable: boolean;
  /** true = surface this error even during a bar-initiated recording. */
  show_during_bar_recording?: boolean;
  /** Machine-readable capture failure signal for VoiceBar daemon supervision. */
  capture_failure?: "broken-mic";
}

/** Word boundary from edge-tts WordBoundary event. */
export interface WordBoundary {
  /** Offset from start of audio in milliseconds. */
  offset_ms: number;
  /** Duration of the word in milliseconds. */
  duration_ms: number;
  /** The word text. */
  text: string;
}

/** Sent after TTS synthesis completes, before playback starts.
 *  Voice Bar uses these timestamps to drive karaoke word highlighting. */
export interface SubtitleEvent {
  type: "subtitle";
  /** Word boundaries with exact timing from the TTS engine. */
  words: WordBoundary[];
}

export type PlaybackPriority =
  "critical" | "high" | "normal" | "low" | "background";

export interface QueueItemSnapshot {
  text: string;
  voice: string;
  priority: PlaybackPriority;
  is_current: boolean;
  /** Progress of the current item from 0.0 to 1.0. Queued items stay at 0. */
  progress: number;
}

export interface QueueEvent {
  type: "queue";
  /** Total queued + currently playing items. */
  depth: number;
  /** Ordered queue snapshot: current item first, then pending items. */
  items: QueueItemSnapshot[];
}

export type PlaybackOutcomeStatus =
  "completed" | "interrupted" | "skipped" | "failed";

export type PlaybackOutcomeReason =
  "stopped" | "barge-in" | "expired" | "collapsed" | "refused" | "player-error";

export interface PlaybackOutcomeEvent {
  type: "playback_outcome";
  playback_id: string;
  status: PlaybackOutcomeStatus;
  reason?: PlaybackOutcomeReason;
  stopped_at_ms: number;
  duration_ms?: number;
  progress: number;
  /** Zero-based word active at the stopped position, when available. */
  word_index?: number;
  word_count?: number;
}

export type CommandModePhase =
  "listening" | "capturing" | "applying" | "fallback" | "done" | "error";

export interface CommandModeEvent {
  type: "command_mode";
  phase: CommandModePhase;
  operation: "replace_selection" | "insert_below";
  prompt?: string;
  replacement_text?: string;
}

export interface ClipMarkerEvent {
  type: "clip_marker";
  marker_id: string;
  label: string;
  source: "tts" | "command";
  status: "marked" | "consumed";
}

export type IntentOutcome = "accept" | "noop" | "reject";

export type AckCommand =
  | "stop"
  | "cancel"
  | "replay"
  | "retranscribe_last"
  | "retranscribe_recording"
  | "toggle"
  | "record"
  | "command"
  | "mark_clip"
  | "vocab_add"
  | "vocab_remove"
  | "vocab_add_term"
  | "vocab_remove_term"
  | "set_recording_hold"
  | "set_whisper_effort";

export interface AckEvent {
  type: "ack";
  command: AckCommand;
  outcome: IntentOutcome;
  id?: string;
  reason?: string;
}

export type SocketEvent =
  | StateEvent
  | SpeechEvent
  | TranscriptionEvent
  | TranscriptionStatusEvent
  | PolishDegradedEvent
  | PolishReadyEvent
  | AudioLevelEvent
  | ErrorEvent
  | SubtitleEvent
  | QueueEvent
  | PlaybackOutcomeEvent
  | CommandModeEvent
  | ClipMarkerEvent
  | AckEvent;

// --- Commands: Voice Bar → VoiceLayer ---

interface SocketCommandBase {
  id?: string;
}

export interface StopCommand extends SocketCommandBase {
  cmd: "stop";
  /** VoiceBar's teleprompter clock at the stop edge. */
  playback_elapsed_ms?: number;
}

export interface CancelCommand extends SocketCommandBase {
  cmd: "cancel";
  /** VoiceBar's teleprompter clock at the cancel edge. */
  playback_elapsed_ms?: number;
}

export interface ReplayCommand extends SocketCommandBase {
  cmd: "replay";
}

export interface RetranscribeLastCommand extends SocketCommandBase {
  cmd: "retranscribe_last";
}

export interface RetranscribeRecordingCommand extends SocketCommandBase {
  cmd: "retranscribe_recording";
  audio_path: string;
}

export interface ToggleCommand extends SocketCommandBase {
  cmd: "toggle";
  scope: "all" | "tts" | "mic";
  enabled: boolean;
}

export interface RecordCommand extends SocketCommandBase {
  cmd: "record";
  /** Recording timeout in seconds (default: 30, max: 3600). */
  timeout_seconds?: number;
  /** Silence detection mode (default: "standard"). */
  silence_mode?: "quick" | "standard" | "thoughtful";
  /** Push-to-talk mode — no VAD, stop via signal (default: false). */
  press_to_talk?: boolean;
}

export interface HealthCommand extends SocketCommandBase {
  cmd: "health";
}

export interface CommandModeCommand extends SocketCommandBase {
  cmd: "command";
  operation: "replace_selection" | "insert_below";
  text: string;
  prompt?: string;
}

export interface MarkClipCommand extends SocketCommandBase {
  cmd: "mark_clip";
  label: string;
  source?: "tts" | "command";
}

export interface VocabAddCommand extends SocketCommandBase {
  cmd: "vocab_add";
  from: string;
  to: string;
}

export interface VocabListCommand extends SocketCommandBase {
  cmd: "vocab_list";
}

export interface VocabRemoveCommand extends SocketCommandBase {
  cmd: "vocab_remove";
  from: string;
}

export interface VocabAddTermCommand extends SocketCommandBase {
  cmd: "vocab_add_term";
  term: string;
}

export interface VocabRemoveTermCommand extends SocketCommandBase {
  cmd: "vocab_remove_term";
  term: string;
}

export interface SetWhisperEffortCommand extends SocketCommandBase {
  cmd: "set_whisper_effort";
  effort: WhisperPerformanceEffort;
}

export interface SetRecordingHoldCommand extends SocketCommandBase {
  cmd: "set_recording_hold";
  engaged: boolean;
}

export type SocketCommand =
  | StopCommand
  | CancelCommand
  | ReplayCommand
  | RetranscribeLastCommand
  | RetranscribeRecordingCommand
  | ToggleCommand
  | RecordCommand
  | HealthCommand
  | CommandModeCommand
  | MarkClipCommand
  | VocabAddCommand
  | VocabListCommand
  | VocabRemoveCommand
  | VocabAddTermCommand
  | VocabRemoveTermCommand
  | SetRecordingHoldCommand
  | SetWhisperEffortCommand;

export interface HealthResponse {
  type: "health";
  uptime_seconds: number;
  queue_depth: number;
  recording_state: "idle" | "recording" | "transcribing";
}

export interface VocabListResponse {
  type: "vocab_list";
  id?: string;
  updated_at: string | null;
  entries: Array<{ canonical: string; variants: string[] }>;
}

export type SocketResponse = HealthResponse | AckEvent | VocabListResponse;

// --- Serialization ---

/**
 * Keep a single VoiceBar-bound NDJSON frame below the historical 8 KiB
 * transport boundary. The newline is included in this byte budget.
 */
export const VOICEBAR_SOCKET_EVENT_MAX_BYTES = 8_191;

function serializedByteLength(payload: string): number {
  return new TextEncoder().encode(payload).byteLength;
}

function serializeJsonEvent(event: SocketEvent): string {
  return JSON.stringify(event) + "\n";
}

function fitSpeakingTextToSocketFrame(event: StateEvent): string | null {
  const withoutText: StateEvent = { ...event };
  delete withoutText.text;
  const basePayload = serializeJsonEvent(withoutText);
  if (serializedByteLength(basePayload) > VOICEBAR_SOCKET_EVENT_MAX_BYTES) {
    return null;
  }

  if (typeof event.text !== "string" || event.text.length === 0) {
    return basePayload;
  }

  // Search Unicode scalar boundaries so truncation never leaves a broken
  // surrogate pair. JSON-escaping and UTF-8 bytes are measured exactly for
  // each candidate; the TTS audio itself is never truncated here.
  const scalars = Array.from(event.text);
  let low = 0;
  let high = scalars.length;
  let best = basePayload;
  while (low <= high) {
    const middle = Math.floor((low + high) / 2);
    const candidate = serializeJsonEvent({
      ...event,
      text: scalars.slice(0, middle).join(""),
    });
    if (serializedByteLength(candidate) <= VOICEBAR_SOCKET_EVENT_MAX_BYTES) {
      best = candidate;
      low = middle + 1;
    } else {
      high = middle - 1;
    }
  }
  return best;
}

function normalizeSpeakingEnvelope(event: StateEvent): StateEvent {
  const envelope = event.playback_amplitude;
  if (
    envelope?.source !== "decoded-rms" ||
    envelope.samples.length <= PLAYBACK_AMPLITUDE_MAX_EVENT_SAMPLES
  ) {
    return event;
  }

  return {
    ...event,
    playback_amplitude: {
      source: "unavailable",
      sample_interval_ms: envelope.sample_interval_ms,
      samples: [],
    },
  };
}

/** Serialize an event to NDJSON (JSON + newline). */
export function serializeEvent(event: SocketEvent): string {
  const normalizedEvent =
    event.type === "state" && event.state === "speaking"
      ? normalizeSpeakingEnvelope(event)
      : event;
  const payload = serializeJsonEvent(normalizedEvent);
  if (serializedByteLength(payload) <= VOICEBAR_SOCKET_EVENT_MAX_BYTES) {
    return payload;
  }

  if (
    normalizedEvent.type === "state" &&
    normalizedEvent.state === "speaking"
  ) {
    const textBoundedPayload = fitSpeakingTextToSocketFrame(normalizedEvent);
    if (textBoundedPayload) return textBoundedPayload;

    // An envelope not produced by our bounded RMS extractor may still exceed
    // the frame even without teleprompter text. Fail truthful and flat instead
    // of emitting a truncated or unparsable waveform.
    if (normalizedEvent.playback_amplitude) {
      const unavailableEvent: StateEvent = {
        ...normalizedEvent,
        playback_amplitude: {
          source: "unavailable",
          sample_interval_ms:
            normalizedEvent.playback_amplitude.sample_interval_ms,
          samples: [],
        },
      };
      const unavailablePayload = fitSpeakingTextToSocketFrame(unavailableEvent);
      if (unavailablePayload) return unavailablePayload;
    }

    return serializeJsonEvent({ type: "state", state: "speaking" });
  }

  return payload;
}

/** Parse a single JSON line into a SocketCommand. Returns null if invalid. */
export function parseCommand(line: string): SocketCommand | null {
  try {
    const parsed = JSON.parse(line);
    if (
      !parsed ||
      typeof parsed !== "object" ||
      typeof parsed.cmd !== "string"
    ) {
      return null;
    }
    const id = parseCommandId(parsed);
    const playbackElapsedMs =
      typeof parsed.playback_elapsed_ms === "number" &&
      Number.isFinite(parsed.playback_elapsed_ms) &&
      parsed.playback_elapsed_ms >= 0
        ? Math.round(parsed.playback_elapsed_ms)
        : undefined;
    switch (parsed.cmd) {
      case "stop":
        return withCommandId<StopCommand>(
          {
            cmd: "stop",
            ...(playbackElapsedMs !== undefined
              ? { playback_elapsed_ms: playbackElapsedMs }
              : {}),
          },
          id,
        );
      case "cancel":
        return withCommandId<CancelCommand>(
          {
            cmd: "cancel",
            ...(playbackElapsedMs !== undefined
              ? { playback_elapsed_ms: playbackElapsedMs }
              : {}),
          },
          id,
        );
      case "replay":
        return withCommandId<ReplayCommand>({ cmd: "replay" }, id);
      case "retranscribe_last":
        return withCommandId<RetranscribeLastCommand>(
          { cmd: "retranscribe_last" },
          id,
        );
      case "retranscribe_recording": {
        if (
          typeof parsed.audio_path !== "string" ||
          parsed.audio_path.trim().length === 0
        ) {
          return null;
        }
        return withCommandId<RetranscribeRecordingCommand>(
          {
            cmd: "retranscribe_recording",
            audio_path: parsed.audio_path.trim(),
          },
          id,
        );
      }
      case "health":
        return withCommandId<HealthCommand>({ cmd: "health" }, id);
      case "command": {
        if (
          typeof parsed.text !== "string" ||
          parsed.text.trim().length === 0
        ) {
          return null;
        }
        const operation =
          parsed.operation === "insert_below"
            ? "insert_below"
            : "replace_selection";
        return withCommandId<CommandModeCommand>(
          {
            cmd: "command",
            operation,
            text: parsed.text,
            prompt:
              typeof parsed.prompt === "string" ? parsed.prompt : undefined,
          },
          id,
        );
      }
      case "mark_clip": {
        if (
          typeof parsed.label !== "string" ||
          parsed.label.trim().length === 0
        ) {
          return null;
        }
        return withCommandId<MarkClipCommand>(
          {
            cmd: "mark_clip",
            label: parsed.label,
            source: parsed.source === "tts" ? "tts" : "command",
          },
          id,
        );
      }
      case "vocab_add": {
        const from = parseRequiredString(parsed.from);
        const to = parseRequiredString(parsed.to);
        if (!from || !to) return null;
        return withCommandId<VocabAddCommand>(
          {
            cmd: "vocab_add",
            from,
            to,
          },
          id,
        );
      }
      case "vocab_list":
        return withCommandId<VocabListCommand>({ cmd: "vocab_list" }, id);
      case "vocab_remove": {
        const from = parseRequiredString(parsed.from);
        if (!from) return null;
        return withCommandId<VocabRemoveCommand>(
          {
            cmd: "vocab_remove",
            from,
          },
          id,
        );
      }
      case "vocab_add_term": {
        const term = parseRequiredString(parsed.term);
        if (!term) return null;
        return withCommandId<VocabAddTermCommand>(
          {
            cmd: "vocab_add_term",
            term,
          },
          id,
        );
      }
      case "vocab_remove_term": {
        const term = parseRequiredString(parsed.term);
        if (!term) return null;
        return withCommandId<VocabRemoveTermCommand>(
          {
            cmd: "vocab_remove_term",
            term,
          },
          id,
        );
      }
      case "set_whisper_effort": {
        if (
          parsed.effort !== "fast" &&
          parsed.effort !== "balanced" &&
          parsed.effort !== "accurate"
        ) {
          return null;
        }
        return withCommandId<SetWhisperEffortCommand>(
          {
            cmd: "set_whisper_effort",
            effort: parsed.effort,
          },
          id,
        );
      }
      case "set_recording_hold": {
        if (typeof parsed.engaged !== "boolean") {
          return null;
        }
        return withCommandId<SetRecordingHoldCommand>(
          {
            cmd: "set_recording_hold",
            engaged: parsed.engaged,
          },
          id,
        );
      }
      case "toggle": {
        if (typeof parsed.enabled !== "boolean") return null;
        const scope = parsed.scope;
        if (scope !== "all" && scope !== "tts" && scope !== "mic") {
          return withCommandId(
            {
              cmd: "toggle",
              scope: "all",
              enabled: parsed.enabled,
            } satisfies ToggleCommand,
            id,
          );
        }
        return withCommandId(
          {
            cmd: "toggle",
            scope,
            enabled: parsed.enabled,
          } satisfies ToggleCommand,
          id,
        );
      }
      case "record": {
        const command: RecordCommand = withCommandId(
          {
            cmd: "record",
          },
          id,
        );
        if (typeof parsed.timeout_seconds === "number") {
          command.timeout_seconds = Math.max(
            5,
            Math.min(3600, parsed.timeout_seconds),
          );
        }
        if (
          parsed.silence_mode === "quick" ||
          parsed.silence_mode === "standard" ||
          parsed.silence_mode === "thoughtful"
        ) {
          command.silence_mode = parsed.silence_mode;
        }
        if (parsed.press_to_talk === true) {
          command.press_to_talk = true;
        }
        return command;
      }
      default:
        return null;
    }
  } catch {
    return null;
  }
}

function parseRequiredString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function parseCommandId(parsed: Record<string, unknown>): string | undefined {
  if (typeof parsed.id !== "string") return undefined;
  const id = parsed.id.trim();
  return id.length > 0 ? id : undefined;
}

function withCommandId<T extends object>(
  command: T,
  id?: string,
): T & { id?: string } {
  if (!id) return command;
  return {
    ...command,
    id,
  };
}
