#!/usr/bin/env bun
/**
 * VoiceLayer MCP Server — 4 voice modes + silent think tool + replay + toggle.
 *
 * Modes:
 *   announce  — fire-and-forget TTS (status updates, narration)
 *   brief     — one-way explanation via TTS (reading back decisions, summaries)
 *   consult   — speak + signal that user may respond (non-blocking checkpoint)
 *   converse  — bidirectional voice Q&A with user-controlled stop (blocking)
 *   think     — silent markdown log (no voice)
 *
 * New (Phase 2):
 *   replay    — replay a recently spoken message from the ring buffer
 *   toggle    — enable/disable TTS and/or mic via flag files
 *
 * Aliases (backward compat):
 *   qa_voice_say → qa_voice_announce
 *   qa_voice_ask → qa_voice_converse
 *
 * Session booking: lockfile at /tmp/voicelayer-session.lock prevents mic conflicts.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { appendFileSync, existsSync, writeFileSync, unlinkSync } from "fs";
import {
  speak,
  getHistoryEntry,
  playAudioNonBlocking,
  resolveVoice,
} from "./tts";
import { waitForInput, clearInput } from "./input";
import { getBackend } from "./stt";
import {
  bookVoiceSession,
  isVoiceBooked,
  clearStopSignal,
} from "./session-booking";
import {
  TTS_DISABLED_FILE,
  MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE,
} from "./paths";
import type { SilenceMode } from "./vad";

const THINK_FILE =
  process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";

/** Map converse silence_mode to SilenceMode. Default: thoughtful (2.5s for conversation). */
const DEFAULT_CONVERSE_SILENCE_MODE: SilenceMode = "thoughtful";

const server = new Server(
  {
    name: "voicelayer",
    version: "2.0.0",
  },
  {
    capabilities: { tools: {} },
    instructions:
      "Voice I/O layer for Claude Code. 2 tools:\n" +
      "- voice_speak(message): TTS. mode is auto-detected (announce=short update, brief=long explanation, consult=checkpoint question, think=silent log). Override with mode param.\n" +
      "- voice_ask(message): BLOCKING. Speaks question, records mic, returns transcription. Session booking prevents mic conflicts. Stop: touch /tmp/voicelayer-stop OR 5s silence.\n" +
      'Auto-mode detection: ends with ? → consult. length > 280 → brief. starts with "insight:" → think. default → announce.\n' +
      "voice_speak returns immediately (non-blocking). Audio plays in background via detached process.\n" +
      "replay=true on voice_ask speaks back last transcription before recording.\n" +
      "noise_floor param (default 0) filters low-confidence STT artifacts.\n" +
      "Voice is disabled by default; user enables via /mcp or toggle tool.\n" +
      "All qa_voice_* tool names still work (backward compat aliases).",
  },
);

// --- Tool definitions ---

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    // === NEW CONSOLIDATED TOOLS (Phase 4) ===

    // --- voice_speak: unified output tool ---
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
        "Stop playback: pkill afplay or skhd hotkey (ctrl+alt-s).\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS).",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description:
              "The message to speak or log (must be non-empty after trimming)",
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
        required: ["message"],
      },
    },
    // --- voice_ask: unified input tool ---
    {
      name: "voice_ask",
      description:
        "Speak a question aloud and wait for the user's voice response. BLOCKING.\n\n" +
        "Records mic audio, transcribes via Silero VAD + whisper.cpp/Wispr Flow.\n" +
        "User-controlled stop: touch /tmp/voicelayer-stop to end recording.\n" +
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
              "VAD silence threshold: 'quick' (0.5s), 'standard' (1.5s), 'thoughtful' (2.5s, default).",
            enum: ["quick", "standard", "thoughtful"],
            default: "thoughtful",
          },
        },
        required: ["message"],
      },
    },

    // === BACKWARD-COMPAT ALIASES (old tool names still work) ===

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
        },
        required: ["message"],
      },
    },
  ],
}));

// --- Tool handlers ---

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      // === Phase 4 consolidated tools ===
      case "voice_speak":
        return await handleVoiceSpeak(args);
      case "voice_ask":
        return await handleVoiceAsk(args);
      // === Backward-compat aliases ===
      case "qa_voice_announce":
        return await handleAnnounce(args);
      case "qa_voice_brief":
        return await handleBrief(args);
      case "qa_voice_consult":
        return await handleConsult(args);
      case "qa_voice_converse":
        return await handleConverse(args);
      case "qa_voice_think":
        return await handleThink(args);
      // New Phase 2 tools
      case "qa_voice_replay":
        return await handleReplay(args);
      case "qa_voice_toggle":
        return await handleToggle(args);
      // Aliases
      case "qa_voice_say":
        return await handleAnnounce(args);
      case "qa_voice_ask":
        return await handleConverse(args);
      default:
        return {
          content: [{ type: "text" as const, text: `Unknown tool: ${name}` }],
          isError: true,
        };
    }
  } catch (err: unknown) {
    return {
      content: [
        {
          type: "text" as const,
          text: `Error in ${name}: ${err instanceof Error ? err.message : String(err)}`,
        },
      ],
      isError: true,
    };
  }
});

// --- Arg validation helpers ---

interface TtsArgs {
  message: string;
  rate?: string;
  voice?: string;
}
interface ConverseArgs {
  message: string;
  timeout_seconds?: number;
  silence_mode?: SilenceMode;
}
interface ThinkArgs {
  thought: string;
  category: string;
}
interface ReplayArgs {
  index: number;
}
interface ToggleArgs {
  enabled: boolean;
  scope: "all" | "tts" | "mic";
}

const THINK_CATEGORIES = [
  "insight",
  "question",
  "red-flag",
  "checklist-update",
] as const;
const SILENCE_MODES: SilenceMode[] = ["quick", "standard", "thoughtful"];

function validateTtsArgs(args: unknown): TtsArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  const message = typeof a.message === "string" ? a.message.trim() : "";
  if (!message) return null;
  const rate = typeof a.rate === "string" ? a.rate : undefined;
  const voice = typeof a.voice === "string" ? a.voice : undefined;
  return { message, rate, voice };
}

function validateConverseArgs(args: unknown): ConverseArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  const message = typeof a.message === "string" ? a.message.trim() : "";
  if (!message) return null;
  const timeout_seconds =
    typeof a.timeout_seconds === "number" && isFinite(a.timeout_seconds)
      ? a.timeout_seconds
      : undefined;
  const rawMode =
    typeof a.silence_mode === "string" ? a.silence_mode : undefined;
  const silence_mode =
    rawMode && (SILENCE_MODES as string[]).includes(rawMode)
      ? (rawMode as SilenceMode)
      : undefined;
  return { message, timeout_seconds, silence_mode };
}

function validateThinkArgs(args: unknown): ThinkArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  const thought = typeof a.thought === "string" ? a.thought.trim() : "";
  if (!thought) return null;
  const raw = typeof a.category === "string" ? a.category : "insight";
  const category = (THINK_CATEGORIES as readonly string[]).includes(raw)
    ? raw
    : "insight";
  return { thought, category };
}

function validateReplayArgs(args: unknown): ReplayArgs {
  if (!args || typeof args !== "object") return { index: 0 };
  const a = args as Record<string, unknown>;
  const index =
    typeof a.index === "number" && isFinite(a.index)
      ? Math.max(0, Math.min(19, Math.floor(a.index)))
      : 0;
  return { index };
}

function validateToggleArgs(args: unknown): ToggleArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  if (typeof a.enabled !== "boolean") return null;
  const rawScope = typeof a.scope === "string" ? a.scope : "all";
  const scope = (["all", "tts", "mic"] as const).includes(
    rawScope as "all" | "tts" | "mic",
  )
    ? (rawScope as "all" | "tts" | "mic")
    : "all";
  return { enabled: a.enabled, scope };
}

// --- Auto-detection for voice_speak ---

const THINK_SIGNALS = [
  /^insight:/i,
  /^note:/i,
  /^TODO:/i,
  /^red.?flag:/i,
  /^question:/i,
];
const CONSULT_SIGNALS = [
  /\?$/,
  /\babout to\b/i,
  /\bshould I\b/i,
  /\bready to\b/i,
  /\bbefore I\b/i,
];

function detectMode(
  message: string,
): "announce" | "brief" | "consult" | "think" {
  if (THINK_SIGNALS.some((r) => r.test(message.trim()))) return "think";
  if (CONSULT_SIGNALS.some((r) => r.test(message.trim()))) return "consult";
  if (message.length > 280) return "brief";
  return "announce";
}

// --- Unified handlers for Phase 4 tools ---

async function handleVoiceSpeak(args: unknown) {
  if (!args || typeof args !== "object") {
    return {
      content: [{ type: "text" as const, text: "Missing arguments" }],
      isError: true,
    };
  }
  const a = args as Record<string, unknown>;

  // Toggle mode — enabled param present
  if (typeof a.enabled === "boolean") {
    return handleToggle({ enabled: a.enabled, scope: a.scope ?? "all" });
  }

  // Replay mode — replay_index present
  if (typeof a.replay_index === "number") {
    return handleReplay({ index: a.replay_index });
  }

  // Speech/think mode
  const message = typeof a.message === "string" ? a.message.trim() : "";
  if (!message) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing or empty required parameter: message",
        },
      ],
      isError: true,
    };
  }

  const requestedMode = typeof a.mode === "string" ? a.mode : "auto";
  const mode = requestedMode === "auto" ? detectMode(message) : requestedMode;
  const rate = typeof a.rate === "string" ? a.rate : undefined;

  const voice = typeof a.voice === "string" ? a.voice : undefined;

  switch (mode) {
    case "think": {
      const category = typeof a.category === "string" ? a.category : "insight";
      return handleThink({ thought: message, category });
    }
    case "announce":
      return handleAnnounce({ message, rate, voice });
    case "brief":
      return handleBrief({ message, rate, voice });
    case "consult":
      return handleConsult({ message, rate, voice });
    default:
      return handleAnnounce({ message, rate, voice });
  }
}

async function handleVoiceAsk(args: unknown) {
  if (!args || typeof args !== "object") {
    return {
      content: [{ type: "text" as const, text: "Missing arguments" }],
      isError: true,
    };
  }
  const a = args as Record<string, unknown>;
  return handleConverse({
    message: a.message,
    timeout_seconds: a.timeout_seconds,
    silence_mode: a.silence_mode,
  });
}

// --- Mode Handlers ---

async function handleAnnounce(args: unknown) {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing or empty required parameter: message",
        },
      ],
      isError: true,
    };
  }

  const { warning } = await speak(validated.message, {
    mode: "announce",
    rate: validated.rate,
    voice: validated.voice,
  });
  const text =
    `[announce] Spoke: "${validated.message}"` +
    (warning ? `\nWarning: ${warning}` : "");

  return { content: [{ type: "text" as const, text }] };
}

async function handleBrief(args: unknown) {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing or empty required parameter: message",
        },
      ],
      isError: true,
    };
  }

  const { warning } = await speak(validated.message, {
    mode: "brief",
    rate: validated.rate,
    voice: validated.voice,
  });
  const text =
    `[brief] Explained: "${validated.message}"` +
    (warning ? `\nWarning: ${warning}` : "");

  return { content: [{ type: "text" as const, text }] };
}

async function handleConsult(args: unknown) {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing or empty required parameter: message",
        },
      ],
      isError: true,
    };
  }

  const { warning } = await speak(validated.message, {
    mode: "consult",
    rate: validated.rate,
    voice: validated.voice,
  });
  const text =
    `[consult] Spoke: "${validated.message}"\n` +
    "User may want to respond. Use voice_ask to collect voice input if needed." +
    (warning ? `\nWarning: ${warning}` : "");

  return { content: [{ type: "text" as const, text }] };
}

async function handleConverse(args: unknown) {
  const validated = validateConverseArgs(args);
  if (!validated) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing or empty required parameter: message",
        },
      ],
      isError: true,
    };
  }

  const timeoutSeconds = Math.min(
    Math.max(validated.timeout_seconds ?? 300, 10),
    3600,
  );

  const silenceMode = validated.silence_mode ?? DEFAULT_CONVERSE_SILENCE_MODE;

  // Session booking — auto-book if not already booked
  const booking = isVoiceBooked();
  if (booking.booked && !booking.ownedByUs) {
    return {
      content: [
        {
          type: "text" as const,
          text:
            `[converse] Line is busy — voice session owned by ${booking.owner?.sessionId} ` +
            `(PID ${booking.owner?.pid}) since ${booking.owner?.startedAt}. ` +
            "Fall back to text input, or wait for the other session to finish.",
        },
      ],
      isError: true,
    };
  }

  if (!booking.booked) {
    const result = bookVoiceSession();
    if (!result.success) {
      return {
        content: [
          { type: "text" as const, text: `[converse] ${result.error}` },
        ],
        isError: true,
      };
    }
  }

  clearInput();
  clearStopSignal();

  // Speak the question aloud — BLOCKING for converse (need to finish before recording)
  // Converse accepts voice from the wrapping voice_ask handler
  const voiceName = (args as Record<string, unknown>)?.voice;
  await speak(validated.message, {
    mode: "converse",
    waitForPlayback: true,
    voice: typeof voiceName === "string" ? voiceName : undefined,
  });

  // Record mic audio, then transcribe with selected STT backend
  // Uses Silero VAD with configurable silence mode
  const response = await waitForInput(timeoutSeconds * 1000, silenceMode);

  if (response === null) {
    return {
      content: [
        {
          type: "text" as const,
          text: `[converse] No response received within ${timeoutSeconds} seconds. The user may have stepped away.`,
        },
      ],
    };
  }

  return {
    content: [{ type: "text" as const, text: response }],
  };
}

async function handleThink(args: unknown) {
  const validated = validateThinkArgs(args);
  if (!validated) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing or empty required parameter: thought",
        },
      ],
      isError: true,
    };
  }

  const { thought, category } = validated;

  const timestamp = new Date().toLocaleTimeString("en-US", {
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  });

  const icons: Record<string, string> = {
    insight: "\u{1F4A1}",
    question: "\u{2753}",
    "red-flag": "\u{1F6A9}",
    "checklist-update": "\u{2705}",
  };

  const icon = icons[category] || "\u{1F4DD}";
  const line = `- [${timestamp}] ${icon} ${thought}\n`;

  // Append to thinking file
  if (!existsSync(THINK_FILE)) {
    writeFileSync(THINK_FILE, `# Live Thinking Log\n\n`);
  }
  appendFileSync(THINK_FILE, line);

  return {
    content: [
      { type: "text" as const, text: `Noted (${category}): ${thought}` },
    ],
  };
}

async function handleReplay(args: unknown) {
  const { index } = validateReplayArgs(args);

  const entry = getHistoryEntry(index);
  if (!entry) {
    return {
      content: [
        {
          type: "text" as const,
          text:
            index === 0
              ? "[replay] No audio in history buffer. Speak something first."
              : `[replay] No audio at index ${index}. Buffer may have fewer entries.`,
        },
      ],
      isError: true,
    };
  }

  if (!existsSync(entry.file)) {
    return {
      content: [
        {
          type: "text" as const,
          text: `[replay] Audio file missing: ${entry.file}. It may have been cleaned up.`,
        },
      ],
      isError: true,
    };
  }

  // Play audio non-blocking
  playAudioNonBlocking(entry.file);

  return {
    content: [
      {
        type: "text" as const,
        text: `[replay] Playing (index ${index}): "${entry.text}"`,
      },
    ],
  };
}

async function handleToggle(args: unknown) {
  const validated = validateToggleArgs(args);
  if (!validated) {
    return {
      content: [
        {
          type: "text" as const,
          text: "Missing required parameter: enabled (boolean)",
        },
      ],
      isError: true,
    };
  }

  const { enabled, scope } = validated;
  const actions: string[] = [];

  if (scope === "all" || scope === "tts") {
    if (enabled) {
      if (existsSync(TTS_DISABLED_FILE)) {
        try {
          unlinkSync(TTS_DISABLED_FILE);
        } catch {}
      }
      actions.push("TTS enabled");
    } else {
      writeFileSync(
        TTS_DISABLED_FILE,
        `disabled at ${new Date().toISOString()}`,
      );
      actions.push("TTS disabled");
    }
  }

  if (scope === "all" || scope === "mic") {
    if (enabled) {
      if (existsSync(MIC_DISABLED_FILE)) {
        try {
          unlinkSync(MIC_DISABLED_FILE);
        } catch {}
      }
      actions.push("mic enabled");
    } else {
      writeFileSync(
        MIC_DISABLED_FILE,
        `disabled at ${new Date().toISOString()}`,
      );
      actions.push("mic disabled");
    }
  }

  // Manage combined flag — used by CC PreToolUse hook to block all voice tools
  if (scope === "all") {
    if (enabled) {
      if (existsSync(VOICE_DISABLED_FILE)) {
        try {
          unlinkSync(VOICE_DISABLED_FILE);
        } catch {}
      }
    } else {
      writeFileSync(
        VOICE_DISABLED_FILE,
        `disabled at ${new Date().toISOString()}`,
      );
    }
  }

  return {
    content: [
      {
        type: "text" as const,
        text: `[toggle] ${actions.join(", ")}`,
      },
    ],
  };
}

// --- Start server ---

async function main() {
  // Detect STT backend early so we log it on startup (getBackend logs details)
  try {
    await getBackend();
  } catch (err: unknown) {
    console.error(
      `[voicelayer] Warning: no STT backend available — converse mode will fail`,
    );
    console.error(
      `[voicelayer]   ${err instanceof Error ? err.message : String(err)}`,
    );
  }

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(
    "[voicelayer] MCP server v2.0 running — modes: announce, brief, consult, converse, replay, toggle",
  );
}

main().catch((err) => {
  console.error("[voicelayer] Fatal:", err);
  process.exit(1);
});
