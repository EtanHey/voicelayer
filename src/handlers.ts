import { formatVoiceAskTurnResult, type VoiceAskTurnOutcome, type VoiceAskTimeoutStage, type McpTextResult } from "./voice-turn-result";
import {
  parseVoiceAskIngress, invalidVoiceAskMode, formatAdmittedVoiceAskResult,
  type VoiceAskIngress, type AdmittedVoiceAskResult,
} from "./voice-ask-admission";
import { finishLiveSpeechReceipt } from "./speech-archive-live";
import { requireIsolatedOverride } from "./test-isolation";
import { randomUUID } from "crypto";
import { createSpeakReceipt, type SpeakArchiveContext } from "./speak-archive";
import { updateSpeakLifecycle, type SpeakLifecycle } from "./speak-archive-store";
import { SPEAK_TEXT_MAX_CHARS } from "./socket-protocol";
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
  SpeechPreparationStoppedError,
  speak,
  getHistoryEntry,
  historyReplayMetadata,
  playAudioNonBlocking,
  awaitCurrentPlayback,
  getPlaybackQueueDepth,
  preemptLongRead,
  reserveCaptureAdmission,
  isCaptureAdmissionReserved,
  cancelPlayback,
  type CaptureAdmission,
  type QueuedPlaybackHandle,
} from "./tts";
import { waitForPlayerExit } from "./tts/playback-exit";
import {
  waitForInput,
  clearInput,
  retranscribeVoiceAskArchive,
} from "./input";
import {
  getEffectiveRecordingState,
  isRecordingConflictError,
} from "./recording-state";
import {
  bookVoiceSession,
  isVoiceBooked,
  yieldVoiceMaintenanceToCapture,
  clearStopSignal,
  clearCancelSignal,
} from "./session-booking";
import {
  TTS_DISABLED_FILE,
  MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE,
} from "./paths";
import type { SilenceMode } from "./vad";
import { isRecordingHoldEngaged } from "./recording-hold";
import { ensureVoiceBarRunning } from "./voice-bar-launcher";
import { broadcast, isConnected, withHistoryPlaybackSuspended } from "./socket-client";
import {
  formatSpeak,
  formatAsk,
  formatThink,
  formatReplay,
  formatToggle,
  formatError,
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
import { reserveStandardVoiceOperation } from "./voice-operation-reservation";
import { whisperLifecycleGate } from "./whisper-lifecycle-gate";

// --- MCP result helper ---

type McpResult = McpTextResult;

export type VoiceOperationLifecycle = {
  deferReleaseUntil: (settlement: Promise<unknown>) => void;
};

function textResult(text: string, isError = false): McpResult {
  return {
    content: [{ type: "text" as const, text }],
    ...(isError && { isError }),
  };
}

// --- Config ---

requireIsolatedOverride(process.env, "QA_VOICE_THINK_FILE");
const THINK_FILE =
  process.env.QA_VOICE_THINK_FILE || "/tmp/voicelayer-thinking.md";

const DEFAULT_CONVERSE_SILENCE_MODE: SilenceMode = "thoughtful";
const VOICE_ASK_RETURN_TIMEOUT_MS = 120_000;
const VOICE_ASK_CAPTURE_TIMEOUT_ALLOWANCE_SECONDS = 15;
const VOICE_ASK_PLAYBACK_WAIT_TIMEOUT_MS = 180_000;
const VOICE_ASK_PROMPT_TIMEOUT_FLOOR_MS = 180_000;
const VOICE_ASK_PROMPT_SYNTHESIS_ALLOWANCE_MS = 60_000;
const VOICE_ASK_PROMPT_SPEECH_MARGIN = 3;
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
 * 600 characters is about 46 seconds. This product cap keeps questions short;
 * prompt playback has its own generous deadline independent of the listening
 * budget, so a short listening window never shortens the accepted question.
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

function voiceAskPromptTimeoutMs(message: string): number {
  // Allow slow voices and cold synthesis without borrowing time from capture.
  const estimatedSpeechSeconds = Math.ceil(
    message.length / SPEECH_CHARS_PER_SECOND,
  );
  return Math.max(
    VOICE_ASK_PROMPT_TIMEOUT_FLOOR_MS,
    estimatedSpeechSeconds * VOICE_ASK_PROMPT_SPEECH_MARGIN * 1000 +
      VOICE_ASK_PROMPT_SYNTHESIS_ALLOWANCE_MS,
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
  const originalMessage = typeof a.message === "string" ? a.message : "";
  const rawMessage = originalMessage.trim();
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

  // Bound raw archive input separately from the later speech-duration policy.
  if (originalMessage.length > SPEAK_TEXT_MAX_CHARS) {
    return textResult("voice_speak refused: raw input exceeds archive admission limit", true);
  }

  const receipt = validateTtsArgs({ message: rawMessage, rate, voice })
    ? createSpeakReceipt({
      input: originalMessage, request_id: randomUUID(), request_source: "voice_speak",
      connection: context?.connection ?? null, format: null, blocking: false,
      requested: { mode: typeof a.mode === "string" ? a.mode : null,
        profile: null, engine: null, voice: voice ?? null, rate: null,
        ...(rate !== undefined ? { rate_raw: rate } : {}) },
      build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
    }) : null;
  if (receipt?.kind === "failed") {
    return textResult(`voice_speak refused: input archive unavailable (${receipt.code})`, true);
  }
  const archiveContext = receipt?.kind === "created" ? receipt.context : undefined;

  // Pathology backstop for the spoken path only — a silent think note costs no
  // playback time, so it is exempt. Runs before synthesis, never truncating.
  const refusal = refuseOverlongMessage(rawMessage, "voice_speak");
  if (refusal) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return refusal;
  }

  // Spoken modes strip SSML-shaped content before synthesis.
  const message = sanitizeTtsText(rawMessage);
  if (!message) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return textResult("Missing or empty required parameter: message", true);
  }

  const reservation = reserveStandardVoiceOperation();
  if (!reservation) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return textResult(
      "voice_speak refused because an archive retranscription voice operation is in progress",
      true,
    );
  }
  try {
    switch (mode) {
      case "announce":
        return await handleAnnounce({ message, rate, voice }, context, archiveContext);
      case "brief":
        return await handleBrief({ message, rate, voice }, context, archiveContext);
      case "consult":
        return await handleConsult({ message, rate, voice }, context, archiveContext);
      default:
        return await handleAnnounce({ message, rate, voice }, context, archiveContext);
    }
  } catch (error) {
    finishSpeakReceipt(archiveContext, error instanceof SpeechPreparationStoppedError ? "stopped" : isSpeakerOutputRefusedError(error) ? "rejected" : "failed",
      error instanceof SpeechPreparationStoppedError ? null : isSpeakerOutputRefusedError(error) ? "REJECTED" : "OUTPUT_UNAVAILABLE");
    if (error instanceof SpeechPreparationStoppedError) return textResult(error.message);
    throw error;
  } finally {
    reservation.release();
  }
}

export async function handleVoiceAsk(
  args: unknown,
  context?: VoiceToolContext,
): Promise<McpResult> {
  const ingress = parseVoiceAskIngress(args);
  if (ingress.kind === "refused") return ingress.result;
  if (ingress.kind === "retranscribe") {
    const retranscribeArchiveId = ingress.input.retranscribe_archive_id;
    try {
      const currentState = getEffectiveRecordingState();
      if (currentState !== "idle") {
        return textResult(
          `voice_ask archive retranscription requires idle voice state (current: ${currentState})`,
          true,
        );
      }
      const playbackQueueDepth = getPlaybackQueueDepth();
      if (playbackQueueDepth > 0) {
        return textResult(
          `voice_ask archive retranscription refused because the playback queue is not empty (${playbackQueueDepth})`,
          true,
        );
      }
      const text = await retranscribeVoiceAskArchive(
        retranscribeArchiveId,
        { delivery: "return-only" },
      );
      return textResult(
        formatAsk(text, {
          retranscribedArchiveId: retranscribeArchiveId,
        }),
      );
    } catch (error) {
      return textResult(
        formatError(
          "voice_ask",
          error instanceof Error ? error.message : String(error),
        ),
        true,
      );
    }
  }
  return formatAdmittedVoiceAskResult(await executeAdmittedNormalAsk({ ingress, context }));
}

export type AdmittedVoiceAskRequest = {
  args: unknown;
  context?: VoiceToolContext;
};

export async function runAdmittedVoiceAsk({ args, context }: AdmittedVoiceAskRequest): Promise<AdmittedVoiceAskResult> {
  const ingress = parseVoiceAskIngress(args);
  if (ingress.kind === "refused") return ingress;
  if (ingress.kind === "retranscribe") return invalidVoiceAskMode();
  return executeAdmittedNormalAsk({ ingress, context });
}

async function executeAdmittedNormalAsk({ ingress, context }: {
  ingress: Extract<VoiceAskIngress, { kind: "normal" }>;
  context?: VoiceToolContext;
}): Promise<AdmittedVoiceAskResult> {
  const { input: parsed, originalMessage } = ingress;
  if (ingress.legacyPressToTalk) {
    warnLegacyPressToTalk("mcp.voice_ask");
  }
  // Bound raw archive input separately from the trimmed prompt-duration policy.
  if (originalMessage.length > SPEAK_TEXT_MAX_CHARS) {
    return { kind: "refused", reason: "raw-input-limit",
      result: textResult("voice_ask refused: raw input exceeds archive admission limit", true) };
  }
  const receipt = createSpeakReceipt({
    input: originalMessage, request_id: randomUUID(), request_source: "ask_prompt",
    connection: context?.connection ?? null, format: null, blocking: true,
    requested: { mode: "converse", profile: null, engine: null, voice: parsed.voice ?? null, rate: null },
    build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
  });
  if (receipt.kind === "failed") {
    return { kind: "refused", reason: "input-archive-unavailable",
      result: textResult(`voice_ask refused: input archive unavailable (${receipt.code})`, true) };
  }
  const archiveContext = receipt.context;
  const refusal = refuseOverlongMessage(
    parsed.message,
    "voice_ask",
  );
  if (refusal) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return { kind: "refused", reason: "prompt-limit", result: refusal };
  }
  const reservation = reserveStandardVoiceOperation();
  if (!reservation) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return { kind: "refused", reason: "archive-operation", result: textResult(
      "voice_ask refused because an archive retranscription voice operation is in progress",
      true,
    ) };
  }
  let releaseDeferred = false;
  const operationLifecycle: VoiceOperationLifecycle = {
    deferReleaseUntil: (settlement) => {
      releaseDeferred = true;
      void settlement.then(
        () => reservation.release(),
        () => reservation.release(),
      );
    },
  };
  try {
    return { kind: "turn", outcome: await runVoiceAskTurn({
      args: {
        message: parsed.message,
        voice: parsed.voice,
        timeout_seconds: parsed.timeout_seconds,
        silence_mode: parsed.silence_mode,
        push_to_end: parsed.push_to_end,
      },
      context,
      operationLifecycle,
      archiveContext,
    }) };
  } finally {
    if (!releaseDeferred) reservation.release();
  }
}

// --- Mode Handlers ---

function finishSpeakReceipt(
  context: SpeakArchiveContext | undefined,
  status: "rejected" | "failed" | "stopped",
  error_code: SpeakLifecycle["summary"]["error_code"],
): void {
  if (!context || finishLiveSpeechReceipt(context, status, error_code)) return;
  const result = updateSpeakLifecycle(context, { status, generation_id: null,
    timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
    summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code }, played_spans: [] });
  if (result.kind === "failed" && result.code !== "FINALIZED") console.error(`[voicelayer] speak archive update failed: ${result.code}`);
}

async function speakWithReceipt(message: string, options: TextToSpeechOptions) {
  const result = await speak(message, options);
  // Empty TTS result is the existing disabled/no-output path, never completion.
  if (!result.playbackId && !result.engine) finishSpeakReceipt(options.archiveContext, "rejected", "REJECTED");
  return result;
}

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
  archiveContext?: SpeakArchiveContext,
): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning, playbackId } = await speakWithReceipt(validated.message, {
    archiveContext,
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
  archiveContext?: SpeakArchiveContext,
): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning, playbackId } = await speakWithReceipt(validated.message, {
    archiveContext,
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
  archiveContext?: SpeakArchiveContext,
): Promise<McpResult> {
  const validated = validateTtsArgs(args);
  if (!validated) {
    return textResult("Missing or empty required parameter: message", true);
  }

  const { warning, playbackId } = await speakWithReceipt(validated.message, {
    archiveContext,
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
  operationLifecycle?: VoiceOperationLifecycle,
  archiveContext?: SpeakArchiveContext,
): Promise<McpResult> {
  return formatVoiceAskTurnResult(await runVoiceAskTurn({ args, context, operationLifecycle, archiveContext }));
}

export type VoiceAskTurnRequest = {
  args: unknown;
  context?: VoiceToolContext;
  operationLifecycle?: VoiceOperationLifecycle;
  archiveContext?: SpeakArchiveContext;
};

export async function runVoiceAskTurn({ args, context, operationLifecycle, archiveContext }: VoiceAskTurnRequest): Promise<VoiceAskTurnOutcome> {
  // Direct internal callers retain their existing no-receipt contract.
  const validated = validateConverseArgs(args);
  if (!validated) {
    return { kind: "invalid-input" };
  }

  const timeoutSeconds = Math.min(
    Math.max(validated.timeout_seconds ?? 30, 5),
    3600,
  );

  const silenceMode = validated.silence_mode ?? DEFAULT_CONVERSE_SILENCE_MODE;

  if (isCaptureAdmissionReserved()) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return { kind: "capture-owned" };
  }
  try { assertSpeakerClear(); }
  catch (error) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return { kind: "failed", message: error instanceof Error ? error.message : String(error) };
  }

  // Reject an external booking before yielding maintenance, so an ask that
  // cannot record does not cancel an in-flight unload.
  const pre = isVoiceBooked();
  if (pre.booked && !pre.ownedByUs) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return { kind: "busy", sessionId: pre.owner?.sessionId ?? "unknown",
      pid: pre.owner?.pid ?? 0, startedAt: pre.owner?.startedAt ?? "unknown" };
  }

  whisperLifecycleGate.yieldToCapture();
  yieldVoiceMaintenanceToCapture();

  // Yield may have released our temporary maintenance lock. Recheck and book
  // the mic for capture; another process can win the lock during that handoff.
  const post = isVoiceBooked();
  if (post.booked && !post.ownedByUs) {
    finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return { kind: "busy", sessionId: post.owner?.sessionId ?? "unknown",
      pid: post.owner?.pid ?? 0, startedAt: post.owner?.startedAt ?? "unknown" };
  }
  if (!post.booked) {
    const result = bookVoiceSession();
    if (!result.success) {
      finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
      return { kind: "booking-refused", detail: result.error };
    }
  }

  clearInput();
  clearStopSignal();
  clearCancelSignal();

  // AIDEV-NOTE: P0-2 — warn if VoiceBar is disconnected (non-blocking)
  if (!isConnected()) {
    console.error(
      "[voicelayer] Warning: VoiceBar not connected — user won't see visual feedback",
    );
  }

  // Capture's existing watchdog allowance is separate from playback deadlines.
  // MCP VAD uses timeout_seconds only until first speech; input owns its safety ceiling.
  const outerTimeoutMs =
    (timeoutSeconds + VOICE_ASK_CAPTURE_TIMEOUT_ALLOWANCE_SECONDS) * 1000;
  const inputAbortController = new AbortController();
  let captureAdmission: CaptureAdmission | undefined;
  const promptPlayers: QueuedPlaybackHandle[] = [];
  const onDisconnect = (): void => {
    inputAbortController.abort(new Error("MCP client disconnected"));
    for (const handle of promptPlayers) cancelPlayback({ id: handle.id });
  };
  context?.disconnectSignal?.addEventListener("abort", onDisconnect, { once: true });
  if (context?.disconnectSignal?.aborted) onDisconnect();
  let promptTimeoutCleanup: Promise<void> | undefined;
  let beforeCaptureExpired = false;
  let promptReaped: Promise<void> = Promise.resolve();
  const abandonedBeforeCapture = Promise.withResolvers<VoiceAskTurnOutcome>();
  let admissionFailed = false;
  let noSpeech = false;
  let captureArchivePath: string | null = null;
  let promptAttempted = false;
  const progressHeartbeat = context
    ? new VoiceAskProgressHeartbeat(context)
    : null;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let timeoutSettled = false;
  let captureActive = false;
  let captureHeld = false;
  let captureHasSpeech = false;
  let captureAllowsHold = false;
  let resolveTimeout!: (result: VoiceAskTurnOutcome) => void;
  const timeoutPromise = new Promise<VoiceAskTurnOutcome>((resolve) => {
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
    stage: VoiceAskTimeoutStage,
    timeoutMs: number,
  ): void => {
    if (timeoutSettled) return;
    timeoutSettled = true;
    const recovery = recoveryOptions(
      `Hard timeout during ${stage} stage after ${Math.round(timeoutMs / 1000)}s`,
    );
    const result: VoiceAskTurnOutcome = { kind: "hard-timeout", stage, timeoutMs, recovery: recovery ?? null };
    if (beforeCaptureExpired) abandonedBeforeCapture.resolve(result);
    resolveTimeout(result);
  };
  const armTimeout = (
    timeoutMs: number,
    stage: VoiceAskTimeoutStage,
  ): void => {
    if (timeoutSettled) return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      if (stage === "capture" && captureAllowsHold &&
          (captureHasSpeech || captureHeld || isRecordingHoldEngaged())) return;
      console.error(
        `[voicelayer] voice_ask ${stage} hard timeout after ${timeoutMs / 1000}s`,
      );
      const abortError = new Error(
        `voice_ask ${stage} stage aborted after hard timeout (${timeoutMs}ms)`,
      );
      if (stage === "prompt" || stage === "playback-wait") {
        beforeCaptureExpired = true;
        inputAbortController.abort(abortError);
        for (const handle of promptPlayers) cancelPlayback({ id: handle.id });
        // Logical release is bounded; History must still wait for real silence.
        // A rejected exit signal cannot authorize History playback or an idle edge.
        promptReaped = new Promise<void>(resolve => {
          void Promise.all(promptPlayers.map(handle => handle.playerExited)).then(
            () => resolve(),
            error => console.error(`[voicelayer] Prompt exit remains unconfirmed: ${String(error)}`),
          );
        });
        promptTimeoutCleanup = waitForPlayerExit(promptPlayers)
          .catch(error => console.error(`[voicelayer] Prompt timeout cleanup: ${String(error)}`))
          .finally(() => captureAdmission?.release());
        // The queue retains physical ownership if this bounded cleanup expires.
        void promptTimeoutCleanup.then(() => settleTimeout(stage, timeoutMs));
        return;
      }
      broadcast({ type: "state", state: "idle", source: "recording" });
      if (stage === "capture-start") {
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
  let promptBudgetRemaining = voiceAskPromptTimeoutMs(validated.message);
  let promptBudgetStartedAt = 0;
  const onPromptParkedChange = (parked: boolean): void => {
    if (timeoutSettled || inputAbortController.signal.aborted) return;
    if (parked) {
      promptBudgetRemaining = Math.max(0, promptBudgetRemaining - (performance.now() - promptBudgetStartedAt));
      if (timer) clearTimeout(timer);
      timer = undefined;
    } else {
      promptBudgetStartedAt = performance.now();
      armTimeout(promptBudgetRemaining, "prompt");
    }
  };
  armTimeout(VOICE_ASK_PLAYBACK_WAIT_TIMEOUT_MS, "playback-wait");

  const converseFlow = async (): Promise<VoiceAskTurnOutcome> => {
    // V1 policy: refuse instead of queueing while the user is recording.
    // Queueing a question would make the eventual prompt stale and can still
    // leak audio if the recording state changes while the caller waits.
    assertSpeakerClear();

    // Wait for all queued playback to finish (P0-2: awaits full queue)
    preemptLongRead();
    await awaitCurrentPlayback({ forCaptureAdmission: true });
    if (timeoutSettled || inputAbortController.signal.aborted) {
      return { kind: "ended-before-capture" };
    }

    captureAdmission = reserveCaptureAdmission();
    if (!captureAdmission) throw new Error("Playback changed before Ask could reserve capture admission; try again");

    // Speak the question aloud — BLOCKING for converse
    promptBudgetStartedAt = performance.now();
    armTimeout(promptBudgetRemaining, "prompt");
    const voiceName = validated.voice;
    promptAttempted = true;
    let speech: Awaited<ReturnType<typeof speak>>;
    try {
      speech = await speak(validated.message, {
        archiveContext,
        mode: "converse",
        waitForPlayback: true,
        voice: voiceName,
        captureAudioArtifact: true,
        onPlaybackQueued: handle => {
          promptPlayers.push(handle);
          if (inputAbortController.signal.aborted || !captureAdmission!.admit(handle, onPromptParkedChange)) {
            admissionFailed = true;
            cancelPlayback({ id: handle.id });
          }
        },
        ...playbackTelemetryOptions(context),
      });
    } catch (error) {
      // Once queued, a failure cannot establish that no prompt audio existed.
      if (!promptPlayers.length) finishSpeakReceipt(archiveContext,
        error instanceof SpeechPreparationStoppedError ? "stopped" : isSpeakerOutputRefusedError(error) ? "rejected" : "failed",
        error instanceof SpeechPreparationStoppedError ? null : isSpeakerOutputRefusedError(error) ? "REJECTED" : "OUTPUT_UNAVAILABLE");
      throw error;
    }
    if (!speech.playbackId && !speech.engine) finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    if (timeoutSettled || inputAbortController.signal.aborted) {
      return { kind: "ended-before-capture" };
    }
    if (admissionFailed) throw new Error("Prompt lost capture admission");
    if (promptPlayers.length) await waitForPlayerExit(promptPlayers);
    if (timeoutSettled || inputAbortController.signal.aborted) {
      return { kind: "ended-before-capture" };
    }
    const promptStopped = speech.playbackOutcome?.reason === "stopped";
    if (speech.playbackOutcome && speech.playbackOutcome.status !== "completed" && !promptStopped) {
      captureAdmission.release();
      if (getPlaybackQueueDepth() === 0 && !isCaptureAdmissionReserved() && getEffectiveRecordingState() === "idle") {
        broadcast({ type: "state", state: "idle", source: "playback" });
      }
      return { kind: "prompt-incomplete", status: speech.playbackOutcome.status };
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
    assertSpeakerClear();
    if (promptPlayers.length) broadcast({ type: "state", state: "idle", source: "playback", next_state: "recording" });
    const pushToEnd = resolvePushToEnd(validated.push_to_end ?? false, {
      caller: "mcp.voice_ask",
    });
    captureAllowsHold = !pushToEnd;
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
          captureActive = true;
          armTimeout(outerTimeoutMs, "capture");
        },
        ...(!pushToEnd ? {
          onSpeechStart: () => {
            captureHasSpeech = true;
            if (!captureActive || timeoutSettled || inputAbortController.signal.aborted) return;
            if (timer) clearTimeout(timer);
            timer = undefined;
          },
          onRecordingHoldChange: (held: boolean) => {
            if (!captureActive || timeoutSettled ||
                inputAbortController.signal.aborted) return;
            captureHeld = held;
            if (held) {
              if (timer) clearTimeout(timer);
              timer = undefined;
            } else if (!captureHasSpeech) {
              armTimeout(outerTimeoutMs, "capture");
            }
          },
        } : {}),
        onArchiveCreated: (archivePath) => {
          captureArchivePath = archivePath;
        },
        onCaptureEnd: () => {
          captureActive = false;
          captureHeld = false;
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
      const promptPlayback = speech.playbackOutcome;
      if (noSpeech) return { kind: "no-speech", recovery: recovery ?? null, promptPlayback };
      if (recovery) return { kind: "retained", recovery, promptPlayback };
      return { kind: "no-input", timeoutSeconds, pushToEnd, promptPlayback };
    }

    return { kind: "answered", transcript: response,
      archiveId: captureArchivePath ? basename(captureArchivePath) : null,
      promptPlayback: speech.playbackOutcome };
  };

  // P0-2: catch pipeline errors cleanly; keep active recording UI intact
  // when v1 refuses voice_ask before question TTS.
  const flowPromise = withHistoryPlaybackSuspended(async () => {
    try {
      // Do not keep History fenced by a synthesis/backend continuation after abort.
      return await (beforeCaptureExpired ? abandonedBeforeCapture.promise :
        Promise.race([converseFlow(), abandonedBeforeCapture.promise]));
    } finally {
      if (beforeCaptureExpired) {
        await promptReaped;
        await promptTimeoutCleanup;
        // A late old exit must not mark a newer playback/capture owner idle.
        if (getPlaybackQueueDepth() === 0 && !isCaptureAdmissionReserved() &&
            getEffectiveRecordingState() === "idle") {
          broadcast({ type: "state", state: "idle", source: "playback" });
        }
      }
    }
  }).finally(() => promptTimeoutCleanup ?? captureAdmission?.release());
  operationLifecycle?.deferReleaseUntil(Promise.race([flowPromise, abandonedBeforeCapture.promise]));
  try {
    const result = await Promise.race([flowPromise, timeoutPromise]);
    if (timer) clearTimeout(timer);
    if (!promptAttempted) finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    return result;
  } catch (err) {
    if (timer) clearTimeout(timer);
    if (!promptAttempted) finishSpeakReceipt(archiveContext, "rejected", "REJECTED");
    if (
      !isSpeakerOutputRefusedError(err) &&
      !isRecordingConflictError(err)
    ) {
      // Errors can return before owned teardown; never idle a foreign/newer owner.
      void Promise.all(promptPlayers.map(handle => handle.playerExited)).then(() => {
        if (getPlaybackQueueDepth() === 0 && !isCaptureAdmissionReserved() &&
            getEffectiveRecordingState() === "idle") {
          broadcast({ type: "state", state: "idle" });
        }
      }, () => {}); // Rejected exit proof cannot authorize idle.
    }
    if (err instanceof SpeechPreparationStoppedError) {
      return { kind: "stopped-before-prompt" };
    }
    const message = err instanceof Error ? err.message : String(err);
    // Wire/recovery errors stay actionable; provider/filesystem messages can
    // contain transcript text or private archive paths and must not enter logs.
    console.error("[voicelayer] voice_ask error: request failed");
    const recovery = recoveryOptions(message);
    if (recovery) {
      return { kind: "retained", recovery, promptPlayback: undefined };
    }
    return { kind: "failed", message };
  } finally {
    context?.disconnectSignal?.removeEventListener("abort", onDisconnect);
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
    playAudioNonBlocking(entry.file, historyReplayMetadata(entry));
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
