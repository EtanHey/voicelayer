import CoreGraphics

public struct VoiceBarNotchCanvasLayout: Equatable, Sendable {
    public let canvasGeometry: VoiceBarNotchGeometry
    public let contentOffsetX: CGFloat

    public static func resolve(
        for presentation: VoiceBarNotchPresentation
    ) -> VoiceBarNotchCanvasLayout {
        guard presentation.visualState != .idle else {
            return VoiceBarNotchCanvasLayout(
                canvasGeometry: presentation.geometry,
                contentOffsetX: 0
            )
        }
        let teleprompterGeometry = VoiceBarNotchContract.geometry(
            for: .teleprompter,
            coreWidth: presentation.geometry.coreWidth,
            visibleCoreOcclusionInset: presentation.visibleCoreOcclusionInset
        )
        let maximumCompactWingWidth = VoiceBarNotchContract.morphCanvasWingCapacity
        let canvasGeometry = VoiceBarNotchGeometry(
            coreWidth: teleprompterGeometry.coreWidth,
            topHeight: teleprompterGeometry.topHeight,
            leadingWingWidth: max(
                teleprompterGeometry.leadingWingWidth,
                maximumCompactWingWidth
            ),
            trailingWingWidth: max(
                teleprompterGeometry.trailingWingWidth,
                maximumCompactWingWidth
            ),
            bodyLeadingExtent: max(
                teleprompterGeometry.bodyLeadingExtent,
                maximumCompactWingWidth
            ),
            bodyTrailingExtent: max(
                teleprompterGeometry.bodyTrailingExtent,
                maximumCompactWingWidth
            ),
            lowerSurfaceHeight: presentation.geometry.lowerSurfaceHeight
        )
        return VoiceBarNotchCanvasLayout(
            canvasGeometry: canvasGeometry,
            contentOffsetX: canvasGeometry.coreOriginX - presentation.geometry.coreOriginX
        )
    }
}
