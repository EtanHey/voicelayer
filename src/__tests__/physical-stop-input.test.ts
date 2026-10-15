import { describe, expect, test } from "bun:test";
import { PHYSICAL_STOP_WINDOW_MS, physicalStopInput } from "../physical-stop-input";
import { parseCommand } from "../socket-protocol";

function fixture(clicks: number[] = [], speechEndMs = 1_500, durationMs = 2_000) {
  const pcm = new Uint8Array(durationMs * 32);
  const view = new DataView(pcm.buffer);
  for (let i = 0; i < durationMs * 16; i++) {
    let sample = i < speechEndMs * 16 ? Math.sin(i * Math.PI / 40) * 1_500 : 10;
    for (const click of clicks) {
      const age = i - click * 16;
      if (age >= 0 && age < 320) sample += (i % 2 ? -1 : 1) * 9_000 * Math.exp(-age / 55);
    }
    view.setInt16(i * 2, sample, true);
  }
  return pcm;
}

describe("physical stop transcription input", () => {
  test("cuts a unique sharp click at its onset minus 5ms; leaves original bytes intact", () => {
    const pcm = fixture([1_750]);
    const original = pcm.slice();
    const result = physicalStopInput(pcm, true);
    expect(result.reason).toBe("cut");
    expect(result.pcmData.byteLength).toBe(1_745 * 32);
    expect(result.pcmData).toEqual(original.slice(0, 1_745 * 32));
    expect(pcm).toEqual(original);
  });
  test("speech reaching the window without a click is untouched", () => {
    const pcm = fixture([], 1_800);
    const result = physicalStopInput(pcm, true);
    expect(result.reason).toBe("no-clear-transient");
    expect(result.pcmData).toBe(pcm);
  });
  test.each([[1_700, 1_850], [1_750, 1_780]])("two separate transients are ambiguous (%j)", (...clicks) => {
    const pcm = fixture(clicks);
    const result = physicalStopInput(pcm, true);
    expect(result.reason).toBe("ambiguous-transients");
    expect(result.pcmData).toBe(pcm);
  });
  test("legacy, timeout, cancel and Ask receive no physical-press opt-in", () => {
    const pcm = fixture([1_750]);
    expect(physicalStopInput(pcm, false).pcmData).toBe(pcm);
  });
  test("ignores a click before the bounded window", () => {
    const pcm = fixture([1_600]);
    expect(physicalStopInput(pcm, true).pcmData).toBe(pcm);
  });
  test("padding never cuts before the window starts", () => {
    const pcm = fixture([2_000 - PHYSICAL_STOP_WINDOW_MS]);
    const result = physicalStopInput(pcm, true);
    expect(result.reason).toBe("cut");
    expect(result.pcmData.byteLength).toBe((2_000 - PHYSICAL_STOP_WINDOW_MS) * 32);
  });
  test("constant loud audio without an isolated transient is preserved", () => {
    const pcm = fixture([], 2_000);
    expect(physicalStopInput(pcm, true).pcmData).toBe(pcm);
  });
  test("physical press flag round-trips; legacy Stop remains unchanged", () => {
    expect(parseCommand('{"cmd":"stop","physical_press":true}')).toEqual({ cmd: "stop", physical_press: true });
    expect(parseCommand('{"cmd":"stop"}')).toEqual({ cmd: "stop" });
    expect(parseCommand('{"cmd":"stop","physical_press":"true"}')).toBeNull();
  });
});
