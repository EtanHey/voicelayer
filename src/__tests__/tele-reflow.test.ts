import { expect, test } from "bun:test";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { projectSpeakableText } from "../speakable-text";
import { structuredReadDisplay } from "../tts/structured-display";

test("numbered selection retains numbers and maps spoken numbers to their display tokens", () => {
  const source = "1. Pick up the blue basket.\n2. Put it down.";
  const structured = projectStructuredSpeech(source);
  expect(structured.speechText).toBe("1. Pick up the blue basket. 2. Put it down.");
  const [display] = structuredReadDisplay(structured, [structured.speechText], 400);
  expect(display?.blocks.map(b => b.word_start)).toEqual([0, 6]);
  for (const engine of ["edge", "clone"] as const) {
    const projected = projectSpeakableText(source, [], engine);
    expect(projected.speechText).toBe("one. Pick up the blue basket. two. Put it down.");
    const marker = projected.ranges.find(r => projected.speechText.slice(r.speech.start, r.speech.end) === "one.");
    expect(marker && source.slice(marker.source.start, marker.source.end)).toBe("1.");
  }
});

test("flattened selection numbers retain measured display-token offsets", async () => {
  const { alignWordBoundariesToDisplayText } = await import("../tts");
  const text = projectStructuredSpeech("1. Pick up the blue basket.\n2. Put it down.").speechText;
  for (const engine of ["edge", "clone"] as const) {
    const projection = projectSpeakableText(text, [], engine);
    const measured = projection.speechText.split(/\s+/).map((text, index) => ({
      text, offset_ms: index * 200, duration_ms: 150,
    }));
    const aligned = alignWordBoundariesToDisplayText(text, projection.speechText, measured, projection.ranges);
    expect(aligned.map(row => row.text)).toEqual(text.split(/\s+/));
    expect(aligned.map(row => row.offset_ms)).toEqual(measured.map(row => row.offset_ms));
    expect(aligned[0].duration_ms).toBe(150);
    expect(aligned[6].duration_ms).toBe(150);
  }
});

test("Hebrew list markers remain numeric for the locale's voice frontend", () => {
  for (const engine of ["edge", "clone"] as const) {
    expect(projectSpeakableText("1. שלום עולם\n2. עוד משפט", [], engine).speechText)
      .toBe("1. שלום עולם. 2. עוד משפט.");
  }
});
