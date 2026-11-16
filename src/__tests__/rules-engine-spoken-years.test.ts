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
