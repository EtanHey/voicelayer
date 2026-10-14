import {expect, test} from "bun:test";
import {readTTSControlsStatus, recordFirstAudio} from "../tts-controls-status";
test("last first audio preserves actual engine, preview origin, and fallback attribution", () => {
  recordFirstAudio("long", 800, {engine: "edge-tts", origin: "preview", fallback: true});
  expect(readTTSControlsStatus().profiles.long).toMatchObject({last_first_audio_ms: 800,
    last_first_audio: {engine: "edge-tts", origin: "preview", fallback: true}});
});
