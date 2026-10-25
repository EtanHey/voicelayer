import { describe, expect, it } from "bun:test";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { markdownToSpeech } from "../tts/markdown-to-speech";
import { structuredReadDisplay } from "../tts/structured-display";
import { serializeEvent, VOICEBAR_SOCKET_EVENT_MAX_BYTES, type StateEvent } from "../socket-protocol";

describe("P14b layout over unchanged speech chunks", () => {
  it("speaks a list starting at 2 without duplicate marker decorations", () => {
    const source = "2. Alpha.\n3. Beta.";
    const projection = projectStructuredSpeech(source);
    const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
    expect(projection.displayText).toBe(source);
    expect(projection.speechText).toBe(markdownToSpeech(source));
    expect(display?.text).toBe("2. Alpha. 3. Beta.");
    expect(display?.blocks.map(block => block.marker)).toEqual([undefined, undefined]);
    expect(display?.blocks.map(block => [block.word_start, block.word_end])).toEqual([[0, 2], [2, 4]]);
    expect(display?.blocks.map(block => block.starts_section)).toEqual([true, false]);
    expect(new Set(display?.blocks.map(block => block.section_id)).size).toBe(1);
  });

  it("groups adjacent short paragraphs and items under the supplied existing budget", () => {
    const projection = projectStructuredSpeech("Intro.\n\n2. A.\n3. B.\n\nTail.");
    const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
    expect(display?.blocks.map(block => block.kind)).toEqual(["paragraph", "list-item", "list-item", "paragraph"]);
    expect(new Set(display?.blocks.map(block => block.section_id)).size).toBe(1);
    expect(display?.blocks.every(block => block.starts_block)).toBe(true);
  });

  it("starts new display sections at semantic boundaries when longer units cannot fit", () => {
    const projection = projectStructuredSpeech("# One\n\nAlpha sentence.\n\nBeta sentence.\n\n# Two\nEnd.");
    const [display] = structuredReadDisplay(projection, [projection.speechText], 25);
    expect(display?.blocks.map(block => block.kind)).toEqual(["heading", "paragraph", "paragraph", "heading", "paragraph"]);
    expect(display?.blocks.filter(block => block.starts_section).map(block => block.word_start)).toEqual([0, 3, 5]);
    expect(display?.blocks.filter(block => block.kind === "heading").every(block => block.starts_section)).toBe(true);
  });

  it("conserves UTF-16 speech slices and whole replacement anchors across legacy chunks", () => {
    const projection = projectStructuredSpeech("2) שלום 😀 same same.\n3. Next.");
    const texts = ["2. שלום 😀 same", "same. 3. Next."];
    const displays = structuredReadDisplay(projection, texts, 400);
    expect(displays.every(Boolean)).toBe(true);
    for (const display of displays) {
      if (!display) throw new Error("display required");
      expect(projection.speechText.slice(display.speech_start, display.speech_start + display.text.length)).toBe(display.text);
      for (const block of display.blocks) {
        expect(block.ranges.map(range => projection.speechText.slice(range.speech.start, range.speech.end)).join(""))
          .toBe(projection.speechText.slice(block.speech.start, block.speech.end));
      }
    }
    const first = displays[0]?.blocks[0], continuation = displays[1]?.blocks[0];
    expect(continuation?.source).toEqual(first?.source);
    expect(continuation?.ranges[0].source).toEqual(first?.ranges[0].source);
    expect(continuation?.marker).toBeUndefined();
    expect(continuation?.starts_block).toBe(false);
  });

  it("does not reconstruct an already flattened inline numeric boundary", () => {
    const projection = projectStructuredSpeech("End.3. Next. Item 4. stays inline.");
    const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
    expect(display?.blocks).toHaveLength(1);
    expect(display?.blocks[0].kind).toBe("paragraph");
    expect(display?.blocks[0].marker).toBeUndefined();
    expect(display?.text).toBe(projection.speechText);
  });

  it("retains captured table-row and setext-heading structure without new speech tokens", () => {
    const source = "Title\n=====\n\n| A | | B |\n| --- | --- | --- |\n| C | | D |";
    const projection = projectStructuredSpeech(source);
    const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
    expect(display?.blocks.map(block => block.kind)).toEqual(["heading", "table-row", "table-row"]);
    expect(display?.text).toBe(markdownToSpeech(source));
    expect(display?.blocks.every(block => block.marker === undefined)).toBe(true);
  });

  it("retains exact anchors when a legacy hard cut divides an unspaced word", () => {
    const projection = projectStructuredSpeech("2) " + "x".repeat(799) + ".");
    const texts = [projection.speechText.slice(0, 400), projection.speechText.slice(400)];
    const displays = structuredReadDisplay(projection, texts, 400);
    expect(displays.map(display => display?.speech_start)).toEqual([0, 400]);
    expect(displays.map(display => display?.text.length)).toEqual([400, 403]);
    expect(displays[1]?.blocks[0].ranges[0].source).toEqual(displays[0]?.blocks[0].ranges[0].source);
    expect(displays[1]?.blocks[0].marker).toBeUndefined();
  });

  it("fails to legacy for changed text or a missing non-whitespace chunk", () => {
    const projection = projectStructuredSpeech("2. Alpha.\n3. Beta.");
    expect(structuredReadDisplay(projection, ["Different."], 400)).toEqual([undefined]);
    expect(structuredReadDisplay(projection, ["Beta."], 400)).toEqual([undefined]);
    const markup = projectStructuredSpeech("2. A<br>B.");
    expect(structuredReadDisplay(markup, ["AB."], 400)).toEqual([undefined]);
  });

  it("keeps paused receipt identity and cursor within the frame when retained layout is oversized", () => {
    const projection = projectStructuredSpeech("2. Alpha.");
    const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
    if (!display) throw new Error("display required");
    const wire = serializeEvent({ type: "playback_state", state: "paused", playback_id: "player", generation: 7,
      offset_ms: 1250, chunk_offset_ms: 250,
      long_read: { id: "read", chunk_index: 0, chunk_count: 1, chunk_start_ms: 1000,
        display: { ...display, blocks: Array.from({ length: 500 }, () => display.blocks[0]) } } });
    expect(Buffer.byteLength(wire)).toBeLessThanOrEqual(VOICEBAR_SOCKET_EVENT_MAX_BYTES);
    expect(JSON.parse(wire)).toEqual({ type: "playback_state", state: "paused", playback_id: "player", generation: 7,
      offset_ms: 1250, chunk_offset_ms: 250,
      long_read: { id: "read", chunk_index: 0, chunk_count: 1, chunk_start_ms: 1000 } });
  });

  it("serializes bounded layout, dropping an oversized optional layout before any speech text", () => {
    const projection = projectStructuredSpeech("2. Alpha.\n3. Beta.");
    const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
    if (!display) throw new Error("display required");
    const event: StateEvent = { type: "state", state: "speaking", text: display.text,
      request_id: "selection", long_read: { id: "read", chunk_index: 0, chunk_count: 1, chunk_start_ms: 0, display } };
    expect(JSON.parse(serializeEvent(event))).toEqual(event);
    const oversized: StateEvent = { ...event, long_read: { id: "read", chunk_index: 0, chunk_count: 1, chunk_start_ms: 0,
      display: { ...display, blocks: Array.from({ length: 500 }, () => display.blocks[0]) } } };
    const wire = serializeEvent(oversized), decoded = JSON.parse(wire);
    expect(Buffer.byteLength(wire)).toBeLessThanOrEqual(VOICEBAR_SOCKET_EVENT_MAX_BYTES);
    expect(decoded.text).toBe(display.text);
    expect(decoded.request_id).toBe("selection");
    expect(decoded.long_read.id).toBe("read");
    expect(decoded.long_read.display).toBeUndefined();
  });
});
