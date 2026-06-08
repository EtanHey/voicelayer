import CoreGraphics
import Foundation

public enum VoiceBarPositionLockPolicy {
    public static func effectivePlacement(
        anchorMode: VoiceBarAnchorMode,
        savedHorizontalOffset: CGFloat,
        savedVerticalOffset: CGFloat?,
        visibleFrame: CGRect,
        pillSize: CGSize,
        bottomClearance: CGFloat = 12
    ) -> VoiceBarAnchorPlacement {
        let anchorPlacement = anchorMode.placement(
            visibleFrame: visibleFrame,
            pillSize: pillSize,
            bottomClearance: bottomClearance
        )

        guard anchorPlacement.followsMouse else {
            return anchorPlacement
        }

        return VoiceBarAnchorPlacement(
            horizontalOffset: savedHorizontalOffset,
            verticalOffset: savedVerticalOffset,
            followsMouse: true
        )
    }
}
