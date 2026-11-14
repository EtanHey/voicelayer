/**
 * Spoken-command prose guard: ambiguous command words must remain ordinary text in noun contexts.
 * Reported 2026-09-05: unguarded symbol replacement removed real words.
 */
import { describe, it, expect } from "bun:test";
import { existsSync, readFileSync } from "fs";
import { join } from "path";
import { applyRules } from "../rules-engine";
import { privateCorpusPaths } from "./setup/private-specimens";

const wordCount = (s: string): number =>
  s.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;

describe("spoken-command prose guard", () => {
  it("keeps 'a new line' when it is prose, not a command (production specimen)", () => {
    const raw =
      "there is sometimes a new line on the garden map before the lantern route is printed";
    expect(applyRules(raw)).toBe(
      "There is sometimes a new line on the garden map before the lantern route is printed",
    );
  });

  it("keeps ordinary words that double as symbol commands mid-prose", () => {
    const cases: [string, string][] = [
      ["I need some space to think", "I need some space to think"],
      [
        "the dash between the words looks wrong",
        "The dash between the words looks wrong",
      ],
      ["that hash is not in the cask", "That hash is not in the cask"],
      ["a big plus for the team", "A big plus for the team"],
      ["open a new tab in helium", "Open a new tab in helium"],
      ["the pipe was leaking", "The pipe was leaking"],
    ];
    for (const [raw, expected] of cases) {
      expect(applyRules(raw)).toBe(expected);
    }
  });

  it("never reduces the word count of a prose utterance", () => {
    const prose = [
      "there is sometimes a new line on the garden map before the lantern route is printed",
      "I need some space to think about the dash and the hash in that branch",
      "the arrow function returns a percent of the total",
    ];
    for (const raw of prose) {
      expect(wordCount(applyRules(raw))).toBeGreaterThanOrEqual(wordCount(raw));
    }
  });

  it("still substitutes explicit dictation commands in code context", () => {
    // Note: "open brace new line close brace" already collapses to "{}" on main
    // (the attach-left cleanup eats the newline) — pre-existing, not this lane.
    expect(applyRules("line one new line line two")).toContain("\n");
    expect(applyRules("foo comma bar period")).toBe("Foo, bar.");
  });

  // Decision 2026-09-06: tab is always a word, never a spoken command.
  // Corpus review found 33 unwanted substitutions among 41 matching dictations.
  describe("'tab' is never a dictation command", () => {
    const specimens: string[] = [
      // Synthetic prose retaining the reported ambiguous command shape.
      "Please open the tab of garden maps beside the painted lantern catalogue",
      // Synthetic prose retaining the reported ambiguous command shape.
      "The tab is named garden 9, but the paper map describes garden 8.",
      // Synthetic prose retaining the reported ambiguous command shape.
      "the imaginary catalogue could show a tab of lanterns beside a tab of baskets",
      // ordinary UI prose
      "open a new tab in helium",
      "the tab component",
    ];

    for (const raw of specimens) {
      it(`keeps the word in ${JSON.stringify(raw.slice(0, 40))}…`, () => {
        const cleaned = applyRules(raw);
        expect(cleaned).not.toContain("\t");
        expect(cleaned.toLowerCase()).toContain("tab");
      });
    }
  });

  // Decision 2026-09-06: noun context distinguishes a layout mention from a command.
  describe("'new line' cuts both ways", () => {
    it("stays verbatim when it is the thing being talked about", () => {
      expect(applyRules("a new line on codex agents")).toBe(
        "A new line on codex agents",
      );
      expect(applyRules("there was a new line in the prompt")).toBe(
        "There was a new line in the prompt",
      );
    });

    it("still fires when dictated between operands", () => {
      expect(applyRules("line one new line line two")).toContain("\n");
      expect(applyRules("foo new paragraph bar")).toContain("\n\n");
    });
  });

  // Decision 2026-09-06: preserve the space word unless code operands establish command intent.
  describe("'space' errs verbatim", () => {
    it("keeps the word in prose", () => {
      expect(applyRules("I need some space to think")).toBe(
        "I need some space to think",
      );
      expect(applyRules("give the team space")).toBe("Give the team space");
      expect(applyRules("there is not enough space here")).toBe(
        "There is not enough space here",
      );
    });

    it("still fires in code-shaped dictation", () => {
      expect(applyRules("foo space bar open paren close paren")).not.toMatch(
        /\bspace\b/,
      );
    });

    // Macroscope on PR #17 (src/rules-engine.ts:355): applyPunctuation gated
    // the space command on `commandFired || isCodeShaped(text)`, so an ordinary
    // sentence that merely ended with a dictated "period" armed the one command
    // Reported in PR #17: the final noun was deleted from a sentence about the night sky.
    // The trigger is the shape of the utterance, never the fact that some other
    // command fired.
    it("is not armed by an unrelated command firing elsewhere", () => {
      expect(applyRules("I saw outer space period")).toBe("I saw outer space.");
      expect(applyRules("the space between words period")).toBe(
        "The space between words.",
      );
      expect(applyRules("give the team space period")).toBe(
        "Give the team space.",
      );
      // The ",." cluster collapses to "." in normalizePunctuationClusters —
      // pre-existing, and not what this case is about: the word survives.
      expect(applyRules("I need more space comma period")).toBe(
        "I need more space.",
      );
    });
  });

  // Macroscope on PR #17 (src/rules-engine.ts:258): the determiner check ran
  // before the operand check, so the article in "a plus b" read as a noun
  // determiner and the operator stayed a word. Between two operands there is no
  // noun reading to protect.
  describe("binary operators fire between single-letter operands", () => {
    it("fires even when the left operand looks like a determiner", () => {
      expect(applyRules("a plus b")).toBe("A + b");
      expect(applyRules("a equals b")).toBe("A = b");
      expect(applyRules("a minus b")).toBe("A - b");
    });

    it("keeps operands that are not single letters or camelCase verbatim", () => {
      // Preserve ambiguous lowercase identifiers as ordinary prose.
      expect(applyRules("foo plus bar")).toBe("Foo plus bar");
      expect(applyRules("a big plus for the team")).toBe(
        "A big plus for the team",
      );
    });
  });

  // Regression cover for commands that still fire without noun evidence.
  describe("explicit commands are preserved by the guard", () => {
    it("single-word commands fire regardless of determiners", () => {
      expect(applyRules("a comma here")).toBe("A, here");
      expect(applyRules("open paren value close paren")).toBe("(value)");
      expect(applyRules("if value not equals zero")).toBe("If value != 0");
      expect(applyRules("left double pipe right")).toBe("Left || right");
    });

    it("keeps multi-word mark names when a determiner makes them nouns", () => {
      expect(applyRules("the question mark")).toBe("The question mark");
      expect(applyRules("a full stop at the end")).toBe(
        "A full stop at the end",
      );
    });
  });

  // --- Hard invariant over the recon corpus ---------------------------------
  //
  // Corpus stays outside the repo and requires explicit read-only opt-in.
  const corpus = privateCorpusPaths("prose-guard");
  const PAIRS_PATH = corpus?.prosePairs ?? "";
  const GOLD_DIR = corpus?.proseGold ?? "";
  const SHADOW_PATH = corpus?.polishShadow ?? "";
  const corpusAvailable = Boolean(corpus) &&
    existsSync(PAIRS_PATH) && existsSync(SHADOW_PATH) && existsSync(GOLD_DIR);
  if (corpus && !corpusAvailable) {
    console.error("[prose-guard] SKIPPING: private recon corpus files absent.");
  }

  function loadCorpus(): string[] {
    const shadow = readFileSync(SHADOW_PATH, "utf8").split("\n");
    const pairs = JSON.parse(readFileSync(PAIRS_PATH, "utf8")) as {
      rows: { real_edit?: boolean; shadow_line?: number }[];
    };
    const raws: string[] = [];
    for (const row of pairs.rows) {
      if (!row.real_edit || !row.shadow_line) continue;
      const line = shadow[row.shadow_line - 1];
      if (!line) continue;
      const rawText = (JSON.parse(line) as { raw_text?: string }).raw_text;
      if (rawText) raws.push(rawText);
    }
    const glob = new Bun.Glob("*.txt");
    for (const name of glob.scanSync(GOLD_DIR)) {
      raws.push(readFileSync(join(GOLD_DIR, name), "utf8").trim());
    }
    return raws;
  }

  // Words applyRules is allowed to consume: spoken commands it substitutes,
  // acoustic fillers it strips, number words it folds into digits, case
  // commands, and the multi-word tech-vocab left-hand sides that merge into a
  // single token. Anything else vanishing is a lost word.
  const CONSUMABLE_WORDS = new Set([
    // unambiguous spoken punctuation commands
    "period", "full", "stop", "comma", "questionmark", "question", "mark",
    "exclamation", "point", "open", "close", "paren", "bracket", "brace",
    "semicolon", "hyphen", "underscore", "triple", "double", "not",
    "asterisk", "backslash", "ampersand", "at", "sign", "dollar", "caret",
    "tilde", "backtick", "single", "quote", "ellipsis",
    // acoustic fillers (default, non-aggressive set)
    "um", "uh", "er", "אמ", "אה",
    // number words folded into digits
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
    "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred",
    "thousand", "million",
    // case commands
    "camel", "snake", "pascal", "kebab", "all", "caps", "case",
    // code-token and tech-vocab left-hand sides that merge into one token
    "dot", "on", "click", "change", "submit",
    // the article normalizePercentPhrases folds into "100% sure"
    "a",
  ]);

  // An ambiguous command word may only disappear when the symbol it stands for
  // actually turned up in the output — that is the "explicit command that
  // fired" half of the invariant. "space" and "tab" are absent on purpose:
  // "space" deletes a word rather than swapping one, and "tab" is no longer a
  // command at all, so neither may ever go missing from a corpus transcript.
  const AMBIGUOUS_COMMAND_SYMBOLS: Record<string, string> = {
    colon: ":",
    dash: "-",
    arrow: "=>",
    equals: "=",
    plus: "+",
    minus: "-",
    slash: "/",
    pipe: "|",
    hash: "#",
    percent: "%",
    line: "\n",
    paragraph: "\n\n",
    new: "\n",
  };

  const tokenize = (s: string): string[] =>
    s.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}'’]*/gu) ?? [];

  function lostWords(raw: string): string[] {
    const cleaned = applyRules(raw).toLowerCase();
    const lost: string[] = [];
    for (const word of tokenize(raw)) {
      if (CONSUMABLE_WORDS.has(word)) continue;
      // Substring, not whole word: tech vocab merges words into one token
      // ("type script" -> "TypeScript"), which is not a loss.
      if (cleaned.includes(word)) continue;
      const symbol = AMBIGUOUS_COMMAND_SYMBOLS[word];
      if (symbol && cleaned.includes(symbol)) continue;
      lost.push(word);
    }
    return lost;
  }

  describe.skipIf(!corpusAvailable)("recon corpus invariant", () => {
    it("never drops a word that is not an explicit command that fired", () => {
      const raws = loadCorpus();
      expect(raws.length).toBeGreaterThan(50);

      const offenders: { raw: string; lost: string[] }[] = [];
      for (const raw of raws) {
        const lost = lostWords(raw);
        if (lost.length > 0) offenders.push({ raw, lost });
      }

      console.log(
        `[corpus] ${raws.length} raw transcripts, ${offenders.length} with lost words`,
      );
      expect(offenders).toEqual([]);
    });
  });
});
