import { applyCoherentParagraphFallback, isConditionalContinuation } from "./stt-coherent-paragraphs";
import type { STTPolishInput, STTPolishResult } from "./stt-polish";

export const POLISH_CHUNK_CHARS = 1800;

/** Lossless slices, retaining the exact separator on each side of every request. */
function chunks(text: string): string[] {
  const result: string[] = [];
  let start = 0;
  for (const match of text.matchAll(/\s+/gu)) {
    const end = match.index! + match[0].length;
    if (end - start < POLISH_CHUNK_CHARS || isConditionalContinuation(text.slice(end))) continue;
    result.push(text.slice(start, end));
    start = end;
  }
  if (start < text.length) result.push(text.slice(start));
  return result;
}

/** Sequential requests share one deadline. An unfinished suffix is formatted, never cut. */
export async function polishLongTake(
  input: STTPolishInput,
  budgetMs: number,
  run: (input: STTPolishInput, deadline: number) => Promise<STTPolishResult>,
): Promise<STTPolishResult> {
  const started = performance.now(), deadline = started + budgetMs;
  // Literal/code spans cannot be arbitrarily split into independently editable inputs.
  const literal = /`|^[ \t]*~~~/mu.test(input.cleanedText);
  const parts = literal ? [input.cleanedText] : chunks(input.cleanedText);
  const output: string[] = [];
  let applied = 0, attempted = 0;
  let failure: STTPolishResult | undefined;
  for (const part of parts) {
    const [, prefix, body, suffix] = /^(\s*)([\s\S]*?)(\s*)$/u.exec(part)!;
    let text = body;
    if (!literal && performance.now() < deadline && failure?.status !== "failed") {
      // The raw whole-take context must not be reintroduced into every chunk.
      const result = await run({ ...input, rawText: body, cleanedText: body }, deadline);
      attempted++;
      if (result.status === "applied") { text = result.text; applied++; }
      else failure ??= result;
      if (result.status === "failed") failure = result;
    }
    output.push(prefix + applyCoherentParagraphFallback(text) + suffix);
  }
  const text = output.join("");
  const complete = applied === parts.length;
  return {
    inputText: input.cleanedText, text, polishedText: complete ? text : null,
    mode: "on", status: complete ? "applied" : failure?.status ?? "skipped",
    surface: input.surface ?? "dictation", changed: text !== input.cleanedText,
    polished: complete, retried: false, latencyMs: performance.now() - started,
    ...(complete ? {} : { reason: `Long-take chunks: applied=${applied}/${parts.length}, attempted=${attempted}; ${literal ? "literal-code deterministic formatting" : failure?.reason ?? "shared budget expired"}` }),
    ...(failure?.failureKind ? { failureKind: failure.failureKind } : {}),
  };
}
