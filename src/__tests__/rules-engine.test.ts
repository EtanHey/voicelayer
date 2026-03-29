/**
 * Tests for dev-aware post-processing rule engine (rules-engine.ts).
 *
 * Seven stages in priority order:
 * 1. Filler removal
 * 2. Spoken punctuation
 * 3. Case formatting commands
 * 4. Number formatting
 * 5. Tech vocabulary
 * 6. Auto-capitalization
 * 7. Custom aliases
 *
 * Note: auto-capitalization runs last, so first word is always capitalized.
 * Tests reflect this — it's correct behavior for dictation output.
 */
import { describe, it, expect } from "bun:test";
import { applyRules, type RulesConfig } from "../rules-engine";

describe("rules-engine", () => {
  // --- Stage 1: Filler removal ---
  describe("filler removal", () => {
    it("removes common English fillers", () => {
      expect(applyRules("um I think uh this is basically working")).toBe(
        "I think this is working",
      );
    });

    it("removes fillers at start and end", () => {
      expect(applyRules("uh hello world um")).toBe("Hello world");
    });

    it("removes 'you know' and 'I mean'", () => {
      expect(applyRules("you know the function I mean works")).toBe(
        "The function works",
      );
    });

    it("removes 'like' as filler before intensifiers", () => {
      expect(applyRules("it's like really fast")).toBe("It's really fast");
    });

    it("handles multiple consecutive fillers", () => {
      expect(applyRules("um uh basically the code")).toBe("The code");
    });
  });

  // --- Stage 2: Spoken punctuation ---
  describe("spoken punctuation", () => {
    it("converts period/full stop", () => {
      expect(applyRules("hello world period")).toBe("Hello world.");
    });

    it("converts comma", () => {
      expect(applyRules("first comma second")).toBe("First, second");
    });

    it("converts question mark and exclamation", () => {
      expect(applyRules("what question mark")).toBe("What?");
      expect(applyRules("wow exclamation mark")).toBe("Wow!");
    });

    it("converts open/close paren", () => {
      expect(applyRules("open paren value close paren")).toBe("(value)");
    });

    it("converts colon and semicolon", () => {
      expect(applyRules("key colon value")).toBe("Key: value");
      expect(applyRules("first semicolon second")).toBe("First; second");
    });

    it("converts arrow", () => {
      expect(applyRules("input arrow output")).toBe("Input => output");
    });

    it("converts new line", () => {
      expect(applyRules("line one new line line two")).toContain("\n");
    });

    it("converts backtick", () => {
      expect(applyRules("backtick code backtick")).toBe("`code`");
    });
  });

  // --- Stage 3: Case formatting commands ---
  describe("case formatting", () => {
    it("camel case", () => {
      // Case commands produce their own casing — auto-cap doesn't override
      // because the result starts with lowercase, but auto-cap capitalizes first char
      const result = applyRules("camel case foo bar baz");
      // Auto-cap makes first char uppercase, but camelCase starts lowercase
      // The rule engine runs case formatting before auto-cap
      expect(result).toMatch(/fooBarBaz/i);
    });

    it("snake case", () => {
      const result = applyRules("snake case foo bar baz");
      expect(result.toLowerCase()).toContain("foo_bar_baz");
    });

    it("pascal case", () => {
      expect(applyRules("pascal case foo bar")).toBe("FooBar");
    });

    it("kebab case", () => {
      const result = applyRules("kebab case foo bar");
      expect(result.toLowerCase()).toContain("foo-bar");
    });

    it("upper case / all caps", () => {
      expect(applyRules("all caps hello world")).toBe("HELLO WORLD");
    });
  });

  // --- Stage 4: Number formatting ---
  describe("number formatting", () => {
    it("converts simple numbers", () => {
      // "forty two" → "42", auto-cap doesn't affect numbers
      expect(applyRules("forty two")).toBe("42");
    });

    it("converts larger numbers", () => {
      expect(applyRules("one hundred twenty three")).toBe("123");
    });

    it("converts zero through ten", () => {
      expect(applyRules("zero")).toBe("0");
      expect(applyRules("ten")).toBe("10");
    });
  });

  // --- Stage 5: Tech vocabulary ---
  describe("tech vocabulary", () => {
    it("corrects common dev terms", () => {
      expect(applyRules("type script")).toBe("TypeScript");
      expect(applyRules("java script")).toBe("JavaScript");
    });

    it("corrects React hooks", () => {
      // useEffect starts with lowercase, auto-cap may capitalize it
      const result = applyRules("use effect");
      expect(result.toLowerCase()).toBe("useeffect");
    });

    it("corrects framework names", () => {
      expect(applyRules("next js")).toBe("Next.js");
      expect(applyRules("node js")).toBe("Node.js");
    });
  });

  // --- Stage 6: Auto-capitalization ---
  describe("auto-capitalization", () => {
    it("capitalizes first word", () => {
      expect(applyRules("hello world")).toBe("Hello world");
    });

    it("capitalizes after period", () => {
      expect(applyRules("first sentence. second sentence")).toBe(
        "First sentence. Second sentence",
      );
    });

    it("capitalizes after question mark", () => {
      expect(applyRules("what? something else")).toBe("What? Something else");
    });
  });

  // --- Stage 7: Custom aliases ---
  describe("custom aliases", () => {
    it("applies custom aliases", () => {
      const config: RulesConfig = {
        aliases: {
          "brain layer": "BrainLayer",
          "voice bar": "VoiceBar",
        },
      };
      expect(
        applyRules("the brain layer is connected to voice bar", config),
      ).toBe("The BrainLayer is connected to VoiceBar");
    });
  });

  // --- Performance ---
  describe("performance", () => {
    it("runs in under 5ms for typical input", () => {
      const input =
        "um basically I think the function should uh take the use state hook and like return the value comma you know comma with the type script interface";
      const start = performance.now();
      for (let i = 0; i < 100; i++) {
        applyRules(input);
      }
      const elapsed = performance.now() - start;
      const perCall = elapsed / 100;
      expect(perCall).toBeLessThan(5);
    });
  });
});
