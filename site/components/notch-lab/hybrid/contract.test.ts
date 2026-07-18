import { describe, expect, test } from "bun:test";
describe("unified glass notch contract", () => {
  test("keeps idle inside the physical 185 by 32 camera housing", async () => {
    const contract = (await import("./contract")) as Record<string, any>;
    const idle = contract.getHybridNotchGeometry?.("idle");

    expect(idle).toEqual({
      width: 185,
      height: 32,
      lowerSurfaceHeight: 0,
      leftWingWidth: 0,
      rightWingWidth: 0,
      bodyLeftWidth: 0,
      bodyRightWidth: 0,
    });
  });

  test("opens the idle launcher into side wings without growing downward", async () => {
    const contract = (await import("./contract")) as Record<string, any>;
    const hover = contract.getHybridNotchGeometry?.("hover");

    expect(hover).toEqual({
      width: 285,
      height: 32,
      lowerSurfaceHeight: 0,
      leftWingWidth: 36,
      rightWingWidth: 64,
      bodyLeftWidth: 36,
      bodyRightWidth: 64,
    });
  });

  test("expands recording sideways and teleprompter downward", async () => {
    const contract = (await import("./contract")) as Record<string, any>;
    const recording = contract.getHybridNotchGeometry?.("recording");
    const teleprompter = contract.getHybridNotchGeometry?.("teleprompter");

    expect(recording).toEqual({
      width: 409,
      height: 32,
      lowerSurfaceHeight: 0,
      leftWingWidth: 72,
      rightWingWidth: 152,
      bodyLeftWidth: 72,
      bodyRightWidth: 152,
    });
    expect(teleprompter).toEqual({
      ...recording,
      width: 465,
      height: 228,
      lowerSurfaceHeight: 196,
      leftWingWidth: 76,
      rightWingWidth: 88,
      bodyLeftWidth: 140,
      bodyRightWidth: 140,
    });
  });

  test("defines one frameless glass surface outside an opaque core", async () => {
    const contract = (await import("./contract")) as Record<string, any>;

    expect(contract.HYBRID_MATERIAL).toEqual({
      blackToGlassBlendPx: 16,
      compactWingBorders: true,
      coreUsesBackdropFilter: false,
      fadeToContentGapPx: 8,
      lowerSurfaceLayers: 1,
      teleprompterBodyOutline: true,
      teleprompterInsetFrames: 0,
      wingOuterPaddingPx: 8,
    });
  });

  test("keeps equal fade-safe and outer padding around content-fit teleprompter wings", async () => {
    const contract = (await import("./contract")) as Record<string, any>;
    const teleprompter = contract.getHybridNotchGeometry?.("teleprompter");
    const material = contract.HYBRID_MATERIAL;
    const reservedPadding =
      material.blackToGlassBlendPx +
      material.fadeToContentGapPx +
      material.wingOuterPaddingPx;

    expect(teleprompter.leftWingWidth - reservedPadding).toBe(44);
    expect(teleprompter.rightWingWidth - reservedPadding).toBe(56);
  });

  test("exposes exactly history, dictionary, and microphone on hover", async () => {
    const contract = (await import("./contract")) as Record<string, any>;

    expect(contract.HOVER_ACTIONS).toEqual([
      "history",
      "dictionary",
      "microphone",
    ]);
  });

  test("opens wings before panel and closes in the reverse order", async () => {
    const contract = (await import("./contract")) as Record<string, any>;

    expect(contract.getHybridMotionPhases?.("opening")).toEqual([
      "wings",
      "panel",
      "content",
    ]);
    expect(contract.getHybridMotionPhases?.("closing")).toEqual([
      "content",
      "panel",
      "wings",
    ]);
    expect(contract.HYBRID_MOTION.panelDelaySeconds).toBe(0.05);
    expect(contract.HYBRID_MOTION.contentExitSeconds).toBe(0.12);
    expect(contract.HYBRID_MOTION.spring.bounce).toBe(0);
  });
});
