import { afterEach, describe, expect, it } from "bun:test";
import { readFileSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { TTS_HISTORY_FILE, ttsHistoryFilePath } from "../paths";
import { addToHistory, historyReplayMetadata, loadHistory, TTS_HISTORY_DISPLAY_MAX_BYTES, type TTSHistoryEntry } from "../tts";
import { serializeEvent, VOICEBAR_STRUCTURED_READ_MAX_BYTES, type StateEvent } from "../socket-protocol";
import { structuredReadDisplay, type StructuredChunkDisplay } from "../tts/structured-display";
import { projectStructuredSpeech } from "../tts/structured-speech";
import { TEST_TMP } from "./setup/test-tmp";

function headingDisplay(text = "Heading."): StructuredChunkDisplay {
  const projection = projectStructuredSpeech(`# ${text}`);
  const [display] = structuredReadDisplay(projection, [projection.speechText], 400);
  if (!display) throw new Error("heading fixture requires layout");
  return display;
}

const display = headingDisplay();
const oversizedDisplay: StructuredChunkDisplay = {
  ...display,
  blocks: Array.from({ length: Math.ceil(5 * 1024 * 1024 / Buffer.byteLength(JSON.stringify(display.blocks[0]))) },
    () => display.blocks[0]),
};

afterEach(() => {
  for (const path of [TTS_HISTORY_FILE, ...Array.from({ length: 20 }, (_, i) => ttsHistoryFilePath(i))]) {
    try { unlinkSync(path); } catch {}
  }
});

describe("S3.1 structured display bounds", () => {
  it("bounds twenty retained decorations without losing history text or audio", () => {
    const audio = `${TEST_TMP}/s3-display-bound.mp3`;
    writeFileSync(audio, "retained audio");
    for (let i = 0; i < 21; i++) {
      expect(addToHistory(display.text, audio, "fixture", [], { display: oversizedDisplay })).toBeDefined();
    }
    expect(statSync(TTS_HISTORY_FILE).size).toBeLessThan(1024 * 1024);
    const entries = loadHistory();
    expect(entries).toHaveLength(20);
    for (const entry of entries) {
      expect(entry.text).toBe(display.text);
      expect(entry.display === undefined).toBe(true);
      expect(readFileSync(entry.file, "utf8")).toBe("retained audio");
      expect(historyReplayMetadata(entry)).toEqual({ text: display.text, voice: "fixture" });
    }
  });

  it("drops legacy oversized decorations on load and replay while retaining text and timings", () => {
    const entry: TTSHistoryEntry = { id: 0, file: `${TEST_TMP}/legacy.mp3`, text: display.text,
      voice: "fixture", timestamp: 0, display: oversizedDisplay,
      wordBoundaries: [{ text: display.text, offset_ms: 0, duration_ms: 100 }] };
    writeFileSync(TTS_HISTORY_FILE, JSON.stringify([entry]));
    expect(loadHistory()[0].display === undefined).toBe(true);
    const replay = historyReplayMetadata(entry);
    expect(replay.display === undefined).toBe(true);
    expect(replay.text).toBe(entry.text);
    expect(replay.wordBoundaries).toEqual(entry.wordBoundaries);
    const audio = `${TEST_TMP}/legacy-rewrite.mp3`;
    writeFileSync(audio, "audio");
    addToHistory("Next.", audio, "fixture");
    expect(statSync(TTS_HISTORY_FILE).size).toBeLessThan(1024 * 1024);
  });

  it("keeps ordinary retained headings unchanged", () => {
    const audio = `${TEST_TMP}/s3-display-small.mp3`;
    writeFileSync(audio, "audio");
    const ref = addToHistory(display.text, audio, "fixture", [], { display });
    const entry = loadHistory().find(e => e.id === ref?.id);
    if (!entry) throw new Error("history fixture missing");
    expect(entry.display).toEqual(display);
    expect(historyReplayMetadata(entry)).toEqual({ text: display.text, voice: "fixture", display });
  });

  for (const extraBytes of [0, 1]) {
    it(`measures escaped UTF-8 layout at the history byte limit plus ${extraBytes}`, () => {
      const section_id = "שלום 😀 \"heading\"\n".repeat(1000);
      const seed = { ...display, blocks: [{ ...display.blocks[0], section_id }] };
      const padding = TTS_HISTORY_DISPLAY_MAX_BYTES - Buffer.byteLength(JSON.stringify(seed)) + extraBytes;
      const candidate = { ...seed, blocks: [{ ...seed.blocks[0], section_id: section_id + "x".repeat(padding) }] };
      expect(Buffer.byteLength(JSON.stringify(candidate))).toBe(TTS_HISTORY_DISPLAY_MAX_BYTES + extraBytes);
      const audio = `${TEST_TMP}/s3-display-limit.mp3`;
      writeFileSync(audio, "audio");
      for (let i = 0; i < 21; i++) addToHistory(display.text, audio, "fixture", [], { display: candidate });
      expect(statSync(TTS_HISTORY_FILE).size).toBeLessThanOrEqual(20 * TTS_HISTORY_DISPLAY_MAX_BYTES + 10_000);
      const entries = loadHistory();
      expect(entries).toHaveLength(20);
      expect(entries.every(entry => (entry.display !== undefined) === (extraBytes === 0))).toBe(true);
      expect(entries.every(entry => entry.text === display.text)).toBe(true);
    });
  }

  it("drops oversized layout before speech text that fits the 1 MiB frame", () => {
    const text = "שלום 😀 \"heading\"\n".repeat(1000);
    const event: StateEvent = { type: "state", state: "speaking", text, voice: "fixture",
      playback_id: "retained", generation: 3, display: { ...oversizedDisplay, text } };
    const wire = serializeEvent(event);
    expect(Buffer.byteLength(wire)).toBeLessThanOrEqual(VOICEBAR_STRUCTURED_READ_MAX_BYTES);
    const decoded = JSON.parse(wire);
    expect(decoded.text === text).toBe(true);
    expect(decoded.display).toBeUndefined();
    expect(decoded.playback_id).toBe("retained");
    expect(event.display === undefined).toBe(false);
    expect(event.text).toBe(text);
  });

  for (const extraBytes of [0, 1]) {
    it(`includes the newline and escaped UTF-8 in the socket limit plus ${extraBytes}`, () => {
      const event: StateEvent = { type: "state", state: "speaking", text: display.text,
        display: { ...display, blocks: [{ ...display.blocks[0], section_id: "שלום 😀 \"\n" }] } };
      const block = event.display!.blocks[0];
      const padding = VOICEBAR_STRUCTURED_READ_MAX_BYTES - Buffer.byteLength(JSON.stringify(event) + "\n") + extraBytes;
      block.section_id += "x".repeat(padding);
      const wire = serializeEvent(event);
      expect(Buffer.byteLength(wire)).toBeLessThanOrEqual(VOICEBAR_STRUCTURED_READ_MAX_BYTES);
      const decoded = JSON.parse(wire);
      expect(decoded.text).toBe(display.text);
      expect(decoded.display !== undefined).toBe(extraBytes === 0);
    });
  }

  for (const type of ["state", "playback_state"] as const) {
    it(`bounds an oversized preparing document on ${type} fallback`, () => {
      const long_read = { id: "read", chunk_index: 0, chunk_count: 1, chunk_start_ms: 0,
        text: "# Heading\n".repeat(550_000), preparing: true,
        chunk_word_starts: [0], display: oversizedDisplay };
      const event = type === "state"
        ? { type, state: "speaking", text: "Preparing speech…", playback_id: "owner", generation: 7, long_read } satisfies StateEvent
        : { type, state: "paused", playback_id: "owner", generation: 7,
          offset_ms: 1250, chunk_offset_ms: 250, long_read };
      const wire = serializeEvent(event);
      expect(Buffer.byteLength(wire)).toBeLessThanOrEqual(VOICEBAR_STRUCTURED_READ_MAX_BYTES);
      const decoded = JSON.parse(wire);
      expect(decoded.playback_id).toBe("owner");
      expect(decoded.generation).toBe(7);
      expect(decoded.long_read.id).toBe("read");
      expect(decoded.long_read.display).toBeUndefined();
      expect(long_read.text.length).toBe(5_500_000);
      if (type === "state") expect(decoded.text).toBe("Preparing speech…");
      else expect(decoded.offset_ms).toBe(1250);
    });
  }
});
