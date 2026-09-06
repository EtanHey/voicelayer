/**
 * Lane `cleanup-spoken-command-prose-guard` (issue #4).
 *
 * The PUNCTUATION_MAP regexes in src/rules-engine.ts used to fire
 * unconditionally, and about a third of them are ordinary English words.
 * Mid-prose they must never fire: "a new line on codex agents" became
 * "a. On codex agents" in production (polish-shadow line 7004, recording
 * 2026-09-05T11-46-00-495Z-81090f01). No cleanup rule may reduce the raw word
 * count on the prose path (AGENTS.md: "a fix that loses my words is worse than
 * the bug").
 */
import { describe, it, expect } from "bun:test";
import { existsSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";
import { applyRules } from "../rules-engine";

const wordCount = (s: string): number =>
  s.split(/\s+/).filter((w) => /[\p{L}\p{N}]/u.test(w)).length;

describe("spoken-command prose guard", () => {
  it("keeps 'a new line' when it is prose, not a command (production specimen)", () => {
    const raw =
      "there's still sometimes a new line on codex agents before the prompt is actually delivered";
    expect(applyRules(raw)).toBe(
      "There's still sometimes a new line on codex agents before the prompt is actually delivered",
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
      "there's still sometimes a new line on codex agents before the prompt is actually delivered",
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

  // Etan's amendment (2026-09-06): "tab specifically is something I almost
  // never if not never say as a command"; "There was a time where I said tab
  // (the dom/ui element) and got a very long space, so I know some commands
  // like tab do bleed." 41 corpus dictations contain the word; 33 shipped a
  // literal tab character. The word is no longer a command at all.
  describe("'tab' is never a dictation command", () => {
    const specimens: string[] = [
      // shadow 6183 (client name redacted for the public repo)
      "Can you maybe send a codex worker to fill out the tab of skills that came up at the end of my application",
      // shadow 6490, verbatim
      "The tab is named run 9, but it's on a work tree of run 8 hotfix.",
      // shadow 6697, verbatim
      "we could have a tab of search across everything in a tab of people or something",
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

  // Etan's amendment: "new line might be something I ask for or am talking
  // about." The determiner/preposition context decides, both ways.
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

  // Etan's amendment: "space" is the only command that DELETES a word, so it
  // errs verbatim unless the utterance is already code-shaped.
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
  });

  // Etan's amendment: plus/minus fire only between operands. "a" is also an
  // article, so the operand check must win — otherwise "a plus b" can never
  // become "a + b" even though isOperandToken("a") is true.
  describe("'plus' / 'minus' need operands", () => {
    it("fires between numbers and single-letter identifiers", () => {
      expect(applyRules("five plus three")).toBe("5 + 3");
      expect(applyRules("a plus b")).toBe("A + b");
      expect(applyRules("x minus 1")).toBe("X - 1");
    });

    it("stays the conjunction in prose", () => {
      expect(applyRules("the readme plus updating the about")).toBe(
        "The readme plus updating the about",
      );
      expect(applyRules("the smoke plus listen to section 3")).toBe(
        "The smoke plus listen to section 3",
      );
      expect(applyRules("a plus for the team")).toBe("A plus for the team");
    });
  });

  // Regression cover for the commands that must keep firing unconditionally.
  describe("unambiguous commands are untouched by the guard", () => {
    it("keeps firing regardless of surrounding determiners", () => {
      expect(applyRules("the question mark")).toBe("The?");
      expect(applyRules("a comma here")).toBe("A, here");
      expect(applyRules("open paren value close paren")).toBe("(value)");
      expect(applyRules("if value not equals zero")).toBe("If value != 0");
      expect(applyRules("left double pipe right")).toBe("Left || right");
    });
  });

  // --- Hard invariant over the recon corpus ---------------------------------
  //
  // Corpus lives outside the repo (personal dictation, docs.local is
  // gitignored), so these skip when it is absent — e.g. in CI.

  const REPO_CORPUS_ROOT = join(homedir(), "Gits", "voicelayer", "docs.local");
  const PAIRS_PATH = join(REPO_CORPUS_ROOT, "recon-2026-09-06", "pairs.json");
  const GOLD_DIR = join(REPO_CORPUS_ROOT, "recon-2026-09-05", "gold");
  const SHADOW_PATH = join(
    homedir(),
    ".voicelayer",
    "eval",
    "polish-shadow.jsonl",
  );

  const corpusAvailable =
    existsSync(PAIRS_PATH) && existsSync(SHADOW_PATH) && existsSync(GOLD_DIR);

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
