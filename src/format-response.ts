/**
 * MCP tool response formatters.
 *
 * Produces compact, readable output using Unicode box-drawing characters.
 * Pure functions — no I/O, no side effects.
 */

import type { PlaybackOutcomeEvent } from "./socket-protocol";

// ── Box-drawing helpers ──

const TOP = "┌─";
const BOT = "└─";
const SEP = "│ ";

function boxed(title: string, lines: string[]): string {
  // Split multi-line strings to preserve box structure
  const body = lines
    .flatMap((l) => l.split("\n"))
    .map((l) => `${SEP}${l}`)
    .join("\n");
  return `${TOP} ${title}\n${body}\n${BOT}`;
}

// ── Speak ──

const MODE_ICONS: Record<string, string> = {
  announce: "🔊",
  brief: "📖",
  consult: "💬",
};

export function formatSpeak(
  mode: string,
  message: string,
  warning?: string,
  playbackId?: string,
): string {
  const icon = MODE_ICONS[mode] ?? "🔊";
  const lines = [`${icon} ${mode} → "${message}"`];

  if (mode === "consult") {
    lines.push("↳ Use voice_ask to collect voice input if needed.");
  }

  if (warning) {
    lines.push(`⚠ ${warning}`);
  }
  if (playbackId) {
    lines.push(`↳ playback ${playbackId}; outcome follows via MCP notification.`);
  }

  return boxed("voice_speak", lines);
}

// ── Ask ──

export function formatAsk(
  transcript: string | null,
  opts?: {
    timeoutSeconds?: number;
    pushToEnd?: boolean;
    outcome?: "timeout" | "no-speech" | "captured";
    recovery?: {
      archiveId: string;
      audioPath: string;
      reason?: string;
    };
    promptPlayback?: PlaybackOutcomeEvent;
  },
): string {
  const promptInterruption = formatPromptInterruption(opts?.promptPlayback);
  // Explicit null check to handle empty string "" as valid transcript
  if (transcript !== null && transcript !== undefined) {
    return boxed("voice_ask", [
      `🎤 "${transcript}"`,
      ...(promptInterruption ? [promptInterruption] : []),
    ]);
  }

  if (opts?.recovery) {
    const summary =
      opts.outcome === "no-speech"
        ? "🎙 No speech detected, but the captured audio was kept."
        : "🎙 Audio captured and kept; transcription did not complete.";
    return boxed("voice_ask", [
      summary,
      `↳ Archive: ${opts.recovery.archiveId}`,
      `↳ Audio: ${opts.recovery.audioPath}`,
      ...(opts.recovery.reason ? [`↳ Reason: ${opts.recovery.reason}`] : []),
      "↳ Re-transcribe from VoiceBar History; do not ask the user to repeat.",
      ...(promptInterruption ? [promptInterruption] : []),
    ]);
  }

  if (opts?.outcome === "no-speech") {
    return boxed("voice_ask", [
      "🎙 No speech detected — recording ended.",
      ...(promptInterruption ? [promptInterruption] : []),
    ]);
  }

  const secs = opts?.timeoutSeconds ?? 30;
  const pushToEnd = opts?.pushToEnd ?? false;
  const prefix = pushToEnd ? "push-to-end timeout" : "timeout";
  return boxed("voice_ask", [
    `⏱ No response — ${prefix} after ${secs}s`,
    ...(promptInterruption ? [promptInterruption] : []),
  ]);
}

function formatPromptInterruption(
  outcome: PlaybackOutcomeEvent | undefined,
): string | null {
  if (outcome?.status !== "interrupted") return null;
  const percent = Math.round(outcome.progress * 100);
  const wordPosition =
    outcome.word_index !== undefined && outcome.word_count
      ? ` at word ${outcome.word_index + 1}/${outcome.word_count}`
      : "";
  return `↳ Prompt interrupted${wordPosition} (${percent}%).`;
}

// ── Think ──

const THINK_ICONS: Record<string, string> = {
  insight: "💡",
  question: "❓",
  "red-flag": "🚩",
  "checklist-update": "✅",
};

export function formatThink(category: string, thought: string): string {
  const icon = THINK_ICONS[category] ?? "📝";
  return boxed("think", [`${icon} ${category}: ${thought}`]);
}

// ── Replay ──

export function formatReplay(index: number, text: string): string {
  return boxed("replay", [`▶ #${index} → "${text}"`]);
}

// ── Toggle ──

export function formatToggle(actions: string[]): string {
  if (actions.length === 0) {
    return boxed("toggle", ["(no changes)"]);
  }
  const lines = actions.map((a) => `• ${a}`);
  return boxed("toggle", lines);
}

// ── Error ──

export function formatError(tool: string, message: string): string {
  return boxed(`${tool} ✗`, [`${message}`]);
}

// ── Busy ──

export function formatBusy(
  sessionId: string,
  pid: number,
  startedAt: string,
): string {
  return boxed("voice_ask ✗", [
    `Line busy — session ${sessionId}`,
    `PID ${pid} since ${startedAt}`,
    "↳ Fall back to text input or wait.",
  ]);
}
