import type { z } from "zod";
import { VoiceAskSchema, type VoiceAskInput } from "./schemas/mcp-inputs";
import type { McpTextResult } from "./voice-turn-result";

export type NormalAskRequest = Extract<z.input<typeof VoiceAskSchema>, { message: string }>;
export type NormalAsk = Extract<VoiceAskInput, { message: string }>;
export type RetranscriptionAsk = Extract<VoiceAskInput, { retranscribe_archive_id: string }>;
export type VoiceAskRefusalReason =
  | "missing-arguments" | "invalid-mode" | "raw-input-limit"
  | "input-archive-unavailable" | "prompt-limit" | "archive-operation";
export type VoiceAskRefusal = {
  kind: "refused";
  reason: VoiceAskRefusalReason;
  result: McpTextResult;
};
export type VoiceAskIngress =
  | VoiceAskRefusal
  | { kind: "normal"; input: NormalAsk; originalMessage: string; legacyPressToTalk: boolean }
  | { kind: "retranscribe"; input: RetranscriptionAsk };

export function parseVoiceAskIngress(args: unknown): VoiceAskIngress {
  if (!args || typeof args !== "object") {
    return { kind: "refused", reason: "missing-arguments",
      result: { content: [{ type: "text", text: "Missing arguments" }], isError: true } };
  }
  const a: object & { message?: unknown } = args;
  const originalMessage = typeof a.message === "string" ? a.message : "";
  const parsed = VoiceAskSchema.safeParse(args);
  if (!parsed.success) {
    return { kind: "refused", reason: "invalid-mode", result: {
      content: [{ type: "text", text: "Invalid voice_ask arguments: provide exactly one mode — {message: ...} or {retranscribe_archive_id: ...}." }],
      isError: true,
    } };
  }
  const input = parsed.data;
  if (typeof input.retranscribe_archive_id === "string") {
    return { kind: "retranscribe", input };
  }
  return { kind: "normal", input, originalMessage,
    legacyPressToTalk: Object.prototype.hasOwnProperty.call(args, "press_to_talk") };
}
