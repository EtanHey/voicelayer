import CoreGraphics
import Foundation

public enum VoiceBarNotchVisualState: CaseIterable, Equatable, Sendable {
    case idle
    case hoverLauncher
    case recording
    case compactStatus
    case teleprompter
}

public struct VoiceBarNotchGeometry: Equatable, Sendable {
    public let coreWidth: CGFloat
    public let topHeight: CGFloat
    public let leadingWingWidth: CGFloat
    public let trailingWingWidth: CGFloat
    public let bodyLeadingExtent: CGFloat
    public let bodyTrailingExtent: CGFloat
    public let lowerSurfaceHeight: CGFloat

    public init(
        coreWidth: CGFloat,
        topHeight: CGFloat,
        leadingWingWidth: CGFloat,
        trailingWingWidth: CGFloat,
        bodyLeadingExtent: CGFloat,
        bodyTrailingExtent: CGFloat,
        lowerSurfaceHeight: CGFloat
    ) {
        self.coreWidth = coreWidth
        self.topHeight = topHeight
        self.leadingWingWidth = leadingWingWidth
        self.trailingWingWidth = trailingWingWidth
        self.bodyLeadingExtent = bodyLeadingExtent
        self.bodyTrailingExtent = bodyTrailingExtent
        self.lowerSurfaceHeight = lowerSurfaceHeight
    }

    public var topWidth: CGFloat {
        leadingWingWidth + coreWidth + trailingWingWidth
    }

    public var bodyWidth: CGFloat {
        bodyLeadingExtent + coreWidth + bodyTrailingExtent
    }

    public var totalWidth: CGFloat {
        max(topWidth, bodyWidth)
    }

    public var totalHeight: CGFloat {
        topHeight + lowerSurfaceHeight
    }

    public var bodyOriginX: CGFloat {
        (totalWidth - bodyWidth) / 2
    }

    public var coreOriginX: CGFloat {
        if lowerSurfaceHeight > 0 {
            bodyOriginX + bodyLeadingExtent
        } else {
            leadingWingWidth
        }
    }

    public var coreMidX: CGFloat {
        coreOriginX + coreWidth / 2
    }

    public var topOriginX: CGFloat {
        coreOriginX - leadingWingWidth
    }
}

public struct VoiceBarNotchMaterialContract: Equatable {
    public let blackToGlassFadeWidth: CGFloat
    public let fadeToContentGap: CGFloat
    public let outerContentInset: CGFloat
    public let compactContentInset: CGFloat
    public let inverseJoinRadius: CGFloat
    public let waveformSlotWidth: CGFloat
    public let lowerSurfaceLayerCount: Int
    public let teleprompterInsetFrameCount: Int
    public let compactWingsHaveOuterEdgeTreatment: Bool
    public let coreUsesBackdropMaterial: Bool
    public let recordingIndicatorSpacing: CGFloat
    public let compactControlSpacing: CGFloat
    public let compactControlSize: CGFloat
    public let hardwareCoreLowerCornerRadius: CGFloat
    public let teleprompterBodyHorizontalInset: CGFloat
    public let teleprompterTextInnerInset: CGFloat

    public var leadingTeleprompterContentWidth: CGFloat {
        VoiceBarNotchContract.teleprompterLeadingContentWidth
    }

    public var trailingTeleprompterContentWidth: CGFloat {
        VoiceBarNotchContract.teleprompterTrailingContentWidth
    }

    public var teleprompterTextWidth: CGFloat {
        teleprompterTextWidth(coreWidth: VoiceBarNotchContract.coreWidth)
    }

    public func teleprompterTextWidth(coreWidth: CGFloat) -> CGFloat {
        VoiceBarNotchContract.geometry(
            for: .teleprompter,
            coreWidth: coreWidth
        ).bodyWidth - 2 * (
            teleprompterBodyHorizontalInset + teleprompterTextInnerInset
        )
    }

    public var teleprompterTextFillRatio: CGFloat {
        teleprompterTextFillRatio(coreWidth: VoiceBarNotchContract.coreWidth)
    }

    public func teleprompterTextFillRatio(coreWidth: CGFloat) -> CGFloat {
        let bodyWidth = VoiceBarNotchContract.geometry(
            for: .teleprompter,
            coreWidth: coreWidth
        ).bodyWidth
        return teleprompterTextWidth(coreWidth: coreWidth) / bodyWidth
    }

    public func wingContentLayout(
        for side: VoiceBarNotchSide,
        state: VoiceBarNotchVisualState,
        visibleCoreOcclusionInset _: CGFloat = 0
    ) -> VoiceBarNotchWingContentLayout {
        let isTeleprompter = state == .teleprompter
        let isWaveformTrailing = side == .trailing && [
            VoiceBarNotchVisualState.recording,
            .compactStatus,
            .teleprompter,
        ].contains(state)
        let coreInset = if isTeleprompter || isWaveformTrailing {
            WaveformLayout.coreGap
        } else {
            VoiceBarNotchContract.compactCoreContentInset
        }
        return VoiceBarNotchWingContentLayout(
            side: side,
            coreInset: coreInset,
            outerInset: isWaveformTrailing || isTeleprompter
                ? WaveformLayout.outerInset
                : compactContentInset,
            alignment: .center
        )
    }

    public func compactOuterCornerRadius(
        for visualState: VoiceBarNotchVisualState
    ) -> CGFloat {
        switch visualState {
        case .hoverLauncher, .recording, .compactStatus:
            15
        case .idle, .teleprompter:
            11
        }
    }
}

public enum VoiceBarNotchWingContentAlignment: Equatable {
    case core
    case center
    case screenLeading
}

public struct VoiceBarNotchWingContentLayout: Equatable {
    public let side: VoiceBarNotchSide
    public let coreInset: CGFloat
    public let outerInset: CGFloat
    public let alignment: VoiceBarNotchWingContentAlignment
}

public struct VoiceBarNotchMotionContract: Equatable {
    public let stiffness: Double
    public let damping: Double
    public let mass: Double
    public let bounce: Double
    public let panelDelay: TimeInterval
    public let contentExitDuration: TimeInterval
}

public enum VoiceBarNotchContentRole: Equatable {
    case microphone
    case history
    case dictionary
    case recordingStatus
    case waveform
    case recordingControls
    case compactStatus
    case teleprompterControls
    case teleprompterBody
}

public struct VoiceBarNotchPresentation: Equatable {
    public let visualState: VoiceBarNotchVisualState
    public let geometry: VoiceBarNotchGeometry
    public let visibleCoreOcclusionInset: CGFloat
    public let virtualNotchIdleCoreHeight: CGFloat?
    public let contentRoles: [VoiceBarNotchContentRole]
    public let accessibilityLabel: String

    public static func resolve(
        hasTeleprompter: Bool,
        isRecording: Bool,
        hasCompactStatus: Bool,
        compactStatusLeadingWingWidth: CGFloat? = nil,
        compactStatusTrailingWingWidth: CGFloat? = nil,
        recordingLeadingWingWidth: CGFloat? = nil,
        recordingTrailingWingWidth: CGFloat? = nil,
        isHovered: Bool,
        isKeyboardFocused: Bool,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0,
        virtualNotchIdleCoreHeight: CGFloat? = nil
    ) -> VoiceBarNotchPresentation {
        let visualState: VoiceBarNotchVisualState = if hasTeleprompter {
            .teleprompter
        } else if isRecording {
            .recording
        } else if hasCompactStatus {
            .compactStatus
        } else if isHovered || isKeyboardFocused {
            .hoverLauncher
        } else {
            .idle
        }

        let baseGeometry = VoiceBarNotchContract.geometry(
            for: visualState,
            coreWidth: coreWidth,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            resolvedTopHeight: visualState == .idle
                ? virtualNotchIdleCoreHeight ?? VoiceBarNotchContract.topHeight
                : VoiceBarNotchContract.topHeight
        )
        let geometry = if visualState == .compactStatus,
                          compactStatusLeadingWingWidth != nil || compactStatusTrailingWingWidth != nil {
            VoiceBarNotchGeometry(
                coreWidth: baseGeometry.coreWidth,
                topHeight: baseGeometry.topHeight,
                leadingWingWidth: compactStatusLeadingWingWidth ?? baseGeometry.leadingWingWidth,
                trailingWingWidth: min(
                    compactStatusTrailingWingWidth ?? baseGeometry.trailingWingWidth,
                    VoiceBarNotchContract.morphCanvasWingCapacity
                ),
                bodyLeadingExtent: baseGeometry.bodyLeadingExtent,
                bodyTrailingExtent: baseGeometry.bodyTrailingExtent,
                lowerSurfaceHeight: baseGeometry.lowerSurfaceHeight
            )
        } else if visualState == .recording,
                  recordingLeadingWingWidth != nil || recordingTrailingWingWidth != nil {
            VoiceBarNotchGeometry(
                coreWidth: baseGeometry.coreWidth,
                topHeight: baseGeometry.topHeight,
                leadingWingWidth: recordingLeadingWingWidth ?? baseGeometry.leadingWingWidth,
                trailingWingWidth: recordingTrailingWingWidth ?? baseGeometry.trailingWingWidth,
                bodyLeadingExtent: baseGeometry.bodyLeadingExtent,
                bodyTrailingExtent: baseGeometry.bodyTrailingExtent,
                lowerSurfaceHeight: baseGeometry.lowerSurfaceHeight
            )
        } else {
            baseGeometry
        }

        return VoiceBarNotchPresentation(
            visualState: visualState,
            geometry: geometry,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            virtualNotchIdleCoreHeight: virtualNotchIdleCoreHeight,
            contentRoles: contentRoles(for: visualState),
            accessibilityLabel: accessibilityLabel(for: visualState)
        )
    }

    private static func contentRoles(
        for visualState: VoiceBarNotchVisualState
    ) -> [VoiceBarNotchContentRole] {
        switch visualState {
        case .idle:
            []
        case .hoverLauncher:
            [.microphone, .history, .dictionary]
        case .recording:
            [.recordingStatus, .waveform, .recordingControls]
        case .compactStatus:
            [.compactStatus]
        case .teleprompter:
            [.teleprompterControls, .waveform, .teleprompterBody]
        }
    }

    private static func accessibilityLabel(
        for visualState: VoiceBarNotchVisualState
    ) -> String {
        switch visualState {
        case .idle:
            "VoiceBar"
        case .hoverLauncher:
            "VoiceBar launcher"
        case .recording:
            "VoiceBar recording"
        case .compactStatus:
            "VoiceBar status"
        case .teleprompter:
            "VoiceBar teleprompter"
        }
    }
}

public enum VoiceBarNotchContract {
    public static let coreWidth: CGFloat = 185
    /// AppKit's auxiliary menu-bar gap includes the rounded clear shoulder
    /// outside the physical camera glass. Keep the measured center, then pull
    /// both software seams inward to meet the physical housing.
    public static let hardwareHorizontalCalibrationInset: CGFloat = 8.5
    public static let compactCoreContentInset: CGFloat = 13.5
    public static let compactStatusTrailingSafetyInset: CGFloat = 8
    public static let compactIndicatorLaneWidth = compactContentFitWingWidth(
        contentWidth: material.compactControlSize
    )

    public static let hoverLauncherTrailingWingWidth = compactContentFitWingWidth(
        contentWidth: 2 * material.compactControlSize + material.compactControlSpacing
    )

    public static let waveformWingWidth = WaveformLayout.coreGap +
        material.waveformSlotWidth + WaveformLayout.outerInset

    public static let compactStatusDefaultTrailingWingWidth = waveformWingWidth +
        material.compactControlSpacing +
        material.compactControlSize

    public static let compactStatusMaximumTrailingWingWidth =
        compactStatusDefaultTrailingWingWidth +
        material.compactControlSpacing +
        material.compactControlSize

    public static let recordingLeadingWingWidth = compactContentFitWingWidth(
        contentWidth: 2 * material.compactControlSize + material.compactControlSpacing
    )

    public static let recordingLeadingWingWidthWithHoldControl: CGFloat =
        recordingLeadingWingWidth + material.compactControlSpacing + material.compactControlSize

    /// The fixed morph canvas reserves this much space on either side of the
    /// hardware core. Dynamic content must lay itself out inside this bound so
    /// SwiftUI truncates it before the canvas edge clips it.
    public static var morphCanvasWingCapacity: CGFloat {
        compactStatusMaximumTrailingWingWidth
    }

    public static let topHeight: CGFloat = 32
    public static let teleprompterLeadingContentWidth: CGFloat = 50
    public static let teleprompterTrailingContentWidth = WaveformLayout.viewportWidth

    public static let teleprompterLeadingWingWidth = teleprompterContentFitWingWidth(
        contentWidth: teleprompterLeadingContentWidth
    )

    public static let teleprompterTrailingWingWidth = teleprompterWaveformWingWidth(
        visibleCoreOcclusionInset: 0
    )

    public static let material = VoiceBarNotchMaterialContract(
        blackToGlassFadeWidth: 16,
        fadeToContentGap: 8,
        outerContentInset: 8,
        compactContentInset: 14,
        inverseJoinRadius: 5,
        waveformSlotWidth: 46,
        lowerSurfaceLayerCount: 1,
        teleprompterInsetFrameCount: 0,
        compactWingsHaveOuterEdgeTreatment: true,
        coreUsesBackdropMaterial: false,
        recordingIndicatorSpacing: 7,
        compactControlSpacing: 6,
        compactControlSize: 20,
        hardwareCoreLowerCornerRadius: 7,
        teleprompterBodyHorizontalInset: 14,
        teleprompterTextInnerInset: 4
    )

    public static let motion = VoiceBarNotchMotionContract(
        stiffness: 310,
        damping: 31,
        mass: 0.72,
        bounce: 0,
        panelDelay: 0.05,
        contentExitDuration: 0.12
    )

    public static func compactContentFitWingWidth(contentWidth: CGFloat) -> CGFloat {
        compactCoreContentInset + contentWidth + material.compactContentInset
    }

    public static func teleprompterContentFitWingWidth(
        contentWidth: CGFloat,
        visibleCoreOcclusionInset: CGFloat = 0
    ) -> CGFloat {
        visibleCoreOcclusionInset + material.blackToGlassFadeWidth +
            material.fadeToContentGap + contentWidth + material.outerContentInset
    }

    public static func teleprompterWaveformWingWidth(
        visibleCoreOcclusionInset _: CGFloat
    ) -> CGFloat {
        WaveformLayout.coreGap + material.waveformSlotWidth + WaveformLayout.outerInset
    }

    public static func geometry(
        for visualState: VoiceBarNotchVisualState,
        coreWidth: CGFloat = coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0,
        resolvedTopHeight: CGFloat = topHeight
    ) -> VoiceBarNotchGeometry {
        switch visualState {
        case .idle:
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: 0,
                trailingWingWidth: 0
            )
        case .hoverLauncher:
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: compactIndicatorLaneWidth,
                trailingWingWidth: hoverLauncherTrailingWingWidth
            )
        case .recording:
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: recordingLeadingWingWidth,
                trailingWingWidth: waveformWingWidth
            )
        case .compactStatus:
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: compactIndicatorLaneWidth,
                trailingWingWidth: compactStatusDefaultTrailingWingWidth
            )
        case .teleprompter:
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: 0,
                trailingWingWidth: teleprompterWaveformWingWidth(
                    visibleCoreOcclusionInset: visibleCoreOcclusionInset
                ),
                bodyLeadingExtent: 140,
                bodyTrailingExtent: 140,
                lowerSurfaceHeight: 196
            )
        }
    }

    private static func geometry(
        coreWidth: CGFloat,
        topHeight: CGFloat,
        leadingWingWidth: CGFloat,
        trailingWingWidth: CGFloat,
        bodyLeadingExtent: CGFloat = 0,
        bodyTrailingExtent: CGFloat = 0,
        lowerSurfaceHeight: CGFloat = 0
    ) -> VoiceBarNotchGeometry {
        VoiceBarNotchGeometry(
            coreWidth: coreWidth,
            topHeight: topHeight,
            leadingWingWidth: leadingWingWidth,
            trailingWingWidth: trailingWingWidth,
            bodyLeadingExtent: bodyLeadingExtent,
            bodyTrailingExtent: bodyTrailingExtent,
            lowerSurfaceHeight: lowerSurfaceHeight
        )
    }
}
