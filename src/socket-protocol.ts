/**
 * Socket protocol types for VoiceLayer ↔ Voice Bar communication.
 *
 * Transport: Unix domain socket at /tmp/voicelayer-{token}.sock (per-session)
 * Framing: Newline-delimited JSON (NDJSON) — one JSON object per line, \n terminated.
 *
 * AIDEV-NOTE: This is the contract between the Bun socket server and the
 * SwiftUI Voice Bar client. Both sides must agree on these types.
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

export type SocketEvent =
  | StateEvent
  | SpeechEvent
  | TranscriptionEvent
  | AudioLevelEvent
  | ErrorEvent;

// --- Commands: Voice Bar → VoiceLayer ---

export interface StopCommand {
  cmd: "stop";
}

export interface CancelCommand {
  cmd: "cancel";
}

export interface ReplayCommand {
  cmd: "replay";
}

export interface ToggleCommand {
  cmd: "toggle";
  scope: "all" | "tts" | "mic";
  enabled: boolean;
}

export interface RecordCommand {
  cmd: "record";
  /** Recording timeout in seconds (default: 30). */
  timeout_seconds?: number;
  /** Silence detection mode (default: "standard"). */
  silence_mode?: "quick" | "standard" | "thoughtful";
  /** Push-to-talk mode — no VAD, stop via signal (default: false). */
  press_to_talk?: boolean;
}

export type SocketCommand =
  | StopCommand
  | CancelCommand
  | ReplayCommand
  | ToggleCommand
  | RecordCommand;

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
    switch (parsed.cmd) {
      case "stop":
        return { cmd: "stop" };
      case "cancel":
        return { cmd: "cancel" };
      case "replay":
        return { cmd: "replay" };
      case "toggle": {
        if (typeof parsed.enabled !== "boolean") return null;
        const scope = parsed.scope;
        if (scope !== "all" && scope !== "tts" && scope !== "mic") {
          return { cmd: "toggle", scope: "all", enabled: parsed.enabled };
        }
        return { cmd: "toggle", scope, enabled: parsed.enabled };
      }
      case "record": {
        const sm = parsed.silence_mode;
        const silenceMode =
          sm === "quick" || sm === "standard" || sm === "thoughtful"
            ? sm
            : "standard";
        const rawTimeout =
          typeof parsed.timeout_seconds === "number"
            ? parsed.timeout_seconds
            : 30;
        return {
          cmd: "record",
          timeout_seconds: Math.max(5, Math.min(300, rawTimeout)),
          silence_mode: silenceMode,
          press_to_talk: parsed.press_to_talk === true,
        };
      }
      default:
        return null;
    }
  } catch {
    return null;
  }
}
