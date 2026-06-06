import CoreGraphics
import Foundation

public enum VoiceBarPositionLockPolicy {
    public static func effectivePlacement(
        anchorMode: VoiceBarAnchorMode,
        isLocked _: Bool,
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

    public static func lockFootnote(
        anchorMode _: VoiceBarAnchorMode,
        isLocked _: Bool
    ) -> String? {
        nil
    }
}
