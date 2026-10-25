import { expect, test } from "bun:test";
import { speechStates, transitionSpeech, initialSpeech } from "../speech-state";
const expected: Record<string, readonly string[]> = {
  requested: ["preparing", "stopped", "cancelled", "failed", "interrupted"],
  preparing: ["playing", "paused", "stopped", "cancelled", "failed", "interrupted"],
  playing: ["paused", "completed", "stopped", "cancelled", "failed", "interrupted"],
  paused: ["playing", "stopped", "cancelled", "failed", "interrupted"],
  completed: [], stopped: [], cancelled: [], failed: [], interrupted: [],
};
for (const from of ["requested", "preparing", "playing", "paused", "completed", "stopped", "cancelled", "failed", "interrupted"] as const) {
  for (const to of ["requested", "preparing", "playing", "paused", "completed", "stopped", "cancelled", "failed", "interrupted"] as const) {
    test(`${from} → ${to}`, () => {
      const state = { ...initialSpeech(), state: from };
      const result = transitionSpeech(state, to, "test", "2026-10-26T12:00:01.000Z");
      expect(result !== null).toBe(expected[from].includes(to));
      expect(state.transitions).toHaveLength(0);
    });
  }
}
test("playing duration excludes paused time", () => {
  let state = initialSpeech();
  for (const [to, seconds] of [["preparing", 0], ["playing", 1], ["paused", 3], ["playing", 10], ["completed", 11]] as const) {
    state = transitionSpeech(state, to, null, `2026-10-26T12:00:${String(seconds).padStart(2, "0")}.000Z`)!;
  }
  expect(state.played_ms).toBe(3000);
  expect(state.playing_since).toBeNull();
  expect(speechStates).toHaveLength(9);
});
