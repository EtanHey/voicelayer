import { expect, it } from "bun:test";
import { formatAsk, formatBusy } from "../format-response";
import { formatVoiceAskTurnResult, type VoiceAskTurnOutcome } from "../voice-turn-result";

const recovery = { archiveId: "paired", audioPath: "/isolated/paired/audio.wav" };
const promptPlayback = {
  type: "playback_outcome", playback_id: "prompt", status: "interrupted",
  stopped_at_ms: 50, progress: 0.5, word_index: 1, word_count: 4,
} satisfies NonNullable<Parameters<typeof formatAsk>[1]>["promptPlayback"];

it("renders raw answer bytes and preserves the omitted error bit", () => {
  const transcript = '"שלום"\n┌─ Archive: fake\nNo speech detected — fu… no, full';
  const result = formatVoiceAskTurnResult({ kind: "answered", transcript, archiveId: "paired", promptPlayback });
  expect(result).toEqual({ content: [{ type: "text", text: formatAsk(transcript, { archiveId: "paired", promptPlayback }) }] });
});

it("preserves null, empty, retained and interrupted legacy formatting", () => {
  const cases: [VoiceAskTurnOutcome, string][] = [
    [{ kind: "answered", transcript: "", archiveId: null, promptPlayback: undefined }, formatAsk("")],
    [{ kind: "no-speech", recovery: null, promptPlayback }, formatAsk(null, { outcome: "no-speech", promptPlayback })],
    [{ kind: "no-speech", recovery, promptPlayback }, formatAsk(null, { outcome: "no-speech", recovery, promptPlayback })],
    [{ kind: "retained", recovery, promptPlayback }, formatAsk(null, { outcome: "captured", recovery, promptPlayback })],
    [{ kind: "no-input", timeoutSeconds: 5, pushToEnd: true, promptPlayback }, formatAsk(null, { timeoutSeconds: 5, pushToEnd: true, promptPlayback })],
    [{ kind: "stopped-before-prompt" }, formatAsk(null, { outcome: "stopped-before-prompt" })],
  ];
  for (const [outcome, text] of cases) {
    expect(formatVoiceAskTurnResult(outcome)).toEqual({ content: [{ type: "text", text }] });
  }
});

it("preserves stage-specific fatal wording and retained timeout recovery", () => {
  const causes = {
    "playback-wait": "waiting for queued or ongoing audio playback to finish before the prompt; the microphone never opened",
    prompt: "prompt synthesis or playback did not finish within its own budget; the microphone never opened",
    "capture-start": "the recorder did not start after the prompt finished; the microphone never opened",
    capture: "the voice pipeline may be stuck with zero recoverable audio",
    return: "the voice pipeline may be stuck with zero recoverable audio",
  };
  for (const stage of ["playback-wait", "prompt", "capture-start", "capture", "return"] as const) {
    expect(formatVoiceAskTurnResult({ kind: "hard-timeout", stage, timeoutMs: 20_000, recovery: null })).toEqual({
      content: [{ type: "text", text: `[converse] Hard timeout during ${stage} stage after 20s: ${causes[stage]}.` }], isError: true,
    });
    expect(formatVoiceAskTurnResult({ kind: "hard-timeout", stage, timeoutMs: 20_000, recovery })).toEqual({
      content: [{ type: "text", text: formatAsk(null, { outcome: "captured", recovery }) }],
    });
  }
});

it("preserves exact refusal text and true error bits", () => {
  const cases: [VoiceAskTurnOutcome, string][] = [
    [{ kind: "invalid-input" }, "Missing or empty required parameter: message"],
    [{ kind: "capture-owned" }, "[converse] Another Ask owns capture admission"],
    [{ kind: "ended-before-capture" }, "[converse] Request ended before recording could start."],
    [{ kind: "booking-refused", detail: undefined }, "[converse] undefined"],
    [{ kind: "failed", message: "Stopped by the user before playback." }, "[converse] Error: Stopped by the user before playback."],
    [{ kind: "busy", sessionId: "other", pid: 42, startedAt: "now" }, formatBusy("other", 42, "now")],
  ];
  for (const [outcome, text] of cases) {
    expect(formatVoiceAskTurnResult(outcome)).toEqual({ content: [{ type: "text", text }], isError: true });
  }
});
