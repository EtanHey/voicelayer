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
import { getHistoryEntry, playAudioNonBlocking, stopPlayback } from "./tts";
import {
  waitForInput,
  transcribeExternalVoiceBarWav,
  finalizeExternalVoiceBarTranscript,
  hasRetainedRecording,
  retranscribeLastCapture,
  retranscribeRecordingCapture,
} from "./input";
import {
  bookVoiceSession,
  isVoiceBooked,
  setCancelSignal,
} from "./session-booking";
import { broadcast } from "./socket-client";
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
  listVocabulary,
  removeAlias,
  removePromptTerm,
} from "./stt-vocabulary-store";
import {
  getEffectiveRecordingState,
  isRecordingConflictError,
  setRecordingState,
} from "./recording-state";
import {
  restartWhisperServerForPerformanceChange,
  setWhisperPerformanceEffort,
} from "./whisper-performance";
import type { SilenceMode } from "./vad";
import {
  AndroidApplianceBridge,
  resolveAndroidApplianceConfig,
  type AndroidResultEvent,
  type AndroidTranscript,
} from "./android-bridge";

interface ActiveAndroidRecording {
  bridge: AndroidApplianceBridge;
  sessionId: string;
  silenceMode: SilenceMode;
  pressToTalk: boolean;
  lastResultSeq: number;
}

let activeAndroidRecording: ActiveAndroidRecording | null = null;

export function handleSocketCommand(
  command: SocketCommand,
): SocketResponse | void {
  const recordingState = getRecordingState();
  const playbackQueueDepth = getPlaybackQueueDepth();
  const isSpeaking = recordingState === "idle" && playbackQueueDepth > 0;

  switch (command.cmd) {
    case "stop":
      if (activeAndroidRecording) {
        const active = activeAndroidRecording;
        activeAndroidRecording = null;
        stopAndroidRecording(active).catch((err) => {
          console.error(
            `[voicelayer] Android appliance stop failed: ${
              err instanceof Error ? err.message : String(err)
            }`,
          );
          setRecordingState("idle");
          broadcast({
            type: "error",
            message: `Android VoiceLayer stop failed: ${
              err instanceof Error ? err.message : String(err)
            }`,
            recoverable: true,
            show_during_bar_recording: true,
          });
          broadcast({ type: "state", state: "idle", source: "android" });
        });
        stopPlayback();
        return buildAck(command, "accept");
      }
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
      stopPlayback();
      return buildAck(command, "accept");
    case "cancel":
      if (activeAndroidRecording) {
        const active = activeAndroidRecording;
        activeAndroidRecording = null;
        cancelAndroidRecording(active).catch((err) => {
          console.error(
            `[voicelayer] Android appliance cancel failed: ${
              err instanceof Error ? err.message : String(err)
            }`,
          );
        });
        setRecordingState("idle");
        broadcast({ type: "state", state: "idle" });
        stopPlayback();
        return buildAck(command, "accept");
      }
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
      stopPlayback();
      return buildAck(command, "accept");
    case "replay": {
      if (recordingState === "recording" || recordingState === "transcribing") {
        return buildAck(command, "reject", "busy");
      }
      const entry = getHistoryEntry(0);
      if (entry && existsSync(entry.file)) {
        if (isSpeaking) {
          stopPlayback();
        }
        try {
          playAudioNonBlocking(entry.file, {
            text: entry.text.slice(0, 2000),
            voice: entry.voice,
            // Idle forces VoiceBar remount for same-text replay, but the queue
            // must emit it only after the speaker gate accepts playback.
            preStartIdle: true,
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
      startAndroidOrLocalRecording(
        timeoutMs,
        silenceMode,
        ptt,
        command.input_source,
      );
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
      return buildHealthResponse({
        queueDepth: playbackQueueDepth,
        recordingState,
      });
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
      if (recordingState === "recording" || recordingState === "transcribing") {
        return buildAck(command, "reject", "busy");
      }
      try {
        setWhisperPerformanceEffort(command.effort);
        restartWhisperServerForPerformanceChange();
        return buildAck(command, "accept");
      } catch (error) {
        return buildAck(command, "reject", vocabularyErrorReason(error));
      }
  }
}

function startLocalVoiceBarRecording(
  timeoutMs: number,
  silenceMode: SilenceMode,
  pressToTalk: boolean,
): void {
  waitForInput(timeoutMs, silenceMode, pressToTalk, {
    archiveSource: "voicebar",
  }).catch((err) => {
    console.error(
      `[voicelayer] Bar-initiated recording failed: ${
        err instanceof Error ? err.message : String(err)
      }`,
    );
    if (
      !isRecordingConflictError(err) &&
      getEffectiveRecordingState() === "idle"
    ) {
      broadcast({ type: "state", state: "idle", source: "recording" });
    }
  });
}

function startAndroidOrLocalRecording(
  timeoutMs: number,
  silenceMode: SilenceMode,
  pressToTalk: boolean,
  inputSource: "default" | "local" | "android" | undefined,
): void {
  const config = resolveAndroidApplianceConfig();
  const wantsAndroid = inputSource === "android" || config.enabled;
  if (!wantsAndroid || inputSource === "local") {
    startLocalVoiceBarRecording(timeoutMs, silenceMode, pressToTalk);
    return;
  }

  if (!config.enabled && inputSource === "android") {
    rejectAndroidRecording("disabled");
    return;
  }

  const bridge = new AndroidApplianceBridge({
    baseUrl: config.baseUrl,
    timeoutMs: config.timeoutMs,
  });
  bridge
    .startRecording({ timeoutMs, pressToTalk })
    .then((result) => {
      if (!result.ok) {
        console.error(
          `[voicelayer] Android appliance unavailable (${result.reason})`,
        );
        rejectAndroidRecording(result.reason);
        return;
      }
      activeAndroidRecording = {
        bridge,
        sessionId: result.sessionId,
        silenceMode,
        pressToTalk,
        lastResultSeq: 0,
      };
      setRecordingState("recording");
      broadcast({
        type: "state",
        state: "recording",
        mode: pressToTalk ? "ptt" : "vad",
        source: "android",
        session_id: result.sessionId,
      });
      broadcast({
        type: "transcription_status",
        status: "recording",
        message: "Phone recording",
        source: "android",
        session_id: result.sessionId,
      });
    })
    .catch((err) => {
      console.error(
        `[voicelayer] Android appliance start failed (${
          err instanceof Error ? err.message : String(err)
        })`,
      );
      rejectAndroidRecording("network");
    });
}

function rejectAndroidRecording(reason: string): void {
  setRecordingState("idle");
  broadcast({
    type: "error",
    message: `Android VoiceLayer unavailable: ${reason}`,
    recoverable: true,
    show_during_bar_recording: true,
  });
  broadcast({ type: "state", state: "idle", source: "android" });
}

async function stopAndroidRecording(
  active: ActiveAndroidRecording,
): Promise<void> {
  const stopped = await active.bridge.stopRecording(active.sessionId);
  if (!stopped.ok) {
    throw new Error(`stop failed: ${stopped.reason}`);
  }
  let transcript = finalTranscriptText(stopped.transcript);
  const result = await active.bridge.getResult(
    active.sessionId,
    active.lastResultSeq,
  );
  if (result.ok) {
    active.lastResultSeq = result.seq;
    forwardAndroidEvents(result.events, active.sessionId);
    transcript = transcript ?? finalTranscriptText(result.transcript);
  }
  const audio = await active.bridge.pullAudio(active.sessionId);
  if (!audio.ok) {
    if (transcript) {
      await finalizeExternalVoiceBarTranscript(transcript, {
        silenceMode: active.silenceMode,
        pressToTalk: active.pressToTalk,
        applianceTranscript: transcript,
        androidSessionId: active.sessionId,
      });
      return;
    }
    if (process.env.QA_VOICE_ANDROID_ALLOW_LOCAL_FALLBACK !== "1") {
      throw new Error("phone transcript missing");
    }
    throw new Error(`pull_audio failed: ${audio.reason}`);
  }
  await transcribeExternalVoiceBarWav(audio.bytes, {
    silenceMode: active.silenceMode,
    pressToTalk: active.pressToTalk,
    applianceTranscript: transcript,
    androidSessionId: active.sessionId,
  });
}

async function cancelAndroidRecording(
  active: ActiveAndroidRecording,
): Promise<void> {
  const cancelled = await active.bridge.cancelRecording(active.sessionId);
  if (!cancelled.ok) {
    throw new Error(`cancel failed: ${cancelled.reason}`);
  }
}

function finalTranscriptText(transcript: AndroidTranscript | null | undefined): string | null {
  if (!transcript || transcript.partial) return null;
  const polished = transcript.polishedText?.trim();
  if (polished) return polished;
  const text = transcript.text.trim();
  return text.length > 0 ? text : null;
}

function forwardAndroidEvents(
  events: AndroidResultEvent[],
  sessionId: string,
): void {
  for (const event of events) {
    if (event.type === "transcription_status") {
      broadcast({
        type: "transcription_status",
        status:
          event.status === "recording" ||
          event.status === "stopping" ||
          event.status === "ready" ||
          event.status === "transcribing"
            ? event.status
            : "recording",
        message: event.message ?? "Phone recording",
        source: "android",
        session_id: sessionId,
      });
    } else if (event.type === "transcription" && event.text) {
      broadcast({
        type: "transcription",
        text: event.polishedText?.trim() || event.text,
        partial: event.partial,
        source: "android",
        session_id: sessionId,
      });
    }
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
