import CoreGraphics

public struct PillResizePlan {
    public let frame: CGRect
    public let animate: Bool

    private static func frame(
        minX: CGFloat,
        minY: CGFloat,
        pillSize: CGSize,
        padding: CGFloat
    ) -> CGRect {
        let newWidth = max(pillSize.width + padding * 2, 50)
        let newHeight = max(pillSize.height + padding * 2, 30)
        return CGRect(
            x: minX,
            y: minY,
            width: newWidth,
            height: newHeight
        )
    }

    public static func make(
        oldFrame: CGRect,
        pillSize: CGSize,
        from oldMode: VoiceMode,
        to newMode: VoiceMode,
        padding: CGFloat
    ) -> PillResizePlan {
        let newWidth = max(pillSize.width + padding * 2, 50)
        let minX = oldFrame.midX - (newWidth / 2)
        let newFrame = frame(
            minX: minX,
            minY: oldFrame.minY,
            pillSize: pillSize,
            padding: padding
        )

        return PillResizePlan(
            frame: newFrame,
            animate: oldMode == .transcribing && newMode == .speaking
        )
    }

    public static func makeAnchored(
        screenFrame: CGRect? = nil,
        visibleFrame: CGRect,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat?,
        menuBarAttached: Bool = false,
        menuBarProfile: VoiceBarMenuBarDisplayProfile = .flat,
        topPadding: CGFloat,
        pillSize: CGSize,
        from oldMode: VoiceMode,
        to newMode: VoiceMode,
        padding: CGFloat
    ) -> PillResizePlan {
        let newWidth = max(pillSize.width + padding * 2, 50)
        let newHeight = max(pillSize.height + padding * 2, 30)
        let minX = if menuBarAttached, let screenFrame {
            VoiceBarMenuBarGeometry.attachedOriginX(
                screenFrame: screenFrame,
                visibleFrame: visibleFrame,
                panelWidth: newWidth,
                horizontalOffset: horizontalOffset,
                profile: menuBarProfile
            )
        } else {
            visibleFrame.origin.x + (visibleFrame.width * horizontalOffset) - (newWidth / 2)
        }
        let minY = if let verticalOffset {
            visibleFrame.origin.y + (visibleFrame.height * verticalOffset) - (newHeight / 2)
        } else if menuBarAttached, let screenFrame {
            if let strip = VoiceBarMenuBarGeometry.menuBarStrip(screenFrame: screenFrame, visibleFrame: visibleFrame) {
                strip.midY - (newHeight / 2)
            } else {
                VoiceBarMenuBarGeometry.attachedOriginY(
                    screenFrame: screenFrame,
                    visibleFrame: visibleFrame,
                    panelHeight: newHeight,
                    fallbackTopPadding: topPadding,
                    profile: menuBarProfile
                )
            }
        } else {
            visibleFrame.maxY - topPadding - newHeight
        }
        let newFrame = frame(
            minX: minX,
            minY: minY,
            pillSize: pillSize,
            padding: padding
        )

        return PillResizePlan(
            frame: newFrame,
            animate: oldMode == .transcribing && newMode == .speaking
        )
    }
}
