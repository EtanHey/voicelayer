export type HybridNotchState =
  | "idle"
  | "hover"
  | "recording"
  | "teleprompter";

export type HybridNotchGeometry = {
  width: number;
  height: number;
  lowerSurfaceHeight: number;
  leftWingWidth: number;
  rightWingWidth: number;
  bodyLeftWidth: number;
  bodyRightWidth: number;
};

export const HYBRID_GEOMETRY = {
  core: { width: 185, height: 32 },
  hover: { width: 285, leftWingWidth: 36, rightWingWidth: 64 },
  recording: { width: 409, leftWingWidth: 72, rightWingWidth: 152 },
  teleprompter: {
    width: 465,
    lowerSurfaceHeight: 196,
    leftWingWidth: 76,
    rightWingWidth: 88,
    bodyLeftWidth: 140,
    bodyRightWidth: 140,
  },
  inverseJoinRadius: 5,
  waveformSlotWidth: 72,
} as const;

export const HYBRID_MATERIAL = {
  blackToGlassBlendPx: 16,
  compactWingBorders: true,
  coreUsesBackdropFilter: false,
  fadeToContentGapPx: 8,
  lowerSurfaceLayers: 1,
  teleprompterBodyOutline: true,
  teleprompterInsetFrames: 0,
  wingOuterPaddingPx: 8,
} as const;

export const HOVER_ACTIONS = [
  "history",
  "dictionary",
  "microphone",
] as const;

export const HYBRID_MOTION = {
  panelDelaySeconds: 0.05,
  contentExitSeconds: 0.12,
  spring: {
    type: "spring",
    stiffness: 310,
    damping: 31,
    mass: 0.72,
    bounce: 0,
  },
} as const;

export function getHybridNotchGeometry(
  state: HybridNotchState,
): HybridNotchGeometry {
  switch (state) {
    case "idle":
      return {
        width: HYBRID_GEOMETRY.core.width,
        height: HYBRID_GEOMETRY.core.height,
        lowerSurfaceHeight: 0,
        leftWingWidth: 0,
        rightWingWidth: 0,
        bodyLeftWidth: 0,
        bodyRightWidth: 0,
      };
    case "hover":
      return {
        width: HYBRID_GEOMETRY.hover.width,
        height: HYBRID_GEOMETRY.core.height,
        lowerSurfaceHeight: 0,
        leftWingWidth: HYBRID_GEOMETRY.hover.leftWingWidth,
        rightWingWidth: HYBRID_GEOMETRY.hover.rightWingWidth,
        bodyLeftWidth: HYBRID_GEOMETRY.hover.leftWingWidth,
        bodyRightWidth: HYBRID_GEOMETRY.hover.rightWingWidth,
      };
    case "recording":
      return {
        width: HYBRID_GEOMETRY.recording.width,
        height: HYBRID_GEOMETRY.core.height,
        lowerSurfaceHeight: 0,
        leftWingWidth: HYBRID_GEOMETRY.recording.leftWingWidth,
        rightWingWidth: HYBRID_GEOMETRY.recording.rightWingWidth,
        bodyLeftWidth: HYBRID_GEOMETRY.recording.leftWingWidth,
        bodyRightWidth: HYBRID_GEOMETRY.recording.rightWingWidth,
      };
    case "teleprompter":
      return {
        width: HYBRID_GEOMETRY.teleprompter.width,
        height:
          HYBRID_GEOMETRY.core.height +
          HYBRID_GEOMETRY.teleprompter.lowerSurfaceHeight,
        lowerSurfaceHeight: HYBRID_GEOMETRY.teleprompter.lowerSurfaceHeight,
        leftWingWidth: HYBRID_GEOMETRY.teleprompter.leftWingWidth,
        rightWingWidth: HYBRID_GEOMETRY.teleprompter.rightWingWidth,
        bodyLeftWidth: HYBRID_GEOMETRY.teleprompter.bodyLeftWidth,
        bodyRightWidth: HYBRID_GEOMETRY.teleprompter.bodyRightWidth,
      };
  }
}

export function getHybridMotionPhases(direction: "opening" | "closing") {
  return direction === "opening"
    ? (["wings", "panel", "content"] as const)
    : (["content", "panel", "wings"] as const);
}
