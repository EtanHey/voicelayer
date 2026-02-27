/**
 * MCP tool handler functions for VoiceLayer.
 *
 * Each handler validates input via Zod schemas and returns MCP tool results.
 * Separated from mcp-server.ts for maintainability and testability.
 */

import { appendFileSync, existsSync, writeFileSync, unlinkSync } from "fs";
import {
  speak,
  getHistoryEntry,
  playAudioNonBlocking,
  awaitCurrentPlayback,
} from "./tts";
import { waitForInput, clearInput } from "./input";
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
import { ensureVoiceBarRunning } from "./voice-bar-launcher";
import {
  AnnounceArgsSchema,
  ConverseArgsSchema,
  ThinkArgsSchema,
  ReplayArgsSchema,
  ToggleArgsSchema,
  type AnnounceArgs,
  type ConverseArgs,
  type ThinkArgs,
  type ReplayArgs,
  type ToggleArgs,
} from "./schemas/mcp-inputs";

// --- MCP result helper ---

type McpResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

function textResult(text: string, isError = false): McpResult {
  return {
    content: [{ type: "text" as const, text }],
    ...(isError && { isError }),
  };
}

// --- Config ---

const THINK_FILE =
  process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";

const DEFAULT_CONVERSE_SILENCE_MODE: SilenceMode = "thoughtful";

// --- Validation wrappers ---

function validateTtsArgs(args: unknown): AnnounceArgs | null {
  const result = AnnounceArgsSchema.safeParse(args);
  return result.success ? result.data : null;
}

function validateConverseArgs(args: unknown): ConverseArgs | null {
  const result = ConverseArgsSchema.safeParse(args);
  return result.success ? result.data : null;
}

function validateThinkArgs(args: unknown): ThinkArgs | null {
  const result = ThinkArgsSchema.safeParse(args);
  return result.success ? result.data : null;
}

function validateReplayArgs(args: unknown): ReplayArgs {
  const result = ReplayArgsSchema.safeParse(args);
  return result.success ? result.data : { index: 0 };
}

function validateToggleArgs(args: unknown): ToggleArgs | null {
  const result = ToggleArgsSchema.safeParse(args);
  return result.success ? result.data : null;
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

// --- Unified handlers ---

export async function handleVoiceSpeak(args: unknown): Promise<McpResult> {
  if (!args || typeof args !== "object") {
    return textResult("Missing arguments", true);
  }
  const a = args as Record<string, unknown>;

  // Auto-launch Voice Bar on first voice_speak call (no-op after first attempt)
  ensureVoiceBarRunning();

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
    return textResult("Missing or empty required parameter: message", true);
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

export async function handleVoiceAsk(args: unknown): Promise<McpResult> {
  if (!args || typeof args !== "object") {
    return textResult("Missing arguments", true);
  }
  const a = args as Record<string, unknown>;
  return handleConverse({
    message: a.message,
    timeout_seconds: a.timeout_seconds,
    silence_mode: a.silence_mode,
    press_to_talk: a.press_to_talk,
  });
}

// --- Mode Handlers ---

export async function handleAnnounce(args: unknown): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning } = await speak(validated.message, {
    mode: "announce",
    rate: validated.rate,
    voice: validated.voice,
  });
  const text =
    `[announce] Spoke: "${validated.message}"` +
    (warning ? `\nWarning: ${warning}` : "");

  return textResult(text);
}

export async function handleBrief(args: unknown): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning } = await speak(validated.message, {
    mode: "brief",
    rate: validated.rate,
    voice: validated.voice,
  });
  const text =
    `[brief] Explained: "${validated.message}"` +
    (warning ? `\nWarning: ${warning}` : "");

  return textResult(text);
}

export async function handleConsult(args: unknown): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
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

  return textResult(text);
}

export async function handleConverse(args: unknown): Promise<McpResult> {
  const validated = validateConverseArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const timeoutSeconds = Math.min(
    Math.max(validated.timeout_seconds ?? 300, 10),
    3600,
  );

  const silenceMode = validated.silence_mode ?? DEFAULT_CONVERSE_SILENCE_MODE;

  // Session booking — auto-book if not already booked
  const booking = isVoiceBooked();
  if (booking.booked && !booking.ownedByUs) {
    return textResult(
      `[converse] Line is busy — voice session owned by ${booking.owner?.sessionId} ` +
        `(PID ${booking.owner?.pid}) since ${booking.owner?.startedAt}. ` +
        "Fall back to text input, or wait for the other session to finish.",
      true,
    );
  }

  if (!booking.booked) {
    const result = bookVoiceSession();
    if (!result.success) {
      return textResult(`[converse] ${result.error}`, true);
    }
  }

  clearInput();
  clearStopSignal();

  // Wait for any currently playing audio to finish
  await awaitCurrentPlayback();

  // Speak the question aloud — BLOCKING for converse
  const voiceName = validated.voice;
  await speak(validated.message, {
    mode: "converse",
    waitForPlayback: true,
    voice: voiceName,
  });

  // Record mic audio, then transcribe with selected STT backend
  const pressToTalk = validated.press_to_talk ?? false;
  const response = await waitForInput(
    timeoutSeconds * 1000,
    silenceMode,
    pressToTalk,
  );

  if (response === null) {
    return textResult(
      pressToTalk
        ? `[converse/PTT] No response received within ${timeoutSeconds} seconds. The user may have stepped away.`
        : `[converse] No response received within ${timeoutSeconds} seconds. The user may have stepped away.`,
    );
  }

  return textResult(response);
}

export async function handleThink(args: unknown): Promise<McpResult> {
  const validated = validateThinkArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: thought", true);
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

  return textResult(`Noted (${category}): ${thought}`);
}

export async function handleReplay(args: unknown): Promise<McpResult> {
  const { index } = validateReplayArgs(args);

  const entry = getHistoryEntry(index);
  if (!entry) {
    return textResult(
      index === 0
        ? "[replay] No audio in history buffer. Speak something first."
        : `[replay] No audio at index ${index}. Buffer may have fewer entries.`,
      true,
    );
  }

  if (!existsSync(entry.file)) {
    return textResult(
      `[replay] Audio file missing: ${entry.file}. It may have been cleaned up.`,
      true,
    );
  }

  // Play audio non-blocking
  playAudioNonBlocking(entry.file);

  return textResult(`[replay] Playing (index ${index}): "${entry.text}"`);
}

export async function handleToggle(args: unknown): Promise<McpResult> {
  const validated = validateToggleArgs(args);
  if (!validated) {
    return textResult("Missing required parameter: enabled (boolean)", true);
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

  return textResult(`[toggle] ${actions.join(", ")}`);
}
