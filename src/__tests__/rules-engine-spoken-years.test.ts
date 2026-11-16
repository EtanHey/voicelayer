import { describe, expect, test } from "bun:test";
import { applyRules } from "../rules-engine";

describe("spoken years", () => {
  test.each([
    ["twenty twenty-six", "2026"],
    ["twenty twenty six", "2026"],
    ["nineteen ninety-nine", "1999"],
    ["twenty ten", "2010"],
    ["nineteen eighty", "1980"],
    ["twenty oh five", "2005"],
    ["twenty oh one.", "2001."],
    ["the museum opened in twenty twenty-five.", "The museum opened in 2025."],
    ["it ran from nineteen eighty to twenty ten.", "It ran from 1980 to 2010."],
    ["compare late twenty twenty-six with early twenty twenty-five", "Compare late 2026 with early 2025"],
    ["the exhibit ran in twenty twenty-six, not twenty twenty-five.", "The exhibit ran in 2026, not 2025."],
    ["in nineteen ninety-nine and twenty ten", "In 1999 and 2010"],
    ["since nineteen ninety nine, we have moved", "Since 1999, we have moved"],
    ["in twenty\ttwenty six", "In 2026"],
  ])("renders %s", (raw, expected) => expect(applyRules(raw)).toBe(expected));

  test.each([
    "two three", "twenty, twenty-six", "ten fifteen", "eleven thirty",
    "twenty-six", "two thousand twenty-six", "twenty items",
    "choose twenty thirty items", "twenty twenty-six items",
    "in twenty\ntwenty six", "in twenty, twenty six",
    "in twenty twenty six hundred", "in one hundred twenty twenty six",
    "in twenty twenty six point five", "in twenty twenty six seven",
    "in twenty oh zero", "in twenty oh five hundred",
    "in twenty twenty-six…", "in twenty no twenty six",
    "in `twenty twenty six`", "in twenty-twenty-six",
    "in 20 26", "in twenty zero five", "eighteen ninety nine",
  ])("preserves main's rendering of %s", raw => {
    expect(applyRules(raw)).toBe(controls[raw]);
  });
  test("respects the disabled numbers stage", () => {
    expect(applyRules("in twenty twenty six", { disabledStages: new Set(["numbers"]) })).toBe("In twenty twenty six");
  });
});

// Captured from origin/main through the real applyRules before implementation.
const controls: Record<string, string> = {
  "two three": "2 3",
  "twenty, twenty-six": "Twenty, 26",
  "ten fifteen": "10 15",
  "eleven thirty": "11 30",
  "twenty-six": "26",
  "two thousand twenty-six": "2026",
  "twenty items": "20 items",
  "choose twenty thirty items": "Choose 20 30 items",
  "twenty twenty-six items": "20 26 items",
  "in twenty\ntwenty six": "In 20\n26",
  "in twenty, twenty six": "In twenty, 26",
  "in twenty twenty six hundred": "In 20 2600",
  "in one hundred twenty twenty six": "In 120 26",
  "in twenty twenty six point five": "In 46.5",
  "in twenty twenty six seven": "In 20 26 7",
  "in twenty oh zero": "In 20 oh 0",
  "in twenty oh five hundred": "In 20 oh 500",
  "in twenty twenty-six\u2026": "In 20 twenty-six\u2026",
  "in twenty no twenty six": "In 20 no 26",
  "in `twenty twenty six`": "In`twenty 20 six`",
  "in twenty-twenty-six": "In twenty-twenty-six",
  "in 20 26": "In 20 26",
  "in twenty zero five": "In 20 0 5",
  "eighteen ninety nine": "18 99"
};


describe("spoken years round 2", () => {
  test.each([
    ["for twenty thirty minutes", "For 20 30 minutes"],
    ["it lasted for twenty thirty years", "It lasted for 20 30 years"],
    ["of twenty thirty items, ten failed", "Of 20 30 items, 10 failed"],
    ["one of twenty twenty items", "One of 20 20 items"],
    ["for twenty twenty-five dollars", "For 20 25 dollars"],
    ["after twenty thirty minutes it stopped", "After 20 30 minutes it stopped"],
    ["in twenty thirty%", "In 20 thirty%"],
    ["in twenty thirty minutes)", "In 20 30 minutes)"],
    ["up to twenty twenty five people", "Up to 20 25 people"],
    ["to twenty twenty-five percent", "To 20 25%"],
    ["around twenty thirty people", "Around 20 30 people"],
    ["between twenty and thirty", "Between 20 and 30"],
    ["give me twenty thirty", "Give me 20 30"],
    ["the twenty twenty-six results", "The 20 26 results"],
    ["twenty twenty-six was a hard year", "2026 was a hard year"],
    ["the twenty twenty-six roadmap", "The 2026 roadmap"],
    ["twenty twenty-six, not twenty twenty-five", "2026, not 2025"],
    ["mid twenty twenty-six", "Mid 2026"],
    ["between twenty twenty-five and twenty twenty-seven", "Between 2025 and 2027"],
    ["in twenty twenty-six, twenty twenty-seven and twenty twenty-eight", "In 2026, 2027 and 2028"],
    ["twenty twenty-six to twenty twenty-seven", "2026 to 2027"],
    ["it was twenty twenty-six", "It was 20 26"],
    ["the score was twenty twenty", "The score was 20 20"],
    ["it is twenty twenty-six", "It is 20 26"],
    ["around twenty twenty-six", "Around 2026"],
    ["done. twenty twenty-six will be busy", "Done. 2026 will be busy"],
    ["done! twenty twenty-six had a milestone", "Done! 2026 had a milestone"],
    ["twenty twenty-six. the plan changed", "2026. The plan changed"],
    ["twenty thirty minutes later", "20 30 minutes later"],
    ["give me twenty thirty, forty fifty", "Give me 20 thirty, 40 50"],
    ["in twenty twenty-six, twenty twenty-seven people", "In 2026, 20 27 people"],
    ["twenty twenty-six or in twenty twenty-seven", "20 26 or in 2027"],
    ["in twenty twenty-six…", "In 20 twenty-six…"],
    ["in twenty twenty-six, I mean twenty twenty-seven", "In 2026, I mean 20 27"],
  ])("formats %s", (raw, expected) => expect(applyRules(raw)).toBe(expected));

  test.each([
    "percent", "per cent", "%", "minutes", "seconds", "hours", "days", "weeks", "months",
    "years", "times", "people", "items", "things", "points", "dollars", "shekels", "euros",
    "pounds", "bucks", "k", "grand", "results", "sales", "feet", "children", "men", "women",
  ])("keeps cued quantities split before %s", quantity => {
    const suffix = quantity === "percent" || quantity === "%" ? "%" :
      quantity === "k" ? "k" : ` ${quantity}`;
    expect(applyRules(`in twenty thirty ${quantity}`)).toBe(`In 20 30${suffix}`);
  });

  test.each([
    "was", "is", "has", "as", "its", "his", "this", "thus", "plus", "versus", "yes", "us",
    "always", "perhaps", "unless", "whereas", "across", "besides",
  ])("allows non-plural %s after a cued year", word => {
    expect(applyRules(`in twenty twenty-six ${word}`)).toBe(`In 2026 ${word}`);
  });

  test.each(["and", "or", "to", "through", "versus", ","])("propagates across %s both ways", connector => {
    const gap = connector === "," ? ", " : ` ${connector} `;
    expect(applyRules(`compare twenty twenty-six${gap}twenty twenty-seven to twenty twenty-eight`))
      .toBe(`Compare 2026${gap}2027 to 2028`);
    expect(applyRules(`in twenty twenty-six${gap}twenty twenty-seven${gap}twenty twenty-eight`))
      .toBe(`In 2026${gap}2027${gap}2028`);
  });
});
