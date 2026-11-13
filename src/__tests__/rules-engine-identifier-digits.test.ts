/**
 * Lane c11-T6 (A): a PR identifier read digit by digit is one number, and the
 * recognizer's misplaced "?" moves to the end of the sentence it belongs to.
 *
 * Parakeet hands over "for PR number? Four seven one three six" (no final mark).
 * The number stage keeps adjacent single values apart on purpose, so the take
 * was delivered as "for PR number? 4 7 1 3 6." The speaker meant one sentence
 * ending "for PR number 47136?".
 *
 * Every sentence here is synthetic. Each NOT-a-join case runs beside a
 * positive control, so every test fails on the base candidate and passes here.
 */
import { describe, expect, it } from "bun:test";
import { applyRules } from "../rules-engine";
import { restoreSentencePunctuation } from "../stt-punctuation";

// The deterministic chain the app runs before polish: rules, then the floor.
const finalize = (raw: string): string => restoreSentencePunctuation(applyRules(raw));

const DIGITS: Record<string, string> = {
  zero: "0", one: "1", two: "2", three: "3", four: "4",
  five: "5", six: "6", seven: "7", eight: "8", nine: "9", ten: "10",
};

/** Word multiset with digit joins ignored: every digit is its own token. */
const bag = (text: string): string[] =>
  (text.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu) ?? [])
    .map((token) => DIGITS[token] ?? token)
    .flatMap((token) => (/^\d+$/u.test(token) ? token.split("") : [token]))
    .sort();

const POSITIVE_CONTROL = "Please review PR four seven one three six today.";
const POSITIVE_EXPECTED = "Please review PR 47136 today.";

const expectControl = () => expect(finalize(POSITIVE_CONTROL)).toBe(POSITIVE_EXPECTED);

describe("PR identifier read digit by digit -> one number", () => {
  it("joins the digits and moves the recognizer's ? to the end of the sentence", () => {
    expect(finalize("Is the fix ready for PR number? Four seven one three six")).toBe(
      "Is the fix ready for PR number 47136?",
    );
  });

  it("joins a run after a bare PR head mid-sentence", () => {
    expectControl();
  });

  it("joins a run after 'PR number' that does not end the sentence", () => {
    expect(finalize("Merge PR number nine zero six now")).toBe("Merge PR number 906 now.");
  });

  it("absorbs the sentence's full stop when the ? moves, and keeps the next sentence", () => {
    expect(finalize("Did it land in PR number? Four seven one three six. Then we ship it.")).toBe(
      "Did it land in PR number 47136? Then we ship it.",
    );
  });

  it("joins a run whose period-final digit is still a word", () => {
    // The number stage leaves "eight." spelled out; the join must reach it.
    expect(finalize("Look at PR nine zero six eight.")).toBe("Look at PR 9068.");
  });

  it("joins after a literal # sign", () => {
    expect(finalize("Close PR #9 0 6 please")).toBe("Close PR #906 please.");
  });

  it("moves a misplaced ? past an already composed PR number", () => {
    expect(finalize("Is that fixed in PR number? 906.")).toBe("Is that fixed in PR number 906?");
  });

  it("never adds a word or loses one: word multiset is unchanged apart from the join", () => {
    expectControl();
    for (const raw of [
      "Is the fix ready for PR number? Four seven one three six",
      POSITIVE_CONTROL,
      "Merge PR number nine zero six now",
      "Did it land in PR number? Four seven one three six. Then we ship it.",
      "Look at PR nine zero six eight.",
      "Is that fixed in PR number? 906.",
    ]) {
      expect(bag(finalize(raw))).toEqual(bag(raw));
    }
  });
});

describe("digits that are separate things stay separate", () => {
  it("keeps the ? where it is when the head is a complete noun phrase (an answer may follow)", () => {
    expectControl();
    expect(finalize("What's the PR number? Four seven one three six.")).toBe(
      "What's the PR number? 47136.",
    );
  });

  it("keeps the ? where it is when the head opens the sentence", () => {
    expectControl();
    expect(finalize("PR number? Two eight four.")).toBe("PR number? 284.");
  });

  it("keeps the ? where it is when more words follow the number (no guessing the sentence end)", () => {
    expectControl();
    expect(finalize("Is it in PR number? Four seven one three six and the other one")).toBe(
      "Is it in PR number? 47136 and the other one.",
    );
  });

  it("does not join a list of counts", () => {
    expectControl();
    const raw = "I counted one, two, three boxes and then four five six more";
    expect(finalize(raw)).toBe(restoreSentencePunctuation(applyRules(raw)));
    expect(finalize(raw)).toContain("4 5 6 more");
  });

  it("does not join a phone number or a countdown with no identifier head", () => {
    expectControl();
    expect(finalize("Call zero five four one two three four five six seven")).toBe(
      "Call 0 5 4 1 2 3 4 5 6 7.",
    );
    expect(finalize("One two three go")).toBe("1 2 3 go.");
  });

  it("does not join digits that run into a time", () => {
    expectControl();
    expect(finalize("Check PR 3 4 5:30 today")).toBe("Check PR 3 4 5:30 today.");
  });

  it("does not join a version read digit by digit", () => {
    expectControl();
    expect(finalize("Version two four zero ships today")).toBe("Version 2 4 0 ships today.");
  });

  it("does not join two spoken digits (they may be two values)", () => {
    expectControl();
    expect(finalize("Compare PR two eight")).toBe("Compare PR 2 8.");
  });

  it("does not join a run that ends in a multi-digit token, a decimal or a percent", () => {
    expectControl();
    expect(finalize("PR 2 8 40 is odd")).toBe("PR 2 8 40 is odd.");
    expect(finalize("PR 2 8 4.5 is odd")).toBe("PR 2 8 4.5 is odd.");
    expect(finalize("PR two eight four five percent")).toBe("PR 2 8 4 5%.");
  });

  it("does not join after heads he never reads that way (issue, bare number)", () => {
    expectControl();
    expect(finalize("Issue two eight four and number one two three")).toBe(
      "Issue 2 8 4 and number 1 2 3.",
    );
  });

  it("leaves a composed PR number without a misplaced ? exactly as it was", () => {
    expectControl();
    expect(finalize("PR # 906 stays")).toBe("PR # 906 stays.");
  });
});
