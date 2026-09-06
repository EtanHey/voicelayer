/**
 * Lane L — spoken enumerators become a deterministic numbered list.
 *
 * Etan on 2.2.13 (2026-09-06 21:01): the hardware-store script stayed PROSE
 * ("damn, that didnt work"), and so did the First/Second/Next/Finally script.
 * Earlier the same day the hardware-store script DID become a list — but only
 * because polish felt like it (17:58 finding: polish-made lists are luck).
 * Ruling: enumerators are decided deterministically in the rules stage; polish
 * only formats.
 *
 * The two RED fixtures are the real 2.2.13 recordings, read straight out of
 * ~/.voicelayer/eval/polish-shadow.jsonl:
 *   - 2026-09-06T17:59:19.924Z (status "rejected") — cardinal heads
 *   - 2026-09-06T18:00:02.572Z (status "rejected") — ordinal + sequence heads
 *
 * AGENTS.md law applies to every case here: never lose a word, never invent
 * one. The only words this stage may consume are pure enumerator heads, and
 * they are enumerated in PURE_ENUMERATOR_WORDS below.
 */
import { describe, it, expect } from "bun:test";
import { applyRules, applySpokenEnumeratorsWithDetail } from "../rules-engine";

const withoutStage = (raw: string): string =>
  applyRules(raw, { disabledStages: new Set(["enumerators"]) });

const tokenize = (s: string): string[] =>
  s.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu) ?? [];

// --- RED fixture 1: cardinal heads (recording 2026-09-06T17:59:19.924Z) ---

const HARDWARE_RAW =
  "We need to pick up a few things from the hardware store. One, two boxes of drywall screws. Two, a roll of painter's tape. Three, a gallon of semi-gloss white paint. And four, a new set of brushes.";

// The "2 boxes" is pre-existing number-formatting behaviour on the cleaned
// path (shadow row cleaned_text is "One, 2 boxes of drywall screws"), not this
// lane. This lane only decides the list.
const HARDWARE_EXPECTED = [
  "We need to pick up a few things from the hardware store.",
  "1. 2 boxes of drywall screws.",
  "2. A roll of painter's tape.",
  "3. A gallon of semi-gloss white paint.",
  "4. A new set of brushes.",
].join("\n");

// --- RED fixture 2: ordinal + sequence heads (2026-09-06T18:00:02.572Z) ---

const DEPLOY_RAW =
  "To deploy the new database, follow these steps. First, back up the current SQLite file to the cloud storage bucket. Second, run the migration script in the terminal. Next, verify that the vector embeddings are returning accurate results. Finally, merge the pull request and notify the engineering team on Slack. like.";

const DEPLOY_EXPECTED = [
  "To deploy the new database, follow these steps.",
  "1. Back up the current SQLite file to the cloud storage bucket.",
  "2. Run the migration script in the terminal.",
  "3. Verify that the vector embeddings are returning accurate results.",
  "4. Merge the Pull Request and notify the engineering team on Slack.",
  "Like.",
].join("\n");

describe("spoken enumerators -> deterministic numbered list", () => {
  it("turns the hardware-store cardinal script into a list (RED fixture)", () => {
    expect(applyRules(HARDWARE_RAW)).toBe(HARDWARE_EXPECTED);
  });

  it("turns the deploy-steps ordinal/sequence script into a list (RED fixture)", () => {
    expect(applyRules(DEPLOY_RAW)).toBe(DEPLOY_EXPECTED);
  });

  it("decides the list in the rules stage, not by luck downstream", () => {
    // Both fixtures must actually be CHANGED by this stage — a test that
    // passes with the stage disabled would be measuring nothing.
    expect(applyRules(HARDWARE_RAW)).not.toBe(withoutStage(HARDWARE_RAW));
    expect(applyRules(DEPLOY_RAW)).not.toBe(withoutStage(DEPLOY_RAW));
  });

  it("is deterministic — the same input gives the same list every time", () => {
    const runs = new Set(
      Array.from({ length: 5 }, () => applyRules(HARDWARE_RAW)),
    );
    expect(runs.size).toBe(1);
  });

  it("numbers 'number one' / 'step one' heads and drops the head words", () => {
    expect(
      applyRules(
        "Here is the plan. Number one, wipe the disk. Number two, reinstall the tap.",
      ),
    ).toBe(
      ["Here is the plan.", "1. Wipe the disk.", "2. Reinstall the tap."].join(
        "\n",
      ),
    );
  });

  it("keeps a head that is also content ('first of all') and still numbers it", () => {
    expect(
      applyRules(
        "Two things. First of all, the build is broken. Second of all, the tap is stale.",
      ),
    ).toBe(
      [
        "Two things.",
        "1. First of all, the build is broken.",
        "2. Second of all, the tap is stale.",
      ].join("\n"),
    );
  });

  it("keeps an intro that ends in a spoken colon", () => {
    expect(
      applyRules(
        "Do these colon first, back up the file. Second, run the script.",
      ),
    ).toBe(
      ["Do these:", "1. Back up the file.", "2. Run the script."].join("\n"),
    );
  });

  it("starts at the first line when there is no intro clause", () => {
    expect(applyRules("One, buy the milk. Two, buy the bread.")).toBe(
      ["1. Buy the milk.", "2. Buy the bread."].join("\n"),
    );
  });
});

describe("spoken enumerators — prose stays prose", () => {
  // Each of these must come out byte-identical to a run with the stage off:
  // the enumerator stage is not allowed to have touched them at all.
  const proseCases: [string, string][] = [
    [
      "a lone cardinal mid-sentence",
      "one of the workers said it was fine and the other one disagreed",
    ],
    [
      "a lone ordinal mid-sentence",
      "the first time I ran it the tap was stale",
    ],
    [
      "a quantity that follows a comma",
      "I picked up two boxes of screws, two rolls of tape, on the way home",
    ],
    [
      "sequence words in ordinary narration",
      "I rebuilt the app, and then, I restarted the daemon, and finally, it worked",
    ],
    [
      "a single enumerator head with no second head",
      "First, let me check the logs before I say anything else about this",
    ],
    [
      "heads that are not in position order",
      "Two, the tap is stale. Three, the cask is wrong. Four, the disk is full.",
    ],
    ["an enumerator head with a one-word clause", "One, milk. Two, bread."],
    [
      "code-shaped dictation",
      "const steps = [one, two, three] first, call open paren foo close paren. second, return steps.",
    ],
    [
      "a head with no comma or colon after it",
      "First I ran the build. Second I ran the tests. It was fine.",
    ],
  ];

  for (const [name, raw] of proseCases) {
    it(`never fires on ${name}`, () => {
      expect(applyRules(raw)).toBe(withoutStage(raw));
    });
  }

  it("never fires on Hebrew prose that has no enumerator heads", () => {
    const raw = "אני חושב שזה עובד עכשיו, אבל צריך לבדוק שוב מחר בבוקר";
    expect(applyRules(raw)).toBe(withoutStage(raw));
  });
});

describe("spoken enumerators — word-count invariant", () => {
  // The complete set of words this stage is allowed to consume. Rule 4 of the
  // lane brief: "words in output >= words in input minus removed pure
  // enumerators, which must be listed".
  const PURE_ENUMERATOR_WORDS = new Set([
    // list-item conjunctions carried by a head ("And four, ...")
    "and",
    "or",
    // head qualifiers
    "number",
    "step",
    // cardinals
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "nine",
    "ten",
    // ordinals
    "first",
    "firstly",
    "second",
    "secondly",
    "third",
    "thirdly",
    "fourth",
    "fourthly",
    "fifth",
    "sixth",
    "seventh",
    "eighth",
    "ninth",
    "tenth",
    // sequence words
    "next",
    "then",
    "finally",
    "lastly",
  ]);

  const fixtures = [HARDWARE_RAW, DEPLOY_RAW];

  it("only ever removes words from the pure-enumerator list", () => {
    for (const raw of fixtures) {
      const { removedWords } = applySpokenEnumeratorsWithDetail(raw);
      for (const word of removedWords) {
        expect(PURE_ENUMERATOR_WORDS.has(word.toLowerCase())).toBe(true);
      }
    }
  });

  it("keeps every other word: out >= in - removed enumerators", () => {
    for (const raw of fixtures) {
      const { text: out, removedWords } = applySpokenEnumeratorsWithDetail(raw);
      expect(tokenize(out).length).toBeGreaterThanOrEqual(
        tokenize(raw).length - removedWords.length,
      );
    }
  });

  it("removes exactly the heads it reports (hardware-store fixture)", () => {
    const { removedWords } = applySpokenEnumeratorsWithDetail(HARDWARE_RAW);
    expect(removedWords.map((w) => w.toLowerCase())).toEqual([
      "one",
      "two",
      "three",
      "and",
      "four",
    ]);
  });

  it("removes exactly the heads it reports (deploy-steps fixture)", () => {
    const { removedWords } = applySpokenEnumeratorsWithDetail(DEPLOY_RAW);
    expect(removedWords.map((w) => w.toLowerCase())).toEqual([
      "first",
      "second",
      "next",
      "finally",
    ]);
  });

  it("reports no removals when the stage does not fire", () => {
    const { text, removedWords } = applySpokenEnumeratorsWithDetail(
      "one of the workers said it was fine",
    );
    expect(text).toBe("one of the workers said it was fine");
    expect(removedWords).toEqual([]);
  });

  it("keeps every non-enumerator word of both fixtures verbatim", () => {
    for (const raw of fixtures) {
      const out = applyRules(raw).toLowerCase();
      for (const word of tokenize(raw)) {
        if (PURE_ENUMERATOR_WORDS.has(word)) continue;
        expect(out).toContain(word);
      }
    }
  });
});
