import type { VoiceToolContext } from "./mcp-notifications";

export const STILL_AWAY = "Still no answer. Do not make another voice call; continue as if the user is away.";
type Session = { generation: number; phase: "ready" | "follow-up" | "away" };
const sessions = new WeakMap<object, Session>();
let presenceGeneration = 0;

/** Real speech or a new VoiceBar recording is evidence the user has returned. */
export function userVoicePresent(): void { presenceGeneration++; }

function session(context?: VoiceToolContext): Session | undefined {
  if (!context) return; // Internal callers without an MCP session keep their contract.
  const key = context.disconnectSignal ?? context;
  let state = sessions.get(key);
  if (!state || state.generation !== presenceGeneration) {
    state = { generation: presenceGeneration, phase: "ready" };
    sessions.set(key, state);
  }
  return state;
}

/** Consume the one follow-up before either tool can speak or open the microphone. */
export function claimVoiceCall(context?: VoiceToolContext): boolean {
  const state = session(context);
  if (state?.phase === "away") return false;
  if (state?.phase === "follow-up") state.phase = "away";
  return true;
}

export function recordNoAnswer(context?: VoiceToolContext): boolean {
  const state = session(context);
  if (!state) return true;
  if (state.phase === "away") return false;
  state.phase = "follow-up";
  return true;
}
