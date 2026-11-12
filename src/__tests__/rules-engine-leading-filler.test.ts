import { describe, expect, it } from "bun:test";
import { applyRules } from "../rules-engine";

// Etan, take 2026-11-12T10-24-45-799Z: the transcript began ", I'm a little confused."
describe("a removed filler takes only its own punctuation with it", () => {
  const cases: [string, string][] = [
    ["Um, I'm a little confused.", "I'm a little confused."],
    ["Uh, um, I'm a little confused.", "I'm a little confused."],
    ["Uh. I'm a little confused.", "I'm a little confused."],
    // Mid-take joins are unchanged (the period-comma collapse owns them).
    ["the language should be fixed a little bit. um, yeah", "The language should be fixed a little bit, yeah"],
    ["So, um, I'm a little confused.", "So, I'm a little confused."],
    ["Um.", ""],
    // Cut-offs keep the fragment (raw accurate): an ellipsis or dash after the sound is not a filler's comma.
    ["Uh... I'm a little confused.", "Uh... I'm a little confused."],
    ["Uh— wait", "Uh— wait"],
    // RF review F1: a decimal point or a domain dot is not the filler's punctuation.
    ["Um.5 liters", ".5 liters"],
    ["uh.25 is the probability", ".25 is the probability"],
    // RF review F2: a protected word ends the run; the filler before it still takes its comma.
    ["Um, ER is what I meant.", "ER is what I meant."],
    ["uh, UM is the abbreviation.", "UM is the abbreviation."],
    // Words are never eaten.
    ["I went to the ER, it was fine.", "I went to the ER, it was fine."],
    ["Umbrella, yes.", "Umbrella, yes."],
  ];
  for (const [spoken, delivered] of cases) {
    it(JSON.stringify(spoken), () => expect(applyRules(spoken)).toBe(delivered));
  }
});
