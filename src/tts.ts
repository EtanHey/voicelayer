/**
 * TTS module — Python edge-tts CLI → platform audio player.
 *
 * Synthesizes speech via edge-tts (Python CLI), plays via afplay (macOS) or aplay (Linux).
 * Supports per-call rate override, auto-slowdown for long text,
 * and stop-signal monitoring during playback.
 */

import { existsSync, unlinkSync } from "fs";
import { platform } from "os";
import { STOP_FILE, ttsFilePath } from "./paths";

const VOICE = process.env.QA_VOICE_TTS_VOICE || "en-US-JennyNeural";
const DEFAULT_RATE = process.env.QA_VOICE_TTS_RATE || "+0%";
const STOP_POLL_MS = 300;

let ttsCounter = 0;

/** Get platform-appropriate audio player command. */
function getAudioPlayer(): string {
  return platform() === "darwin" ? "afplay" : "aplay";
}

/** Per-mode default rates. Announce is snappy, brief is slow for digestion. */
export const MODE_RATES: Record<string, string> = {
  announce: "+10%",
  brief: "-10%",
  consult: "+5%",
  converse: "+0%",
};

/**
 * Auto-adjust rate for long text. Subtracts percentage points for longer content.
 * Returns the adjusted rate string (e.g., "-10%" → "-20%" for 800-char text).
 */
function adjustRateForLength(baseRate: string, textLength: number): string {
  if (textLength < 300) return baseRate;

  const base = parseInt(baseRate, 10) || 0;
  let adjustment = 0;
  if (textLength >= 1000) adjustment = -15;
  else if (textLength >= 600) adjustment = -10;
  else adjustment = -5;

  const final = base + adjustment;
  return `${final >= 0 ? "+" : ""}${final}%`;
}

/**
 * Speak text aloud via edge-tts (Python) → afplay.
 *
 * @param text - Text to speak
 * @param options.rate - Rate override (e.g., "-10%", "+5%"). If omitted, uses DEFAULT_RATE.
 * @param options.mode - Voice mode name for auto-rate selection (announce/brief/consult/converse).
 */
export async function speak(
  text: string,
  options?: { rate?: string; mode?: string },
): Promise<void> {
  if (!text?.trim()) return;

  // Determine rate: explicit > mode default > env default
  let rate = options?.rate
    ?? (options?.mode ? MODE_RATES[options.mode] : undefined)
    ?? DEFAULT_RATE;

  // Auto-slow for long text
  rate = adjustRateForLength(rate, text.length);

  const ttsFile = ttsFilePath(process.pid, ttsCounter++);

  try {
    // Generate speech via Python edge-tts CLI
    const synth = Bun.spawn([
      "python3", "-m", "edge_tts",
      "--text", text,
      "--voice", VOICE,
      "--rate", rate,
      "--write-media", ttsFile,
    ]);
    const synthExit = await synth.exited;
    if (synthExit !== 0) {
      throw new Error(`edge-tts failed with exit code ${synthExit}. Is edge-tts installed? Run: pip3 install edge-tts`);
    }

    // Play audio — monitor stop signal so user can interrupt
    const play = Bun.spawn([getAudioPlayer(), ttsFile]);

    // Poll for stop signal during playback — clean up signal file after kill
    let stoppedByUser = false;
    const stopPoll = setInterval(() => {
      if (existsSync(STOP_FILE)) {
        stoppedByUser = true;
        play.kill("SIGTERM");
        clearInterval(stopPoll);
        try { unlinkSync(STOP_FILE); } catch {}
      }
    }, STOP_POLL_MS);

    try {
      const playExit = await play.exited;
      // Non-zero exit is expected when user stops playback via signal
      if (playExit !== 0 && !stoppedByUser) {
        throw new Error(`Audio playback failed with exit code ${playExit}. Player: ${getAudioPlayer()}`);
      }
    } finally {
      clearInterval(stopPoll);
    }
  } finally {
    try {
      unlinkSync(ttsFile);
    } catch {}
  }
}
