/**
 * MCP tool handler functions for VoiceLayer.
 *
 * Each handler validates input via Zod schemas and returns MCP tool results.
 * Separated from mcp-server.ts for maintainability and testability.
 */

import { appendFileSync, existsSync, writeFileSync, unlinkSync } from "fs";
import {
  assertSpeakerClear,
  isSpeakerOutputRefusedError,
  speak,
  getHistoryEntry,
  playAudioNonBlocking,
  awaitCurrentPlayback,
} from "./tts";
import { waitForInput, clearInput } from "./input";
import {
  getEffectiveRecordingState,
  isRecordingConflictError,
} from "./recording-state";
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
import { broadcast, isConnected } from "./socket-client";
import {
  formatSpeak,
  formatAsk,
  formatThink,
  formatReplay,
  formatToggle,
  formatError,
  formatBusy,
} from "./format-response";
import { sanitizeTtsText } from "./sanitize";
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

  // Speech/think mode — sanitize to prevent SSML injection
  const message = sanitizeTtsText(
    typeof a.message === "string" ? a.message.trim() : "",
  );
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

  return textResult(formatSpeak("announce", validated.message, warning));
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

  return textResult(formatSpeak("brief", validated.message, warning));
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

  return textResult(formatSpeak("consult", validated.message, warning));
}

export async function handleConverse(args: unknown): Promise<McpResult> {
  const validated = validateConverseArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const timeoutSeconds = Math.min(
    Math.max(validated.timeout_seconds ?? 30, 5),
    3600,
  );

  const silenceMode = validated.silence_mode ?? DEFAULT_CONVERSE_SILENCE_MODE;

  // Session booking — auto-book if not already booked
  const booking = isVoiceBooked();
  if (booking.booked && !booking.ownedByUs) {
    return textResult(
      formatBusy(
        booking.owner?.sessionId ?? "unknown",
        booking.owner?.pid ?? 0,
        booking.owner?.startedAt ?? "unknown",
      ),
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

  // AIDEV-NOTE: P0-2 — warn if VoiceBar is disconnected (non-blocking)
  if (!isConnected()) {
    console.error(
      "[voicelayer] Warning: VoiceBar not connected — user won't see visual feedback",
    );
  }

  // Outer timeout guard — prevents the entire converse flow from hanging
  // if speak(), awaitCurrentPlayback(), or waitForInput() gets stuck
  const outerTimeoutMs = (timeoutSeconds + 15) * 1000;
  const inputAbortController = new AbortController();
  const converseFlow = async (): Promise<McpResult> => {
    // V1 policy: refuse instead of queueing while the user is recording.
    // Queueing a question would make the eventual prompt stale and can still
    // leak audio if the recording state changes while the caller waits.
    assertSpeakerClear();

    // Wait for all queued playback to finish (P0-2: awaits full queue)
    await awaitCurrentPlayback();

    // Speak the question aloud — BLOCKING for converse
    const voiceName = validated.voice;
    const speech = await speak(validated.message, {
      mode: "converse",
      waitForPlayback: true,
      voice: voiceName,
      captureAudioArtifact: true,
    });
    if (
      !speech.audioArtifact ||
      !speech.displayText?.trim() ||
      !speech.engine ||
      !speech.voice?.trim()
    ) {
      throw new Error(
        "voice_ask could not retain synthesized prompt audio/transcript and actual-used engine/voice; recording was not started",
      );
    }

    // Record mic audio, then transcribe with selected STT backend
    const pressToTalk = validated.press_to_talk ?? false;
    const response = await waitForInput(
      timeoutSeconds * 1000,
      silenceMode,
      pressToTalk,
      {
        archiveSource: "voice_ask",
        voiceAskArtifacts: {
          agentAudioBytes: speech.audioArtifact.bytes,
          agentAudioFormat: speech.audioArtifact.format,
          agentTranscript: speech.displayText,
          agentTtsEngine: speech.engine,
          agentTtsVoice: speech.voice,
        },
        signal: inputAbortController.signal,
      },
    );

    if (response === null) {
      return textResult(formatAsk(null, { timeoutSeconds, pressToTalk }));
    }

    return textResult(formatAsk(response));
  };

  let timer: ReturnType<typeof setTimeout>;
  const timeoutPromise = new Promise<McpResult>((resolve) => {
    timer = setTimeout(() => {
      console.error(
        `[voicelayer] voice_ask hard timeout after ${outerTimeoutMs / 1000}s`,
      );
      const timeoutResult = textResult(
        `[converse] Hard timeout after ${Math.round(outerTimeoutMs / 1000)}s. ` +
          "The voice pipeline may be stuck. Try again.",
        true,
      );
      // P0-2: broadcast idle so VoiceBar doesn't get stuck
      broadcast({ type: "state", state: "idle", source: "recording" });
      // Settle the public timeout result before aborting the deeper pipeline so
      // a synchronous abort rejection cannot replace the intended response.
      resolve(timeoutResult);
      inputAbortController.abort(
        new Error(
          `voice_ask input aborted after hard timeout (${outerTimeoutMs}ms)`,
        ),
      );
    }, outerTimeoutMs);
  });

  // P0-2: catch pipeline errors cleanly; keep active recording UI intact
  // when v1 refuses voice_ask before question TTS.
  try {
    const result = await Promise.race([converseFlow(), timeoutPromise]);
    clearTimeout(timer!);
    return result;
  } catch (err) {
    clearTimeout(timer!);
    if (
      !isSpeakerOutputRefusedError(err) &&
      !isRecordingConflictError(err) &&
      getEffectiveRecordingState() === "idle"
    ) {
      broadcast({ type: "state", state: "idle" });
    }
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[voicelayer] voice_ask error: ${message}`);
    return textResult(`[converse] Error: ${message}`, true);
  }
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

  return textResult(formatThink(category, thought));
}

export async function handleReplay(args: unknown): Promise<McpResult> {
  const { index } = validateReplayArgs(args);

  const entry = getHistoryEntry(index);
  if (!entry) {
    return textResult(
      formatError(
        "replay",
        index === 0
          ? "No audio in history buffer. Speak something first."
          : `No audio at index ${index}. Buffer may have fewer entries.`,
      ),
      true,
    );
  }

  if (!existsSync(entry.file)) {
    return textResult(
      formatError(
        "replay",
        `Audio file missing: ${entry.file}. It may have been cleaned up.`,
      ),
      true,
    );
  }

  try {
    assertSpeakerClear();
  } catch (err) {
    return textResult(
      formatError(
        "replay",
        err instanceof Error ? err.message : String(err),
      ),
      true,
    );
  }

  // Play audio non-blocking — pass metadata for queue-aware broadcasting
  try {
    playAudioNonBlocking(entry.file, {
      text: entry.text.slice(0, 2000),
      voice: entry.voice,
    });
  } catch (err) {
    return textResult(
      formatError(
        "replay",
        err instanceof Error ? err.message : String(err),
      ),
      true,
    );
  }

  return textResult(formatReplay(index, entry.text));
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

  return textResult(formatToggle(actions));
}
