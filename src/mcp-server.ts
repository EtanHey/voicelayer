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
import { speak, getHistoryEntry, playAudioNonBlocking } from "./tts";
import { waitForInput, clearInput } from "./input";
import { getBackend } from "./stt";
import {
  bookVoiceSession,
  isVoiceBooked,
  clearStopSignal,
} from "./session-booking";
import { TTS_DISABLED_FILE, MIC_DISABLED_FILE } from "./paths";
import type { SilenceMode } from "./vad";

const THINK_FILE = process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";

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
      "VoiceLayer provides voice I/O for AI coding assistants via 5 modes:\n" +
      "- announce: fire-and-forget TTS (status updates) — NON-BLOCKING\n" +
      "- brief: one-way TTS explanation (summaries, decisions) — NON-BLOCKING\n" +
      "- consult: speak a checkpoint, user MAY respond — NON-BLOCKING\n" +
      "- converse: speak + record + transcribe (BLOCKING, requires mic)\n" +
      "- think: silent markdown log (no audio)\n" +
      "- replay: replay a recently spoken message\n" +
      "- toggle: enable/disable TTS and/or mic\n\n" +
      "Stop TTS: skhd hotkey (ctrl+alt-s) or `pkill afplay`.\n" +
      "Stop recording: touch /tmp/voicelayer-stop to end recording.\n" +
      "Session booking: converse mode auto-books the mic; other sessions see 'line busy'.\n" +
      "VAD: Silero VAD neural network — detects real speech, ignores background noise.\n" +
      "Prerequisites: python3 + edge-tts (TTS), sox (recording), whisper.cpp or Wispr Flow (STT).",
  }
);

// --- Tool definitions ---

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    // --- Voice Mode: Announce ---
    {
      name: "qa_voice_announce",
      description:
        "Speak a message aloud via TTS without waiting for a response. " +
        "NON-BLOCKING — returns instantly, audio plays in background. " +
        "Use for status updates, narration, task completion alerts. " +
        "Does NOT require voice session booking. " +
        "Stop playback: pkill afplay or skhd hotkey (ctrl+alt-s)\n\n" +
        "Returns: text confirmation of what was spoken.\n" +
        "Errors: edge-tts not installed (pip3 install edge-tts), audio player missing, empty message.\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS).",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The message to speak aloud (must be non-empty after trimming)",
          },
          rate: {
            type: "string",
            description: "Speech rate as percent string (e.g. '-10%', '+5%'). Default: +10% for announce. Auto-slows for long text.",
            pattern: "^[+-]\\d+%$",
            default: "+10%",
          },
        },
        required: ["message"],
      },
    },
    // --- Voice Mode: Brief ---
    {
      name: "qa_voice_brief",
      description:
        "Speak a one-way explanation aloud via TTS. No response expected. " +
        "NON-BLOCKING — returns instantly, audio plays in background. " +
        "Use for reading back decisions, summarizing findings, explaining plans. " +
        "Speaks SLOWER than announce (auto-adjusted for text length). " +
        "Stop playback: pkill afplay or skhd hotkey (ctrl+alt-s)\n\n" +
        "Returns: text confirmation of what was spoken.\n" +
        "Errors: same as announce (edge-tts, audio player).\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS).",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The explanation or summary to speak aloud (must be non-empty after trimming)",
          },
          rate: {
            type: "string",
            description: "Speech rate as percent string (e.g. '-15%', '+0%'). Default: -10% for brief. Auto-slows further for long text.",
            pattern: "^[+-]\\d+%$",
            default: "-10%",
          },
        },
        required: ["message"],
      },
    },
    // --- Voice Mode: Consult ---
    {
      name: "qa_voice_consult",
      description:
        "Speak a checkpoint message — the user MAY want to respond. Non-blocking. " +
        "Use for preemptive checkpoints: 'about to commit, want to review?' " +
        "Returns immediately. If user input is needed, follow up with qa_voice_converse. " +
        "Stop playback: pkill afplay or skhd hotkey (ctrl+alt-s)\n\n" +
        "Returns: confirmation text; does not collect voice input.\n" +
        "Errors: same as announce (edge-tts, audio player).\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS).",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The checkpoint question or status to speak (must be non-empty after trimming)",
          },
          rate: {
            type: "string",
            description: "Speech rate as percent string (e.g. '-5%', '+10%'). Default: +5% for consult.",
            pattern: "^[+-]\\d+%$",
            default: "+5%",
          },
        },
        required: ["message"],
      },
    },
    // --- Voice Mode: Converse ---
    {
      name: "qa_voice_converse",
      description:
        "Speak a question aloud and wait for the user's voice response. BLOCKING. " +
        "Records mic audio, transcribes via STT, returns transcription text. " +
        "User-controlled stop: touch /tmp/voicelayer-stop to end recording. " +
        "Silero VAD silence detection with configurable mode (quick/standard/thoughtful). " +
        "Requires voice session booking — other sessions see 'line busy' (isError: true). " +
        "Use for interactive Q&A, drilling sessions, interviews.\n\n" +
        "Returns: on success, the user's transcribed text (plain string). " +
        "On timeout/no speech: status message '[converse] No response received...' " +
        "On busy: error with isError: true.\n" +
        "Errors: line busy (another session has mic), sox not installed, mic permission denied, " +
        "no STT backend (install whisper-cpp or set QA_VOICE_WISPR_KEY).\n" +
        "Prerequisites: sox (recording), whisper.cpp or Wispr Flow (STT), python3 + edge-tts (TTS).",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The question or prompt to speak aloud (must be non-empty after trimming)",
          },
          timeout_seconds: {
            type: "number",
            description: "How long to wait for a response in seconds. Clamped to 10-3600. Default: 300.",
            default: 300,
            minimum: 10,
            maximum: 3600,
          },
          silence_mode: {
            type: "string",
            description: "How long to wait after speech stops: 'quick' (0.5s), 'standard' (1.5s), 'thoughtful' (2.5s, default for converse).",
            enum: ["quick", "standard", "thoughtful"],
            default: "thoughtful",
          },
        },
        required: ["message"],
      },
    },
    // --- Silent: Think ---
    {
      name: "qa_voice_think",
      description:
        "Append a thought or insight to the live thinking log (markdown file). " +
        "Use during discovery calls to silently take notes the user can glance at. " +
        "Does NOT speak — writes to a file that can be open in a split screen. " +
        `Writes to QA_VOICE_THINK_FILE (default: /tmp/voicelayer-thinking.md).\n\n` +
        "Returns: confirmation text with the noted thought.\n" +
        "Errors: file write failure (rare).",
      inputSchema: {
        type: "object" as const,
        properties: {
          thought: {
            type: "string",
            description: "The insight, suggestion, or note to append",
          },
          category: {
            type: "string",
            description: "Category: insight, question, red-flag, checklist-update. Defaults to insight.",
            enum: ["insight", "question", "red-flag", "checklist-update"],
            default: "insight",
          },
        },
        required: ["thought"],
      },
    },
    // --- Replay ---
    {
      name: "qa_voice_replay",
      description:
        "Replay a recently spoken message from the ring buffer. " +
        "NON-BLOCKING — returns instantly, audio plays in background. " +
        "The ring buffer holds the last 20 spoken messages. " +
        "Index 0 = most recent, 1 = second-most-recent, etc.\n\n" +
        "Returns: text of what was replayed, or error if index out of range.\n" +
        "Stop playback: pkill afplay or skhd hotkey (ctrl+alt-s).",
      inputSchema: {
        type: "object" as const,
        properties: {
          index: {
            type: "number",
            description: "Recency index: 0 = most recent (default), 1 = second-most-recent, etc. Max 19.",
            default: 0,
            minimum: 0,
            maximum: 19,
          },
        },
      },
    },
    // --- Toggle Voice ---
    {
      name: "qa_voice_toggle",
      description:
        "Enable or disable voice output and/or mic input via flag files. " +
        "When disabled, TTS calls return silently and mic recording returns null. " +
        "Use to mute during meetings, quiet hours, or when audio isn't wanted.\n\n" +
        "Scope:\n" +
        "- 'all': disables both TTS and mic (default)\n" +
        "- 'tts': disables speech output only\n" +
        "- 'mic': disables microphone recording only\n\n" +
        "Returns: confirmation of new state.",
      inputSchema: {
        type: "object" as const,
        properties: {
          enabled: {
            type: "boolean",
            description: "true = enable voice, false = disable voice",
          },
          scope: {
            type: "string",
            description: "What to toggle: 'all' (default), 'tts', or 'mic'.",
            enum: ["all", "tts", "mic"],
            default: "all",
          },
        },
        required: ["enabled"],
      },
    },
    // --- Aliases (backward compat) ---
    {
      name: "qa_voice_say",
      description:
        "Backward-compat alias for qa_voice_announce. Prefer qa_voice_announce for new code. " +
        "Same contract: NON-BLOCKING fire-and-forget TTS, no response. " +
        "Stop playback: pkill afplay or skhd hotkey (ctrl+alt-s).",
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
      description:
        "Backward-compat alias for qa_voice_converse. Prefer qa_voice_converse for new code. " +
        "Same contract: BLOCKING voice Q&A with session booking, user-controlled stop, " +
        "Silero VAD silence detection, returns transcription on success or status/error on failure.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The question or message to speak aloud",
          },
          timeout_seconds: {
            type: "number",
            description: "How long to wait for a response in seconds. Clamped to 10-3600. Default: 300.",
            default: 300,
            minimum: 10,
            maximum: 3600,
          },
          silence_mode: {
            type: "string",
            description: "How long to wait after speech stops: 'quick' (0.5s), 'standard' (1.5s), 'thoughtful' (2.5s, default).",
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
      // Core modes
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

interface TtsArgs { message: string; rate?: string }
interface ConverseArgs { message: string; timeout_seconds?: number; silence_mode?: SilenceMode }
interface ThinkArgs { thought: string; category: string }
interface ReplayArgs { index: number }
interface ToggleArgs { enabled: boolean; scope: "all" | "tts" | "mic" }

const THINK_CATEGORIES = ["insight", "question", "red-flag", "checklist-update"] as const;
const SILENCE_MODES: SilenceMode[] = ["quick", "standard", "thoughtful"];

function validateTtsArgs(args: unknown): TtsArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  const message = typeof a.message === "string" ? a.message.trim() : "";
  if (!message) return null;
  const rate = typeof a.rate === "string" ? a.rate : undefined;
  return { message, rate };
}

function validateConverseArgs(args: unknown): ConverseArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  const message = typeof a.message === "string" ? a.message.trim() : "";
  if (!message) return null;
  const timeout_seconds = typeof a.timeout_seconds === "number" && isFinite(a.timeout_seconds)
    ? a.timeout_seconds
    : undefined;
  const rawMode = typeof a.silence_mode === "string" ? a.silence_mode : undefined;
  const silence_mode = rawMode && (SILENCE_MODES as string[]).includes(rawMode)
    ? rawMode as SilenceMode
    : undefined;
  return { message, timeout_seconds, silence_mode };
}

function validateThinkArgs(args: unknown): ThinkArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  const thought = typeof a.thought === "string" ? a.thought.trim() : "";
  if (!thought) return null;
  const raw = typeof a.category === "string" ? a.category : "insight";
  const category = (THINK_CATEGORIES as readonly string[]).includes(raw) ? raw : "insight";
  return { thought, category };
}

function validateReplayArgs(args: unknown): ReplayArgs {
  if (!args || typeof args !== "object") return { index: 0 };
  const a = args as Record<string, unknown>;
  const index = typeof a.index === "number" && isFinite(a.index)
    ? Math.max(0, Math.min(19, Math.floor(a.index)))
    : 0;
  return { index };
}

function validateToggleArgs(args: unknown): ToggleArgs | null {
  if (!args || typeof args !== "object") return null;
  const a = args as Record<string, unknown>;
  if (typeof a.enabled !== "boolean") return null;
  const rawScope = typeof a.scope === "string" ? a.scope : "all";
  const scope = (["all", "tts", "mic"] as const).includes(rawScope as "all" | "tts" | "mic")
    ? rawScope as "all" | "tts" | "mic"
    : "all";
  return { enabled: a.enabled, scope };
}

// --- Mode Handlers ---

async function handleAnnounce(args: unknown) {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return {
      content: [{ type: "text" as const, text: "Missing or empty required parameter: message" }],
      isError: true,
    };
  }

  await speak(validated.message, { mode: "announce", rate: validated.rate });

  return {
    content: [{ type: "text" as const, text: `[announce] Spoke: "${validated.message}"` }],
  };
}

async function handleBrief(args: unknown) {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return {
      content: [{ type: "text" as const, text: "Missing or empty required parameter: message" }],
      isError: true,
    };
  }

  await speak(validated.message, { mode: "brief", rate: validated.rate });

  return {
    content: [{ type: "text" as const, text: `[brief] Explained: "${validated.message}"` }],
  };
}

async function handleConsult(args: unknown) {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return {
      content: [{ type: "text" as const, text: "Missing or empty required parameter: message" }],
      isError: true,
    };
  }

  await speak(validated.message, { mode: "consult", rate: validated.rate });

  return {
    content: [
      {
        type: "text" as const,
        text:
          `[consult] Spoke: "${validated.message}"\n` +
          "User may want to respond. Use qa_voice_converse to collect voice input if needed.",
      },
    ],
  };
}

async function handleConverse(args: unknown) {
  const validated = validateConverseArgs(args);
  if (!validated) {
    return {
      content: [{ type: "text" as const, text: "Missing or empty required parameter: message" }],
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
  await speak(validated.message, { mode: "converse", waitForPlayback: true });

  // Record mic audio, then transcribe with selected STT backend
  // Uses Silero VAD with configurable silence mode
  const response = await waitForInput(
    timeoutSeconds * 1000,
    silenceMode,
  );

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
      content: [{ type: "text" as const, text: "Missing or empty required parameter: thought" }],
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
    content: [{ type: "text" as const, text: `Noted (${category}): ${thought}` }],
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
          text: index === 0
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
      content: [{ type: "text" as const, text: "Missing required parameter: enabled (boolean)" }],
      isError: true,
    };
  }

  const { enabled, scope } = validated;
  const actions: string[] = [];

  if (scope === "all" || scope === "tts") {
    if (enabled) {
      // Remove disable flag → enable TTS
      if (existsSync(TTS_DISABLED_FILE)) {
        try { unlinkSync(TTS_DISABLED_FILE); } catch {}
      }
      actions.push("TTS enabled");
    } else {
      // Create disable flag → disable TTS
      writeFileSync(TTS_DISABLED_FILE, `disabled at ${new Date().toISOString()}`);
      actions.push("TTS disabled");
    }
  }

  if (scope === "all" || scope === "mic") {
    if (enabled) {
      // Remove disable flag → enable mic
      if (existsSync(MIC_DISABLED_FILE)) {
        try { unlinkSync(MIC_DISABLED_FILE); } catch {}
      }
      actions.push("mic enabled");
    } else {
      // Create disable flag → disable mic
      writeFileSync(MIC_DISABLED_FILE, `disabled at ${new Date().toISOString()}`);
      actions.push("mic disabled");
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
    console.error(`[voicelayer] Warning: no STT backend available — converse mode will fail`);
    console.error(`[voicelayer]   ${err instanceof Error ? err.message : String(err)}`);
  }

  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("[voicelayer] MCP server v2.0 running — modes: announce, brief, consult, converse, replay, toggle");
}

main().catch((err) => {
  console.error("[voicelayer] Fatal:", err);
  process.exit(1);
});
