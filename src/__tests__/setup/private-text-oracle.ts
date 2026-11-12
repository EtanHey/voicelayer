import { expect } from "bun:test";

/** Private transcripts never reach an assertion as a string. Every check is a
 * boolean or a count computed here, so a failure prints labels and numbers only. */
export function expectPrivateText(text: string, checks: Record<string, (text: string) => boolean | number>, expected: Record<string, boolean | number>): void {
  const observed: Record<string, boolean | number> = {};
  for (const [label, check] of Object.entries(checks)) observed[label] = check(text);
  expect(observed).toEqual(expected);
}

/** c8 T1 specimen: the final sentence must survive, exactly once. */
export function expectTailKept(text: string): void {
  expectPrivateText(text, {
    endsWithFinalWord: t => /confusing\.?$/i.test(t.trim()),
    finalWordCount: t => t.match(/confusing/gi)?.length ?? 0,
    thisIsCount: t => t.match(/\bthis is\b/gi)?.length ?? 0,
  }, { endsWithFinalWord: true, finalWordCount: 1, thisIsCount: 1 });
}
