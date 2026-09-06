/**
 * Lane A3 — whisper comma-wraps spoken commands.
 *
 * Whisper punctuates each spoken command as its own comma-delimited token:
 * "update colon Q3 roadmap update new line hey Sarah comma new paragraph"
 * comes back as "update, colon, Q3, roadmap, update, new line, hey, Sarah,
 * comma, new paragraph.". Those commas are whisper's, not Etan's. On main the
 * attach-left cleanup in applyPunctuation then collapsed ", : ," to ",:," and
 * ate every "\n" that "new line" produced, so the whole layout of a dictated
 * email vanished.
 *
 * Live specimen: Etan's v2.2.12 acceptance dictation, shadow row created_at
 * 2026-09-06T14:42:25Z in ~/.voicelayer/eval/polish-shadow.jsonl.
 *
 * The same words WITHOUT whisper's commas already cleaned correctly on main,
 * which is what pins the blame on the comma handling rather than on the
 * ALWAYS/AMBIGUOUS policy from #17/#20 — that policy must survive intact.
 */
import { describe, it, expect } from "bun:test";
import { applyRules } from "../rules-engine";

// Etan's v2.2.12 acceptance dictation, raw whisper output.
const SPECIMEN =
  "Subject line, colon, Q3, roadmap, update, new line, hey, Sarah, comma, " +
  "new paragraph. Here are my three main priorities for next week. Colon, " +
  "new line, bullet point, finalize the deck.";

const tokenize = (s: string): string[] =>
  s.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu) ?? [];

describe("comma-wrapped spoken commands", () => {
  describe("the v2.2.12 acceptance specimen", () => {
    const cleaned = applyRules(SPECIMEN);

    it("keeps the newline that 'new line' asked for", () => {
      // Raw: "update, new line, hey" — the line break is the whole point of
      // the command, and main deleted it.
      expect(cleaned).toMatch(/update\s*\n\s*hey/i);
    });

    it("keeps the paragraph break that 'new paragraph' asked for", () => {
      // Raw: "hey, Sarah, comma, new paragraph." — the dictated "comma" is the
      // one comma that survives; the break follows it.
      expect(cleaned).toMatch(/Sarah,\s*\n\n/);
    });

    it("never emits the ',:,' cluster", () => {
      expect(cleaned).not.toContain(",:,");
      expect(cleaned).not.toContain(",:");
    });

    it("turns the spoken colons into real colons", () => {
      expect(cleaned).toMatch(/Subject line:\s*Q3/);
      // Whisper ended the sentence before the second spoken colon; the period
      // is whisper's, the colon is Etan's.
      expect(cleaned).toMatch(/week:/);
      expect(cleaned).not.toMatch(/week\.\s*:/);
    });

    it("leaves 'bullet point' verbatim — it is not a command", () => {
      // Bullets are polish's job, not the rules engine's.
      expect(cleaned.toLowerCase()).toContain("bullet point");
    });

    it("loses none of the spoken words that are not commands", () => {
      const commands = new Set([
        "colon", "comma", "new", "line", "paragraph",
      ]);
      const lost = tokenize(SPECIMEN).filter(
        (w) => !commands.has(w) && !cleaned.toLowerCase().includes(w),
      );
      // "three" -> "3" is number formatting, not loss.
      expect(lost.filter((w) => w !== "three")).toEqual([]);
    });
  });

  describe("a command whisper isolated between its own commas", () => {
    it("substitutes the colon and drops both of whisper's commas", () => {
      expect(applyRules("update, colon, Q3")).toBe("Update: Q3");
    });

    it("substitutes the newline when whisper ended the sentence first", () => {
      // "week colon new line bullet point": whisper heard the spoken colon as
      // a sentence end AND as the word, so the period is an artefact.
      const cleaned = applyRules("week. Colon, new line, bullet point");
      expect(cleaned).toMatch(/^Week:\s*\n\s*Bullet point$/);
    });

    it("keeps exactly one comma when the speaker actually said 'comma'", () => {
      expect(applyRules("hey Sarah, comma, here are the notes")).toBe(
        "Hey Sarah, here are the notes",
      );
    });

    it("keeps the newline when a delimiter follows the command run", () => {
      expect(applyRules("alpha, new line, beta")).toMatch(/^Alpha\s*\n\s*Beta$/);
    });
  });

  // Lead's addition — Etan's 2026-09-06T14:56:58.449Z row. Three commands in a
  // row, each isolated by whisper's own commas. Main dropped all three and
  // shipped one flat line; every one of them has to land.
  describe("a run of consecutive commands", () => {
    const RUN_SPECIMEN =
      "Here are a few things, new line, new line, new paragraph, " +
      "first of all I went there, and then next I returned back home, " +
      "and lastly I went to the store.";

    it("honours all three commands — one blank line, then a paragraph", () => {
      const cleaned = applyRules(RUN_SPECIMEN);
      // "new line" + "new line" + "new paragraph" = 4 newlines, in that order.
      expect(cleaned.match(/\n/g) ?? []).toHaveLength(4);
      // Lead's ruling: whisper's comma before a newline command is dropped —
      // Etan said "things new line", not "things comma new line".
      expect(cleaned).toMatch(
        /^Here are a few things\s*\n\s*\n\s*\n\s*\n\s*First of all I went there/,
      );
    });

    it("keeps every word of the prose around the run", () => {
      const cleaned = applyRules(RUN_SPECIMEN).toLowerCase();
      const commands = new Set(["new", "line", "paragraph"]);
      const lost = tokenize(RUN_SPECIMEN).filter(
        (w) => !commands.has(w) && !cleaned.includes(w),
      );
      expect(lost).toEqual([]);
    });
  });

  // Lead's ruling (2026-09-06), verbatim: "DROP the comma whisper inserted
  // immediately before a newline/paragraph command — Etan said 'update new
  // line', not 'update comma new line'; a comma survives only when he actually
  // dictated 'comma' (its own command token)."
  describe("whisper's comma before a newline command", () => {
    it("is dropped when whisper supplied both delimiters", () => {
      expect(applyRules("update, new line, hey")).toBe("Update \n Hey");
    });

    it("is dropped when whisper supplied only the leading one", () => {
      // Neither lane specimen covers this shape, but the ruling does.
      expect(applyRules("Here are a few things, new line first of all")).toBe(
        "Here are a few things \n First of all",
      );
      expect(applyRules("hey Sarah, new line and then next")).toBe(
        "Hey Sarah \n And then next",
      );
      expect(
        applyRules("update, new paragraph here are my priorities"),
      ).toBe("Update \n\n Here are my priorities");
    });

    it("survives when Etan actually dictated the word 'comma'", () => {
      // The comma command is still the WORD "comma" when the drop pass runs,
      // so it cannot be matched — this is why that pass runs before the unwrap.
      expect(applyRules("hey, Sarah, comma, new paragraph. Here are")).toBe(
        "Hey, Sarah, \n\n Here are",
      );
      expect(applyRules("hey Sarah, comma, new line and then")).toBe(
        "Hey Sarah, \n And then",
      );
    });

    it("survives in prose, where the command never fires", () => {
      // "is" marks the noun reading, so "new line" stays a word — and the
      // comma that precedes it stays a comma.
      const cleaned = applyRules(
        "if you want a break, new line is what you need",
      );
      expect(cleaned).toContain(",");
      expect(cleaned.toLowerCase()).toContain("new line is");
      expect(cleaned).not.toContain("\n");
    });
  });

  // The corpus gate caught this: 5 shadow rows open a sentence with the
  // connective "Plus,", which the unwrap read as a comma-isolated operator and
  // ate. ARITHMETIC_ONLY commands want operands on both sides, and whisper's
  // delimiters are not operands, so they never unwrap.
  describe("'plus' and 'minus' still need operand evidence", () => {
    it("keeps the sentence-opening connective verbatim", () => {
      // shadow row, verbatim opening
      const raw =
        "the same quality as what Google gives us in Flex. Plus, I don't know if we can match it";
      const cleaned = applyRules(raw);
      expect(cleaned.toLowerCase()).toContain("plus");
      expect(cleaned).not.toContain("+");
    });

    it("keeps 'minus' verbatim when whisper isolated it", () => {
      const cleaned = applyRules("we shipped the pill, minus, the teleprompter");
      expect(cleaned.toLowerCase()).toContain("minus");
    });

    it("still fires between operands", () => {
      expect(applyRules("a plus b")).toBe("A + b");
    });
  });

  // The guard from #17/#20 is unchanged: whisper does not wrap prose in commas,
  // so the determiner/preposition heuristics still decide the unwrapped cases.
  describe("prose is untouched", () => {
    it("keeps 'a new line' verbatim when it is prose", () => {
      expect(applyRules("a new line on codex agents")).toBe(
        "A new line on codex agents",
      );
      expect(
        applyRules(
          "there's still sometimes a new line on codex agents before the prompt is actually delivered",
        ),
      ).toBe(
        "There's still sometimes a new line on codex agents before the prompt is actually delivered",
      );
    });

    it("keeps ordinary comma-delimited prose verbatim", () => {
      expect(applyRules("we shipped the tab, the pill, and the notch")).toBe(
        "We shipped the tab, the pill, and the notch",
      );
      expect(applyRules("I need some space, to think, about it")).toContain(
        "space",
      );
    });

    it("never reduces the word count of comma-delimited prose", () => {
      const prose = [
        "the dash, the hash, and the pipe are all in that branch",
        "there was a new line, in the prompt, before the delivery",
      ];
      for (const raw of prose) {
        const cleaned = applyRules(raw).toLowerCase();
        const lost = tokenize(raw).filter((w) => !cleaned.includes(w));
        expect(lost).toEqual([]);
      }
    });
  });
});
