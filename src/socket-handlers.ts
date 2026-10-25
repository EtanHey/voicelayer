/**
 * Socket command handlers — logic for Voice Bar socket commands.
 *
 * Extracted from mcp-server.ts for testability. All handlers use
 * broadcast() to communicate state back to Voice Bar clients.
 */

import { normalizedSpeechHash } from "./speech-identity";
import { randomUUID } from "crypto";
import { createSpeakReceipt, type SpeakArchiveContext } from "./speak-archive";
import { updateSpeakLifecycle, type SpeakLifecycle } from "./speak-archive-store";
import { setTTSSetting, setTTSProfile } from "./tts-settings";
import { setTTSPreviewActive, readTTSControlsStatus } from "./tts-controls-status";
import { PROCESSING_ENV_VARS, setProcessingSetting } from "./processing-settings";
import { readPolishControlsStatus } from "./polish-controls-status";
import { ensureSTTPolishServer, stopSTTPolishServerAndWait } from "./stt-polish-server";
import { existsSync, unlinkSync } from "fs";
import {
  TTS_DISABLED_FILE,
  MIC_DISABLED_FILE,
  VOICE_DISABLED_FILE,
  STOP_FILE,
  safeWriteFileSync,
} from "./paths";
import {
  speak,
  awaitCurrentPlayback,
  getHistoryEntry,
  playAudioNonBlocking,
  restartPlayback,
  stopPlayback,
  hasPendingSpeechPreparation,
  speakText,
  seekPlayback,
  pausePlayback,
  resumePlayback,
  isPlaybackPaused,
  isCaptureAdmissionReserved,
  isSpeakerOutputRefusedError,
  SpeechPreparationStoppedError,
  setLongReadSettledListener,
  setExternalSpeechPreemptionListener,
  prepareSelectionReadStart,
} from "./tts";
import type { PreparedReadStart } from "./tts/selection-read-preparation";
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
import { SELECTION_READ_QUEUE_LIMIT, SelectionReadQueue, type QueuedSelectionRead } from "./selection-read-queue";
import type {
  AckCommand,
  AckEvent,
  HealthResponse,
  SocketCommand,
  SocketResponse,
} from "./socket-protocol";
import { buildHealthResponse } from "./daemon-health";
import { displayTokenBoundaries, getPlaybackQueueDepth } from "./tts";
import { getRecordingState, reportInputDeviceLost } from "./input";
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
  getPersistedWhisperPerformanceEffort,
  restartWhisperServerForPerformanceChange,
  restorePersistedWhisperPerformanceEffort,
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
import { reserveStandardVoiceOperation, hasActiveVoiceOperation } from "./voice-operation-reservation";
import { markdownToSpeech } from "./tts/markdown-to-speech";
import { clipAlignedWordsToText, clipWordBoundariesToText, replayDisplayText } from "./tts/history-timings";

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

function finishRawSpeakReceipt(context: SpeakArchiveContext | undefined, status: "rejected" | "failed",
  error_code: SpeakLifecycle["summary"]["error_code"]): void {
  if (!context) return;
  const result = updateSpeakLifecycle(context, { status, generation_id: null,
    timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
    summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code }, played_spans: [] });
  if (result.kind === "failed") console.error(`[voicelayer] speak archive update failed: ${result.code}`);
}

function finishRawSpeakFailure(context: SpeakArchiveContext | undefined, error: unknown): void {
  const refused = isSpeakerOutputRefusedError(error) || (error instanceof Error &&
    (error.message === "busy" || error.message === "TTS is disabled"));
  finishRawSpeakReceipt(context, refused ? "rejected" : "failed", refused ? "REJECTED" : "OUTPUT_UNAVAILABLE");
}

function startSelectionRead(read: QueuedSelectionRead, prepared?: PreparedReadStart): void {
  try {
    if (getEffectiveRecordingState() !== "idle" || hasActiveVoiceOperation()) throw new Error("busy");
    const identity = { request_id: read.requestId, text_hash: read.textHash, archiveContext: read.archiveContext };
    if (prepared) speakText(read.text, read.profile, identity, prepared);
    else speakText(read.text, read.profile, identity);
  } catch (error) { finishRawSpeakFailure(read.archiveContext, error); throw error; }
}

/** QPRE1: the queue head's first chunk is prepared once the playing read's synthesis is complete. */
const selectionReadPreparation = {
  prepare: (read: QueuedSelectionRead, signal: AbortSignal, owner: string) =>
    prepareSelectionReadStart(read.text, read.profile, owner, signal, read.archiveContext),
};
const newSelectionReadQueue = () => new SelectionReadQueue<PreparedReadStart>(startSelectionRead,
  (state) => broadcast({ type: "read_queue", ...state }), SELECTION_READ_QUEUE_LIMIT, selectionReadPreparation);

/** QUEUE1: the user's Option+F5 reads. Agent voice_speak/announce keep the tts.ts priority queue and,
 * as before, preempt a user read; that ends this queue too (no surprise resumption after an agent). */
let selectionReads = newSelectionReadQueue();
setLongReadSettledListener((requestId, outcome) => selectionReads.settled(requestId, outcome));
// QUEUE1b: agent speech and Ask end the user chain, including reads F5 left waiting for Next.
setExternalSpeechPreemptionListener(() => selectionReads.clear());

export function resetSelectionReadQueueForTests(): void {
  selectionReads.clear();
  selectionReads = newSelectionReadQueue();
}

/** Stop means stop. F5 over a playing read (`suspend`) still stops it, but keeps the queued reads for Next;
 * a stop or cancel aimed at the capture (`keep`) leaves those waiting reads alone (QUEUE1b). */
function stopAll(playbackElapsedMs?: number, queue: "clear" | "suspend" | "keep" = "clear"): void {
  if (queue === "suspend") selectionReads.suspend();
  else if (queue === "clear") selectionReads.clear();
  stopPlayback(playbackElapsedMs);
}

function stopQueuePolicy(recordingState: string, retain: boolean): "clear" | "suspend" | "keep" {
  return recordingState !== "idle" ? "keep" : retain ? "suspend" : "clear";
}

export function handleSocketCommand(
  command: SocketCommand,
  onSpeak?: (read: import("./tts").LongReadHandle) => void,
): SocketResponse | void | Promise<SocketResponse> {
  const recordingState = getRecordingState();
  const playbackQueueDepth = getPlaybackQueueDepth();
  const isSpeaking = recordingState === "idle" && playbackQueueDepth > 0;

  switch (command.cmd) {
    case "seek": {
      if (recordingState !== "idle" || getEffectiveRecordingState() !== "idle") return buildAck(command, "reject", "busy");
      const result = seekPlayback(command.offset_ms, command.scope, command.readback_id);
      return { ...buildAck(command, result.outcome, result.reason),
        ...(result.offset_ms !== undefined ? { offset_ms: result.offset_ms, clamped: result.clamped } : {}) };
    }
    case "pause":
    case "resume": {
      const scope = { ...(command.playback_id ? { id: command.playback_id } : {}),
        ...(command.generation !== undefined ? { generation: command.generation } : {}) };
      const result = command.cmd === "pause"
        ? pausePlayback(scope, command.playback_elapsed_ms)
        : recordingState !== "idle" && isPlaybackPaused() ? { outcome: "reject" as const, reason: "busy" }
        : resumePlayback(scope);
      return { ...buildAck(command, result.outcome, result.reason),
        ...(result.offset_ms !== undefined ? { offset_ms: result.offset_ms } : {}) };
    }
    case "speak_text": {
      // Socket parsing/authentication precede this boundary. IDs retain their existing ownership
      // meaning: each validated invocation gets one receipt, including repeated client IDs.
      const receipt = createSpeakReceipt({
        input: command.text, request_id: command.id ?? randomUUID(),
        request_source: command.source === "selection" || command.source === "clipboard" || command.source === "cli"
          ? command.source : null,
        connection: null, format: command.format ?? null, blocking: null,
        requested: { mode: null, profile: command.profile ?? null, engine: null, voice: null, rate: null },
        build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
      });
      if (receipt.kind === "failed") return buildAck(command, "reject", `Speech refused: input archive unavailable (${receipt.code})`);
      if (getEffectiveRecordingState() !== "idle" || hasActiveVoiceOperation()) {
        finishRawSpeakReceipt(receipt.context, "rejected", "REJECTED");
        return buildAck(command, "reject", "busy");
      }
      let launched = false, queueStartOwnsFailure = false;
      try {
        const text = command.format === "markdown" ? markdownToSpeech(command.text) : command.text;
        const textHash = normalizedSpeechHash(command.text);
        if (command.queue === true && command.id) {
          // The queue starts the read itself when no user read is live; onSpeak observes only direct starts.
          queueStartOwnsFailure = true;
          const outcome = selectionReads.submit({ requestId: command.id, text, textHash, profile: command.profile ?? "auto",
            archiveContext: receipt.context }, true);
          if (outcome === "full") {
            finishRawSpeakReceipt(receipt.context, "rejected", "REJECTED");
            return buildAck(command, "reject", "queue full");
          }
          return buildAck(command, "accept", outcome === "queued" ? "queued" : undefined);
        }
        // The first Option+F5 selection owns the queue, so a different one queues behind it.
        if (command.source === "selection" && command.id) selectionReads.own(command.id);
        else selectionReads.clear();
        const read = speakText(text, command.profile ?? "auto", { request_id: command.id, text_hash: textHash,
          archiveContext: receipt.context });
        launched = true;
        onSpeak?.(read);
        return buildAck(command, "accept");
      } catch (error) {
        // A callback failure after speakText returned does not prove absent audio.
        if (!launched && !queueStartOwnsFailure) finishRawSpeakFailure(receipt.context, error);
        if (command.id) selectionReads.settled(command.id, "failed");
        return buildAck(command, "reject", error instanceof Error ? error.message : String(error));
      }
    }
    case "read_next": {
      const outcome = selectionReads.next(command.request_id);
      if (outcome === "stale") return buildAck(command, "noop", "stale");
      if (outcome === "advanced") return buildAck(command, "accept");
      // Next on the last item is Stop.
      stopPlayback();
      return awaitCurrentPlayback().then(() => buildAck(command, "accept"),
        (error) => buildAck(command, "reject", error instanceof Error ? error.message : String(error)));
    }
    case "stop":
      if (recordingState === "idle" && playbackQueueDepth === 0 && !hasPendingSpeechPreparation() && !isPlaybackPaused()) {
        // An explicit Stop also discards reads F5 left waiting for Next.
        if (command.retain_read_queue !== true) selectionReads.clear();
        return buildAck(command, "noop", "already idle");
      }
      if (recordingState === "transcribing") {
        return buildAck(command, "noop", "already transcribing");
      }
      safeWriteFileSync(
        STOP_FILE,
        command.physical_press === true && recordingState === "recording"
          ? JSON.stringify({ physical_press: true })
          : `stop from voice-bar at ${new Date().toISOString()}`,
      );
      // AIDEV-NOTE: Must call stopPlayback() — not just pkill — to reset
      // playbackQueue and queueSize. Otherwise queued items resume after kill.
      // P16: a stop/cancel aimed at an active capture (F5 release over a paused read) ends only the
      // capture; the parked read stays parked for Play, and the ack never waits on it (P16b, TLA+
      // CaptureCmdAckWithoutAwait): a parked long read cannot finish, so awaiting it false-rejected at 35 s.
      if (recordingState !== "idle" && isPlaybackPaused()) return buildAck(command, "accept");
      stopAll(command.playback_elapsed_ms, stopQueuePolicy(recordingState, command.retain_read_queue === true));
      return awaitCurrentPlayback().then(
        () => buildAck(command, "accept"),
        (error) => buildAck(command, "reject", error instanceof Error ? error.message : String(error)),
      );
    case "cancel":
      // Hide (QUEUE1b ruling) and an idle Cancel with no capture (QUEUE1c ruling) end the user read chain,
      // before the idle no-op below. A Cancel aimed at a capture keeps the waiting reads.
      if (command.discard_read_queue === true || recordingState === "idle") selectionReads.clear();
      if (recordingState === "idle" && playbackQueueDepth === 0 && !isPlaybackPaused()) {
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
      // P16: a stop/cancel aimed at an active capture (F5 release over a paused read) ends only the
      // capture; the parked read stays parked for Play, and the ack never waits on it (P16b, TLA+
      // CaptureCmdAckWithoutAwait): a parked long read cannot finish, so awaiting it false-rejected at 35 s.
      if (recordingState !== "idle" && isPlaybackPaused()) return buildAck(command, "accept");
      stopAll(command.playback_elapsed_ms, stopQueuePolicy(recordingState, false));
      return awaitCurrentPlayback().then(
        () => buildAck(command, "accept"),
        (error) => buildAck(command, "reject", error instanceof Error ? error.message : String(error)),
      );
    case "replay": {
      if (recordingState === "recording" || recordingState === "transcribing") {
        return buildAck(command, "reject", "busy");
      }
      // CLICK2: Replay while paused restarts the paused read from 0:00 and plays it. Only a capture refuses it.
      const paused = isPlaybackPaused();
      if (paused && (getEffectiveRecordingState() !== "idle" || isCaptureAdmissionReserved())) {
        return buildAck(command, "reject", "busy");
      }
      if (isSpeaking || paused) {
        if (restartPlayback()) {
          return buildAck(command, "accept");
        }
        return buildAck(command, "reject", "busy");
      }
      const entry = getHistoryEntry(0);
      if (entry && existsSync(entry.file)) {
        try {
          const text = replayDisplayText(entry.text);
          // WORDTIME1: a replay carries the timings the read used, so it is never less timed than the first run.
          playAudioNonBlocking(entry.file, {
            text,
            voice: entry.voice,
            ...(entry.alignedWords?.length ? { alignedWords: clipAlignedWordsToText(entry.alignedWords, text) } : {}),
            ...(entry.wordBoundaries?.length ? { wordBoundaries: text === entry.text ? entry.wordBoundaries
              : clipWordBoundariesToText(displayTokenBoundaries(entry.text, entry.wordBoundaries), text) } : {}),
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
          "[voicelayer] Retranscribe last capture failed: status=failed (details redacted)",
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
          "[voicelayer] Retranscribe archived recording failed: status=failed (details redacted)",
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
        // F5 over a playing read stops it as today; queued Option+F5 reads wait for Next.
        stopAll(undefined, "suspend");
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
    case "preview_tts_profile": {
      const reject = (reason: string) => ({...buildAck(command, "reject", reason), tts_controls: readTTSControlsStatus()});
      const sample = "Here is a sample of this voice. Clear speech, at your preferred pace.";
      const receipt = createSpeakReceipt({
        input: sample, request_id: randomUUID(), request_source: "preview",
        // Both MCP entrypoints register this socket handler; transport is unknown here.
        connection: null, format: "plain", blocking: true,
        requested: { mode: null, profile: command.profile, engine: null, voice: null, rate: null },
        build: { app_version: null, daemon_version: null, git_sha: null, executable_hash: null },
      });
      if (receipt.kind === "failed") return reject(`Preview refused: input archive unavailable (${receipt.code})`);
      const finish = (status: "rejected" | "failed" | "stopped", error_code: SpeakLifecycle["summary"]["error_code"]) => {
        const result = updateSpeakLifecycle(receipt.context, { status, generation_id: null,
          timing: { request_clock_id: null, first_player_start_ms: null, acoustic_first_audio_ms: null, ended_ms: null },
          summary: { generated_audio_ms: null, player_reported_played_ms: null, error_code }, played_spans: [] });
        if (result.kind === "failed") console.error(`[voicelayer] speak archive update failed: ${result.code}`);
      };
      if (residencyBusy()) { finish("rejected", "REJECTED"); return reject(residencyBusyReason()); }
      const reservation = reserveStandardVoiceOperation();
      if (!reservation) { finish("rejected", "REJECTED"); return reject("Voice session in progress"); }
      setTTSPreviewActive(true);
      return (async () => {
        let ack: AckEvent;
        let queued = false;
        try {
          const result = await speak(sample, {
            profile: command.profile, waitForPlayback: true, measurementOrigin: "preview",
            archiveContext: receipt.context, onPlaybackQueued: () => { queued = true; },
          });
          if (!result.playbackId && !result.engine) finish("rejected", "REJECTED");
          ack = buildAck(command, result.playbackId ? "accept" : "reject",
            result.playbackId ? undefined : "No preview audio was played");
        } catch (error) {
          if (!queued) finish(error instanceof SpeechPreparationStoppedError ? "stopped" : isSpeakerOutputRefusedError(error) ? "rejected" : "failed",
            error instanceof SpeechPreparationStoppedError ? null : isSpeakerOutputRefusedError(error) ? "REJECTED" : "OUTPUT_UNAVAILABLE");
          ack = buildAck(command, "reject", vocabularyErrorReason(error));
        } finally {
          setTTSPreviewActive(false);
          reservation.release();
        }
        return {...ack, tts_controls: readTTSControlsStatus()};
      })();
    }
    case "set_tts_setting":
      try {
        if ("profile" in command) setTTSProfile(command.profile, command);
        else setTTSSetting(command.key, command.value);
        return {...buildAck(command, "accept"), tts_controls: readTTSControlsStatus()};
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
    case "set_processing_setting":
      return handleProcessingSettingCommand(command);
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
    case "input_device_lost":
      // MICDROP3: evidence from VoiceBar's CoreAudio listener; it never ends the capture, it only
      // labels it when the audio after it is flat. A report for another or a finished capture is
      // stale and ignored. No ack: VoiceBar acts on nothing back.
      if (!reportInputDeviceLost(command.reason, command.capture_id)) {
        console.error(`[voicelayer] input_device_lost (${command.reason}, device ${command.device_id}) for capture ${command.capture_id} is not the live capture — ignored`);
      }
      return;
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

let polishTransitions: Promise<void> = Promise.resolve();

/** Resolves once every queued Polish on/off transition has finished (tests). */
export function polishTransitionsSettled(): Promise<void> {
  return polishTransitions;
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
    // The SAVED preference, not an env override: restoring the override would
    // write it into the file and lose the user's choice (#142 round 3).
    const previousEffort = getPersistedWhisperPerformanceEffort();
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
      try {
        restorePersistedWhisperPerformanceEffort(previousEffort);
      } catch (rollbackError) {
        return buildAck(
          command,
          "reject",
          `Effort change failed (${vocabularyErrorReason(error)}) and the saved effort ` +
            `could not be restored (${vocabularyErrorReason(rollbackError)})`,
        );
      }
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
    if (!reason && modelStatus.configured_effort !== command.effort) {
      // QA_VOICE_WHISPER_PERFORMANCE_EFFORT outranks the saved choice, so the
      // relaunched server runs the override: say that, not "not ours".
      reason = `Saved. QA_VOICE_WHISPER_PERFORMANCE_EFFORT=${modelStatus.configured_effort} ` +
        "overrides it, so the model uses that until the override is removed.";
    } else if (!reason && modelStatus.residency === "loaded" &&
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

/**
 * Settings → Models → Processing (P1). The toggle applies from the next
 * dictation. Rejected while busy (as effort is), so one transcription never
 * mixes settings, and when the environment sets the flag, because the file
 * could not change what the pipeline reads.
 */
function handleProcessingSettingCommand(
  command: Extract<SocketCommand, { cmd: "set_processing_setting" }>,
): AckEvent {
  if (residencyBusy() || residencyLoadPending || whisperLifecycleGate.isInUse) {
    const booking = isVoiceBooked();
    return buildAck(command, "reject", booking.booked && !booking.ownedByUs
      ? EXTERNAL_VOICE_SESSION_REASON : "busy");
  }
  const envVar = PROCESSING_ENV_VARS[command.key];
  if (process.env[envVar] !== undefined) {
    return buildAck(command, "reject", `set by ${envVar}`);
  }
  try {
    setProcessingSetting(command.key, command.value);
  } catch (error) {
    return buildAck(command, "reject", vocabularyErrorReason(error));
  }
  if (command.key === "model_polish") {
    // Off frees the local polish model (waiting for it to exit); either way the
    // server status is re-published. Transitions run one at a time, so a rapid
    // off → on never probes a server that is still shutting down (#146 round 2).
    const turnOn = command.value;
    polishTransitions = polishTransitions
      .then(async () => {
        if (!turnOn) await stopSTTPolishServerAndWait();
        await ensureSTTPolishServer(turnOn ? { forceRestart: true } : {});
      })
      .catch((error: unknown) => {
        console.error(`[voicelayer] polish server after toggle: ${vocabularyErrorReason(error)}`);
      });
  }
  return { ...buildAck(command, "accept"), polish_controls: readPolishControlsStatus() };
}

function vocabularyErrorReason(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function vocabularyCollisionReason(
  warnings: { code: string; existing: string }[] | undefined,
  submitted: string,
  mode: "alias" | "term",
): string | null {
  if (mode === "alias") {
    if (warnings?.some((warning) => warning.code === "same_as_canonical")) {
      return "Already the same as the term";
    }
    if (warnings?.some((warning) => warning.code === "duplicate_variant")) {
      return "Already listed as a misheard spelling";
    }
    const variantOwner = warnings?.find((warning) => warning.code === "dictionary_variant_collision");
    if (variantOwner) return `${submitted.trim()} is already a variant of ${variantOwner.existing}`;
  }
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
