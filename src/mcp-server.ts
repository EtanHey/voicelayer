/**
 * QA Voice MCP Server — 4 voice modes + silent think tool.
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
  releaseVoiceSession,
  isVoiceBooked,
  clearStopSignal,
} from "./session-booking";

const THINK_FILE = process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";
const DEFAULT_TIMEOUT_MS = 300_000; // 5 minutes
const CONVERSE_SILENCE_SECONDS = 5; // longer silence for converse mode (user pauses to think)

const server = new Server(
  { name: "voicelayer", version: "1.0.0" },
  { capabilities: { tools: {} } }
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
        "User can stop playback: touch /tmp/voicelayer-stop",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The message to speak aloud",
          },
          rate: {
            type: "string",
            description: "Speech rate override (e.g. '-10%', '+5%'). Default: +10% for announce. Auto-slows for long text.",
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
        "User can stop playback: touch /tmp/voicelayer-stop",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The explanation or summary to speak aloud",
          },
          rate: {
            type: "string",
            description: "Speech rate override (e.g. '-15%', '+0%'). Default: -10% for brief. Auto-slows further for long text.",
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
        "User can stop playback: touch /tmp/voicelayer-stop",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The checkpoint question or status to speak",
          },
          rate: {
            type: "string",
            description: "Speech rate override (e.g. '-5%', '+10%'). Default: +5% for consult.",
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
        "Records mic audio, streams to STT, returns transcription. " +
        "User-controlled stop: touch /tmp/voicelayer-stop to end recording. " +
        "Silence detection (5s) is fallback only. " +
        "Requires voice session booking — other sessions see 'line busy'. " +
        "Use for interactive Q&A, drilling sessions, interviews.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The question or prompt to speak aloud",
          },
          timeout_seconds: {
            type: "number",
            description: "How long to wait for a response (default: 300 seconds)",
            default: 300,
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
        "Does NOT speak — writes to a file that can be open in a split screen.",
      inputSchema: {
        type: "object" as const,
        properties: {
          thought: {
            type: "string",
            description: "The insight, suggestion, or note to append",
          },
          category: {
            type: "string",
            description: "Category: insight, question, red-flag, checklist-update",
            enum: ["insight", "question", "red-flag", "checklist-update"],
          },
        },
        required: ["thought"],
      },
    },
    // --- Aliases (backward compat) ---
    {
      name: "qa_voice_say",
      description:
        "ALIAS for qa_voice_announce. Speak a message aloud without waiting for a response.",
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
        "ALIAS for qa_voice_converse. Speak a question and wait for voice response.",
      inputSchema: {
        type: "object" as const,
        properties: {
          message: {
            type: "string",
            description: "The question or message to speak aloud",
          },
          timeout_seconds: {
            type: "number",
            description: "How long to wait for a response (default: 300 seconds)",
            default: 300,
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

// --- Mode Handlers ---

async function handleAnnounce(args: any) {
  const message = args?.message;
  if (!message) {
    return {
      content: [{ type: "text" as const, text: "Missing required: message" }],
      isError: true,
    };
  }

  await speak(message, { mode: "announce", rate: args?.rate });

  return {
    content: [{ type: "text" as const, text: `[announce] Spoke: "${message}"` }],
  };
}

async function handleBrief(args: any) {
  const message = args?.message;
  if (!message) {
    return {
      content: [{ type: "text" as const, text: "Missing required: message" }],
      isError: true,
    };
  }

  await speak(message, { mode: "brief", rate: args?.rate });

  return {
    content: [{ type: "text" as const, text: `[brief] Explained: "${message}"` }],
  };
}

async function handleConsult(args: any) {
  const message = args?.message;
  if (!message) {
    return {
      content: [{ type: "text" as const, text: "Missing required: message" }],
      isError: true,
    };
  }

  await speak(message, { mode: "consult", rate: args?.rate });

  return {
    content: [
      {
        type: "text" as const,
        text:
          `[consult] Spoke: "${message}"\n` +
          "User may want to respond. Use qa_voice_converse to collect voice input if needed.",
      },
    ],
  };
}

async function handleConverse(args: any) {
  const message = args?.message;
  const timeoutSeconds = Math.min(
    Math.max(Number(args?.timeout_seconds) || 300, 10),
    3600,
  );

  if (!message) {
    return {
      content: [{ type: "text" as const, text: "Missing required: message" }],
      isError: true,
    };
  }

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
  await speak(message, { mode: "converse" });

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

async function handleThink(args: any) {
  const thought = args?.thought;
  const category = args?.category || "insight";

  if (!thought) {
    return {
      content: [{ type: "text" as const, text: "Missing required: thought" }],
      isError: true,
    };
  }

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
