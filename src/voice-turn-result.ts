import { formatAsk, formatBusy } from "./format-response";
import type { PlaybackOutcomeEvent } from "./socket-protocol";

export type VoiceAskTimeoutStage = "playback-wait" | "prompt" | "capture-start" | "capture" | "return";
type Recovery = NonNullable<NonNullable<Parameters<typeof formatAsk>[1]>["recovery"]>;
type PromptPlayback = PlaybackOutcomeEvent | undefined;
export type VoiceAskTurnOutcome =
  | { kind: "answered"; transcript: string; archiveId: string | null; promptPlayback: PromptPlayback }
  | { kind: "no-speech"; recovery: Recovery | null; promptPlayback: PromptPlayback }
  | { kind: "retained"; recovery: Recovery; promptPlayback: PromptPlayback }
  | { kind: "no-input"; timeoutSeconds: number; pushToEnd: boolean; promptPlayback: PromptPlayback }
  | { kind: "hard-timeout"; stage: VoiceAskTimeoutStage; timeoutMs: number; recovery: Recovery | null }
  | { kind: "stopped-before-prompt" }
  | { kind: "ended-before-capture" }
  | { kind: "invalid-input" }
  | { kind: "capture-owned" }
  | { kind: "busy"; sessionId: string; pid: number; startedAt: string }
  | { kind: "booking-refused"; detail: string | undefined }
  | { kind: "failed"; message: string };

export type McpTextResult = {
  content: { type: "text"; text: string }[];
  isError?: boolean;
};

export function formatVoiceAskTurnResult(outcome: VoiceAskTurnOutcome): McpTextResult {
  const textResult = (text: string, isError = false): McpTextResult => ({
    content: [{ type: "text", text }],
    ...(isError && { isError }),
  });
  switch (outcome.kind) {
    case "answered":
      return textResult(formatAsk(outcome.transcript, {
        ...(outcome.archiveId ? { archiveId: outcome.archiveId } : {}),
        promptPlayback: outcome.promptPlayback,
      }));
    case "no-speech":
      return textResult(formatAsk(null, {
        outcome: "no-speech", ...(outcome.recovery ? { recovery: outcome.recovery } : {}),
        promptPlayback: outcome.promptPlayback,
      }));
    case "retained":
      return textResult(formatAsk(null, { outcome: "captured", recovery: outcome.recovery, promptPlayback: outcome.promptPlayback }));
    case "no-input":
      return textResult(formatAsk(null, outcome));
    case "hard-timeout": {
      if (outcome.recovery) return textResult(formatAsk(null, { outcome: "captured", recovery: outcome.recovery }));
      const cause = outcome.stage === "playback-wait"
        ? "waiting for queued or ongoing audio playback to finish before the prompt; the microphone never opened"
        : outcome.stage === "prompt"
          ? "prompt synthesis or playback did not finish within its own budget; the microphone never opened"
          : outcome.stage === "capture-start"
            ? "the recorder did not start after the prompt finished; the microphone never opened"
            : "the voice pipeline may be stuck with zero recoverable audio";
      return textResult(`[converse] Hard timeout during ${outcome.stage} stage after ${Math.round(outcome.timeoutMs / 1000)}s: ${cause}.`, true);
    }
    case "stopped-before-prompt":
      return textResult(formatAsk(null, { outcome: "stopped-before-prompt" }));
    case "ended-before-capture":
      return textResult("[converse] Request ended before recording could start.", true);
    case "invalid-input":
      return textResult("Missing or empty required parameter: message", true);
    case "capture-owned":
      return textResult("[converse] Another Ask owns capture admission", true);
    case "busy":
      return textResult(formatBusy(outcome.sessionId, outcome.pid, outcome.startedAt), true);
    case "booking-refused":
      return textResult(`[converse] ${outcome.detail}`, true);
    case "failed":
      return textResult(`[converse] Error: ${outcome.message}`, true);
    default: {
      const exhaustive: never = outcome;
      return exhaustive;
    }
  }
}
