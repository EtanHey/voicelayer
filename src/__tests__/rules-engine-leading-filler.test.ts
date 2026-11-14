import { describe, expect, it } from "bun:test";
import { applyRules } from "../rules-engine";

// Reported 2026-11-12: removing a leading filler left its comma before the sentence.
describe("a removed filler takes only its own punctuation with it", () => {
  const cases: [string, string][] = [
    ["Um, The lantern is glowing.", "The lantern is glowing."],
    ["Uh, um, The lantern is glowing.", "The lantern is glowing."],
    ["Uh. The lantern is glowing.", "The lantern is glowing."],
    // Mid-take joins are unchanged (the period-comma collapse owns them).
    ["the language should be fixed a little bit. um, yeah", "The language should be fixed a little bit, yeah"],
    ["So, um, The lantern is glowing.", "So, The lantern is glowing."],
    ["Um.", ""],
    // Cut-offs keep the fragment (raw accurate): an ellipsis or dash after the sound is not a filler's comma.
    ["Uh... The lantern is glowing.", "Uh... The lantern is glowing."],
    ["Uh— wait", "Uh— wait"],
    // RF review F1: a decimal point or a domain dot is not the filler's punctuation.
    ["Um.5 liters", ".5 liters"],
    ["uh.25 is the probability", ".25 is the probability"],
    // RF review F2: a protected word ends the run; the filler before it still takes its comma.
    ["Um, ER is what I meant.", "ER is what I meant."],
    ["uh, UM is the abbreviation.", "UM is the abbreviation."],
    // RF review round 2 F3: unspaced decoder text.
    ["Um,uh, hello", "Hello"],
    ["Uh,um, I am confused.", "I am confused."],
    ["Um,uh", ""],
    ["Um,hello", "Hello"],
    ["Um,uh-huh", "Uh-huh"],
    ["Um.Uh, hello", "Hello"],
    // Words are never eaten.
    ["I went to the ER, it was fine.", "I went to the ER, it was fine."],
    ["Umbrella, yes.", "Umbrella, yes."],
  ];
  for (const [spoken, delivered] of cases) {
    it(JSON.stringify(spoken), () => expect(applyRules(spoken)).toBe(delivered));
  }
});
