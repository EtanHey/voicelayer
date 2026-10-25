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

it("SPEECH-PACING caps only the startup chunk and retains all words", async () => {
  const { chunkTextForLongRead } = await import("../tts");
  const text = "First sentence starts promptly. " + "A longer sentence follows with every original word retained. ".repeat(20);
  const chunks = chunkTextForLongRead(text);
  expect(chunks[0]).toBe("First sentence starts promptly.");
  expect(chunks[0].length).toBeLessThanOrEqual(100);
  expect(chunks.slice(1).some(chunk => chunk.length > 100)).toBe(true);
  expect(normalize(chunks.join(" "))).toBe(normalize(text));
});

it("SPEECH-PACING retains every character of an overlong first token", async () => {
  const { chunkTextForLongRead } = await import("../tts");
  const text = "x".repeat(450) + " final words.";
  const chunks = chunkTextForLongRead(text);
  expect(chunks[0].length).toBeLessThanOrEqual(100);
  expect(chunks.join("").replace(/\s/g, "")).toBe(text.replace(/\s/g, ""));
});

it("SPEECH-PACING retains tokens across repeated whitespace and paragraphs", async () => {
  const { chunkTextForLongRead } = await import("../tts");
  const text = "First   sentence is deliberately long enough to split at a word boundary before its final punctuation ".repeat(4) + ".\n\nLast paragraph.";
  expect(normalize(chunkTextForLongRead(text).join(" "))).toBe(normalize(text));
});
