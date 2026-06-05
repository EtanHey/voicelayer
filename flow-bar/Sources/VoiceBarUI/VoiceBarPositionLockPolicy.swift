import CoreGraphics
import Foundation

public enum VoiceBarPositionLockPolicy {
    public static func effectivePlacement(
        anchorMode: VoiceBarAnchorMode,
        isLocked: Bool,
        savedHorizontalOffset: CGFloat,
        savedVerticalOffset: CGFloat?,
        visibleFrame: CGRect,
        pillSize: CGSize
    ) -> VoiceBarAnchorPlacement {
        let anchorPlacement = anchorMode.placement(
            visibleFrame: visibleFrame,
            pillSize: pillSize
        )

        if isLocked, anchorPlacement.followsMouse {
            return VoiceBarAnchorMode.topCenter.placement(
                visibleFrame: visibleFrame,
                pillSize: pillSize
            )
        }

        guard anchorPlacement.followsMouse else {
            return anchorPlacement
        }

        return VoiceBarAnchorPlacement(
            horizontalOffset: savedHorizontalOffset,
            verticalOffset: savedVerticalOffset,
            followsMouse: true
        )
    }

    public static func lockFootnote(
        anchorMode: VoiceBarAnchorMode,
        isLocked: Bool
    ) -> String? {
        guard isLocked, anchorMode == .follow else { return nil }
        return "Follow Mouse is disabled while position is locked."
    }
}
