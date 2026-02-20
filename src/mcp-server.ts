/**
 * VoiceLayer MCP Server — 4 voice modes + silent think tool.
 *
 * Modes:
 *   announce  — fire-and-forget TTS (status updates, narration)
 *   brief     — one-way explanation via TTS (reading back decisions, summaries)
 *   consult   — speak + signal that user may respond (non-blocking checkpoint)
 *   converse  — bidirectional voice Q&A with user-controlled stop (blocking)
 *   think     — silent markdown log (no voice)
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
import { appendFileSync, existsSync, writeFileSync } from "fs";
import { speak } from "./tts";
import { waitForInput, clearInput } from "./input";
import { getBackend } from "./stt";
import {
  bookVoiceSession,
  isVoiceBooked,
  clearStopSignal,
} from "./session-booking";
import { STOP_FILE } from "./paths";

const THINK_FILE = process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";
const CONVERSE_SILENCE_SECONDS = 5; // longer silence for converse mode (user pauses to think)

const server = new Server(
  {
    name: "voicelayer",
    version: "1.0.0",
  },
  {
    capabilities: { tools: {} },
    instructions:
      "VoiceLayer provides voice I/O for AI coding assistants via 5 modes:\n" +
      "- announce: fire-and-forget TTS (status updates)\n" +
      "- brief: one-way TTS explanation (summaries, decisions)\n" +
      "- consult: speak a checkpoint, user MAY respond (non-blocking)\n" +
      "- converse: speak + record + transcribe (BLOCKING, requires mic)\n" +
      "- think: silent markdown log (no audio)\n\n" +
      "Stop signal: touch /tmp/voicelayer-stop to end playback or recording.\n" +
      "Session booking: converse mode auto-books the mic; other sessions see 'line busy'.\n" +
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
        "Fire-and-forget — use for status updates, narration, task completion alerts. " +
        "Does NOT require voice session booking. " +
        "User can stop playback: touch /tmp/voicelayer-stop\n\n" +
        "Returns: text confirmation of what was spoken.\n" +
        "Errors: edge-tts not installed (pip3 install edge-tts), audio player missing, empty message.\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS, aplay on Linux).",
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
        "Use for reading back decisions, summarizing findings, explaining plans. " +
        "Longer content than announce — Claude explains, user listens. " +
        "Speaks SLOWER than announce (auto-adjusted for text length). " +
        "User can stop playback: touch /tmp/voicelayer-stop\n\n" +
        "Returns: text confirmation of what was spoken.\n" +
        "Errors: same as announce (edge-tts, audio player).\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS, aplay on Linux).",
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
        "User can stop playback: touch /tmp/voicelayer-stop\n\n" +
        "Returns: confirmation text; does not collect voice input.\n" +
        "Errors: same as announce (edge-tts, audio player).\n" +
        "Prerequisites: python3 + edge-tts, audio player (afplay on macOS, aplay on Linux).",
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
        "Silence detection (5s) is fallback only. " +
        "Requires voice session booking — other sessions see 'line busy' (isError: true). " +
        "Use for interactive Q&A, drilling sessions, interviews.\n\n" +
        "Returns: on success, the user's transcribed text (plain string). " +
        "On timeout/no speech: status message '[converse] No response received...' " +
        "On busy: error with isError: true.\n" +
        "Errors: line busy (another session has mic), sox not installed, mic permission denied, " +
        "no STT backend (install whisper-cpp or set QA_VOICE_WISPR_KEY).\n" +
        "Prerequisites: sox (recording), whisper.cpp or Wispr Flow (STT), python3 + edge-tts (TTS). " +
        "STT may be local (whisper.cpp) or cloud (Wispr Flow) depending on config; " +
        "avoid cloud mode for sensitive audio.",
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
    // --- Aliases (backward compat) ---
    {
      name: "qa_voice_say",
      description:
        "Backward-compat alias for qa_voice_announce. Prefer qa_voice_announce for new code. " +
        "Same contract: fire-and-forget TTS, no response. " +
        "Stop playback: touch /tmp/voicelayer-stop.",
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
        "returns transcription on success or status/error on failure.",
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
      // New 4 modes
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
interface ConverseArgs { message: string; timeout_seconds?: number }
interface ThinkArgs { thought: string; category?: string }

const THINK_CATEGORIES = ["insight", "question", "red-flag", "checklist-update"] as const;
type ThinkCategory = typeof THINK_CATEGORIES[number];

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
  return { message, timeout_seconds };
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

  // Speak the question aloud
  await speak(validated.message, { mode: "converse" });

  // Record mic audio, then transcribe with selected STT backend
  // Uses longer silence threshold (5s) — user may pause to think
  const response = await waitForInput(
    timeoutSeconds * 1000,
    CONVERSE_SILENCE_SECONDS,
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
  console.error("[voicelayer] MCP server v1.0 running — 4 modes: announce, brief, consult, converse");
}

main().catch((err) => {
  console.error("[voicelayer] Fatal:", err);
  process.exit(1);
});
