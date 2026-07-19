import CoreGraphics

public struct VoiceBarNotchScreenMetrics: Equatable {
    public let frame: CGRect
    public let safeAreaTop: CGFloat
    public let auxiliaryTopLeftArea: CGRect?
    public let auxiliaryTopRightArea: CGRect?

    public init(
        frame: CGRect,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.frame = frame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeftArea = auxiliaryTopLeftArea
        self.auxiliaryTopRightArea = auxiliaryTopRightArea
    }
}

public enum VoiceBarNotchScreenKind: Equatable {
    case hardwareNotch
    case flatDisplayFallback
}

public struct VoiceBarNotchScreenGeometry: Equatable {
    public let kind: VoiceBarNotchScreenKind
    public let screenFrame: CGRect
    public let housingFrame: CGRect
    public let leadingSeamError: CGFloat?
    public let trailingSeamError: CGFloat?

    public static func resolve(
        metrics: VoiceBarNotchScreenMetrics
    ) -> VoiceBarNotchScreenGeometry {
        if let left = metrics.auxiliaryTopLeftArea,
           let right = metrics.auxiliaryTopRightArea,
           right.minX > left.maxX {
            let housingFrame = CGRect(
                x: left.maxX,
                y: metrics.frame.maxY - VoiceBarNotchContract.topHeight,
                width: right.minX - left.maxX,
                height: VoiceBarNotchContract.topHeight
            )
            return VoiceBarNotchScreenGeometry(
                kind: .hardwareNotch,
                screenFrame: metrics.frame,
                housingFrame: housingFrame,
                leadingSeamError: housingFrame.minX - left.maxX,
                trailingSeamError: right.minX - housingFrame.maxX
            )
        }

        let housingFrame = CGRect(
            x: metrics.frame.midX - (VoiceBarNotchContract.coreWidth / 2),
            y: metrics.frame.maxY - VoiceBarNotchContract.topHeight,
            width: VoiceBarNotchContract.coreWidth,
            height: VoiceBarNotchContract.topHeight
        )
        return VoiceBarNotchScreenGeometry(
            kind: .flatDisplayFallback,
            screenFrame: metrics.frame,
            housingFrame: housingFrame,
            leadingSeamError: nil,
            trailingSeamError: nil
        )
    }

    public func panelFrame(for geometry: VoiceBarNotchGeometry) -> CGRect {
        CGRect(
            x: housingFrame.midX - (geometry.coreWidth / 2) - geometry.coreOriginX,
            y: screenFrame.maxY - geometry.totalHeight,
            width: geometry.totalWidth,
            height: geometry.totalHeight
        )
    }

    /// Resolves every visual state against the same measured hardware core.
    /// Flat displays deliberately retain the 185pt synthetic fallback.
    public func geometry(
        for visualState: VoiceBarNotchVisualState
    ) -> VoiceBarNotchGeometry {
        VoiceBarNotchContract.geometry(
            for: visualState,
            coreWidth: housingFrame.width
        )
    }
}
