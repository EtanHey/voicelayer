/**
 * Lane c11-T6 (B): "So number one, … Number two, … And number three, …" is a
 * spoken list. The enumerator rule already knew "number one" heads, but a
 * lead-in "So" before the first head hid it, so the list started at two and
 * the whole take stayed prose. A spoken "So", "and" or "or" before a head is
 * his word: it stays at the front of that item. Only the numeral phrase
 * ("number one", "first") becomes the item number.
 *
 * Synthetic sentences only. Each NOT-a-list case runs beside a positive
 * control, so every test fails on the base candidate and passes here.
 */
import { describe, expect, it } from "bun:test";
import { applyRules, applySpokenEnumeratorsWithDetail } from "../rules-engine";

const withoutStage = (raw: string): string =>
  applyRules(raw, { disabledStages: new Set(["enumerators"]) });

const DIGITS: Record<string, string> = {
  one: "1", two: "2", three: "3", four: "4", five: "5",
  first: "1", second: "2", third: "3",
};
const tokens = (text: string): string[] =>
  (text.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu) ?? []).map((t) => DIGITS[t] ?? t);
const stripListNumerals = (text: string): string => text.replace(/^\d+\.[ \t]/gmu, "");
const minus = (all: string[], removed: string[]): string[] => {
  const rest = [...all];
  for (const word of removed) {
    const at = rest.indexOf(word);
    if (at >= 0) rest.splice(at, 1);
  }
  return rest.sort();
};

const CONTROL_RAW =
  "We need a plan. So number one, we fix the tap. Number two, we bump the cask. And number three, we ship the release.";
const CONTROL_EXPECTED = [
  "We need a plan.",
  "1. So we fix the tap.",
  "2. We bump the cask.",
  "3. And we ship the release.",
].join("\n");
const expectControl = () => expect(applyRules(CONTROL_RAW)).toBe(CONTROL_EXPECTED);

describe("'number one / number two' becomes a numbered list", () => {
  it("turns a So-led number list into numbered lines, keeping So and And", () => {
    expectControl();
  });

  it("keeps a comma after the lead-in So", () => {
    expect(
      applyRules("We need a plan. So, number one, we fix the tap. Number two, we bump the cask."),
    ).toBe(["We need a plan.", "1. So, we fix the tap.", "2. We bump the cask."].join("\n"));
  });

  it("accepts the lead-in before ordinal heads too", () => {
    expect(
      applyRules("Here is the order. So first, we open the app. Second, we close the app."),
    ).toBe(["Here is the order.", "1. So we open the app.", "2. We close the app."].join("\n"));
  });

  it("keeps a sentence after the last item as its own line", () => {
    expect(applyRules(`${CONTROL_RAW} That is all.`)).toBe(`${CONTROL_EXPECTED}\nThat is all.`);
  });

  it("keeps 'and' on a bare cardinal head too", () => {
    expect(applyRules("One, buy the milk. Two, buy the bread. And three, buy the eggs.")).toBe(
      ["1. Buy the milk.", "2. Buy the bread.", "3. And buy the eggs."].join("\n"),
    );
  });

  it("never loses or adds a word: only the numeral phrases become item numbers", () => {
    for (const raw of [
      CONTROL_RAW,
      "We need a plan. So, number one, we fix the tap. Number two, we bump the cask.",
      "Here is the order. So first, we open the app. Second, we close the app.",
      "One, buy the milk. Two, buy the bread. And three, buy the eggs.",
    ]) {
      const staged = withoutStage(raw);
      const { removedWords } = applySpokenEnumeratorsWithDetail(staged);
      expect(removedWords.map((w) => w.toLowerCase()).every((w) =>
        ["number", "step", "one", "two", "three", "first", "second", "third"].includes(w))).toBe(true);
      const out = applyRules(raw);
      expect(out).not.toBe(staged);
      expect(tokens(stripListNumerals(out)).sort()).toEqual(
        minus(tokens(raw), removedWords.map((w) => DIGITS[w.toLowerCase()] ?? w.toLowerCase())),
      );
    }
  });
});

describe("'number one' in prose is not a list", () => {
  const prose: [string, string][] = [
    ["a lone 'number one' head", "Number one, I like this plan a lot."],
    ["'my number one priority'", "My number one priority is speed. Number two, we test it."],
    ["'number two pencil'", "Use a number two pencil. Number one, it is cheap."],
    ["'PR number one hundred'", "Look at PR number one hundred, then PR number two hundred, then stop."],
    ["PR numbers that look like heads", "Look at PR number one, and PR number two, then stop."],
    ["a list that starts at two", "So number two, we fix the tap. Number three, we bump the cask."],
    ["one-word items", "So number one, milk. Number two, bread."],
    ["a single So-led head", "So number one, we fix the tap and then we rest."],
  ];
  for (const [name, raw] of prose) {
    it(`leaves ${name} as prose`, () => {
      expectControl();
      expect(applyRules(raw)).toBe(withoutStage(raw));
    });
  }
});
