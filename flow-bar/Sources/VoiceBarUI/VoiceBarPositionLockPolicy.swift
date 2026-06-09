import CoreGraphics
import Foundation

public enum VoiceBarPositionLockPolicy {
    public static func effectivePlacement(
        anchorMode: VoiceBarAnchorMode,
        savedHorizontalOffset: CGFloat,
        savedVerticalOffset: CGFloat?,
        visibleFrame: CGRect,
        pillSize: CGSize
    ) -> VoiceBarAnchorPlacement {
        let anchorPlacement = anchorMode.placement(
            visibleFrame: visibleFrame,
            pillSize: pillSize
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
