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
        VoiceBarNotchContract.teleprompterLeadingWingWidth - reservedWingInset
    }

    public var trailingTeleprompterContentWidth: CGFloat {
        VoiceBarNotchContract.teleprompterTrailingWingWidth - reservedWingInset
    }

    public var teleprompterTextWidth: CGFloat {
        VoiceBarNotchContract.geometry(for: .teleprompter).bodyWidth -
            2 * (teleprompterBodyHorizontalInset + teleprompterTextInnerInset)
    }

    public var teleprompterTextFillRatio: CGFloat {
        teleprompterTextWidth /
            VoiceBarNotchContract.geometry(for: .teleprompter).bodyWidth
    }

    private var reservedWingInset: CGFloat {
        blackToGlassFadeWidth + fadeToContentGap + outerContentInset
    }

    public func compactOuterCornerRadius(
        for visualState: VoiceBarNotchVisualState
    ) -> CGFloat {
        switch visualState {
        case .recording, .compactStatus:
            15
        case .idle, .hoverLauncher, .teleprompter:
            11
        }
    }
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
    public let contentRoles: [VoiceBarNotchContentRole]
    public let accessibilityLabel: String

    public static func resolve(
        hasTeleprompter: Bool,
        isRecording: Bool,
        hasCompactStatus: Bool,
        compactStatusTrailingWingWidth: CGFloat? = nil,
        isHovered: Bool,
        isKeyboardFocused: Bool,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth
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
            coreWidth: coreWidth
        )
        let geometry = if visualState == .compactStatus,
                          let compactStatusTrailingWingWidth {
            VoiceBarNotchGeometry(
                coreWidth: baseGeometry.coreWidth,
                topHeight: baseGeometry.topHeight,
                leadingWingWidth: baseGeometry.leadingWingWidth,
                trailingWingWidth: max(
                    baseGeometry.trailingWingWidth,
                    compactStatusTrailingWingWidth
                ),
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
            [.microphone, .history]
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
    public static let topHeight: CGFloat = 32
    public static let teleprompterLeadingWingWidth: CGFloat = 76
    public static let teleprompterTrailingWingWidth: CGFloat = 88

    public static let material = VoiceBarNotchMaterialContract(
        blackToGlassFadeWidth: 10,
        fadeToContentGap: 8,
        outerContentInset: 8,
        inverseJoinRadius: 5,
        waveformSlotWidth: 72,
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

    public static func geometry(
        for visualState: VoiceBarNotchVisualState,
        coreWidth: CGFloat = coreWidth
    ) -> VoiceBarNotchGeometry {
        switch visualState {
        case .idle:
            geometry(coreWidth: coreWidth, leadingWingWidth: 0, trailingWingWidth: 0)
        case .hoverLauncher:
            geometry(coreWidth: coreWidth, leadingWingWidth: 36, trailingWingWidth: 64)
        case .recording, .compactStatus:
            geometry(coreWidth: coreWidth, leadingWingWidth: 72, trailingWingWidth: 152)
        case .teleprompter:
            geometry(
                coreWidth: coreWidth,
                leadingWingWidth: teleprompterLeadingWingWidth,
                trailingWingWidth: teleprompterTrailingWingWidth,
                bodyLeadingExtent: 140,
                bodyTrailingExtent: 140,
                lowerSurfaceHeight: 196
            )
        }
    }

    private static func geometry(
        coreWidth: CGFloat,
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
