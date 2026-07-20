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

    /// Software pixels between the calibrated core edge and the physical
    /// bezel edge are hidden by the camera glass. Any visible seam treatment
    /// must start beyond this inset, into the wing.
    public var visibleCoreOcclusionInset: CGFloat {
        guard kind == .hardwareNotch else { return 0 }
        return max(abs(leadingSeamError ?? 0), abs(trailingSeamError ?? 0))
    }

    public static func resolve(
        metrics: VoiceBarNotchScreenMetrics,
        hardwareHorizontalCalibrationInset: CGFloat = VoiceBarNotchContract
            .hardwareHorizontalCalibrationInset
    ) -> VoiceBarNotchScreenGeometry {
        if let left = metrics.auxiliaryTopLeftArea,
           let right = metrics.auxiliaryTopRightArea,
           right.minX > left.maxX {
            let appKitHousingFrame = CGRect(
                x: left.maxX,
                y: metrics.frame.maxY - VoiceBarNotchContract.topHeight,
                width: right.minX - left.maxX,
                height: VoiceBarNotchContract.topHeight
            )
            let maximumInset = max(0, (appKitHousingFrame.width - 1) / 2)
            let calibrationInset = min(
                max(0, hardwareHorizontalCalibrationInset),
                maximumInset
            )
            let housingFrame = appKitHousingFrame.insetBy(
                dx: calibrationInset,
                dy: 0
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
            coreWidth: housingFrame.width,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset
        )
    }
}
