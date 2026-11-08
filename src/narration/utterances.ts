/**
 * Lane B (2.4): bounded utterances with pauses for voice_ask narration (dictation lead, 2026-11-08, from
 * w4's controlled renders: one whole request ran 173-195 words per minute; bounded utterances with pauses
 * ran 158-170, the calmer arm every time, and it is the NarrationLayer planning direction Etan wants).
 *
 * The planner never drops, adds or reorders a word: joining the utterances gives back the text's words.
 */
import type { WordBoundary } from "../socket-protocol";
import type { NarrationAudio, NarrationRequest, NarrationSource } from "./source";

export interface UtterancePolicy {
  /** Hard cap on words per synthesis request. */
  maxWords: number;
  /** Silence after a sentence end (. ! ? …). */
  sentencePauseMs: number;
  /** Silence after a clause break (, ; : and dashes) or a hard split. */
  clausePauseMs: number;
}

/** w4's bounded arm: at most 14 words, 0.55 s sentence pauses, 0.25 s clause pauses. */
export const ASK_UTTERANCE_POLICY: UtterancePolicy = { maxWords: 14, sentencePauseMs: 550, clausePauseMs: 250 };

export interface PlannedUtterance {
  text: string;
  /** Silence to insert after this utterance (0 after the last). */
  pauseAfterMs: number;
}

const SENTENCE_END = /[.!?…]["'”’)\]]*$/;
const CLAUSE_END = /[,;:—–]["'”’)\]]*$|\s[-–—]$/;

export function planUtterances(text: string, policy: UtterancePolicy = ASK_UTTERANCE_POLICY): PlannedUtterance[] {
  const words = text.split(/\s+/).filter(Boolean);
  if (words.length === 0) return [];
  const planned: PlannedUtterance[] = [];
  let current: string[] = [];
  const flush = (pause: number) => {
    if (current.length) planned.push({ text: current.join(" "), pauseAfterMs: pause });
    current = [];
  };
  // Greedy: end an utterance at a sentence end; otherwise at the last clause break before the cap; else at the cap.
  let lastClause = -1;
  for (const word of words) {
    current.push(word);
    if (SENTENCE_END.test(word)) { flush(policy.sentencePauseMs); lastClause = -1; continue; }
    if (CLAUSE_END.test(word)) lastClause = current.length;
    if (current.length >= policy.maxWords) {
      if (lastClause > 0 && lastClause < current.length) {
        const rest = current.slice(lastClause);
        current = current.slice(0, lastClause);
        flush(policy.clausePauseMs);
        current = rest;
      } else {
        flush(policy.clausePauseMs);
      }
      lastClause = -1;
    }
  }
  flush(0);
  planned[planned.length - 1] = { ...planned[planned.length - 1], pauseAfterMs: 0 };
  return planned;
}

/** Joins the parts into one file: utterance audio and silences, in order. */
export type AssembleNarration = (parts: Array<{ file: string } | { silenceMs: number }>, outFile: string,
  signal?: AbortSignal) => Promise<void>;

export interface BoundedNarrationDeps {
  source: NarrationSource;
  assemble: AssembleNarration;
  /** Measures a file the source could not time (cloned voices). */
  probeMs(file: string): number;
  dispose(file: string): void;
}

/**
 * Synthesizes `request.text` as bounded utterances with pauses through the one NarrationSource and assembles
 * them into `request.outFile`, with word timings offset onto the assembled clock. One utterance is a plain
 * request (no assembly). Null when the engine family is unavailable, exactly like the source.
 */
export async function synthesizeBounded(request: NarrationRequest, deps: BoundedNarrationDeps,
  policy: UtterancePolicy = ASK_UTTERANCE_POLICY): Promise<NarrationAudio | null> {
  const plan = planUtterances(request.text, policy);
  if (plan.length <= 1) return deps.source.synthesize(request);
  const files: string[] = [];
  try {
    const parts: Array<{ file: string } | { silenceMs: number }> = [];
    const wordBoundaries: WordBoundary[] = [];
    let offset = 0;
    let engine = "";
    let voice = request.voice;
    for (const [index, utterance] of plan.entries()) {
      const outFile = request.outFile.replace(/(\.[a-z0-9]+)?$/i, `.u${index}$1`);
      files.push(outFile);
      const audio = await deps.source.synthesize({ ...request, text: utterance.text, outFile });
      if (!audio) return null;
      engine ||= audio.engine;
      voice = audio.voice;
      const duration = audio.durationMs > 0 ? audio.durationMs : deps.probeMs(audio.audioFile);
      for (const word of audio.wordBoundaries) wordBoundaries.push({ ...word, offset_ms: word.offset_ms + offset });
      parts.push({ file: audio.audioFile });
      offset += duration;
      if (utterance.pauseAfterMs > 0) { parts.push({ silenceMs: utterance.pauseAfterMs }); offset += utterance.pauseAfterMs; }
    }
    await deps.assemble(parts, request.outFile, request.signal);
    return { audioFile: request.outFile, durationMs: Math.round(offset), wordBoundaries, engine, voice };
  } finally {
    for (const file of files) { try { deps.dispose(file); } catch {} }
  }
}
