import { describe, expect, it } from "bun:test";

function normalize(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

describe("chunkTextForTTS", () => {
  it("returns short text unchanged", async () => {
    const mod = await import("../tts");
    expect(mod.chunkTextForTTS("Short text.")).toEqual(["Short text."]);
  });

  it("keeps a single sentence intact when it fits the limit", async () => {
    const mod = await import("../tts");
    const text = "This sentence should stay in one chunk because it is short.";
    expect(mod.chunkTextForTTS(text, 200)).toEqual([text]);
  });

  it("splits many sentences into ordered chunks under the limit", async () => {
    const mod = await import("../tts");
    const text = [
      "Sentence one is short.",
      "Sentence two is also short.",
      "Sentence three adds a bit more text.",
      "Sentence four should force a new chunk.",
    ].join(" ");

    const chunks = mod.chunkTextForTTS(text, 70);

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => chunk.length <= 70)).toBe(true);
    expect(normalize(chunks.join(" "))).toBe(normalize(text));
  });

  it("splits long text without punctuation into capped chunks", async () => {
    const mod = await import("../tts");
    const text =
      "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi omega";

    const chunks = mod.chunkTextForTTS(text, 25);

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => chunk.length <= 25)).toBe(true);
    expect(normalize(chunks.join(" "))).toBe(normalize(text));
  });

  it("handles unicode and Hebrew text", async () => {
    const mod = await import("../tts");
    const text =
      "שלום עולם. זאת בדיקה של פיצול טקסט ארוך יחסית? כן, וגם English mixed in.";

    const chunks = mod.chunkTextForTTS(text, 30);

    expect(chunks.length).toBeGreaterThan(1);
    expect(chunks.every((chunk) => chunk.length <= 30)).toBe(true);
    expect(normalize(chunks.join(" "))).toBe(normalize(text));
  });
});

it("SPEECH-PACING starts at a useful sentence boundary and retains all words", async () => {
  const { chunkTextForLongRead } = await import("../tts");
  const text = "First sentence starts promptly. " + "A longer sentence follows with every original word retained. ".repeat(20);
  const chunks = chunkTextForLongRead(text);
  expect(chunks[0]).toBe("First sentence starts promptly. A longer sentence follows with every original word retained.");
  expect(chunks[0].length).toBeLessThanOrEqual(100);
  expect(chunks.slice(1).some(chunk => chunk.length > 100)).toBe(true);
  expect(normalize(chunks.join(" "))).toBe(normalize(text));
});

it("SPEECH-PACING retains every character of an overlong first token", async () => {
  const { chunkTextForLongRead } = await import("../tts");
  const text = "x".repeat(450) + " final words.";
  const chunks = chunkTextForLongRead(text);
  expect(chunks[0], "WholeStartupWord").toBe("x".repeat(450));
  expect(chunks.slice(1).every(chunk => chunk.length <= 400)).toBe(true);
  expect(chunks.join(" ").match(/\S+/gu)).toEqual(text.match(/\S+/gu));
});

it("SPEECH-PACING retains tokens across repeated whitespace and paragraphs", async () => {
  const { chunkTextForLongRead } = await import("../tts");
  const text = "First   sentence is deliberately long enough to split at a word boundary before its final punctuation ".repeat(4) + ".\n\nLast paragraph.";
  expect(normalize(chunkTextForLongRead(text).join(" "))).toBe(normalize(text));
});


describe("SPEECH-PACING natural startup and ramp", () => {
  const tail = " The remaining document has another complete sentence for the next chunk.".repeat(20);
  for (const opening of [
    "The complete archive was reviewed today by Dr. Smith who approved the release.",
    "Dr. Smith reviewed the change and approved the complete release today.",
    "Mr. Heyman reviewed the complete release and approved it today.",
    "We moved to the U.S. East region last week and verified the result.",
    "We use examples, e.g. apples and pears, to explain the complete result.",
    "1. Pick up the blue basket and carry it carefully to the garden gate.",
    "2. Walk to the garden gate and wait beside the old apple tree.",
    "Ok. We can start the full review of this document today.",
    "שלום לכולם. אנחנו בודקים את המשפט הראשון ואת כל המילים לפי הסדר.",
  ]) {
    it(`keeps a natural opening: ${opening}`, async () => {
      const { chunkTextForLongRead } = await import("../tts");
      const text = opening + tail;
      const chunks = chunkTextForLongRead(text);
      expect(chunks[0].length).toBeGreaterThanOrEqual(40);
      expect(chunks[0]).not.toMatch(/(?:\b(?:Dr|Mr|e\.g)|U\.S|\b\d+)\.$/u);
      expect(chunks.join(" ").match(/\S+/gu)).toEqual(text.match(/\S+/gu));
    });
  }
  for (const [opening, expected] of [
    ["This first sentence contains enough words to exceed the old startup budget and continues naturally until its final punctuation.", "This first sentence contains enough words to exceed the old startup budget and continues naturally"],
    ["This first clause contains enough words to reach a natural pause; the following clause continues well beyond the old startup budget and ends here.", "This first clause contains enough words to reach a natural pause;"],
    ["This first clause contains enough words to reach a natural pause, and the following clause continues well beyond the old startup budget and ends here.", "This first clause contains enough words to reach a natural pause,"],
  ]) {
    it(`uses a sentence or clause boundary: ${opening}`, async () => {
      const { chunkTextForLongRead } = await import("../tts");
      const chunks = chunkTextForLongRead(opening! + tail);
      expect(chunks[0], "StartupRequestBound").toBe(expected ?? opening!);
      expect(chunks[0].length).toBeLessThanOrEqual(100);
      expect(chunks.join(" ").match(/\S+/gu)).toEqual((opening! + tail).match(/\S+/gu));
    });
  }
  it("does not end the startup on a quoted title abbreviation", async () => {
    const { chunkTextForLongRead } = await import("../tts");
    const text = 'The complete archive was reviewed today by "Dr." Smith who approved the release.' + tail;
    const chunks = chunkTextForLongRead(text);
    expect(chunks[0]).toContain("Smith");
    expect(chunks.join(" ").match(/\S+/gu)).toEqual(text.match(/\S+/gu));
  });
  it("bounds a pathological first sentence without losing or repeating words", async () => {
    const { chunkTextForLongRead } = await import("../tts");
    const text = Array.from({ length: 250 }, (_, index) => `word${index}`).join(" ") + ".";
    const chunks = chunkTextForLongRead(text);
    expect(chunks.every(chunk => chunk.length <= 400)).toBe(true);
    expect(chunks.join(" ").match(/\S+/gu)).toEqual(text.match(/\S+/gu));
  });
  it("ramps the second synthesis budget before the 400 character body", async () => {
    const { chunkTextForLongRead } = await import("../tts");
    const sentence = "This sentence has enough words to make a useful spoken chunk.";
    const chunks = chunkTextForLongRead(Array(30).fill(sentence).join(" "));
    expect(chunks[0].length).toBeLessThanOrEqual(100);
    expect(chunks[1].length).toBeGreaterThan(100);
    expect(chunks[1].length).toBeLessThanOrEqual(200);
    expect(chunks[2].length).toBeGreaterThan(200);
    expect(chunks.slice(2).every(chunk => chunk.length <= 400)).toBe(true);
  });
});


describe("F-speech R2 real clause boundary", () => {
  for (const [token, marker, language] of [
    ["https://example.test/path", ":", "English"], ["1,000", ",", "English"],
    ["inside;token", ";", "English"], ["מילה،המשך", "،", "Hebrew"],
  ]) {
    it(`keeps ${token} whole when ${marker} is at index 99 (${language})`, async () => {
      const { chunkTextForLongRead } = await import("../tts");
      const lead = (language === "Hebrew" ? "שלום " : "word ").repeat(20).slice(0, 99 - token.indexOf(marker) - 1) + " ";
      const source = lead + token + " trailing words without a sentence break ".repeat(20);
      expect(source[99]).toBe(marker);
      for (const engine of ["edge", "clone"] as const) {
        const chunks = chunkTextForLongRead(source, engine);
        expect(source.slice(chunks[0].length, chunks[0].length + 1), "RealClauseBoundary head ends at whitespace").toMatch(/\s/u);
        expect(chunks.join(" ").match(/\S+/gu), "RealClauseBoundary token conservation").toEqual(source.match(/\S+/gu));
      }
    });
  }

  it("fuzzes 6000 engine/text pairs with no head token splits or character drops/duplicates", async () => {
    const { chunkTextForLongRead } = await import("../tts");
    const vocabulary = ["https://example.test/path", "1,000", "inside;token", "מילה،המשך", "שלום", "U.S.", "alpha", "…"];
    let seed = 2261, splits = 0, changed = 0;
    const next = () => (seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0);
    for (let i = 0; i < 3000; i++) {
      const source = Array.from({ length: 60 + next() % 30 }, () => vocabulary[(next() >>> 16) % vocabulary.length]).join(" ");
      for (const engine of ["edge", "clone"] as const) {
        const chunks = chunkTextForLongRead(source, engine), head = chunks[0];
        if (head.length < source.length && !/\s/u.test(source[head.length])) splits++;
        if (chunks.join("").replace(/\s/gu, "") !== source.replace(/\s/gu, "")) changed++;
      }
    }
    console.log(`F-speech R2 fuzz: 6000 pairs; ${splits} head token splits; ${changed} character drops/duplicates`);
    expect(splits, "RealClauseBoundary fuzz").toBe(0);
    expect(changed).toBe(0);
  });
});
