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
import { waitForInput } from "./input";
import { isVoiceBooked, setCancelSignal } from "./session-booking";
import { broadcast } from "./socket-client";
import type { HealthResponse, SocketCommand } from "./socket-protocol";
import { buildHealthResponse } from "./daemon-health";
import { getPlaybackQueueDepth } from "./tts";
import { getRecordingState } from "./input";

export function handleSocketCommand(
  command: SocketCommand,
): HealthResponse | void {
  switch (command.cmd) {
    case "stop":
      safeWriteFileSync(
        STOP_FILE,
        `stop from voice-bar at ${new Date().toISOString()}`,
      );
      // AIDEV-NOTE: Must call stopPlayback() — not just pkill — to reset
      // playbackQueue and queueSize. Otherwise queued items resume after kill.
      stopPlayback();
      break;
    case "cancel":
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
      break;
    case "replay": {
      const entry = getHistoryEntry(0);
      if (entry && existsSync(entry.file)) {
        // Idle forces VoiceBar remount for same-text replay
        broadcast({ type: "state", state: "idle" });
        playAudioNonBlocking(entry.file, {
          text: entry.text.slice(0, 2000),
          voice: entry.voice,
        });
      }
      break;
    }
    case "record": {
      if (existsSync(VOICE_DISABLED_FILE) || existsSync(MIC_DISABLED_FILE)) {
        broadcast({
          type: "error",
          message: "Mic is disabled",
          recoverable: false,
        });
        break;
      }
      // H5 fix: check session booking to prevent concurrent recordings
      const booking = isVoiceBooked();
      if (booking.booked && !booking.ownedByUs) {
        broadcast({
          type: "error",
          message: `Line is busy — voice session owned by ${booking.owner?.sessionId ?? "unknown"}`,
          recoverable: true,
        });
        break;
      }
      const timeoutMs = (command.timeout_seconds ?? 30) * 1000;
      const silenceMode = command.silence_mode ?? "standard";
      const ptt = command.press_to_talk ?? false;
      waitForInput(timeoutMs, silenceMode, ptt).catch((err) => {
        console.error(
          `[voicelayer] Bar-initiated recording failed: ${err instanceof Error ? err.message : String(err)}`,
        );
        broadcast({ type: "state", state: "idle" });
      });
      break;
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
      break;
    }
    case "health":
      return buildHealthResponse({
        queueDepth: getPlaybackQueueDepth(),
        recordingState: getRecordingState(),
      });
    case "command":
      broadcast({
        type: "command_mode",
        phase: "applying",
        operation: command.operation,
        replacement_text: command.text,
        prompt: command.prompt,
      });
      break;
    case "mark_clip":
      broadcast({
        type: "clip_marker",
        marker_id: `command-${command.label.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")}`,
        label: command.label,
        source: command.source ?? "command",
        status: "marked",
      });
      break;
  }
}
