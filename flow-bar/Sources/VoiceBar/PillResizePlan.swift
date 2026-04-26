import CoreGraphics

struct PillResizePlan {
    let frame: CGRect
    let animate: Bool

    static func make(
        oldFrame: CGRect,
        pillSize: CGSize,
        from oldMode: VoiceMode,
        to newMode: VoiceMode,
        padding: CGFloat
    ) -> PillResizePlan {
        let newWidth = max(pillSize.width + padding * 2, 50)
        let newHeight = max(pillSize.height + padding * 2, 30)
        let newFrame = CGRect(
            x: oldFrame.midX - newWidth / 2,
            y: oldFrame.midY - newHeight / 2,
            width: newWidth,
            height: newHeight
        )

        return PillResizePlan(
            frame: newFrame,
            animate: (oldMode == .transcribing && newMode == .speaking)
                || (oldMode == .idle && newMode == .recording)
        )
    }
}
