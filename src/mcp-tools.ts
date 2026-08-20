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
        "Speak an announcement/status aloud or log a note silently. NON-BLOCKING — returns instantly.\n" +
        "Spoken modes have a HARD LIMIT: 1,200 characters — longer messages are refused, not truncated. " +
        "Use them only for announcements or status updates that do not require the user to understand or respond. " +
        "voice_speak never waits for the user to absorb it — it has no acknowledgement gate, " +
        "so an agent can queue the next utterance before the user has taken in the current one. " +
        "Content the user must understand or respond to belongs in sequential voice_ask checkpoints.\n\n" +
        "Modes (auto-detected from message if omitted):\n" +
        "- announce: fast TTS for status updates (default for short messages)\n" +
        "- brief: slower TTS for explanations (auto for messages > 280 chars)\n" +
        "- consult: non-blocking spoken consultation; never waits for a response\n" +
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
        "Ask one short question aloud and wait for the user's voice response. BLOCKING: " +
        "the question is spoken before the microphone opens, and the caller blocks for the entire playback plus the response.\n" +
        "HARD LIMIT: 600 characters maximum; the effective per-request limit may be lower for short timeout_seconds values. " +
        "Longer messages are refused, not truncated. " +
        "That is roughly 45 seconds of speech, and it is a question, not a briefing.\n" +
        "If content the user must understand or respond to is longer, split it into two or more sequential voice_ask calls. " +
        "Each ask is a checkpoint: the user confirms they absorbed one part before the next is spoken. " +
        "voice_speak is only for announcements or status updates that do not need a response.\n" +
        "Auto-waits for any playing voice_speak audio to finish before speaking.\n\n" +
        "Two recording modes:\n" +
        "- VAD mode (default): Silero VAD detects speech, auto-stops on silence\n" +
        "- Push-to-end (push_to_end=true; gated): DISABLES automatic silence detection. " +
        "Recording will not stop when the user stops speaking; use only when the user explicitly asked for manual stop.\n\n" +
        `User-controlled stop: touch ${STOP_FILE} to end recording.\n` +
        "Requires voice session booking — other sessions see 'line busy'.\n\n" +
        "Captured user audio is always kept, including cancel, abort, and hard-timeout paths. " +
        "If transcription cannot finish after audio exists, the non-fatal result includes an archive ID and audio path. " +
        "Recover it with Re-transcribe in VoiceBar History; do not ask the user to repeat.\n" +
        "Optional archive retranscription is explicit only and never automatic: call voice_ask with only retranscribe_archive_id from the preceding successful Ask. " +
        "It binds to that exact receipt, sends the complete retained response audio to STT, does not speak and does not open the microphone, and returns the result only to this caller.\n" +
        "Returns: transcribed text on success, recoverable archive details when captured audio needs retranscription, error if busy or the pipeline is stuck with zero recoverable audio.\n" +
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
            description:
              "Short question to speak aloud before recording. Split long content into sequential voice_ask checkpoints.",
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
          retranscribe_archive_id: {
            type: "string",
            description:
              "The exact archive receipt returned by the preceding successful voice_ask. Use by itself for explicit retranscription of that retained Ask response.",
            pattern:
              "^\\d{4}-\\d{2}-\\d{2}T\\d{2}-\\d{2}-\\d{2}-\\d{3}Z-[a-f0-9]{8}$",
          },
        },
        required: [],
        oneOf: [
          {
            required: ["message"],
            not: { required: ["retranscribe_archive_id"] },
          },
          {
            required: ["retranscribe_archive_id"],
            not: {
              anyOf: [
                { required: ["message"] },
                { required: ["voice"] },
                { required: ["timeout_seconds"] },
                { required: ["silence_mode"] },
                { required: ["push_to_end"] },
              ],
            },
          },
        ],
      },
    },

  ];
}
