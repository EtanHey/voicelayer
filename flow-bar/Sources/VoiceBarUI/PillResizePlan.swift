import CoreGraphics

public struct PillResizePlan {
    public let frame: CGRect
    public let animate: Bool

    public init(frame: CGRect, animate: Bool) {
        self.frame = frame
        self.animate = animate
    }

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
        visibleFrame: CGRect,
        horizontalOffset: CGFloat,
        verticalOffset: CGFloat?,
        topPadding: CGFloat,
        pillSize: CGSize,
        from oldMode: VoiceMode,
        to newMode: VoiceMode,
        padding: CGFloat
    ) -> PillResizePlan {
        let newWidth = max(pillSize.width + padding * 2, 50)
        let newHeight = max(pillSize.height + padding * 2, 30)
        let proposedMinX = visibleFrame.origin.x + (visibleFrame.width * horizontalOffset) - (newWidth / 2)
        let proposedMinY = if let verticalOffset {
            visibleFrame.origin.y + (visibleFrame.height * verticalOffset) - (newHeight / 2)
        } else {
            visibleFrame.maxY - topPadding - newHeight
        }
        let maximumMinX = max(visibleFrame.minX, visibleFrame.maxX - newWidth)
        let maximumMinY = max(visibleFrame.minY, visibleFrame.maxY - newHeight)
        let minX = min(max(proposedMinX, visibleFrame.minX), maximumMinX)
        let minY = min(max(proposedMinY, visibleFrame.minY), maximumMinY)
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
