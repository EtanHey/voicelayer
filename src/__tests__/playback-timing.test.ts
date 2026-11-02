import { describe, expect, it } from "bun:test";
import { initialPlaybackTiming } from "../tts/playback-timing";

describe("first-player timing data", () => {
  it("estimates exact display token identities across the chunk duration", () => {
    const event = initialPlaybackTiming("One two three.", 3000);
    expect(event).toMatchObject({ type: "subtitle", words: [], duration_ms: 3000 });
    if (!("aligned_words" in event) || !event.aligned_words) throw new Error("Missing initial estimate");
    expect(event.aligned_words.map(word => word.text)).toEqual(["One", "two", "three."]);
    expect(event.aligned_words.map(word => word.word_index)).toEqual([0, 1, 2]);
    expect(event.aligned_words.every(word => word.estimated && word.offset_ms !== null && (word.duration_ms ?? 0) > 0)).toBe(true);
    const end = event.aligned_words.at(-1)!;
    expect(end.offset_ms! + end.duration_ms!).toBe(3000);
  });
  it("real retained alignment and Edge boundaries take priority over estimates", () => {
    const aligned = [{ word_index: 0, text: "One", offset_ms: 120, duration_ms: 800 }];
    expect(initialPlaybackTiming("One", 1000, [], aligned)).toMatchObject({ aligned_words: aligned });
    const words = [{ text: "One", offset_ms: 100, duration_ms: 900 }];
    expect(initialPlaybackTiming("One", 1000, words)).toEqual({ type: "subtitle", words });
    expect(initialPlaybackTiming("One", 1000, words, aligned)).toMatchObject({ aligned_words: aligned });
  });
  it("null alignment still receives startup estimates without a decoder or player", () => {
    const event = initialPlaybackTiming("שלום read/write", undefined,
      [], [{ word_index: 0, text: "שלום", offset_ms: null, duration_ms: null }]);
    expect(event).toMatchObject({ aligned_words: [
      { word_index: 0, text: "שלום", estimated: true },
      { word_index: 1, text: "read", estimated: true },
      { word_index: 2, text: "/write", estimated: true },
    ] });
  });
});
