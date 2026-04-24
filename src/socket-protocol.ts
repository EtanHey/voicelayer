/**
 * Socket protocol types for VoiceLayer <-> Voice Bar communication.
 *
 * Transport: Unix domain socket at /tmp/voicelayer.sock (Voice Bar is server, MCP is client).
 * Framing: Newline-delimited JSON (NDJSON) -- one JSON object per line, \n terminated.
 *
 * Both the Bun socket client and SwiftUI Voice Bar server must agree on these types.
 */

// --- Events: VoiceLayer → Voice Bar ---

export type VoiceLayerState =
  | "idle"
  | "speaking"
  | "recording"
  | "transcribing";

export interface StateEvent {
  type: "state";
  state: VoiceLayerState;
  /** Present when state is "speaking" — the text being spoken. */
  text?: string;
  /** Present when state is "speaking" — the voice being used. */
  voice?: string;
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
  | "critical"
  | "high"
  | "normal"
  | "low"
  | "background";

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

export type CommandModePhase =
  | "listening"
  | "capturing"
  | "applying"
  | "fallback"
  | "done"
  | "error";

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
  | "toggle"
  | "record"
  | "command"
  | "mark_clip";

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
  | AudioLevelEvent
  | ErrorEvent
  | SubtitleEvent
  | QueueEvent
  | CommandModeEvent
  | ClipMarkerEvent
  | AckEvent;

// --- Commands: Voice Bar → VoiceLayer ---

interface SocketCommandBase {
  id?: string;
}

export interface StopCommand extends SocketCommandBase {
  cmd: "stop";
}

export interface CancelCommand extends SocketCommandBase {
  cmd: "cancel";
}

export interface ReplayCommand extends SocketCommandBase {
  cmd: "replay";
}

export interface ToggleCommand extends SocketCommandBase {
  cmd: "toggle";
  scope: "all" | "tts" | "mic";
  enabled: boolean;
}

export interface RecordCommand extends SocketCommandBase {
  cmd: "record";
  /** Recording timeout in seconds (default: 30). */
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

export type SocketCommand =
  | StopCommand
  | CancelCommand
  | ReplayCommand
  | ToggleCommand
  | RecordCommand
  | HealthCommand
  | CommandModeCommand
  | MarkClipCommand;

export interface HealthResponse {
  type: "health";
  uptime_seconds: number;
  queue_depth: number;
  recording_state: "idle" | "recording" | "transcribing";
}

export type SocketResponse = HealthResponse | AckEvent;

// --- Serialization ---

/** Serialize an event to NDJSON (JSON + newline). */
export function serializeEvent(event: SocketEvent): string {
  return JSON.stringify(event) + "\n";
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
    switch (parsed.cmd) {
      case "stop":
        return withCommandId({ cmd: "stop" }, id);
      case "cancel":
        return withCommandId({ cmd: "cancel" }, id);
      case "replay":
        return withCommandId({ cmd: "replay" }, id);
      case "health":
        return withCommandId({ cmd: "health" }, id);
      case "command": {
        if (typeof parsed.text !== "string" || parsed.text.trim().length === 0) {
          return null;
        }
        const operation =
          parsed.operation === "insert_below" ? "insert_below" : "replace_selection";
        return withCommandId({
          cmd: "command",
          operation,
          text: parsed.text,
          prompt: typeof parsed.prompt === "string" ? parsed.prompt : undefined,
        }, id);
      }
      case "mark_clip": {
        if (typeof parsed.label !== "string" || parsed.label.trim().length === 0) {
          return null;
        }
        return withCommandId({
          cmd: "mark_clip",
          label: parsed.label,
          source: parsed.source === "tts" ? "tts" : "command",
        }, id);
      }
      case "toggle": {
        if (typeof parsed.enabled !== "boolean") return null;
        const scope = parsed.scope;
        if (scope !== "all" && scope !== "tts" && scope !== "mic") {
          return withCommandId(
            { cmd: "toggle", scope: "all", enabled: parsed.enabled },
            id,
          );
        }
        return withCommandId(
          { cmd: "toggle", scope, enabled: parsed.enabled },
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
          command.timeout_seconds = Math.max(5, Math.min(300, parsed.timeout_seconds));
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

function parseCommandId(parsed: Record<string, unknown>): string | undefined {
  if (typeof parsed.id !== "string") return undefined;
  const id = parsed.id.trim();
  return id.length > 0 ? id : undefined;
}

function withCommandId<T extends object>(command: T, id?: string): T & { id?: string } {
  if (!id) return command;
  return {
    ...command,
    id,
  };
}
