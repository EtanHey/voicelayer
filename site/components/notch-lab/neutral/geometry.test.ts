import { describe, expect, test } from "bun:test";

import {
  NEUTRAL_NOTCH_TOKENS,
  getNeutralNotchGeometry,
} from "./geometry";

describe("neutral notch geometry", () => {
  test("keeps the physical camera core at exactly 185 by 32 pixels", () => {
    expect(NEUTRAL_NOTCH_TOKENS.core).toEqual({ width: 185, height: 32 });
  });

  test("idle adds no rendered pixels beyond the hardware core", () => {
    const idle = getNeutralNotchGeometry("idle");

    expect(idle.width).toBe(185);
    expect(idle.height).toBe(32);
    expect(idle.leftWingWidth).toBe(0);
    expect(idle.rightWingWidth).toBe(0);
    expect(idle.lowerPanelHeight).toBe(0);
  });

  test("recording expands sideways only and preserves the camera gap", () => {
    const recording = getNeutralNotchGeometry("recording");

    expect(recording.leftWingWidth).toBe(104);
    expect(recording.rightWingWidth).toBe(176);
    expect(recording.cameraGapWidth).toBe(185);
    expect(recording.width).toBe(
      recording.leftWingWidth +
        recording.cameraGapWidth +
        recording.rightWingWidth,
    );
    expect(recording.width).toBe(465);
    expect(recording.height).toBe(32);
    expect(recording.lowerPanelHeight).toBe(0);
  });

  test("uses an almost-square five-pixel inverse join and turns vertical", () => {
    const teleprompter = getNeutralNotchGeometry("teleprompter");

    expect(teleprompter.inverseJoinRadius).toBe(5);
    expect(teleprompter.verticalTurnDistance).toBe(5);
    expect(teleprompter.panelWidth).toBe(465);
    expect(teleprompter.topBandWidth).toBe(465);
  });

  test("teleprompter is the only state with a lower panel", () => {
    const idle = getNeutralNotchGeometry("idle");
    const recording = getNeutralNotchGeometry("recording");
    const teleprompter = getNeutralNotchGeometry("teleprompter");

    expect(idle.lowerPanelHeight).toBe(0);
    expect(recording.lowerPanelHeight).toBe(0);
    expect(teleprompter.lowerPanelHeight).toBe(196);
    expect(teleprompter.height).toBe(
      NEUTRAL_NOTCH_TOKENS.core.height + teleprompter.lowerPanelHeight,
    );
  });

  test("reserves one fixed waveform slot across live states", () => {
    const recording = getNeutralNotchGeometry("recording");
    const teleprompter = getNeutralNotchGeometry("teleprompter");

    expect(recording.waveformSlotWidth).toBe(72);
    expect(teleprompter.waveformSlotWidth).toBe(
      recording.waveformSlotWidth,
    );
  });
});
