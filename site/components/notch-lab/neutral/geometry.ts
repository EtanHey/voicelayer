export type NeutralNotchState = "idle" | "recording" | "teleprompter";

export const NEUTRAL_NOTCH_TOKENS = {
  core: { width: 185, height: 32 },
  leftWingWidth: 104,
  rightWingWidth: 176,
  recordingWidth: 465,
  teleprompterPanelWidth: 465,
  teleprompterPanelHeight: 196,
  inverseJoinRadius: 5,
  waveformSlotWidth: 72,
} as const;

export type NeutralNotchGeometry = {
  width: number;
  height: number;
  topBandWidth: number;
  panelWidth: number;
  leftWingWidth: number;
  rightWingWidth: number;
  cameraGapWidth: number;
  lowerPanelHeight: number;
  inverseJoinRadius: number;
  verticalTurnDistance: number;
  waveformSlotWidth: number;
};

export function getNeutralNotchGeometry(
  state: NeutralNotchState,
): NeutralNotchGeometry {
  const isIdle = state === "idle";
  const hasTeleprompter = state === "teleprompter";
  const width = isIdle
    ? NEUTRAL_NOTCH_TOKENS.core.width
    : NEUTRAL_NOTCH_TOKENS.recordingWidth;
  const lowerPanelHeight = hasTeleprompter
    ? NEUTRAL_NOTCH_TOKENS.teleprompterPanelHeight
    : 0;

  return {
    width,
    height: NEUTRAL_NOTCH_TOKENS.core.height + lowerPanelHeight,
    topBandWidth: width,
    panelWidth: hasTeleprompter
      ? NEUTRAL_NOTCH_TOKENS.teleprompterPanelWidth
      : 0,
    leftWingWidth: isIdle ? 0 : NEUTRAL_NOTCH_TOKENS.leftWingWidth,
    rightWingWidth: isIdle ? 0 : NEUTRAL_NOTCH_TOKENS.rightWingWidth,
    cameraGapWidth: NEUTRAL_NOTCH_TOKENS.core.width,
    lowerPanelHeight,
    inverseJoinRadius: hasTeleprompter
      ? NEUTRAL_NOTCH_TOKENS.inverseJoinRadius
      : 0,
    verticalTurnDistance: hasTeleprompter
      ? NEUTRAL_NOTCH_TOKENS.inverseJoinRadius
      : 0,
    waveformSlotWidth: isIdle
      ? 0
      : NEUTRAL_NOTCH_TOKENS.waveformSlotWidth,
  };
}
