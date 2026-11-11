import { afterEach, expect, test, spyOn } from "bun:test";
import { applyRules } from "../rules-engine";
import { finalizeTranscriptionResultForSurface } from "../input";
import layoutCorpus from "./fixtures/layout-intent-corpus.json";

for (const { input, old } of [...layoutCorpus.commands, ...layoutCorpus.percent]) {
  test(`matches OLD command/quantity bytes: ${input}`, () => expect(applyRules(input)).toBe(old));
}
for (const { input, old } of layoutCorpus.legacyCommands) {
  test(`keeps OLD's non-command interpretation: ${input}`, () => {
    expect(old).not.toContain("\n");
    expect(applyRules(input)).toContain("new line");
  });
}
for (const { input, expected } of layoutCorpus.nouns) {
  test(`keeps the layout noun words: ${input}`, () => expect(applyRules(input)).toBe(expected));
}

// Synthetic text only. The regression is loss of the noun, not its punctuation.
export const nounRegressions = [
  "The editor reports a trailing new line? Keep checking.",
  "there is an extra new line here?",
  "remove the unwanted new paragraph now",
  "why is the leading new line visible?",
  "the buffer has an empty new line",
  "the sample has a blank new paragraph",
  "add an additional new line here",
  "what do you mean it is an unexpected new line?",
  "remove new line now",
  "new line?",
  "new paragraph!",
] as const;
for (const raw of nounRegressions) {
  test(`retains layout nouns: ${raw}`, () => {
    expect(applyRules(raw)).toBe(raw[0]!.toUpperCase() + raw.slice(1));
  });
}
for (const phrase of ["new line", "newline", "new paragraph", "line break"]) {
  for (const prefix of ["a", "the", "that", "an extra", "a trailing", "an unusual"]) {
    test(`retains a qualified layout noun: ${prefix} ${phrase}`, () => {
      const raw = `There is ${prefix} ${phrase} here?`;
      expect(applyRules(raw)).toBe(raw);
    });
  }
}

export const pronounRegressions = [
  "this one works", "that one failed", "which one fits", "each one matters",
  "every one works", "any one works", "no one knows", "another one arrived",
  "the other one failed", "one more attempt", "one another", "I need one",
  "one can retry", "I want one now",
] as const;
for (const raw of pronounRegressions) {
  test(`retains pronoun one: ${raw}`, () =>
    expect(applyRules(raw)).toBe(raw[0]!.toUpperCase() + raw.slice(1)));
}

// Exact old-engine receipts. This intentionally does not repair unrelated old
// number formatting (including comma-separated numbers) in the pronoun lane.
export const compatibility = [
  ["one or two", "1 or 2"], ["between one and five", "Between 1 and 5"],
  ["one, two, three", "One, two, 3"], ["at one o'clock", "At 1 o'clock"],
  ["one hundred", "100"], ["version one point two", "Version 1.2"],
  ["number one", "Number 1"], ["one thing", "1 thing"], ["one day", "1 day"],
  ["one time I saw it", "1 time I saw it"], ["one out of ten", "1 out of 10"],
  ["version one can retry", "Version 1 can retry"], ["line one is correct", "Line 1 is correct"],
  ["this, one thing", "This, 1 thing"], ["that. One day", "That. 1 day"],
  ["one in five", "1 in 5"], ["one plus two", "1 + 2"],
  ["rows one through three", "Rows 1 through 3"],
  ["add this to new line dot env", "Add this to\n.env"],
  ["Run new line dot slash build dot sh", "Run\n. / build .sh"],
  ["add these new line dot gitignore new line dot npmrc", "Add these\n.gitignore\n.npmrc"],
  ["foo new line question mark", "Foo\n?"],
  ["foo new paragraph question mark", "Foo\n\n?"],
  ["foo new line close paren new line bar", "Foo\n)\nBar"],
  ["first new line comma new line second", "First\n,\nSecond"],
  ["call foo open paren new line close paren", "Call foo (\n)"],
  ["foo new line comma bar", "Foo\n, bar"],
  ["foo new line period bar", "Foo\n. Bar"],
  ["the one I want", "The one I want"], ["one of them", "One of them"],
  ["one more time", "One more time"], ["one's work", "One's work"],
] as const;
for (const [raw, expected] of compatibility) {
  test(`preserves old rendering: ${raw}`, () => expect(applyRules(raw)).toBe(expected));
}

let fetchMock: ReturnType<typeof spyOn> | undefined;
afterEach(() => fetchMock?.mockRestore());
for (const surface of ["dictation", "voice_ask"] as const) {
  for (const [raw, candidate, expectedStatus, expected] of [
    ["this one works", "This 1 works.", "rejected", "This one works."],
    ["pick one or two apples", "Pick 1 or 2 apples.", "applied", "Pick 1 or 2 apples."],
    ["this one has two files", "This one has 2 files.", "applied", "This one has 2 files."],
    ["that one percent", "That 1%.", "applied", "That 1%."],
    ["the sample has an extra new line?", "The sample has an extra new line?", "applied", "The sample has an extra new line?"],
  ]) {
    test(`${surface} preserves consistent polish: ${raw}`, async () => {
      fetchMock = spyOn(globalThis, "fetch").mockImplementation(Object.assign(async () =>
        Response.json({ choices: [{ message: { content: candidate } }] }), { preconnect: () => {} }));
      const result = await finalizeTranscriptionResultForSurface(raw!, surface, {
        ...process.env, QA_VOICE_CORRECTOR: "off", QA_VOICE_STT_POLISH: "on",
        QA_VOICE_STT_POLISH_ENDPOINT: "http://fidelity.invalid/v1/chat/completions",
      });
      expect(result.text).toBe(expected!);
      expect(result.polishStatus).toBe(expectedStatus!);
    });
  }
}
