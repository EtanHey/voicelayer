import { z } from "zod";
export const speechStates = ["requested", "preparing", "playing", "paused", "completed", "stopped", "cancelled", "failed", "interrupted"] as const;
export type SpeechState = typeof speechStates[number];
export const legalSpeechTransitions: Record<SpeechState, readonly SpeechState[]> = {
  requested: ["preparing", "stopped", "cancelled", "failed", "interrupted"],
  preparing: ["playing", "paused", "stopped", "cancelled", "failed", "interrupted"],
  playing: ["paused", "completed", "stopped", "cancelled", "failed", "interrupted"],
  paused: ["playing", "stopped", "cancelled", "failed", "interrupted"],
  completed: [], stopped: [], cancelled: [], failed: [], interrupted: [],
};
export const speechReasons = ["PROCESS_RESTART", "PROCESS_EXIT", "REJECTED", "SYNTH_FAILED", "PLAYER_FAILED", "OUTPUT_UNAVAILABLE", "ARCHIVE_INCOMPLETE", "SPEECH_FAILED", "USER_STOP", "USER_STOP_PREPARING", "USER_CANCEL", "QUEUE_CLEARED", "PLAYBACK_COMPLETED", "REPLACED"] as const;
export const speechReasonSchema = z.enum(speechReasons).nullable();
export const speechSchema = z.object({
  state: z.enum(speechStates), reason: speechReasonSchema, played_ms: z.number().nonnegative(),
  playing_since: z.string().datetime().nullable(),
  transitions: z.array(z.object({ from: z.enum(speechStates), to: z.enum(speechStates), at: z.string().datetime(), reason: speechReasonSchema })),
  generated: z.array(z.object({ index: z.number().int().nonnegative(), text: z.string(), audio_path: z.string(),
    voice: z.string(), profile: z.string(), engine: z.string(), generated_at: z.string().datetime() })),
});
export type SpeechRecord = z.infer<typeof speechSchema>;
export function initialSpeech(): SpeechRecord {
  return { state: "requested", reason: null, played_ms: 0, playing_since: null, transitions: [], generated: [] };
}
/** The sole speech transition function, shared by live writing and restart recovery. */
export function transitionSpeech(record: SpeechRecord, to: SpeechState, reason: string | null, at: string): SpeechRecord | null {
  const code = speechReasonSchema.parse(reason);
  if (!legalSpeechTransitions[record.state].includes(to)) {
    console.error(`[speech] illegal transition ${record.state} -> ${to}`);
    return null;
  }
  const elapsed = record.playing_since === null ? 0 : Math.max(0, Date.parse(at) - Date.parse(record.playing_since));
  return { ...record, state: to, reason: code, played_ms: record.played_ms + elapsed,
    playing_since: to === "playing" ? at : null,
    transitions: [...record.transitions, { from: record.state, to, at, reason: code }] };
}
