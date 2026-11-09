import { describe, expect, it } from "bun:test";
import {
  RECORDING_PAUSE_TAIL_BYTES,
  RecordingPauseGate,
} from "../recording-pause";

// One VAD chunk of 16 kHz mono PCM16: 512 samples, 32 ms.
const CHUNK = 1024;

describe("RecordingPauseGate", () => {
  it("keeps ~200 ms after the click, then admits nothing until resume", () => {
    expect(RECORDING_PAUSE_TAIL_BYTES).toBe(6400); // 200 ms * 16 kHz * 2 bytes
    const gate = new RecordingPauseGate(1_000);
    for (let i = 0; i < 10; i++) expect(gate.admit(CHUNK)).toBe(true);
    expect(gate.pause(1_400)).toBe(true);
    expect(gate.pause(1_401)).toBe(false); // already paused
    const tail = Array.from({ length: 7 }, () => gate.admit(CHUNK));
    expect(tail).toEqual(Array(7).fill(true)); // 7 * 1024 >= 6400: the word in flight is kept
    expect(gate.isDropping()).toBe(true);
    for (let i = 0; i < 20; i++) expect(gate.admit(CHUNK)).toBe(false);
    expect(gate.resume(3_400)).toBe(true);
    expect(gate.resume(3_401)).toBe(false);
    expect(gate.admit(CHUNK)).toBe(true);
    expect(gate.spans(4_000)).toEqual([
      { start_ms: 400, end_ms: 2_400, audio_offset_ms: 544, dropped_ms: 640 },
    ]);
  });

  it("freezes the active clock while paused, so deadlines skip paused time", () => {
    const gate = new RecordingPauseGate(0);
    expect(gate.activeNow(5_000)).toBe(5_000);
    gate.pause(5_000);
    expect(gate.activeNow(65_000)).toBe(5_000);
    gate.resume(65_000);
    expect(gate.activeNow(70_000)).toBe(10_000);
    gate.pause(80_000);
    gate.resume(81_000);
    expect(gate.activeNow(90_000)).toBe(29_000);
  });

  it("closes an open span when the take ends while paused", () => {
    const gate = new RecordingPauseGate(0);
    gate.admit(CHUNK);
    gate.pause(100);
    for (let i = 0; i < 9; i++) gate.admit(CHUNK);
    expect(gate.spans(900)).toEqual([
      { start_ms: 100, end_ms: 900, audio_offset_ms: 256, dropped_ms: 64 },
    ]);
  });

  it("a resume inside the tail drops nothing and still records the span", () => {
    const gate = new RecordingPauseGate(0);
    gate.pause(10);
    gate.admit(CHUNK);
    gate.resume(40);
    gate.admit(CHUNK);
    expect(gate.spans(50)).toEqual([
      { start_ms: 10, end_ms: 40, audio_offset_ms: 32, dropped_ms: 0 },
    ]);
  });
});
