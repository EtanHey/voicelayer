/**
 * MCP tool definitions for VoiceLayer.
 *
 * Defines the ListTools response — tool names, descriptions, and JSON Schema
 * input specifications. Separated from handler logic for maintainability.
 */

import { STOP_FILE } from "./paths";

/** The two canonical VoiceLayer MCP tools. */
export function getToolDefinitions() {
  return [
    // === CONSOLIDATED TOOLS ===

    {
      name: "voice_speak",
      description:
        "Speak a message aloud or log it silently. NON-BLOCKING — returns instantly.\n\n" +
        "Modes (auto-detected from message if omitted):\n" +
        "- announce: fast TTS for status updates (default for short messages)\n" +
        "- brief: slower TTS for explanations (auto for messages > 280 chars)\n" +
        "- consult: checkpoint — speaks, hints user may respond\n" +
        "- think: silent markdown log, no audio (auto for 'insight:', 'note:', 'TODO:')\n\n" +
        "Also supports: replay (index param) and toggle (enabled param).\n\n" +
        "Stop playback: Voice Bar stop button or socket 'stop' command.\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS).",
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description:
              "The message to speak or log. Required for speak/think modes, ignored for toggle/replay.",
          },
          mode: {
            type: "string",
            description:
              "Output mode. Auto-detected from message content if omitted.",
            enum: ["announce", "brief", "consult", "think", "auto"],
            default: "auto",
          },
          voice: {
            type: "string",
            description:
              "Voice name — profile name (e.g. 'andrew') or raw edge-tts voice (e.g. 'en-US-AndrewNeural'). Default: jenny.",
          },
          rate: {
            type: "string",
            description:
              "Speech rate override (e.g. '+10%', '-5%'). Each mode has sensible defaults.",
            pattern: "^[+-]\\d+%$",
          },
          category: {
            type: "string",
            description:
              "Category for think mode: insight, question, red-flag, checklist-update.",
            enum: ["insight", "question", "red-flag", "checklist-update"],
            default: "insight",
          },
          replay_index: {
            type: "number",
            description:
              "Replay a cached message instead of speaking new text. 0 = most recent. Ignores message param.",
            minimum: 0,
            maximum: 19,
          },
          enabled: {
            type: "boolean",
            description:
              "Toggle voice on/off. When set, acts as toggle instead of speaking.",
          },
          scope: {
            type: "string",
            description:
              "Toggle scope: 'all' (default), 'tts', or 'mic'. Only used with enabled param.",
            enum: ["all", "tts", "mic"],
            default: "all",
          },
        },
        required: [],
      },
    },

    {
      name: "voice_ask",
      description:
        "Speak a question aloud and wait for the user's voice response. BLOCKING.\n" +
        "Auto-waits for any playing voice_speak audio to finish before speaking.\n\n" +
        "Two recording modes:\n" +
        "- VAD mode (default): Silero VAD detects speech, auto-stops on silence\n" +
        "- Push-to-end (push_to_end=true; gated): DISABLES automatic silence detection. " +
        "Recording will not stop when the user stops speaking; use only when the user explicitly asked for manual stop.\n\n" +
        `User-controlled stop: touch ${STOP_FILE} to end recording.\n` +
        "Requires voice session booking — other sessions see 'line busy'.\n\n" +
        "Returns: transcribed text on success, status message on timeout, error if busy.\n" +
        "Prerequisites: sox (recording), whisper.cpp or Wispr Flow (STT), python3 + edge-tts (TTS).",
      annotations: {
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The question to speak aloud before recording",
          },
          voice: {
            type: "string",
            description:
              "Voice name — profile name or raw edge-tts voice for the spoken question.",
          },
          timeout_seconds: {
            type: "number",
            description:
              "Max wait time in seconds. Clamped to 5-3600. Default: 30.",
            default: 30,
            minimum: 5,
            maximum: 3600,
          },
          silence_mode: {
            type: "string",
            description:
              "VAD silence threshold: 'quick' (0.5s), 'standard' (1.5s), 'thoughtful' (2.5s, default). Ignored in push-to-end mode.",
            enum: ["quick", "standard", "thoughtful"],
            default: "thoughtful",
          },
          push_to_end: {
            type: "boolean",
            description:
              "Manual-stop mode that disables automatic silence detection. " +
              "The recording will not stop when the user stops speaking; it ends only on an explicit " +
              `stop (touch ${STOP_FILE}) or timeout. Use only when the user explicitly asked for manual stop. ` +
              "Ignored unless VOICELAYER_ALLOW_PUSH_TO_END=1.",
            default: false,
          },
        },
        required: ["message"],
      },
    },

  ];
}
