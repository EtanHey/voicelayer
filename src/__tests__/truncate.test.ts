import { describe, it, expect } from "bun:test";
import { truncateAtWordBoundary } from "../tts/truncate";

describe("truncateAtWordBoundary", () => {
  it("returns text unchanged if under limit", () => {
    expect(truncateAtWordBoundary("hello world", 300)).toBe("hello world");
  });

  it("returns text unchanged if exactly at limit", () => {
    const text = "a".repeat(300);
    expect(truncateAtWordBoundary(text, 300)).toBe(text);
  });

  it("truncates at last word boundary before limit", () => {
    // 10 chars: "hello worl" would be naive slice
    // Should get: "hello"
    expect(truncateAtWordBoundary("hello world", 10)).toBe("hello");
  });

  it("does not cut mid-word for long text", () => {
    const words =
      "The quick brown fox jumps over the lazy dog and continues running across the field";
    const result = truncateAtWordBoundary(words, 30);
    // Should end at a word boundary
    expect(result.length).toBeLessThanOrEqual(30);
    expect(result).toMatch(/\w$/); // ends with a complete word char, not space
    // The result should not end with a partial word
    expect(words.startsWith(result)).toBe(true);
    // Next char in original should be a space (we cut at word boundary)
    expect(words[result.length]).toBe(" ");
  });

  it("handles 300+ char input ending at word boundary for F5-TTS", () => {
    // Build text that is exactly 310 chars with word "boundary" crossing at 300
    const base = "This is a test sentence that we repeat many times. ";
    const longText = base.repeat(10); // ~510 chars
    expect(longText.length).toBeGreaterThan(300);

    const result = truncateAtWordBoundary(longText, 300);
    expect(result.length).toBeLessThanOrEqual(300);
    // Must end at a complete word
    expect(result).not.toMatch(/\s$/); // no trailing space
    // Next char in original should be a space (clean word boundary)
    if (result.length < longText.length) {
      expect(longText[result.length]).toBe(" ");
    }
  });

  it("handles 240+ char input for XTTS limit", () => {
    const base = "Voice synthesis requires careful text handling for quality. ";
    const longText = base.repeat(6); // ~360 chars
    expect(longText.length).toBeGreaterThan(240);

    const result = truncateAtWordBoundary(longText, 240);
    expect(result.length).toBeLessThanOrEqual(240);
    // Must end at a complete word
    if (result.length < longText.length) {
      expect(longText[result.length]).toBe(" ");
    }
  });

  it("falls back to hard cut for single long word", () => {
    const longWord = "a".repeat(400);
    const result = truncateAtWordBoundary(longWord, 300);
    expect(result.length).toBe(300);
    expect(result).toBe("a".repeat(300));
  });

  it("handles empty string", () => {
    expect(truncateAtWordBoundary("", 300)).toBe("");
  });

  it("handles text with multiple spaces", () => {
    const text = "hello   world   this   is   a   test   with   spaces";
    const result = truncateAtWordBoundary(text, 20);
    expect(result.length).toBeLessThanOrEqual(20);
    expect(text.startsWith(result)).toBe(true);
  });
});
