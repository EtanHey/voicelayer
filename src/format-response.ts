/**
 * MCP tool response formatters.
 *
 * Produces compact, readable output using Unicode box-drawing characters.
 * Pure functions — no I/O, no side effects.
 */

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
): string {
  const icon = MODE_ICONS[mode] ?? "🔊";
  const lines = [`${icon} ${mode} → "${message}"`];

  if (mode === "consult") {
    lines.push("↳ Use voice_ask to collect voice input if needed.");
  }

  if (warning) {
    lines.push(`⚠ ${warning}`);
  }

  return boxed("voice_speak", lines);
}

// ── Ask ──

export function formatAsk(
  transcript: string | null,
  opts?: { timeoutSeconds?: number; pressToTalk?: boolean },
): string {
  // Explicit null check to handle empty string "" as valid transcript
  if (transcript !== null && transcript !== undefined) {
    return boxed("voice_ask", [`🎤 "${transcript}"`]);
  }

  const secs = opts?.timeoutSeconds ?? 30;
  const ptt = opts?.pressToTalk ?? false;
  const prefix = ptt ? "PTT timeout" : "timeout";
  return boxed("voice_ask", [`⏱ No response — ${prefix} after ${secs}s`]);
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
