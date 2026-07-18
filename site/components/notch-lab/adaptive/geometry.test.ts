import { describe, expect, test } from "bun:test";

import {
  ADAPTIVE_NOTCH_TOKENS,
  getAdaptiveNotchGeometry,
} from "./geometry";

describe("adaptive notch geometry", () => {
  test("keeps the physical camera housing at 185 by 32 in every state", () => {
    for (const state of ["idle", "recording", "teleprompter"] as const) {
      const geometry = getAdaptiveNotchGeometry(state);

      expect(geometry.core).toEqual({ width: 185, height: 32 });
      expect(geometry.coreMaterial).toBe("opaque-black");
    }
  });

  test("does not expose shared core geometry through a returned result", () => {
    const first = getAdaptiveNotchGeometry("idle");
    first.core.width = 999;

    expect(getAdaptiveNotchGeometry("recording").core).toEqual({
      width: 185,
      height: 32,
    });
  });

  test("idle contributes no pixels beyond the hardware footprint", () => {
    const idle = getAdaptiveNotchGeometry("idle");

    expect(idle.shell).toEqual({ width: 185, height: 32 });
    expect(idle.wings).toEqual({ left: 0, right: 0 });
    expect(idle.lowerPanelHeight).toBe(0);
    expect(idle.adaptiveMaterialRegions).toEqual([]);
  });

  test("recording expands only into compact side wings", () => {
    const recording = getAdaptiveNotchGeometry("recording");

    expect(recording.shell).toEqual({ width: 465, height: 32 });
    expect(recording.wings).toEqual({ left: 104, right: 176 });
    expect(recording.lowerPanelHeight).toBe(0);
    expect(recording.adaptiveMaterialRegions).toEqual([
      "left-wing",
      "right-wing",
    ]);
  });

  test("teleprompter is the only state with a lower panel", () => {
    expect(getAdaptiveNotchGeometry("idle").lowerPanelHeight).toBe(0);
    expect(getAdaptiveNotchGeometry("recording").lowerPanelHeight).toBe(0);

    const teleprompter = getAdaptiveNotchGeometry("teleprompter");
    expect(teleprompter.shell).toEqual({ width: 465, height: 228 });
    expect(teleprompter.lowerPanelHeight).toBe(196);
    expect(teleprompter.adaptiveMaterialRegions).toEqual([
      "left-wing",
      "right-wing",
      "lower-panel",
    ]);
  });

  test("uses an almost-square inverse join rather than a shoulder", () => {
    expect(ADAPTIVE_NOTCH_TOKENS.inverseJoin).toBeGreaterThanOrEqual(4);
    expect(ADAPTIVE_NOTCH_TOKENS.inverseJoin).toBeLessThanOrEqual(6);
    expect(ADAPTIVE_NOTCH_TOKENS.inverseJoin).toBe(5);
  });

  test("reserves a fixed waveform slot", () => {
    expect(ADAPTIVE_NOTCH_TOKENS.waveformSlot).toBe(72);
  });

  test("clips adaptive material to the exact shell and never the core", () => {
    for (const state of ["idle", "recording", "teleprompter"] as const) {
      const geometry = getAdaptiveNotchGeometry(state);

      expect(geometry.clipStrategy).toBe("exact-shell");
      expect(geometry.adaptiveMaterialRegions).not.toContain("core");
    }
  });
});
