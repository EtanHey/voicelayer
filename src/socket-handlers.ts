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
import { getHistoryEntry, playAudioNonBlocking } from "./tts";
import { waitForInput } from "./input";
import { isVoiceBooked } from "./session-booking";
import { broadcast } from "./socket-server";
import type { SocketCommand } from "./socket-protocol";

export function handleSocketCommand(command: SocketCommand): void {
  switch (command.cmd) {
    case "stop":
    case "cancel":
      safeWriteFileSync(
        STOP_FILE,
        `${command.cmd} from voice-bar at ${new Date().toISOString()}`,
      );
      try {
        Bun.spawnSync(["pkill", "-f", "afplay"]);
      } catch {}
      break;
    case "replay": {
      const entry = getHistoryEntry(0);
      if (entry && existsSync(entry.file)) {
        broadcast({ type: "state", state: "idle" });
        broadcast({
          type: "state",
          state: "speaking",
          text: entry.text.slice(0, 200),
        });
        playAudioNonBlocking(entry.file);
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
  }
}
