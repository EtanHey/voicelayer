/**
 * MCP tool definitions for VoiceLayer.
 *
 * Defines the ListTools response — tool names, descriptions, and JSON Schema
 * input specifications. Separated from handler logic for maintainability.
 */

import { STOP_FILE } from "./paths";

/** All VoiceLayer MCP tools (consolidated + backward-compat aliases). */
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
        "- Push-to-talk (press_to_talk=true): Records until stop signal — best for noisy environments\n\n" +
        `User-controlled stop: touch ${STOP_FILE} to end recording.\n` +
        "Requires voice session booking — other sessions see 'line busy'.\n\n" +
        "Returns: transcribed text on success, status message on timeout, error if busy.\n" +
        "Prerequisites: sox (recording), whisper.cpp or Wispr Flow (STT), python3 + edge-tts (TTS).",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The question to speak aloud before recording",
          },
          timeout_seconds: {
            type: "number",
            description:
              "Max wait time in seconds. Clamped to 10-3600. Default: 300.",
            default: 300,
            minimum: 10,
            maximum: 3600,
          },
          silence_mode: {
            type: "string",
            description:
              "VAD silence threshold: 'quick' (0.5s), 'standard' (1.5s), 'thoughtful' (2.5s, default). Ignored in PTT mode.",
            enum: ["quick", "standard", "thoughtful"],
            default: "thoughtful",
          },
          press_to_talk: {
            type: "boolean",
            description:
              `Push-to-talk mode. When true, recording runs until user sends stop signal ` +
              `(touch ${STOP_FILE}). No VAD silence detection. ` +
              "Recommended for loud/noisy environments.",
            default: false,
          },
        },
        required: ["message"],
      },
    },

    // === BACKWARD-COMPAT ALIASES ===

    {
      name: "qa_voice_announce",
      description: "Alias for voice_speak(mode='announce'). NON-BLOCKING TTS.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The message to speak aloud",
          },
          rate: { type: "string", pattern: "^[+-]\\d+%$", default: "+10%" },
        },
        required: ["message"],
      },
    },
    {
      name: "qa_voice_brief",
      description:
        "Alias for voice_speak(mode='brief'). NON-BLOCKING TTS, slower rate.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The message to speak aloud",
          },
          rate: { type: "string", pattern: "^[+-]\\d+%$", default: "-10%" },
        },
        required: ["message"],
      },
    },
    {
      name: "qa_voice_consult",
      description:
        "Alias for voice_speak(mode='consult'). NON-BLOCKING checkpoint.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The message to speak aloud",
          },
          rate: { type: "string", pattern: "^[+-]\\d+%$", default: "+5%" },
        },
        required: ["message"],
      },
    },
    {
      name: "qa_voice_converse",
      description: "Alias for voice_ask. BLOCKING voice Q&A.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: { type: "string", description: "The question to speak" },
          timeout_seconds: {
            type: "number",
            default: 300,
            minimum: 10,
            maximum: 3600,
          },
          silence_mode: {
            type: "string",
            enum: ["quick", "standard", "thoughtful"],
            default: "thoughtful",
          },
          press_to_talk: {
            type: "boolean",
            description: `Push-to-talk mode. No VAD, stop via ${STOP_FILE}.`,
            default: false,
          },
        },
        required: ["message"],
      },
    },
    {
      name: "qa_voice_think",
      description: "Alias for voice_speak(mode='think'). Silent markdown log.",
      inputSchema: {
        type: "object" as const,
        properties: {
          thought: { type: "string", description: "The thought to log" },
          category: {
            type: "string",
            enum: ["insight", "question", "red-flag", "checklist-update"],
            default: "insight",
          },
        },
        required: ["thought"],
      },
    },
    {
      name: "qa_voice_replay",
      description:
        "Alias for voice_speak(replay_index=N). Replay cached audio.",
      inputSchema: {
        type: "object" as const,
        properties: {
          index: { type: "number", default: 0, minimum: 0, maximum: 19 },
        },
      },
    },
    {
      name: "qa_voice_toggle",
      description: "Alias for voice_speak(enabled=bool). Toggle voice on/off.",
      inputSchema: {
        type: "object" as const,
        properties: {
          enabled: { type: "boolean" },
          scope: {
            type: "string",
            enum: ["all", "tts", "mic"],
            default: "all",
          },
        },
        required: ["enabled"],
      },
    },
    {
      name: "qa_voice_say",
      description: "Alias for voice_speak(mode='announce'). NON-BLOCKING TTS.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The message to speak aloud",
          },
        },
        required: ["message"],
      },
    },
    {
      name: "qa_voice_ask",
      description: "Alias for voice_ask. BLOCKING voice Q&A.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: { type: "string", description: "The question to speak" },
          timeout_seconds: {
            type: "number",
            default: 300,
            minimum: 10,
            maximum: 3600,
          },
          silence_mode: {
            type: "string",
            enum: ["quick", "standard", "thoughtful"],
            default: "thoughtful",
          },
          press_to_talk: {
            type: "boolean",
            description: `Push-to-talk mode. No VAD, stop via ${STOP_FILE}.`,
            default: false,
          },
        },
        required: ["message"],
      },
    },
  ];
}
