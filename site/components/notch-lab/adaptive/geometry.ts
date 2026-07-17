export type AdaptiveNotchState = "idle" | "recording" | "teleprompter";

export type AdaptiveMaterialRegion =
  | "left-wing"
  | "right-wing"
  | "lower-panel";

export const ADAPTIVE_NOTCH_TOKENS = {
  coreWidth: 185,
  coreHeight: 32,
  leftWing: 104,
  rightWing: 176,
  recordingWidth: 465,
  teleprompterPanelHeight: 196,
  inverseJoin: 5,
  waveformSlot: 72,
} as const;

export interface AdaptiveNotchGeometry {
  core: { width: number; height: number };
  shell: { width: number; height: number };
  wings: { left: number; right: number };
  lowerPanelHeight: number;
  coreMaterial: "opaque-black";
  adaptiveMaterialRegions: readonly AdaptiveMaterialRegion[];
  clipStrategy: "exact-shell";
}

const HARDWARE_CORE = {
  width: ADAPTIVE_NOTCH_TOKENS.coreWidth,
  height: ADAPTIVE_NOTCH_TOKENS.coreHeight,
};

export function getAdaptiveNotchGeometry(
  state: AdaptiveNotchState,
): AdaptiveNotchGeometry {
  const isIdle = state === "idle";
  const hasPanel = state === "teleprompter";
  const lowerPanelHeight = hasPanel
    ? ADAPTIVE_NOTCH_TOKENS.teleprompterPanelHeight
    : 0;

  return {
    core: { ...HARDWARE_CORE },
    shell: {
      width: isIdle
        ? ADAPTIVE_NOTCH_TOKENS.coreWidth
        : ADAPTIVE_NOTCH_TOKENS.recordingWidth,
      height: ADAPTIVE_NOTCH_TOKENS.coreHeight + lowerPanelHeight,
    },
    wings: isIdle
      ? { left: 0, right: 0 }
      : {
          left: ADAPTIVE_NOTCH_TOKENS.leftWing,
          right: ADAPTIVE_NOTCH_TOKENS.rightWing,
        },
    lowerPanelHeight,
    coreMaterial: "opaque-black",
    adaptiveMaterialRegions: isIdle
      ? []
      : hasPanel
        ? ["left-wing", "right-wing", "lower-panel"]
        : ["left-wing", "right-wing"],
    clipStrategy: "exact-shell",
  };
}
