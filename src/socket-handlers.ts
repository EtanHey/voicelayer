/**
 * Socket command handlers — logic for Voice Bar socket commands.
 *
 * Extracted from mcp-server.ts for testability. All handlers use
 * broadcast() to communicate state back to Voice Bar clients.
 */

import { existsSync, unlinkSync } from "fs";
import {
  TTS_DISABLED_FILE,
  MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE,
  STOP_FILE,
  safeWriteFileSync,
} from "./paths";
import {
  awaitCurrentPlayback,
  getHistoryEntry,
  playAudioNonBlocking,
  restartPlayback,
  stopPlayback,
} from "./tts";
import {
  waitForInput,
  hasRetainedRecording,
  retranscribeLastCapture,
  retranscribeRecordingCapture,
} from "./input";
import {
  bookVoiceSession,
  isVoiceBooked,
  yieldVoiceMaintenanceToCapture,
  EXTERNAL_VOICE_SESSION_REASON,
  setCancelSignal,
} from "./session-booking";
import { broadcast, isConnected } from "./socket-client";
import type {
  AckCommand,
  AckEvent,
  HealthResponse,
  SocketCommand,
  SocketResponse,
} from "./socket-protocol";
import { buildHealthResponse } from "./daemon-health";
import { getPlaybackQueueDepth } from "./tts";
import { getRecordingState } from "./input";
import {
  addAlias,
  addPromptTerm,
  buildDictionaryDisplayEntries,
  listVocabulary,
  removeAlias,
  removePromptTerm,
} from "./stt-vocabulary-store";
import {
  getEffectiveRecordingState,
  isRecordingConflictError,
} from "./recording-state";
import {
  getWhisperPerformanceEffort,
  restartWhisperServerForPerformanceChange,
  setWhisperPerformanceEffort,
} from "./whisper-performance";
import { setRecordingHold } from "./recording-hold";
import { readWhisperModelStatus } from "./model-status";
import {
  ensureServer,
  onWhisperModelStateChange,
  unloadOwnedServer,
  verifiedWhisperServerLaunchRecord,
} from "./whisper-server";
import { whisperLifecycleGate } from "./whisper-lifecycle-gate";
import { hasActiveVoiceOperation } from "./voice-operation-reservation";

let modelStatusRevision = 0;
function publishModelStatusEvent(): void {
  const revision = ++modelStatusRevision;
  if (!isConnected()) return;
  void readWhisperModelStatus().then((modelStatus) => {
    if (revision === modelStatusRevision) {
      broadcast({ type: "model_status", model_status: modelStatus });
    }
  }).catch((error) => {
    console.error(`[voicelayer] Model status event failed: ${error instanceof Error ? error.message : String(error)}`);
  });
}
onWhisperModelStateChange(publishModelStatusEvent);

export function handleSocketCommand(
  command: SocketCommand,
): SocketResponse | void | Promise<SocketResponse> {
  const recordingState = getRecordingState();
  const playbackQueueDepth = getPlaybackQueueDepth();
  const isSpeaking = recordingState === "idle" && playbackQueueDepth > 0;

  switch (command.cmd) {
    case "stop":
      if (recordingState === "idle" && playbackQueueDepth === 0) {
        return buildAck(command, "noop", "already idle");
      }
      if (recordingState === "transcribing") {
        return buildAck(command, "noop", "already transcribing");
      }
      safeWriteFileSync(
        STOP_FILE,
        `stop from voice-bar at ${new Date().toISOString()}`,
      );
      // AIDEV-NOTE: Must call stopPlayback() — not just pkill — to reset
      // playbackQueue and queueSize. Otherwise queued items resume after kill.
      stopPlayback(command.playback_elapsed_ms);
      return awaitCurrentPlayback().then(() => buildAck(command, "accept"));
    case "cancel":
      if (recordingState === "idle" && playbackQueueDepth === 0) {
        return buildAck(command, "noop", "already idle");
      }
      // AIDEV-NOTE: Cancel differs from stop — it sets the cancel signal
      // so waitForInput() discards the recording instead of transcribing.
      setCancelSignal();
      safeWriteFileSync(
        STOP_FILE,
        `cancel from voice-bar at ${new Date().toISOString()}`,
      );
      // AIDEV-NOTE: Must call stopPlayback() — not just pkill — to reset
      // playbackQueue and queueSize. Otherwise queued items resume after kill.
      stopPlayback(command.playback_elapsed_ms);
      return awaitCurrentPlayback().then(() => buildAck(command, "accept"));
    case "replay": {
      if (recordingState === "recording" || recordingState === "transcribing") {
        return buildAck(command, "reject", "busy");
      }
      if (isSpeaking) {
        if (restartPlayback()) {
          return buildAck(command, "accept");
        }
        return buildAck(command, "reject", "busy");
      }
      const entry = getHistoryEntry(0);
      if (entry && existsSync(entry.file)) {
        try {
          playAudioNonBlocking(entry.file, {
            text: entry.text.slice(0, 2000),
            voice: entry.voice,
          });
        } catch (err) {
          return buildAck(
            command,
            "reject",
            err instanceof Error ? err.message : String(err),
          );
        }
        return buildAck(command, "accept");
      }
      return buildAck(command, "noop", "nothing to replay");
    }
    case "retranscribe_last": {
      if (
        recordingState === "recording" ||
        recordingState === "transcribing" ||
        isSpeaking
      ) {
        return buildAck(command, "reject", "busy");
      }
      if (!hasRetainedRecording()) {
        return buildAck(command, "noop", "nothing to retranscribe");
      }
      retranscribeLastCapture().catch((err) => {
        console.error(
          `[voicelayer] Retranscribe last capture failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        broadcast({ type: "state", state: "idle" });
      });
      return buildAck(command, "accept");
    }
    case "retranscribe_recording": {
      if (
        recordingState === "recording" ||
        recordingState === "transcribing" ||
        isSpeaking
      ) {
        return buildAck(command, "reject", "busy");
      }
      retranscribeRecordingCapture(command.audio_path).catch((err) => {
        console.error(
          `[voicelayer] Retranscribe archived recording failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        broadcast({ type: "state", state: "idle", source: "recording" });
      });
      return buildAck(command, "accept");
    }
    case "record": {
      if (recordingState === "recording") {
        return buildAck(command, "noop", "already recording");
      }
      if (recordingState === "transcribing") {
        return buildAck(command, "reject", "busy");
      }
      if (existsSync(VOICE_DISABLED_FILE) || existsSync(MIC_DISABLED_FILE)) {
        broadcast({
          type: "error",
          message: "Mic is disabled",
          recoverable: false,
        });
        return buildAck(command, "reject", "mic disabled");
      }
      whisperLifecycleGate.yieldToCapture();
      yieldVoiceMaintenanceToCapture();
      // H5 fix: check session booking to prevent concurrent recordings
      const booking = isVoiceBooked();
      if (booking.booked && !booking.ownedByUs) {
        broadcast({
          type: "error",
          message: `Line is busy — voice session owned by ${booking.owner?.sessionId ?? "unknown"}`,
          recoverable: true,
        });
        return buildAck(command, "reject", "busy");
      }
      // V1 single-recorder invariant: claim the cross-process voice-session
      // lock before recording, mirroring handleConverse. A bar-initiated F5
      // recording previously checked the lock but never wrote one, so a
      // voice_ask in a second daemon process could book + record concurrently
      // → two `sox` on one mic → rms=0 silence → lost transcript (#7d). The
      // lockfile is the single mic mutex honored by both entry points.
      if (!booking.booked) {
        const claim = bookVoiceSession();
        if (!claim.success) {
          broadcast({
            type: "error",
            message: `Line is busy — ${claim.error ?? "another session holds voice"}`,
            recoverable: true,
          });
          return buildAck(command, "reject", "busy");
        }
      }
      if (isSpeaking) {
        stopPlayback();
      }
      const timeoutMs = (command.timeout_seconds ?? 30) * 1000;
      const silenceMode = command.silence_mode ?? "standard";
      const ptt = command.press_to_talk ?? false;
      waitForInput(timeoutMs, silenceMode, ptt, {
        archiveSource: "voicebar",
      }).catch((err) => {
        console.error(
          `[voicelayer] Bar-initiated recording failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        if (
          !isRecordingConflictError(err) &&
          getEffectiveRecordingState() === "idle"
        ) {
          broadcast({ type: "state", state: "idle", source: "recording" });
        }
      });
      return buildAck(command, "accept");
    }
    case "toggle": {
      const { scope, enabled } = command;
      const flagFile =
        scope === "tts"
          ? TTS_DISABLED_FILE
          : scope === "mic"
            ? MIC_DISABLED_FILE
            : VOICE_DISABLED_FILE;
      if (enabled) {
        try {
          unlinkSync(flagFile);
        } catch {}
        if (scope === "all") {
          try {
            unlinkSync(TTS_DISABLED_FILE);
          } catch {}
          try {
            unlinkSync(MIC_DISABLED_FILE);
          } catch {}
        }
      } else {
        const ts = `disabled from voice-bar at ${new Date().toISOString()}`;
        safeWriteFileSync(flagFile, ts);
        // M1 fix: when disabling "all", also write individual flag files
        if (scope === "all") {
          safeWriteFileSync(TTS_DISABLED_FILE, ts);
          safeWriteFileSync(MIC_DISABLED_FILE, ts);
        }
      }
      return buildAck(command, "accept");
    }
    case "health":
      return readWhisperModelStatus().then((modelStatus) =>
        buildHealthResponse({
          queueDepth: getPlaybackQueueDepth(),
          recordingState: getRecordingState(),
          modelStatus,
        }),
      );
    case "command":
      broadcast({
        type: "command_mode",
        phase: "applying",
        operation: command.operation,
        replacement_text: command.text,
        prompt: command.prompt,
      });
      return buildAck(command, "accept");
    case "mark_clip":
      broadcast({
        type: "clip_marker",
        marker_id: `command-${command.label
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "-")
          .replace(/^-+|-+$/g, "")}`,
        label: command.label,
        source: command.source ?? "command",
        status: "marked",
      });
      return buildAck(command, "accept");
    case "vocab_add":
      try {
        const result = addAlias({ from: command.from, to: command.to });
        const collisionReason = vocabularyCollisionReason(
          result.warnings,
          command.from,
          "alias",
        );
        if (collisionReason) {
          return buildAck(command, "reject", collisionReason);
        }
        return buildAck(command, "accept");
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
    case "vocab_list": {
      const snapshot = listVocabulary();
      return {
        type: "vocab_list",
        ...(command.id ? { id: command.id } : {}),
        ...snapshot,
        display_entries: buildDictionaryDisplayEntries(snapshot.entries),
      };
    }
    case "vocab_remove": {
      try {
        const result = removeAlias(command.from);
        return buildAck(
          command,
          result.removed ? "accept" : "noop",
          result.removed ? undefined : "not found",
        );
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
    }
    case "vocab_add_term":
      try {
        const result = addPromptTerm(command.term);
        const collisionReason = vocabularyCollisionReason(
          result.warnings,
          command.term,
          "term",
        );
        if (collisionReason) {
          return buildAck(command, "reject", collisionReason);
        }
        return buildAck(command, "accept");
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
    case "vocab_remove_term": {
      try {
        const result = removePromptTerm(command.term);
        return buildAck(
          command,
          result.removed ? "accept" : "noop",
          result.removed ? undefined : "not found",
        );
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
    }
    case "set_whisper_effort":
      if (residencyLoadPending) {
        return buildAck(command, "reject", "Model load in progress");
      }
      if (residencyBusy() || whisperLifecycleGate.isUnloading ||
          whisperLifecycleGate.isInUse) {
        const booking = isVoiceBooked();
        return buildAck(command, "reject", booking.booked && !booking.ownedByUs
          ? EXTERNAL_VOICE_SESSION_REASON : "busy");
      }
      return handleEffortCommand(command);
    case "set_whisper_residency":
      return handleResidencyCommand(command);
    case "set_recording_hold":
      if (recordingState !== "recording") {
        return buildAck(command, "noop", "not recording");
      }
      try {
        setRecordingHold(command.engaged);
        return buildAck(command, "accept");
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
  }
}

function residencyBusy(): boolean {
  const booking = isVoiceBooked();
  return getRecordingState() !== "idle" ||
    getPlaybackQueueDepth() > 0 || hasActiveVoiceOperation() ||
    (booking.booked && !booking.ownedByUs);
}

function residencyBusyReason(): string {
  const state = getRecordingState();
  const booking = isVoiceBooked();
  if (booking.booked && !booking.ownedByUs) return EXTERNAL_VOICE_SESSION_REASON;
  if (state === "recording") return "Recording in progress";
  if (state === "transcribing") return "Transcription in progress";
  if (getPlaybackQueueDepth() > 0) return "Playing back audio";
  if (hasActiveVoiceOperation()) return "Voice session in progress";
  return "busy";
}

// Settings requests reserve their own admission slot. Capture booking remains
// higher priority: it can proceed while load is pending, and the load then
// rejects at its next busy check rather than refusing a live dictation.
let residencyLoadPending = false;

async function handleResidencyCommand(
  command: Extract<SocketCommand, { cmd: "set_whisper_residency" }>,
): Promise<AckEvent> {
  let outcome: AckEvent["outcome"] = "reject";
  let reason: string | undefined;
  let ownsLoadSlot = false;
  const startedAt = Date.now();
  console.error(`[voicelayer] Residency request ${command.id} ${command.action} started`);
  const backend = (process.env.QA_VOICE_STT_BACKEND ?? "auto").toLowerCase();
  if (backend === "wispr" || backend === "whisper") {
    reason = "resident backend is not configured";
  } else if (residencyLoadPending || residencyBusy()) {
    reason = residencyLoadPending ? "Model load in progress" : residencyBusyReason();
  } else if (command.action === "load") {
    residencyLoadPending = true;
    ownsLoadSlot = true;
    try {
      await ensureServer();
      if (residencyBusy()) reason = residencyBusyReason();
      else {
        const port = Number.parseInt(process.env.QA_VOICE_WHISPER_SERVER_PORT ?? "", 10) || 8178;
        const record = verifiedWhisperServerLaunchRecord(port);
        if (!record || record.adopted) reason = "server is not owned by this daemon";
        else outcome = "accept";
      }
    } catch (error) {
      reason = vocabularyErrorReason(error);
    }
  } else {
    const result = await unloadOwnedServer(residencyBusy);
    outcome = result.outcome;
    if (result.outcome === "reject") reason = result.reason;
  }
  try {
    const modelStatus = await readWhisperModelStatus();
    if (command.action === "load" && outcome === "accept" && residencyBusy()) {
      outcome = "reject";
      reason = residencyBusyReason();
    }
    const expected = command.action === "load" ? "loaded" : "not_loaded";
    if (outcome === "accept" && modelStatus.residency !== expected) {
      outcome = "reject";
      reason = "fresh residency differs from requested state";
    }
    return {
      ...buildAck(command, outcome, reason),
      residency: modelStatus.residency,
      model_status: modelStatus,
    };
  } catch (error) {
    outcome = "reject";
    reason ??= vocabularyErrorReason(error);
    return {
      ...buildAck(command, "reject", reason),
      residency: "unknown",
    };
  } finally {
    if (ownsLoadSlot) residencyLoadPending = false;
    publishModelStatusEvent();
    console.error(
      `[voicelayer] Residency request ${command.id} ${command.action} ${outcome}` +
      ` reason=${reason ?? "none"} elapsed_ms=${Date.now() - startedAt}`,
    );
  }
}

/**
 * Effort is a whisper-server launch flag, so a change stops the server. If the
 * model was in memory, relaunch it with the new effort before acking, so "In
 * memory" returns to Loaded without a click (E2). The socket client sends the
 * same `loading` ack a Load gets while this runs.
 *
 * AIDEV-NOTE: a server this daemon did not launch is only detached by the stop
 * and re-adopted with its old flags, so the ack says the effort is not active
 * yet instead of claiming it applied.
 */
async function handleEffortCommand(
  command: Extract<SocketCommand, { cmd: "set_whisper_effort" }>,
): Promise<AckEvent> {
  residencyLoadPending = true;
  let reason: string | undefined;
  try {
    const wasLoaded = (await readWhisperModelStatus()).residency === "loaded";
    // The status probe yielded; a capture may have started meanwhile.
    if (residencyBusy() || whisperLifecycleGate.isInUse) {
      return buildAck(command, "reject", residencyBusyReason());
    }
    const previousEffort = getWhisperPerformanceEffort();
    try {
      setWhisperPerformanceEffort(command.effort);
    } catch (error) {
      return buildAck(command, "reject", vocabularyErrorReason(error));
    }
    try {
      await restartWhisperServerForPerformanceChange();
    } catch (error) {
      // The old server is still running its old flags: say so, and keep the
      // setting truthful rather than report an effort that is not in effect.
      setWhisperPerformanceEffort(previousEffort);
      return buildAck(
        command,
        "reject",
        `Effort unchanged: ${vocabularyErrorReason(error)}`,
      );
    }
    if (wasLoaded) {
      try {
        await ensureServer();
      } catch (error) {
        reason = `Saved, but the model did not reload: ${vocabularyErrorReason(error)}`;
      }
    }
  } finally {
    residencyLoadPending = false;
  }
  try {
    const modelStatus = await readWhisperModelStatus();
    if (!reason && modelStatus.residency === "loaded" &&
        modelStatus.active_effort !== command.effort) {
      reason = "Saved. The running model server was not started by VoiceLayer, " +
        "so it keeps its current effort until it restarts.";
    }
    return {
      ...buildAck(command, "accept", reason),
      residency: modelStatus.residency,
      model_status: modelStatus,
    };
  } catch (error) {
    return buildAck(command, "accept", reason ?? vocabularyErrorReason(error));
  } finally {
    publishModelStatusEvent();
  }
}

function vocabularyErrorReason(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function vocabularyCollisionReason(
  warnings: { code: string; existing: string }[] | undefined,
  submitted: string,
  mode: "alias" | "term",
): string | null {
  const collision = warnings?.find(
    (warning) => warning.code === "dictionary_alias_collision",
  );
  if (!collision) return null;
  const trimmed = submitted.trim();
  if (mode === "alias") {
    return `${trimmed} is already a canonical term: ${collision.existing}`;
  }
  return `${trimmed} is already a variant of ${collision.existing}`;
}

function buildAck(
  command: SocketCommand & { cmd: AckCommand; id?: string },
  outcome: AckEvent["outcome"],
  reason?: string,
): AckEvent {
  return {
    type: "ack",
    command: command.cmd,
    outcome,
    ...(command.id ? { id: command.id } : {}),
    ...(reason ? { reason } : {}),
  };
}
