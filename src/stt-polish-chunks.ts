import { applyCoherentParagraphFallback, hasParagraphCodeBlock, sentenceBoundaries } from "./stt-coherent-paragraphs";
import { restoreSentencePunctuation } from "./stt-punctuation";
import type { STTPolishInput, STTPolishResult } from "./stt-polish";

export const POLISH_CHUNK_CHARS = 1800;
export const POLISH_CHUNK_MAX_CHARS = 3600;
const terminal = (text: string) => /[.!?]["'”’»)\]]*$/u.test(text.trimEnd()) &&
  !/(?:\.{2,}|…)["'”’»)\]]*$/u.test(text.trimEnd());

/** Sentence ends are read BEFORE polish. An oversized sentence stays unpolished. */
export function planLongTakeChunks(text: string): Array<{ text: string; start: number; end: number; eligible: boolean }> {
  const ends = [...sentenceBoundaries(text).map(b => b.end), text.length];
  const result: Array<{ text: string; start: number; end: number; eligible: boolean }> = [];
  let start = 0;
  while (start < text.length) {
    const within = ends.filter(end => end > start && end <= start + POLISH_CHUNK_MAX_CHARS);
    const end = within.find(end => end >= start + POLISH_CHUNK_CHARS) ?? within.at(-1) ?? ends.find(end => end > start)!;
    const part = text.slice(start, end);
    result.push({ text: part, start, end, eligible: end - start <= POLISH_CHUNK_MAX_CHARS && !hasParagraphCodeBlock(part) });
    start = end;
  }
  return result;
}

/** Also protects a future pause-owned seam: a pause is not invented punctuation. */
export function preservesChunkSeam(source: string, proposed: string, startsContinuation: boolean, internalEnd: boolean): boolean {
  if (internalEnd && !terminal(source) && terminal(proposed)) return false;
  const first = (text: string) => text.match(/\p{L}/u)?.[0] ?? "";
  if (startsContinuation && /\p{Ll}/u.test(first(source)) && /\p{Lu}/u.test(first(proposed))) return false;
  return true;
}

/** One deadline, contiguous source slices, and a deterministic unattempted remainder. */
export async function polishLongTake(input: STTPolishInput, budgetMs: number,
  run: (input: STTPolishInput, deadline: number) => Promise<STTPolishResult>): Promise<STTPolishResult> {
  const started = performance.now(), deadline = started + budgetMs;
  const parts = planLongTakeChunks(input.cleanedText), output: string[] = [];
  let applied = 0, attempted = 0;
  let failure: STTPolishResult | undefined;
  for (const part of parts) {
    const [, prefix, body, suffix] = /^(\s*)([\s\S]*?)(\s*)$/u.exec(part.text)!;
    let text = body;
    if (part.eligible && performance.now() < deadline && failure?.status !== "failed") {
      let result = await run({ ...input, rawText: body, cleanedText: body }, deadline);
      attempted++;
      if (result.status === "applied" && !preservesChunkSeam(body, result.text,
        part.start > 0 && !terminal(input.cleanedText.slice(0, part.start)), part.end < input.cleanedText.length)) {
        result = { ...result, status: "rejected", text: body, polished: false, changed: false, reason: "chunk seam changed" };
      }
      if (result.status === "applied") { text = result.text; applied++; }
      else failure ??= result;
      if (result.status === "failed") failure = result;
    }
    output.push(prefix + applyCoherentParagraphFallback(text) + suffix);
  }
  // Only the END of the whole take receives a terminal floor, never an internal seam.
  const text = restoreSentencePunctuation(output.join(""));
  const complete = applied === parts.length;
  return {
    inputText: input.cleanedText, text, polishedText: applied ? text : null,
    mode: "on", status: complete ? "applied" : applied ? "partial" : failure?.status ?? "skipped",
    surface: input.surface ?? "dictation", changed: text !== input.cleanedText,
    polished: applied > 0, retried: false, latencyMs: performance.now() - started,
    chunkCounts: { applied, attempted, total: parts.length },
    reason: `Long-take chunks: applied=${applied}/${parts.length}, attempted=${attempted}; ${failure?.status ?? (performance.now() >= deadline ? "shared budget expired" : "deterministic spans")}`,
    ...(failure?.failureKind ? { failureKind: failure.failureKind } : {}),
  };
}
