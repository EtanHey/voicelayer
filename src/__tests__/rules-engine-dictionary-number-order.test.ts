import { describe, expect, test } from "bun:test";
import { applyRules, type RulesConfig } from "../rules-engine";
import { BUILTIN_STT_DICTIONARY_ENTRIES } from "../stt-vocabulary-store";

// Ordering properties between Stage 7 (custom aliases) and Stage 4 (number
// words -> digits) in applyRules. Every alias here is synthetic or comes from
// the bundled dictionary; none is a personal entry.
//
// D1 regression pins on integration/2.3: normalized sources and final canonical outputs.

function run(raw: string, aliases: Record<string, string>, extra: Partial<RulesConfig> = {}): string {
  return applyRules(raw, { aliases, ...extra });
}

const UNITS = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
  "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
  "eighteen", "nineteen"];
const TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"];

/** Spoken cardinal for 0..999, in the words whisper emits ("one hundred twenty three"). */
function spoken(n: number): string {
  if (n < 20) return UNITS[n];
  if (n < 100) return n % 10 === 0 ? TENS[n / 10] : `${TENS[Math.floor(n / 10)]} ${UNITS[n % 10]}`;
  const rest = n % 100;
  return `${UNITS[Math.floor(n / 100)]} hundred${rest === 0 ? "" : ` ${spoken(rest)}`}`;
}

// Deterministic sample: every value whose spoken form has a distinct shape.
const SAMPLE = [0, 1, 2, 6, 9, 10, 11, 13, 19, 20, 21, 42, 57, 66, 90, 99, 100, 105, 123, 340];

describe("precondition: number stage alone (aliases disabled)", () => {
  test.each(SAMPLE)("spoken %i normalizes to its digits", (n) => {
    expect(run(`${spoken(n)} widgets`, {}, { disabledStages: new Set(["aliases"]) }))
      .toBe(`${n} widgets`);
  });
});

describe("digit-keyed aliases see normalized numbers", () => {
  // D1: the alias source is digits; on main it is matched against "six widgets".
  for (const n of SAMPLE) {
    test(`D1: "${spoken(n)} widgets" with {"${n} widgets"} -> "${n} Widgets"`, () => {
      expect(run(`${spoken(n)} widgets`, { [`${n} widgets`]: `${n} Widgets` })).toBe(`${n} Widgets`);
    });
  }

  test.each([
    // [label, raw, aliases, expected]
    ["cardinal", "six sol", { "6 sol": "6 Sol" }, "6 Sol"],
    ["cardinal, every occurrence", "six sol, then six sol", { "6 sol": "6 Sol" }, "6 Sol, then 6 Sol"],
    ["cardinal, mid sentence", "we drove route sixty six", { "route 66": "Route-66" }, "We drove Route-66"],
    ["number run stays split", "two three widgets", { "3 widgets": "3 Widgets" }, "2 3 Widgets"],
    ["range with to", "pages two to five", { "2 to 5": "2–5" }, "Pages 2–5"],
    ["range with through", "rows ten through twenty", { "10 through 20": "10–20" }, "Rows 10–20"],
    ["range idiom", "a nine to five job", { "9 to 5": "9-to-5" }, "A 9-to-5 job"],
    ["compact digit token", "ship v two today", { "v 2": "V2" }, "Ship V2 today"],
  ] as const)("D1 %s: %p", (_label, raw, aliases, expected) => {
    expect(run(raw, aliases)).toBe(expected);
  });
});

describe("point decimals before aliases", () => {
  test.each([
    ["D1 report: decimal + digit-keyed alias", "six point one sol", { "6.1 sol": "6.1 Sol" }, "6.1 Sol"],
    ["D1 report: decimal + word alias", "six point one sol", { sol: "Sol" }, "6.1 Sol"],
    ["decimal inside sentence", "use gizmo two point five now", { "gizmo 2.5": "Gizmo-2.5" }, "Use Gizmo-2.5 now"],
    ["zero point decimal", "set it to zero point five", { "0.5": "0.5x" }, "Set it to 0.5x"],
  ] as const)("D1 %s: %p", (_label, raw, aliases, expected) => {
    expect(run(raw, aliases)).toBe(expected);
  });

  // Guards: "point" with no number on both sides is a word, not a decimal.
  // These pass on main and must keep passing after D1.
  test.each([
    ["point as a noun", "the point is one thing", "The point is 1 thing"],
    ["trailing point", "six point", "6 point"],
    ["leading point", "point six", "Point 6"],
    ["exclamation point command", "six exclamation point", "6!"],
    ["point between non-numbers", "the gizmo point sol", "The gizmo point sol"],
  ] as const)("%s: %p", (_label, raw, expected) => {
    expect(run(raw, { "6.1 sol": "6.1 Sol" })).toBe(expected);
  });
});

describe("alias canonical spelling is final", () => {
  // D1 (b): the alias writes number words, then the number stage rewrites them.
  test.each([
    ["two-word number", "catch twenty two is good", { "catch twenty two": "Catch Twenty Two" }, "Catch Twenty Two is good"],
    ["single number word", "we hit tier one", { "tier one": "Tier One" }, "We hit Tier One"],
    ["capitalized number word", "the seven gizmos", { "seven gizmos": "Seven Gizmos" }, "The Seven Gizmos"],
  ] as const)("D1 %s: %p", (_label, raw, aliases, expected) => {
    expect(run(raw, aliases)).toBe(expected);
  });

  for (const n of [1, 6, 21, 123]) {
    test(`D1: target "Gizmo ${spoken(n)}" is not digit-normalized`, () => {
      const target = `Gizmo ${spoken(n).replace(/\b\w/g, (c) => c.toUpperCase())}`;
      expect(run(`gizmo ${spoken(n)}`, { [`gizmo ${spoken(n)}`]: target })).toBe(target);
    });
  }
});

describe("guards that pass on main and must survive the D1 reorder", () => {
  // A naive "move aliases after numbers" breaks every case below: the spoken
  // source would already have become digits before the alias stage runs.
  for (const n of SAMPLE) {
    test(`word-keyed alias "${spoken(n)} gizmos" still applies`, () => {
      expect(run(`${spoken(n)} gizmos`, { [`${spoken(n)} gizmos`]: `Gizmo-${n}` })).toBe(`Gizmo-${n}`);
    });
  }

  test.each([
    ["number word fused into a brand", "one password works", { "one password": "1Password" }, "1Password works"],
    ["ordinal phrase", "the twenty first century", { "twenty first century": "21st century" }, "The 21st century"],
    ["ordinal word", "the third quarter", { "third quarter": "Q3" }, "The Q3"],
    ["word-keyed range", "a nine to five job", { "nine to five": "9-to-5" }, "A 9-to-5 job"],
    ["word-keyed compact token", "ship v two today", { "v two": "V2" }, "Ship V2 today"],
    ["literal digit ordinal in input", "the 3rd quarter", { "3rd quarter": "Q3" }, "The Q3"],
    ["literal digits in input", "the 6 sol", { "6 sol": "6 Sol" }, "The 6 Sol"],
  ] as const)("%s: %p", (_label, raw, aliases, expected) => {
    expect(run(raw, aliases)).toBe(expected);
  });

  test.each([
    ["no match inside a larger number", "sixteen sol", "16 sol"],
    ["no match inside a compound", "twenty six sol", "26 sol"],
    ["no match on a longer word", "six solar panels", "6 solar panels"],
    ["no match across a line break", "six\nsol", "6\nSol"],
    ["no match on a different number", "seven sol", "7 sol"],
  ] as const)("digit alias boundary — %s: %p", (_label, raw, expected) => {
    expect(run(raw, { "6 sol": "6 Sol" })).toBe(expected);
  });

  test("bundled dictionary aliases still apply next to a spoken number", () => {
    const aliases = Object.fromEntries(
      BUILTIN_STT_DICTIONARY_ENTRIES.flatMap((entry) => entry.variants.map((variant) => [variant, entry.canonical])),
    );
    expect(aliases["קוברנטיס"]).toBe("Kubernetes");
    expect(run("three קוברנטיס clusters", aliases)).toBe("3 Kubernetes clusters");
    expect(run("פיגמה two point", aliases)).toBe("Figma 2 point");
  });
});

describe("stage toggles prove the ordering", () => {
  test("numbers disabled: a digit-keyed alias has no digits to match", () => {
    expect(run("six sol", { "6 sol": "6 Sol" }, { disabledStages: new Set(["numbers"]) })).toBe("Six sol");
  });

  test("numbers disabled: a word-keyed alias applies verbatim", () => {
    expect(run("one password", { "one password": "1Password" }, { disabledStages: new Set(["numbers"]) }))
      .toBe("1Password");
  });

  test("aliases disabled: numbers still normalize and nothing is aliased", () => {
    expect(run("six sol", { "6 sol": "6 Sol", sol: "Sol" }, { disabledStages: new Set(["aliases"]) }))
      .toBe("6 sol");
  });

  test("a word-keyed alias consumes the whole spoken phrase before numbers see it", () => {
    expect(run("six sol", { "six sol": "SIX-SOL" })).toBe("SIX-SOL");
  });

  test("word- and digit-keyed aliases for one phrase do not double-apply", () => {
    // The word-keyed source consumes the phrase; its output is not re-aliased.
    expect(run("six sol", { "six sol": "Six-Sol", "6 sol": "6-SOL" })).toBe("Six-Sol");
  });
});
