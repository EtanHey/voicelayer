import { describe, expect, test } from "bun:test";
import { applyRules } from "../rules-engine";

describe("independent spoken numbers", () => {
  test.each([
    ["select two three and seven cards", "Select 2 3 and 7 cards"],
    ["select four five and six cards", "Select 4 5 and 6 cards"],
    ["codes zero one two three", "Codes 0 1 2 3"],
    ["count five five five items", "Count 5 5 5 items"],
    ["choose twelve three items", "Choose 12 3 items"],
    ["choose twenty thirty items", "Choose 20 30 items"],
    ["choose twenty zero items", "Choose 20 0 items"],
    ["choose twenty one two items", "Choose 21 2 items"],
    ["choose four\tfive and six items", "Choose 4 5 and 6 items"],
  ])("keeps each value in %s", (raw, expected) => {
    expect(applyRules(raw)).toBe(expected);
  });

  test.each([
    ["forty two", "42"],
    ["one hundred twenty three", "123"],
    ["one thousand two hundred", "1200"],
    ["two million three hundred thousand forty five", "2300045"],
    ["twenty\tone", "21"],
    ["one thousand\ntwo hundred", "1000\n200"],
  ])("retains compound number %s", (raw, expected) => {
    expect(applyRules(raw)).toBe(expected);
  });

  test("keeps retractions, fragments, conjunctions, and genuine repetitions", () => {
    expect(applyRules("four no five and si… six six tickets")).toBe(
      "4 no 5 and si… 6 6 tickets",
    );
    expect(applyRules("pick four, five and six tickets")).toBe(
      "Pick four, 5 and 6 tickets",
    );
  });

  test("respects the disabled number stage", () => {
    expect(applyRules("choose two three items", {
      disabledStages: new Set(["numbers"]),
    })).toBe("Choose two three items");
  });
});
