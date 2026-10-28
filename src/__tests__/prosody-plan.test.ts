import { describe, expect, it } from "bun:test";
import { projectSpeakableText } from "../speakable-text";
import { chunkTextForTTS, TTS_CHUNK_MAX_CHARS } from "../tts";
import { PROSODY_POLICY, PROSODY_MAX_CHARS, planProsody, type ProsodyPlan } from "../tts/prosody";
import type { SpeakableText } from "../speakable-text";
import { projectStructuredSpeech } from "../tts/structured-speech";
import * as policies from "../tts/prosody";
const PAUSE = PROSODY_POLICY.pauses;

it("S1 render and timing identity include the versioned pause policy and planned silences", () => {
  const readText = "## Heading\n1. First item\n2. Second item";
  const input = { readText, projection: projectSpeakableText(readText, [], "clone"), listNumbers: "inline" as const };
  const initial = planProsody(input);
  const versioned = planProsody({ ...input, policy: { ...policies.PROSODY_POLICY, version: "next" } });
  const changed = planProsody({ ...input, policy: { ...policies.PROSODY_POLICY,
    pauses: { ...policies.PROSODY_POLICY.pauses, shortItem: 500 } } });
  expect(initial.renderIdentity).toBeTruthy();
  expect(planProsody(input).renderIdentity).toBe(initial.renderIdentity);
  expect(versioned.renderIdentity).not.toBe(initial.renderIdentity);
  expect(changed.renderIdentity).not.toBe(initial.renderIdentity);
  expect(initial.segments.map(s => s.text)).toEqual(versioned.segments.map(s => s.text));
});

/** voice_speak path: the read text is the sanitized markdown itself. */
function speakPlan(readText: string, options: { ask?: boolean; engine?: "edge" | "clone" } = {}): ProsodyPlan {
  return planProsody({ readText, projection: projectSpeakableText(readText, [], options.engine ?? "edge"), ask: options.ask });
}
/** Selection path: the read text is the structured (flattened) speech; structure comes from the source. */
function selectionPlan(source: string): ProsodyPlan {
  const structure = projectStructuredSpeech(source);
  return planProsody({ readText: structure.speechText, projection: projectSpeakableText(structure.speechText, [], "edge"), structure });
}
const letters = (text: string) => text.replace(/[^\p{L}\p{M}\p{N}]/gu, "").toLowerCase();
const texts = (plan: ProsodyPlan) => plan.segments.map((s) => s.text);
const pauses = (plan: ProsodyPlan) => plan.segments.map((s) => s.pauseMs);

describe("R-ONE clone list numbers", () => {
  const releaseNotes = "## Release notes\n\n**Fixed:** the pill no longer jumps.\n\n1. First item.\n2. Second item.\n";
  const punctuationCases = [
    {
      name: "B1 parenthesized selection abbreviation",
      source: "1) Intro.\n2) Ask Dr. Smith.",
      markdown: "one, Intro. two, Ask Dr. Smith.",
      selection: "one, Intro. 2) Ask Dr. Smith.",
    },
    {
      name: "abbreviations",
      source: "1. Ask Dr. Smith about e.g. item counts.\n2. Keep U.S. names.",
      markdown: "one, Ask Dr. Smith about e.g. item counts. two, Keep U.S. names.",
      selection: "one, Ask Dr. Smith about e.g. item counts. 2, Keep U.S. names.",
    },
    {
      name: "decimals",
      source: "1. Value 3.14 stays.\n2) Keep 2.50.",
      markdown: "one, Value 3.14 stays. two, Keep 2.50.",
      selection: "one, Value 3.14 stays. 2) Keep 2.50.",
    },
    {
      name: "questions and exclamations",
      source: "1. Can we ship?\n2) Really!",
      markdown: "one, Can we ship? two, Really!",
      selection: "one, Can we ship? 2) Really!",
    },
    {
      name: "nested lists",
      source: "1. Parent item.\n   1. Nested item.\n   2) Nested alternative!\n2. Final item.",
      markdown: "one, Parent item. one, Nested item. two, Nested alternative! two, Final item.",
      selection: "one, Parent item. 1, Nested item. 2) Nested alternative! 2, Final item.",
    },
    {
      name: "Hebrew",
      source: "1. שלום עולם.\n2. האם זה עובד?\n3) גרסה 3.14 נשמרת!",
      markdown: "1, שלום עולם. 2, האם זה עובד? 3, גרסה 3.14 נשמרת!",
      selection: "1, שלום עולם. 2, האם זה עובד? 3) גרסה 3.14 נשמרת!",
    },
    {
      name: "parenthesized sentence stops",
      source: "1) First item. More words.\n2) Second item?",
      markdown: "one, First item. More words. two, Second item?",
      selection: "one, First item. More words. 2) Second item?",
    },
    {
      name: "numbered labels",
      source: "1. **Item:** Keep 1.2.\n2) **Note:** Ask Dr. Smith.",
      markdown: "one, Item. Keep 1.2. two, Note. Ask Dr. Smith.",
      selection: "one, Item: Keep 1.2. 2) Note: Ask Dr. Smith.",
    },
    {
      name: "oversized items",
      source: "1. " + "Ask Dr. Smith about value 3.14 and keep every original word. ".repeat(12) + "\n2) End.",
      markdown: "one, " + "Ask Dr. Smith about value 3.14 and keep every original word. ".repeat(12) + "two, End.",
      selection: "one, " + "Ask Dr. Smith about value 3.14 and keep every original word. ".repeat(12) + "2) End.",
    },
  ];
  for (const fixture of punctuationCases) for (const selection of [false, true]) {
    it(`preserves full body punctuation: ${fixture.name} (selection=${selection})`, () => {
      const structure = selection ? projectStructuredSpeech(fixture.source) : undefined;
      const readText = structure?.speechText ?? fixture.source;
      const projection = projectSpeakableText(readText, [], "clone");
      const plan = planProsody({ readText, projection, structure, engine: "clone", listNumbers: "inline", concurrency: 1 });
      expect(plan.speechText).toBe(selection ? fixture.selection : fixture.markdown);
      expectSound(plan, projection.speechText);
    });
  }
  for (const selection of [false, true]) it(`keeps every number in the item without a sentence stop (selection=${selection})`, () => {
    const structure = selection ? projectStructuredSpeech(releaseNotes) : undefined;
    const readText = structure?.speechText ?? releaseNotes;
    const projection = projectSpeakableText(readText, [], "clone");
    const plan = planProsody({ readText, projection, structure, engine: "clone", listNumbers: "inline", concurrency: 1 });
    const numbers = selection ? ["1", "2"] : ["one", "two"];
    expect(plan.segments.some(segment => /^(?:one|two|\d+)\./i.test(segment.text))).toBe(false);
    expect(texts(plan).slice(-2)).toEqual([`${numbers[0]}, First item.`, `${numbers[1]}, Second item.`]);
    for (const [index, word] of numbers.entries()) {
      expect(plan.segments.at(index - 2)?.text).toMatch(new RegExp(`\\b${word}\\b`, "i"));
    }
    expectSound(plan, projection.speechText);
    expect(pauses(plan)).toEqual([1000, 320, 1000, 450, 0]);
    expect(plan.chunks.map(chunk => [chunk.first, chunk.end])).toEqual([[0, 1], [1, 2], [2, 3], [3, 4], [4, 5]]);
  });
  it("keeps all ten number words, numbered labels and parenthesized markers", () => {
    const words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"];
    const readText = "\n\n" + words.map((_, i) => `  ${i + 1}${i % 2 ? ")" : "."} **Item:** Keep these words.`).join("\n");
    const projection = projectSpeakableText(readText, [], "clone");
    const plan = planProsody({ readText, projection, engine: "clone", listNumbers: "inline", concurrency: 1 });
    expect(plan.segments.filter(segment => segment.kind === "label").map(segment => segment.text))
      .toEqual(words.map(word => `${word}, Item.`));
    for (const word of words) expect(plan.segments.some(segment => segment.text.startsWith(`${word}.`))).toBe(false);
    expectSound(plan, projection.speechText);
  });
  it("preserves Edge separate number requests and their pauses", () => {
    const plan = planProsody({ readText: releaseNotes, projection: projectSpeakableText(releaseNotes, [], "edge"),
      engine: "edge", listNumbers: "separate" });
    expect(texts(plan)).toEqual(["Release notes.", "Fixed.", "the pill no longer jumps.", "one.", "First item.", "two.", "Second item."]);
    expect(pauses(plan)).toEqual([1000, 320, 1000, 250, 450, 250, 0]);
  });
  it("preserves sentence stops on prose and unnumbered bullets", () => {
    const readText = "One. Keep this sentence.\n\n- Two. Keep this bullet.";
    const projection = projectSpeakableText(readText, [], "clone");
    const plan = planProsody({ readText, projection, engine: "clone", listNumbers: "inline", concurrency: 1 });
    expect(texts(plan)).toEqual(["One. Keep this sentence.", "Two. Keep this bullet."]);
  });
});

/** Invariants every plan must hold: nothing added or lost, ordered spans, exact read partition. */
function expectSound(plan: ProsodyPlan, projectionSpeech: string) {
  expect(letters(plan.speechText)).toBe(letters(projectionSpeech));
  expect(plan.speechText).toBe(texts(plan).join(" "));
  if (!plan.segments.length) { expect(plan.chunks).toEqual([]); expect(projectionSpeech.trim()).toBe(""); return; }
  let speech = 0;
  for (const segment of plan.segments) {
    expect(segment.speech.start).toBeGreaterThanOrEqual(speech);
    expect(segment.text.trim()).toBe(segment.text);
    expect(/[\p{L}\p{N}]/u.test(segment.text)).toBe(true);
    speech = segment.speech.end;
  }
  expect(plan.segments.at(-1)?.pauseMs ?? 0).toBe(0);
  let read = 0;
  for (const chunk of plan.chunks) {
    expect(chunk.read.start).toBe(read);
    expect(chunk.text).toBe(plan.readText.slice(chunk.read.start, chunk.read.end).trim());
    // A chunk cut never splits a whitespace token, so the teleprompter token map stays exact.
    if (read > 0) expect(/\s/.test(plan.readText[read - 1]) || /\s/.test(plan.readText[read])).toBe(true);
    read = chunk.read.end;
  }
  expect(read).toBe(plan.readText.length);
  expect(plan.chunks.flatMap((c) => plan.segments.slice(c.first, c.end))).toEqual(plan.segments);
  expect(plan.chunks.at(-1)?.trailingPauseMs ?? 0).toBe(0);
}

describe("projection-first structure (v1 defect 3: main's projection is never re-done per fragment)", () => {
  const cases: [string, string][] = [
    ["code fence", "Before\n```ts\nconst secret = foo(42);\n```\nAfter"],
    ["table", "| Name | Value |\n| --- | ---: |\n| A | 5 |"],
    ["link", "See [VoiceLayer](https://example.com) for details."],
  ];
  for (const [name, raw] of cases) it(`${name}: speech is exactly main's projection, in one engine request`, () => {
    const main = projectSpeakableText(raw, [], "edge").speechText;
    const plan = speakPlan(raw);
    expectSound(plan, main);
    expect(plan.speechText).toBe(main);
    expect(plan.segments).toHaveLength(1);
  });
  it("code is never read aloud and table pipes are never spoken", () => {
    const plan = speakPlan("Before\n```ts\nconst secret = foo(42);\n```\nAfter\n\n| Name | Value |\n| --- | ---: |\n| A | 5 |");
    expect(plan.speechText).not.toContain("secret");
    expect(plan.speechText).not.toContain("pipe");
    expect(plan.speechText).not.toContain("example");
    expect(texts(plan)).toEqual(["Before code block After", "Name, Value. A, 5."]);
    expect(pauses(plan)).toEqual([PAUSE.paragraph, 0]);
  });
  it("selection reads keep markdown-to-speech flattening: setext is a heading, not 'triple equals'", () => {
    const plan = selectionPlan("Title\n=====\nBody here.");
    expectSound(plan, projectSpeakableText("Title Body here.", [], "edge").speechText);
    expect(texts(plan)).toEqual(["Title.", "Body here."]);
    expect(pauses(plan)).toEqual([PAUSE.h1, 0]);
    expect(plan.speechText).not.toContain("equals");
  });
  it("selection reads map source structure onto the flattened read text", () => {
    const source = "## Choose\n**Question:** Which one?\n1. Red apple\n2. Green pear";
    const plan = selectionPlan(source);
    expect(plan.readText).toBe(projectStructuredSpeech(source).speechText);
    expectSound(plan, projectSpeakableText(plan.readText, [], "edge").speechText);
    // R3 reflow keeps list numbers in the flattened text; each spoken number is its own utterance (N1).
    expect(texts(plan)).toEqual(["Choose.", "Question.", "Which one?", "1.", "Red apple.", "2.", "Green pear."]);
    expect(plan.segments.map((s) => s.emphasis)).toEqual([true, true, false, false, false, false, false]);
    expect(pauses(plan).slice(3)).toEqual([PAUSE.number, PAUSE.shortItem, PAUSE.number, 0]);
  });
});

describe("only structural boundaries split (v1 defects 4 and 5)", () => {
  it("a soft-wrap newline inside a paragraph is not a boundary", () => {
    const plan = speakPlan("Line one wraps here\nand continues the same sentence.");
    expect(texts(plan)).toEqual(["Line one wraps here and continues the same sentence."]);
  });
  it("plain sentences inside one paragraph stay one engine request", () => {
    const plan = speakPlan("Dr. Smith is here. The build is green. Every check passed.");
    expect(plan.segments).toHaveLength(1);
  });
  it("inline bold, dunder identifiers and call parentheses are prose, not labels or asides", () => {
    for (const raw of ["This is **very** important to me.", "Call __init__ first.", "Run foo(bar) and word(s) then path(1)."]) {
      const plan = speakPlan(raw);
      expect(plan.segments).toHaveLength(1);
      expect(plan.segments[0].emphasis).toBe(false);
    }
  });
  it("parentheses inside inline code or link targets are never asides", () => {
    expect(speakPlan("Use `f (a b)` here.").segments).toHaveLength(1);
    expect(speakPlan("See [docs](https://x.dev/a_(b c)) now.").segments).toHaveLength(1);
  });
});

describe("pause vocabulary (spec table) with max-collapse", () => {
  it("headings: H1 900, H2/H3 750, H4+ 800, 600 before a mid-message heading, paragraph 1000 not 1550", () => {
    expect(pauses(speakPlan("# Top\nBody."))).toEqual([PAUSE.h1, 0]);
    expect(pauses(speakPlan("### Three\nBody."))).toEqual([PAUSE.h2, 0]);
    expect(pauses(speakPlan("#### Four\nBody."))).toEqual([PAUSE.heading, 0]);
    expect(pauses(speakPlan("Intro.\n## Heading\nBody"))).toEqual([PAUSE.beforeHeading, PAUSE.h2, 0]);
    expect(pauses(speakPlan("First paragraph ends.\n\nSecond paragraph."))).toEqual([PAUSE.paragraph, 0]);
    expect(pauses(speakPlan("Intro.\n\n## Heading\n\nBody"))).toEqual([PAUSE.paragraph, PAUSE.paragraph, 0]);
  });
  it("headings and labels are emphasized utterances ending in a period", () => {
    const plan = speakPlan("## Status\n**Next step:** merge it");
    expect(texts(plan)).toEqual(["Status.", "Next step.", "merge it"]);
    expect(plan.segments.map((s) => s.emphasis)).toEqual([true, true, false]);
    expect(pauses(plan)).toEqual([PAUSE.h2, PAUSE.label, 0]);
    expect(texts(speakPlan("**Label**: text"))).toEqual(["Label.", "text"]);
  });
  it("list intro colon 600, short items 450, long items (6+ words) 700", () => {
    const plan = speakPlan("Options:\n- Small item\n- This item contains six or more words\n- Last");
    expect(texts(plan)).toEqual(["Options:", "Small item.", "This item contains six or more words.", "Last."]);
    expect(pauses(plan)).toEqual([PAUSE.listIntro, PAUSE.shortItem, PAUSE.longItem, 0]);
  });
  it("an item that speaks nothing never overwrites the previous boundary", () => {
    expect(pauses(speakPlan("Intro.\n\n- **\n- Real item"))).toEqual([PAUSE.paragraph, 0]);
  });
  it("N1: a spoken list number is its own utterance with 250 ms (short item) or 280 ms (long item) after it", () => {
    const plan = speakPlan("1. Pick up the blue basket.\n2. Walk past the old apple tree to the wall.");
    expect(texts(plan)).toEqual(["one.", "Pick up the blue basket.", "two.", "Walk past the old apple tree to the wall."]);
    expect(pauses(plan)).toEqual([PAUSE.number, PAUSE.shortItem, PAUSE.longNumber, 0]);
    expect(plan.segments.map((s) => s.kind)).toEqual(["number", "item", "number", "item"]);
  });
  it("N1: Hebrew and multi-digit markers are spoken as the projection keeps them, in order, never dropped", () => {
    const raw = "1. שלום עולם\n2. מה נשמע\n100. Hundredth item";
    const plan = speakPlan(raw);
    expect(texts(plan)).toEqual(["1.", "שלום עולם.", "2.", "מה נשמע.", "100.", "Hundredth item."]);
    expect(texts(plan).join(" ")).toBe(projectSpeakableText(raw, [], "edge").speechText);
  });
  it("N1: a numbered label keeps the number, then the emphasized label", () => {
    const plan = speakPlan("1. **Merge:** now\n2. **Wait:** later");
    expect(texts(plan)).toEqual(["one.", "Merge.", "now.", "two.", "Wait.", "later."]);
    expect(pauses(plan)).toEqual([PAUSE.number, PAUSE.label, PAUSE.shortItem, PAUSE.number, PAUSE.label, 0]);
    expect(texts(selectionPlan("1. **Merge:** now\n2. **Wait:** later"))).toEqual(["one.", "Merge.", "now.", "2.", "Wait.", "later."]);
  });
  it("N1: inline numbers (clone engines) stay inside the item request; bullets never add a number", () => {
    const raw = "1. Pick up the blue basket.\n2. Walk to the gate.";
    const plan = planProsody({ readText: raw, projection: projectSpeakableText(raw, [], "clone"), listNumbers: "inline" });
    expect(plan.segments).toHaveLength(2);
    expect(plan.segments.some((s) => s.kind === "number")).toBe(false);
    expect(speakPlan("- one bullet\n- two bullet").segments.some((s) => s.kind === "number")).toBe(false);
  });
  it("asides: 200 before, 300 after; trailing punctuation stays with the aside", () => {
    const plan = speakPlan("The build (which took long) passed today.");
    expect(texts(plan)).toEqual(["The build", "(which took long)", "passed today."]);
    expect(pauses(plan)).toEqual([PAUSE.beforeAside, PAUSE.afterAside, 0]);
    expect(texts(speakPlan("Done here (see PR 512)."))).toEqual(["Done here", "(see PR 512)."]);
    const dash = speakPlan("Next — the quiet aside — finish.");
    expect(texts(dash)).toEqual(["Next", "— the quiet aside —", "finish."]);
    expect(pauses(dash)).toEqual([PAUSE.beforeAside, PAUSE.afterAside, 0]);
  });
  it("a sentence end before an aside keeps the sentence floor", () => {
    expect(pauses(speakPlan("It works. (Mostly, at least.) Ship it."))[0]).toBe(PAUSE.sentence);
  });
});

describe("evidence passages (GEMINI-1 §4–5)", () => {
  it("video 1: bold heading, numbered steps", () => {
    const raw = "Nothing needed from you.\n\n**Orchard route**\n\nAn orchard route follows three stops.\n\n1. Pick up the blue basket.\n2. Walk to the garden gate.\n3. Follow the path past the old apple tree to the low stone wall.";
    const plan = speakPlan(raw);
    expectSound(plan, projectSpeakableText(raw, [], "edge").speechText);
    expect(texts(plan).slice(0, 4)).toEqual(["Nothing needed from you.", "Orchard route.", "An orchard route follows three stops.", "one."]);
    expect(plan.segments[1].emphasis).toBe(true);
    expect(pauses(plan)).toEqual([PAUSE.paragraph, PAUSE.paragraph, PAUSE.paragraph,
      PAUSE.number, PAUSE.shortItem, PAUSE.number, PAUSE.shortItem, PAUSE.longNumber, 0]);
  });
  it("video 2: colon lead-in and bold bullet labels", () => {
    const raw = "I spent today on:\n- **Archive backend:** saving every spoken reply.\n- **Your Option+F5 formatting bug:** preserving list structure.";
    const plan = speakPlan(raw);
    expectSound(plan, projectSpeakableText(raw, [], "edge").speechText);
    expect(plan.segments[0]).toMatchObject({ text: "I spent today on:", pauseMs: PAUSE.listIntro });
    expect(plan.segments[1]).toMatchObject({ kind: "label", emphasis: true, pauseMs: PAUSE.label, text: "Archive backend." });
    // "Archive backend: saving every spoken reply." is six words: a long item.
    expect(plan.segments[2]).toMatchObject({ kind: "item", pauseMs: PAUSE.longItem });
    expect(plan.segments[3]).toMatchObject({ kind: "label", emphasis: true, pauseMs: PAUSE.label });
  });
});

describe("voice_ask", () => {
  it("pauses 600 ms before the actual question, which follows the context", () => {
    const plan = speakPlan("The build is green and every check passed. Should I merge PR 512 now?", { ask: true });
    expect(texts(plan)).toEqual(["The build is green and every check passed.", "Should I merge PR 512 now?"]);
    expect(pauses(plan)).toEqual([PAUSE.askQuestion, 0]);
  });
  it("finds the question before an options list; a lone question stays whole", () => {
    const plan = speakPlan("Checks passed. Should I merge now?\n1. Merge now\n2. Wait for the proof", { ask: true });
    expect(texts(plan).slice(0, 2)).toEqual(["Checks passed.", "Should I merge now?"]);
    expect(pauses(plan).slice(0, 2)).toEqual([PAUSE.askQuestion, PAUSE.sentence]);
    expect(speakPlan("Should I merge now?", { ask: true }).segments).toHaveLength(1);
    expect(speakPlan("Checks passed. Should I merge now?").segments).toHaveLength(1);
  });
});

describe("single owner of chunk boundaries (integrates with the long-read chunker)", () => {
  it("shares the long-read size limit", () => expect(PROSODY_MAX_CHARS).toBe(TTS_CHUNK_MAX_CHARS));
  it("plain prose chunks exactly like main: same count, same texts, one request per chunk", () => {
    for (const raw of [
      "New long read.",
      Array.from({ length: 80 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" "),
      Array.from({ length: 1000 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" "),
      `One very long sentence ${"with many plain words ".repeat(40)}ends here. Short tail.`,
    ]) {
      const plan = speakPlan(raw);
      expectSound(plan, projectSpeakableText(raw, [], "edge").speechText);
      expect(plan.chunks.map((c) => c.text)).toEqual(chunkTextForTTS(raw));
      expect(plan.chunks.every((c) => c.end - c.first === 1)).toBe(true);
    }
  });
  it("an oversized token is never hard-cut (no split surrogate pairs)", () => {
    const raw = `Lead ${"😀".repeat(260)} tail.`;
    const plan = speakPlan(raw);
    expect(plan.segments.some((s) => s.text.includes("😀".repeat(260)))).toBe(true);
  });
  it("oversized paragraphs split at sentence ends with the sentence pause", () => {
    const raw = Array.from({ length: 20 }, (_, i) => `Sentence ${i} has enough words to fill the next chunk.`).join(" ");
    const plan = speakPlan(raw);
    expect(plan.segments.length).toBeGreaterThan(1);
    expect(pauses(plan).slice(0, -1).every((p) => p === PAUSE.sentence)).toBe(true);
    expect(plan.segments.every((s) => s.text.length <= PROSODY_MAX_CHARS)).toBe(true);
  });
  it("chunk 0 is the first segment alone (fast first audio); chunk 1 fits one concurrent round", () => {
    const raw = "## Status\n\nThe build is green.\n\n- One\n- Two\n- Three\n- Four\n- Five";
    const plan = speakPlan(raw);
    expectSound(plan, projectSpeakableText(raw, [], "edge").speechText);
    expect(plan.chunks[0]).toMatchObject({ first: 0, end: 1, text: "## Status", trailingPauseMs: PAUSE.paragraph });
    expect(plan.chunks[1].end - plan.chunks[1].first).toBeLessThanOrEqual(3);
    expect(plan.chunks.map((c) => c.trailingPauseMs).slice(0, -1).every((p) => p > 0)).toBe(true);
  });
  it("the whole read partition survives soft wraps, CRLF and surrounding whitespace", () => {
    const raw = "  # Head\r\n\r\nPara one\nwraps.\r\n- item one\r\n- item two  ";
    expectSound(speakPlan(raw), projectSpeakableText(raw, [], "edge").speechText);
  });
  it("rejects a projection of different text", () => {
    expect(() => planProsody({ readText: "a", projection: projectSpeakableText("b", [], "edge") })).toThrow();
  });
});

/** Every engine request is nonempty and within the limit, unless it is one atomic replacement or one token. */
function expectBounded(plan: ProsodyPlan, projection: SpeakableText) {
  for (const segment of plan.segments) {
    expect(segment.text.length).toBeGreaterThan(0);
    if (segment.text.length <= PROSODY_MAX_CHARS) continue;
    const atomic = projection.ranges.some((r) => r.kind !== "identity" && r.speech.start <= segment.speech.start && segment.speech.end <= r.speech.end + 1);
    expect(atomic || !/\s/.test(segment.text)).toBe(true);
  }
}

describe("round 2 (Sol, TEAM-PROSODY-V2A-SOL)", () => {
  it("B1: a long code fence is never cut inside; no empty request", () => {
    const raw = "Before\n```ts\n" + "const value = foo(42);\n".repeat(50) + "```\nAfter";
    const projection = projectSpeakableText(raw, [], "edge");
    const plan = speakPlan(raw);
    expectSound(plan, projection.speechText);
    expectBounded(plan, projection);
    expect(texts(plan)).toEqual(["Before code block After"]);
  });
  it("B1: an oversized link replacement is one whole request, never cut and never empty", () => {
    const raw = "See [" + "label word ".repeat(80) + "](https://example.com) now.";
    const projection = projectSpeakableText(raw, [], "edge");
    const plan = speakPlan(raw);
    expectSound(plan, projection.speechText);
    expectBounded(plan, projection);
  });
  it("B1: the selection route holds the same invariants", () => {
    const source = "See [" + "label word ".repeat(80) + "](https://example.com) now.\n\n" + "Plain words follow here. ".repeat(30);
    const plan = selectionPlan(source);
    const projection = projectSpeakableText(plan.readText, [], "edge");
    expectSound(plan, projection.speechText);
    expectBounded(plan, projection);
  });
  it("B2: after a short label or heading, the next request is small enough to be ready in time", () => {
    for (const raw of ["**X:** " + "word ".repeat(79) + "end.", "## A\n" + "word ".repeat(79) + "end."]) {
      const plan = speakPlan(raw);
      expectSound(plan, projectSpeakableText(raw, [], "edge").speechText);
      expect(plan.segments[0].text.length).toBeLessThanOrEqual(2);
      expect(plan.segments[1].text.length).toBeLessThan(120);
      expect(plan.segments[1].pauseMs).toBe(0); // a word-run cut inside a sentence adds no pause
    }
  });
  it("B3: a soft-wrapped inline bold word is prose, through both routes", () => {
    const raw = "This is\n**very** important to me.";
    for (const plan of [speakPlan(raw), selectionPlan(raw)]) {
      expect(texts(plan)).toEqual(["This is very important to me."]);
      expect(plan.segments[0].emphasis).toBe(false);
    }
    expect(texts(speakPlan("**very** important to me."))).toEqual(["very important to me."]);
    expect(speakPlan("Intro line\n**very important**").segments).toHaveLength(1);
  });
  it("B3: colon labels, standalone bold headings and runs of label lines keep their structure", () => {
    expect(texts(speakPlan("**Label:** text"))).toEqual(["Label.", "text"]);
    expect(texts(speakPlan("**Label**: text"))).toEqual(["Label.", "text"]);
    expect(texts(speakPlan("**A:** first\n**B:** second"))).toEqual(["A.", "first", "B.", "second"]);
    expect(texts(selectionPlan("**A:** first\n**B:** second"))).toEqual(["A.", "first", "B.", "second"]);
    expect(texts(speakPlan("**Orchard route**\nAn orchard route follows three stops."))).toEqual(["Orchard route.", "An orchard route follows three stops."]);
  });
  it("R2-B1: an oversized heading or label is still sized; every piece keeps the emphasis, the last keeps the pause", () => {
    for (const [raw, kind, pause] of [
      ["# " + "word ".repeat(100) + "end.\nBody.", "heading", PAUSE.h1],
      ["**" + "word ".repeat(100) + "end:** body.", "label", PAUSE.label],
    ] as const) {
      const projection = projectSpeakableText(raw, [], "edge");
      const plan = speakPlan(raw);
      expectSound(plan, projection.speechText);
      expectBounded(plan, projection);
      const pieces = plan.segments.filter((s) => s.kind === kind);
      expect(pieces.length).toBeGreaterThan(1);
      expect(pieces.every((s) => s.emphasis && s.text.length <= PROSODY_MAX_CHARS)).toBe(true);
      expect(pieces.slice(0, -1).every((s) => s.pauseMs === 0 && !s.text.endsWith("."))).toBe(true);
      expect(pieces.at(-1)).toMatchObject({ pauseMs: pause });
      expect(pieces.at(-1)!.text.endsWith(".")).toBe(true);
    }
  });
  it("N2: plain prose chunk parity holds on the normalized token stream when lines wrap", () => {
    const raw = "Sentence has enough plain words.\n".repeat(20);
    const plan = speakPlan(raw);
    expect(plan.chunks.map((c) => c.text.split(/\s+/).join(" "))).toEqual(chunkTextForTTS(raw));
  });
});

describe("corpus invariants (edge and clone)", () => {
  const corpus = [
    "# Heading\nDescription. Next.\n\n**Label:** details\nOptions:\n- Small item\n- This item contains six or more words.\nAside (quiet words) done.",
    "Before\n```ts\nconst secret = foo(42);\n```\nAfter",
    "Version v1.2.3 lives at src/tts/prosody.ts and https://example.com/a/b/c?q=1 — see it — ok.",
    "Prefix\n\n> quoted line\n> continues\n\n---\n\n1. [x] done\n2. [ ] todo",
    "שלום עולם. זה משפט.\n\n- פריט אחד\n- פריט שני",
    "",
    "   ",
    "Before\n```ts\n" + "const value = foo(42);\n".repeat(50) + "```\nAfter",
    "See [" + "label word ".repeat(80) + "](https://example.com) now.",
    "| A | B |\n| --- | --- |\n" + "| cell words here | more cell words |\n".repeat(40),
    "# " + "word ".repeat(100) + "end.\nBody.",
    "**" + "word ".repeat(100) + "end:** body.",
  ];
  for (const engine of ["edge", "clone"] as const) for (const raw of corpus) it(`${engine}: ${JSON.stringify(raw.slice(0, 30))}`, () => {
    const projection = projectSpeakableText(raw, [], engine);
    expectSound(speakPlan(raw, { engine }), projection.speechText);
    expectSound(speakPlan(raw, { engine, ask: true }), projection.speechText);
    expectBounded(speakPlan(raw, { engine }), projection);
  });
});
