/**
 * MCP tool handler functions for VoiceLayer.
 *
 * Each handler validates input via Zod schemas and returns MCP tool results.
 * Separated from mcp-server.ts for maintainability and testability.
 */

import { appendFileSync, existsSync, writeFileSync, unlinkSync } from "fs";
import { basename, join } from "path";
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
import {
  VoiceAskProgressHeartbeat,
  type VoiceToolContext,
} from "./mcp-notifications";
import type { TextToSpeechOptions } from "./soundlayer";
import {
  resolvePushToEnd,
  warnLegacyPressToTalk,
} from "./push-to-end";
import { appendControlLayerEvent } from "./control-layer-journal";

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
const VOICE_ASK_RETURN_TIMEOUT_MS = 120_000;
const VOICE_ASK_CAPTURE_TIMEOUT_ALLOWANCE_SECONDS = 15;
const VOICE_ASK_PLAYBACK_MARGIN_SECONDS = 1;
const VOICE_ASK_ABORT_SETTLE_GRACE_MS = 15_000;

/**
 * Measured median synthesis rate across 326 retained `voice_ask` prompts
 * (`agent_transcript_chars` vs ffprobe duration of the retained
 * `agent-audio.mp3`). Used to tell a refused caller what its message would
 * have cost in blocking seconds.
 */
const SPEECH_CHARS_PER_SECOND = 13.9;

/**
 * Hard maximum for the BLOCKING tool. At the measured ~13 characters/second,
 * 600 characters is about 46 seconds: it lands on the 45-second default
 * playback stage budget, `(timeout_seconds + 15)s`, armed before `speak()`.
 * The principle is that the spoken prompt cannot consume the recording budget
 * it is supposed to precede. At 1,200 characters (about 92 seconds), the prompt
 * is already twice the default budget and can time out before the microphone
 * opens.
 *
 * A second mechanical constraint points the same way: the teleprompter carries
 * its text and the RMS waveform in one 8,191-byte socket frame. Past ~50s of
 * audio the envelope saturates at 1,000 samples and single-frame capacity
 * collapses to ~1,254 Latin / ~712 Hebrew characters. Staying under 45s keeps
 * the envelope small and the whole question on screen in either script.
 *
 * The MCP description is the primary intervention: it teaches callers to split
 * long prompts into sequential acknowledgement checkpoints. This guard is the
 * backstop. Its cost is refusing 97/326 retained asks (29.8%). Etan explicitly
 * confirmed the 600-character product limit on 2026-08-01.
 * AIDEV-NOTE: This is the blocking cap. Do NOT raise it to match
 * VOICE_SPEAK_MESSAGE_MAX_CHARS — voice_speak does not block or wait for an
 * acknowledgement.
 */
export const VOICE_ASK_MESSAGE_MAX_CHARS = 600;

/**
 * Roomier cap for the NON-BLOCKING tool. `voice_speak` returns instantly and the
 * user can ignore or stop it, so this is a pathology backstop only — it exists to
 * catch the 2,300-character class, not to shape normal announcements.
 */
export const VOICE_SPEAK_MESSAGE_MAX_CHARS = 1_200;

function voiceAskMessageMaxCharsForTimeout(timeoutSeconds: unknown): number {
  const normalizedTimeoutSeconds =
    typeof timeoutSeconds === "number" && Number.isFinite(timeoutSeconds)
      ? Math.min(Math.max(timeoutSeconds, 5), 3_600)
      : 30;
  const playbackBudgetSeconds =
    normalizedTimeoutSeconds +
    VOICE_ASK_CAPTURE_TIMEOUT_ALLOWANCE_SECONDS -
    VOICE_ASK_PLAYBACK_MARGIN_SECONDS;
  return Math.min(
    VOICE_ASK_MESSAGE_MAX_CHARS,
    Math.floor(playbackBudgetSeconds * SPEECH_CHARS_PER_SECOND),
  );
}

// --- Length guard ---

type VoiceTool = "voice_ask" | "voice_speak";

const MESSAGE_MAX_CHARS: Record<VoiceTool, number> = {
  voice_ask: VOICE_ASK_MESSAGE_MAX_CHARS,
  voice_speak: VOICE_SPEAK_MESSAGE_MAX_CHARS,
};

/**
 * Refuse an over-long message before anything is synthesised, booked, or
 * recorded, and journal the refusal so the anomaly is never invisible.
 *
 * Returns null when the message is acceptable (or is not a string — schema
 * validation downstream owns that case).
 */
function refuseOverlongMessage(
  message: unknown,
  tool: VoiceTool,
  thresholdOverride?: number,
): McpResult | null {
  const threshold = thresholdOverride ?? MESSAGE_MAX_CHARS[tool];
  if (typeof message !== "string" || message.length <= threshold) return null;

  const approximateSpeechSeconds = Math.ceil(
    message.length / SPEECH_CHARS_PER_SECOND,
  );
  appendControlLayerEvent(`${tool}.message_too_long`, {
    caller: `mcp.${tool}`,
    message_length: message.length,
    threshold,
    approximate_speech_seconds: approximateSpeechSeconds,
  });

  const cost =
    tool === "voice_ask"
      ? `It would take approximately ${approximateSpeechSeconds} seconds of blocking speech before the microphone opens. `
      : `It would take approximately ${approximateSpeechSeconds} seconds to speak. `;
  const remedy =
    tool === "voice_ask"
      ? "Split long content into two or more sequential voice_ask calls. " +
        "Each ask is a checkpoint where the user confirms they absorbed one part before the next is spoken. " +
        "Use voice_speak only for announcements or status updates that do not need a response."
      : "Shorten the announcement, or split it across separate voice_speak calls. " +
        "If the user must understand or respond to this content, use sequential voice_ask checkpoints instead.";

  return textResult(
    `${tool} message is ${message.length.toLocaleString("en-US")} characters; ` +
      `the limit is ${threshold.toLocaleString("en-US")}. ` +
      cost +
      remedy,
    true,
  );
}

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

export async function handleVoiceSpeak(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
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

  // Resolve think mode before TTS sanitization so silent notes retain code and
  // markup-shaped text exactly as the former direct think tool did.
  const rawMessage =
    typeof a.message === "string" ? a.message.trim() : "";
  if (!rawMessage) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const requestedMode = typeof a.mode === "string" ? a.mode : "auto";
  const mode =
    requestedMode === "auto" ? detectMode(rawMessage) : requestedMode;
  const rate = typeof a.rate === "string" ? a.rate : undefined;
  const voice = typeof a.voice === "string" ? a.voice : undefined;

  if (mode === "think") {
    const category = typeof a.category === "string" ? a.category : "insight";
    return handleThink({ thought: rawMessage, category });
  }

  // Pathology backstop for the spoken path only — a silent think note costs no
  // playback time, so it is exempt. Runs before synthesis, never truncating.
  const refusal = refuseOverlongMessage(rawMessage, "voice_speak");
  if (refusal) return refusal;

  // Spoken modes strip SSML-shaped content before synthesis.
  const message = sanitizeTtsText(rawMessage);
  if (!message) {
    return textResult("Missing or empty required parameter: message", true);
  }

  switch (mode) {
    case "announce":
      return handleAnnounce({ message, rate, voice }, context);
    case "brief":
      return handleBrief({ message, rate, voice }, context);
    case "consult":
      return handleConsult({ message, rate, voice }, context);
    default:
      return handleAnnounce({ message, rate, voice }, context);
  }
}

export async function handleVoiceAsk(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
  if (!args || typeof args !== "object") {
    return textResult("Missing arguments", true);
  }
  const a = args as Record<string, unknown>;
  if (Object.prototype.hasOwnProperty.call(a, "press_to_talk")) {
    warnLegacyPressToTalk("mcp.voice_ask");
  }
  const message = typeof a.message === "string" ? a.message.trim() : a.message;
  const refusal = refuseOverlongMessage(
    message,
    "voice_ask",
    voiceAskMessageMaxCharsForTimeout(a.timeout_seconds),
  );
  if (refusal) return refusal;
  return handleConverse(
    {
      message,
      voice: a.voice,
      timeout_seconds: a.timeout_seconds,
      silence_mode: a.silence_mode,
      push_to_end: a.push_to_end,
    },
    context,
  );
}

// --- Mode Handlers ---

function playbackTelemetryOptions(
  context?: VoiceToolContext,
): Pick<TextToSpeechOptions, "onPlaybackComplete"> {
  if (!context) return {};
  return {
    onPlaybackComplete: (outcome) => {
      context.emit({ kind: "playback_outcome", outcome });
    },
  };
}

export async function handleAnnounce(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning, playbackId } = await speak(validated.message, {
    mode: "announce",
    rate: validated.rate,
    voice: validated.voice,
    ...playbackTelemetryOptions(context),
  });

  return textResult(
    formatSpeak("announce", validated.message, warning, playbackId),
  );
}

export async function handleBrief(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning, playbackId } = await speak(validated.message, {
    mode: "brief",
    rate: validated.rate,
    voice: validated.voice,
    ...playbackTelemetryOptions(context),
  });

  return textResult(formatSpeak("brief", validated.message, warning, playbackId));
}

export async function handleConsult(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning, playbackId } = await speak(validated.message, {
    mode: "consult",
    rate: validated.rate,
    voice: validated.voice,
    ...playbackTelemetryOptions(context),
  });

  return textResult(
    formatSpeak("consult", validated.message, warning, playbackId),
  );
}

export async function handleConverse(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
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
  const outerTimeoutMs =
    (timeoutSeconds + VOICE_ASK_CAPTURE_TIMEOUT_ALLOWANCE_SECONDS) * 1000;
  const inputAbortController = new AbortController();
  let noSpeech = false;
  let captureArchivePath: string | null = null;
  const progressHeartbeat = context
    ? new VoiceAskProgressHeartbeat(context)
    : null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let timeoutSettled = false;
  let resolveTimeout!: (result: McpResult) => void;
  const timeoutPromise = new Promise<McpResult>((resolve) => {
    resolveTimeout = resolve;
  });
  const recoveryOptions = (reason?: string) =>
    captureArchivePath
      ? {
          archiveId: basename(captureArchivePath),
          audioPath: join(captureArchivePath, "audio.wav"),
          ...(reason ? { reason } : {}),
        }
      : undefined;
  const settleTimeout = (
    stage: "prompt" | "capture-start" | "capture" | "return",
    timeoutMs: number,
  ): void => {
    if (timeoutSettled) return;
    timeoutSettled = true;
    const recovery = recoveryOptions(
      `Hard timeout during ${stage} stage after ${Math.round(timeoutMs / 1000)}s`,
    );
    resolveTimeout(
      recovery
        ? textResult(formatAsk(null, { outcome: "captured", recovery }))
        : textResult(
            `[converse] Hard timeout during ${stage} stage after ${Math.round(timeoutMs / 1000)}s. ` +
              "The voice pipeline may be stuck with zero recoverable audio.",
            true,
          ),
    );
  };
  const armTimeout = (
    timeoutMs: number,
    stage: "prompt" | "capture-start" | "capture" | "return",
  ): void => {
    if (timeoutSettled) return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      console.error(
        `[voicelayer] voice_ask ${stage} hard timeout after ${timeoutMs / 1000}s`,
      );
      broadcast({ type: "state", state: "idle", source: "recording" });
      const abortError = new Error(
        `voice_ask ${stage} stage aborted after hard timeout (${timeoutMs}ms)`,
      );
      if (stage === "prompt" || stage === "capture-start") {
        // No mic has opened, so there cannot be captured audio to publish.
        settleTimeout(stage, timeoutMs);
        inputAbortController.abort(abortError);
        return;
      }

      // Let the abort path publish captured PCM before the public fallback wins.
      inputAbortController.abort(abortError);
      timer = setTimeout(
        () => settleTimeout(stage, timeoutMs),
        VOICE_ASK_ABORT_SETTLE_GRACE_MS,
      );
    }, timeoutMs);
  };
  armTimeout(outerTimeoutMs, "prompt");

  const converseFlow = async (): Promise<McpResult> => {
    // V1 policy: refuse instead of queueing while the user is recording.
    // Queueing a question would make the eventual prompt stale and can still
    // leak audio if the recording state changes while the caller waits.
    assertSpeakerClear();

    // Wait for all queued playback to finish (P0-2: awaits full queue)
    await awaitCurrentPlayback();
    if (timeoutSettled || inputAbortController.signal.aborted) {
      return textResult(
        "[converse] Request ended before recording could start.",
        true,
      );
    }

    // Speak the question aloud — BLOCKING for converse
    const voiceName = validated.voice;
    const speech = await speak(validated.message, {
      mode: "converse",
      waitForPlayback: true,
      voice: voiceName,
      captureAudioArtifact: true,
      ...playbackTelemetryOptions(context),
    });
    if (timeoutSettled || inputAbortController.signal.aborted) {
      return textResult(
        "[converse] Request ended before recording could start.",
        true,
      );
    }
    // Bound recorder startup separately from prompt playback. The full capture
    // window is rearmed only by onCaptureStart after the microphone opens.
    armTimeout(outerTimeoutMs, "capture-start");
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
    const pushToEnd = resolvePushToEnd(validated.push_to_end ?? false, {
      caller: "mcp.voice_ask",
    });
    progressHeartbeat?.start("recording");
    const response = await waitForInput(
      timeoutSeconds * 1000,
      silenceMode,
      pushToEnd,
      {
        archiveSource: "voice_ask",
        voiceAskArtifacts: {
          agentAudioBytes: speech.audioArtifact.bytes,
          agentAudioFormat: speech.audioArtifact.format,
          agentTranscript: speech.displayText,
          agentTtsEngine: speech.engine,
          agentTtsVoice: speech.voice,
        },
        onCaptureStart: () => {
          armTimeout(outerTimeoutMs, "capture");
        },
        onArchiveCreated: (archivePath) => {
          captureArchivePath = archivePath;
        },
        onCaptureEnd: () => {
          armTimeout(VOICE_ASK_RETURN_TIMEOUT_MS, "return");
        },
        onPhaseChange: (phase) => {
          progressHeartbeat?.setStage(phase);
        },
        onNoSpeech: () => {
          noSpeech = true;
        },
        signal: inputAbortController.signal,
      },
    );

    if (response === null) {
      const recovery = recoveryOptions();
      return textResult(
        formatAsk(null, {
          timeoutSeconds,
          pushToEnd,
          ...(noSpeech
            ? { outcome: "no-speech" as const }
            : recovery
              ? { outcome: "captured" as const }
              : {}),
          ...(recovery ? { recovery } : {}),
          promptPlayback: speech.playbackOutcome,
        }),
      );
    }

    return textResult(
      formatAsk(response, { promptPlayback: speech.playbackOutcome }),
    );
  };

  // P0-2: catch pipeline errors cleanly; keep active recording UI intact
  // when v1 refuses voice_ask before question TTS.
  try {
    const result = await Promise.race([converseFlow(), timeoutPromise]);
    if (timer) clearTimeout(timer);
    return result;
  } catch (err) {
    if (timer) clearTimeout(timer);
    if (
      !isSpeakerOutputRefusedError(err) &&
      !isRecordingConflictError(err) &&
      getEffectiveRecordingState() === "idle"
    ) {
      broadcast({ type: "state", state: "idle" });
    }
    const message = err instanceof Error ? err.message : String(err);
    console.error(`[voicelayer] voice_ask error: ${message}`);
    const recovery = recoveryOptions(message);
    if (recovery) {
      return textResult(formatAsk(null, { outcome: "captured", recovery }));
    }
    return textResult(`[converse] Error: ${message}`, true);
  } finally {
    progressHeartbeat?.stop();
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
