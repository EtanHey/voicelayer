/**
 * Lane B (2.4): the default NarrationSource, today's engines behind the contract.
 * edge-tts for preset voices; synthesizeCloned (Qwen3 daemon, XTTS profiles) for cloned voices.
 * The engine functions are injected by tts.ts so this adapter owns no process or file policy.
 */
import { writeFileSync } from "fs";
import type { WordBoundary } from "../socket-protocol";
import type { NarrationAudio, NarrationProsody, NarrationRequest, NarrationSource } from "./source";
import type { AssembleNarration } from "./utterances";

/**
 * The MP3 bitrate each narration family writes for one utterance. A one-piece ask keeps the engine's file as
 * written; a multi-utterance ask re-encodes its joined file at the same bitrate, so both paths carry one encoding.
 * - edge: edge-tts requests `audio-24khz-48kbitrate-mono-mp3` (edge_tts/communicate.py).
 * - clone: the Qwen3 daemon writes MP3 through mlx-audio → ffmpeg with the default `-b:a 128k`
 *   (mlx_audio/audio_io.py `_encode_ffmpeg`); measured 128000 bit/s on a 24 kHz mono write, 2026-11-18.
 */
export const NARRATION_MP3_BITRATE = { edge: "48k", clone: "128k" } as const;

export interface EngineNarrationDeps {
  edge(text: string, voice: string, rate: string, outFile: string, signal?: AbortSignal, retries?: number,
    prosody?: NarrationProsody): Promise<{ audioFile: string; durationMs: number; wordBoundaries: WordBoundary[] }>;
  clone(text: string, voice: string, signal?: AbortSignal): Promise<Uint8Array | null>;
  /** Joins cloned pieces into one file. Without it a long cloned request is sent whole (the old behaviour). */
  assemble?: AssembleNarration;
  dispose?(file: string): void;
}

/**
 * T28: the most words one cloned-voice request may carry. The Qwen3 clone tends to stop generating at about its
 * reference clip's length (10.0 s = 126 codec positions), often mid-word. NarrationLayer #153 measured it: 35-39-word
 * sentences stopped at the wall in 4-9 of 12 takes; split at 24 words (about 7 s at 3.5 words/s) 0 of 12 were cut.
 */
export const CLONE_PIECE_MAX_WORDS = 24;
/** The fewest words a cut may leave on either side (NarrationLayer #153's rule), so no piece is a stray scrap. */
const CLONE_PIECE_MIN_SIDE = 5;
const CLAUSE_BREAK = /(?:[.!?…,;:—–]|[^-]--)["'”’)\]]*$|^(?:-{1,2}|[–—])$/;
const CONJUNCTION = /^(?:and|but|or|so|because|while|whereas|although|though|which|then|yet|when|where|unless|until)$/i;

/**
 * Splits `text` into pieces of at most `maxWords` words. A piece over the bound is cut once, at the gap nearest its
 * middle that leaves CLONE_PIECE_MIN_SIDE words each side, preferring a gap after punctuation, then one before a
 * conjunction, then any gap; each half is split again until it fits. Every piece is a slice of `text` (its own
 * whitespace kept), so the pieces hold every word, none added, in order.
 */
export function splitClonePieces(text: string, maxWords = CLONE_PIECE_MAX_WORDS): string[] {
  const tokens = [...text.matchAll(/\S+/gu)].map(match => ({ word: match[0], start: match.index!, end: match.index! + match[0].length }));
  if (tokens.length === 0) return [text];
  const pieces: string[] = [];
  const split = (first: number, end: number) => {
    const count = end - first;
    if (count <= maxWords) { pieces.push(text.slice(tokens[first].start, tokens[end - 1].end)); return; }
    const side = Math.min(CLONE_PIECE_MIN_SIDE, Math.floor(count / 2));
    const middle = first + count / 2;
    let best = -1, bestRank = Infinity;
    for (let cut = first + side; cut <= end - side; cut++) {
      const tier = CLAUSE_BREAK.test(tokens[cut - 1].word) ? 0 : CONJUNCTION.test(tokens[cut].word.replace(/^["'“‘(]+/u, "")) ? 1 : 2;
      const rank = tier * tokens.length + Math.abs(cut - middle);
      if (rank < bestRank) { best = cut; bestRank = rank; }
    }
    split(first, best);
    split(best, end);
  };
  split(0, tokens.length);
  return pieces;
}

export function createEngineNarrationSource(deps: EngineNarrationDeps): NarrationSource {
  return {
    id: "voicelayer-engines",
    async synthesize(request: NarrationRequest): Promise<NarrationAudio | null> {
      if (request.engine === "edge") {
        const chunk = await deps.edge(request.text, request.voice, request.rate, request.outFile, request.signal,
          request.retries, request.prosody);
        return { ...chunk, engine: "edge-tts", voice: request.voice };
      }
      const cloned: NarrationAudio = { audioFile: request.outFile, durationMs: 0, wordBoundaries: [], engine: "qwen3-tts", voice: request.voice };
      const pieces = deps.assemble ? splitClonePieces(request.text) : [request.text];
      if (pieces.length > 1) {
        const files: string[] = [];
        try {
          for (const [index, piece] of pieces.entries()) {
            const audio = await deps.clone(piece, request.voice, request.signal);
            if (!audio) return null;
            const file = request.outFile.replace(/(\.[a-z0-9]+)?$/i, `.p${index}$1`);
            files.push(file);
            writeFileSync(file, audio);
          }
          // No added silence: the cut is for the model's length wall, not a pause; the clone keeps its own phrasing.
          await deps.assemble!(files.map(file => ({ file })), request.outFile, request.signal);
          return cloned;
        } catch (error) {
          if (request.signal?.aborted) throw error;
          // The words are never lost to the split: without assembly the request is sent whole, as before T28.
          console.error(`[voicelayer] Cloned piece assembly failed (${error instanceof Error ? error.message : String(error)}); synthesizing it as one request`);
        } finally {
          for (const file of files) { try { deps.dispose?.(file); } catch {} }
        }
      }
      const audio = await deps.clone(request.text, request.voice, request.signal);
      if (!audio) return null;
      writeFileSync(request.outFile, audio);
      return cloned;
    },
  };
}
