/** Test-only capture of real formatter fixture calls. No archive or live inputs. */
import "../src/__tests__/setup/preload";
import { mock } from "bun:test";
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";
import type { STTPolishInput, STTPolishResult } from "../src/stt-polish";
if (process.env.VOICELAYER_TEST_ISOLATED !== "1") throw new Error("Corpus capture requires test isolation");
const oldSrc = process.env.T2_OLD_SRC!, newSrc = process.env.T2_NEW_SRC!;
const capture = process.env.T2_CAPTURE!;
if (!oldSrc || !newSrc || !capture) throw new Error("Run through compare-formatter-corpus.ts");
type Fn = (...args: unknown[]) => unknown;
const encode = (value: unknown) => JSON.stringify(value, (_key, item) =>
  item instanceof Set ? { set: [...item] } : typeof item === "function" ? "[callback]" : item);
function record(stage: string, args: unknown[], old: unknown, current: unknown): void {
  const equal = encode(old) === encode(current);
  const safeArgs = stage === "applyRules" && args.length > 1
    ? [args[0], { configSHA256: createHash("sha256").update(encode(args.slice(1))).digest("hex") }] : args;
  appendFileSync(capture, encode({ stage, equal, ...(equal ? {} : { args: safeArgs, old, current }) }) + "\n");
}
function evaluate(fn: Fn, args: unknown[]): unknown {
  try { return { value: fn(...args) }; }
  catch (error) { return { error: error instanceof Error ? error.message : String(error) }; }
}
for (const [file, exports] of [
  ["rules-engine", ["applyRules", "applySpokenEnumeratorsWithDetail"]],
  ["stt-punctuation", ["restoreSentencePunctuation"]],
  ["stt-coherent-paragraphs", ["applyCoherentParagraphs", "applyCoherentParagraphFallback"]],
] as const) {
  const actual = await import(join(process.cwd(), "src", file + ".ts"));
  const previous = await import(join(oldSrc, file + ".ts"));
  const wrapped = { ...actual };
  for (const name of exports) {
    const fn = actual[name] as Fn;
    wrapped[name] = (...args: unknown[]) => {
      const current = evaluate(fn, args), old = evaluate(previous[name] as Fn, args);
      record(name, args, old, current);
      if ("error" in (current as object)) throw new Error((current as { error: string }).error);
      return (current as { value: unknown }).value;
    };
  }
  mock.module(join(process.cwd(), "src", file + ".ts"), () => wrapped);
}
const actual = await import(join(process.cwd(), "src/stt-polish.ts"));
const oldGuard = (await import(join(oldSrc, "stt-polish.ts"))).compareValidate as Fn;
const newGuard = (await import(join(newSrc, "stt-polish.ts"))).compareValidate as Fn;
const polish = actual.polishTranscriptionText as (input: STTPolishInput) => Promise<STTPolishResult>;
mock.module(join(process.cwd(), "src/stt-polish.ts"), () => ({ ...actual,
  polishTranscriptionText: async (input: STTPolishInput) => {
    const result = await polish(input);
    if (result.polishedText) {
      const args = [input.cleanedText, result.polishedText];
      record("polish-validation", args, oldGuard(...args, input.env), newGuard(...args, input.env));
    }
    return result;
  },
}));
