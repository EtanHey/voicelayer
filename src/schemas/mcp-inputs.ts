/**
 * Zod schemas for all MCP tool inputs.
 *
 * AIDEV-NOTE: Single source of truth for both runtime validation and TypeScript types.
 * All MCP tool handlers use these schemas instead of hand-rolled validation.
 * Use z.infer<typeof Schema> to derive types.
 */

import { z } from "zod";

// --- Shared refinements ---

/** Non-empty trimmed string. */
const nonEmptyTrimmed = z.string().trim().min(1);

/** Speech rate pattern: +10%, -5%, etc. */
const ratePattern = z.string().regex(/^[+-]\d+%$/);

/** Silence mode enum. */
const silenceModeEnum = z.enum(["quick", "standard", "thoughtful"]);

/** Toggle scope enum. */
const scopeEnum = z.enum(["all", "tts", "mic"]);

/** Think category enum. */
const thinkCategoryEnum = z.enum([
  "insight",
  "question",
  "red-flag",
  "checklist-update",
]);

// --- Tool input schemas ---

/** voice_speak tool input. */
export const VoiceSpeakSchema = z.object({
  message: nonEmptyTrimmed,
  mode: z.enum(["announce", "brief", "consult", "think", "auto"]).optional(),
  voice: z.string().optional(),
  rate: ratePattern.optional(),
  category: thinkCategoryEnum.optional(),
  replay_index: z.number().int().min(0).max(19).optional(),
  enabled: z.boolean().optional(),
  scope: scopeEnum.optional(),
});

/** voice_ask tool input. */
export const VoiceAskSchema = z.object({
  message: nonEmptyTrimmed,
  timeout_seconds: z.number().min(10).max(3600).default(300),
  silence_mode: silenceModeEnum.optional(),
  press_to_talk: z.boolean().optional(),
});

/** qa_voice_announce / qa_voice_say args. */
export const AnnounceArgsSchema = z.object({
  message: nonEmptyTrimmed,
  rate: ratePattern.optional(),
  voice: z.string().optional(),
});

/** qa_voice_brief args. */
export const BriefArgsSchema = z.object({
  message: nonEmptyTrimmed,
  rate: ratePattern.optional(),
  voice: z.string().optional(),
});

/** qa_voice_consult args. */
export const ConsultArgsSchema = z.object({
  message: nonEmptyTrimmed,
  rate: ratePattern.optional(),
  voice: z.string().optional(),
});

/** qa_voice_converse / qa_voice_ask args. */
export const ConverseArgsSchema = z.object({
  message: nonEmptyTrimmed,
  timeout_seconds: z.number().min(10).max(3600).default(300),
  silence_mode: silenceModeEnum.optional(),
  press_to_talk: z.boolean().optional(),
  voice: z.string().optional(),
});

/** qa_voice_think args. */
export const ThinkArgsSchema = z.object({
  thought: nonEmptyTrimmed,
  category: thinkCategoryEnum.default("insight"),
});

/** qa_voice_replay args. */
export const ReplayArgsSchema = z.object({
  index: z.number().int().min(0).max(19).default(0),
});

/** qa_voice_toggle args. */
export const ToggleArgsSchema = z.object({
  enabled: z.boolean(),
  scope: scopeEnum.default("all"),
});

// --- Inferred types ---

export type VoiceSpeakInput = z.infer<typeof VoiceSpeakSchema>;
export type VoiceAskInput = z.infer<typeof VoiceAskSchema>;
export type AnnounceArgs = z.infer<typeof AnnounceArgsSchema>;
export type BriefArgs = z.infer<typeof BriefArgsSchema>;
export type ConsultArgs = z.infer<typeof ConsultArgsSchema>;
export type ConverseArgs = z.infer<typeof ConverseArgsSchema>;
export type ThinkArgs = z.infer<typeof ThinkArgsSchema>;
export type ReplayArgs = z.infer<typeof ReplayArgsSchema>;
export type ToggleArgs = z.infer<typeof ToggleArgsSchema>;
