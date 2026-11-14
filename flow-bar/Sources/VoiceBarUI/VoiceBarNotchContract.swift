import CoreGraphics
import Foundation

public enum VoiceBarNotchVisualState: CaseIterable, Equatable, Sendable {
    case idle
    case hoverLauncher
    case recording
    case compactStatus
    case teleprompter
    /// Spec §4: the History panel drops out of the notch in the teleprompter's shell, narrower and taller.
    case history
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

    /// With a lower body, each side reaches as far as its wider part: the wing or the body. Centring the body in
    /// `max(topWidth, bodyWidth)` was only right while the body was at least as wide as the wings on BOTH sides;
    /// a narrower body (N1's note tab under asymmetric wings) shifted the core and the far wing overhung the frame.
    public var totalWidth: CGFloat {
        guard lowerSurfaceHeight > 0 else { return max(topWidth, bodyWidth) }
        return max(leadingWingWidth, bodyLeadingExtent) + coreWidth + max(trailingWingWidth, bodyTrailingExtent)
    }

    public var totalHeight: CGFloat {
        topHeight + lowerSurfaceHeight
    }

    public var bodyOriginX: CGFloat {
        if lowerSurfaceHeight > 0 {
            coreOriginX - bodyLeadingExtent
        } else {
            (totalWidth - bodyWidth) / 2
        }
    }

    public var coreOriginX: CGFloat {
        if lowerSurfaceHeight > 0 {
            max(leadingWingWidth, bodyLeadingExtent)
        } else {
            leadingWingWidth
        }
    }

    /// N1: a bodiless shell draws no body, so its body extents are invisible. Two geometries draw the same shell
    /// when they differ only there.
    public func drawsIdentically(to other: VoiceBarNotchGeometry) -> Bool {
        guard lowerSurfaceHeight == 0, other.lowerSurfaceHeight == 0 else { return self == other }
        return bodyFlushWithWings == other.bodyFlushWithWings
    }

    public var coreMidX: CGFloat {
        coreOriginX + coreWidth / 2
    }

    public var topOriginX: CGFloat {
        coreOriginX - leadingWingWidth
    }

    /// NOTCH2: a bodiless shell with its body extents flush with its wings. It renders identically at rest (no
    /// lower surface, so no body is drawn and the core still sits after the leading wing). A body that grows out
    /// of it (the note band, the teleprompter) then starts as wide as the top row instead of the core: from zero
    /// extents the early frames centred the core under a narrower body, so the wider wing overhung the shell's
    /// frame and was cut flat (reported wing clipping).
    public var bodyFlushWithWings: VoiceBarNotchGeometry {
        guard lowerSurfaceHeight == 0 else { return self }
        return VoiceBarNotchGeometry(
            coreWidth: coreWidth,
            topHeight: topHeight,
            leadingWingWidth: leadingWingWidth,
            trailingWingWidth: trailingWingWidth,
            bodyLeadingExtent: leadingWingWidth,
            bodyTrailingExtent: trailingWingWidth,
            lowerSurfaceHeight: 0
        )
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
        visibleCoreOcclusionInset: CGFloat = 0
    ) -> VoiceBarNotchWingContentLayout {
        // P16: every leading wing, the teleprompter's pause/play included, uses the idle-hover mic's lane
        // (P16 design: share the idle microphone alignment).
        // 2.3 U2 (3-wings mock): the right wing is a fixed 73.5 pt in every state, so its content sits centred
        // between the shared fixed-wing insets instead of the old waveform lane (24 pt from the core). That room
        // is what fits the reading time beside Stop without widening the wing.
        let isFixedTrailing = side == .trailing && [
            VoiceBarNotchVisualState.recording,
            .compactStatus,
            .teleprompter,
        ].contains(state)
        // 2.3 N1 (Etan, real M4): the recording time starts 8 pt past the PHYSICAL notch, which hides the wing's first
        // `visibleCoreOcclusionInset` points on a hardware notch (0 on a flat display).
        let isRecordingTrailing = side == .trailing && state == .recording
        let hiddenByGlass = isRecordingTrailing ? max(0, visibleCoreOcclusionInset) : 0
        // C7-W (Etan, QA 2026-11-11): the recording row ends `compactContentInset` from the wing's outer edge, the
        // inset Stop keeps from the left edge, and is pinned there; spare width faces the notch.
        return VoiceBarNotchWingContentLayout(
            side: side,
            coreInset: isFixedTrailing
                ? hiddenByGlass + VoiceBarNotchContract.fixedWingContentInset
                : VoiceBarNotchContract.compactCoreContentInset,
            outerInset: isFixedTrailing && !isRecordingTrailing
                ? VoiceBarNotchContract.fixedWingContentInset : compactContentInset,
            alignment: isRecordingTrailing ? .outer : .center
        )
    }

    /// The shell's outer bottom corner radius: the compact wings' corners, or the lower body's when it has one.
    /// One animated value for both (UXP-2), so opening a panel eases 15 → 18 pt instead of jumping.
    public func compactOuterCornerRadius(
        for visualState: VoiceBarNotchVisualState
    ) -> CGFloat {
        switch visualState {
        case .hoverLauncher, .recording, .compactStatus:
            15
        case .teleprompter:
            18
        case .history:
            // 2.3 lane U4, morph B: the open panel's convex bottom corners.
            NotchHistoryMorph.openBottomRadius
        case .idle:
            11
        }
    }

    /// The convex corner where a lower body steps out past a narrower wing. History's panel is wider than the
    /// mic's fitted wing, so it steps out with the wing's own 15 pt corner; the launcher shares the value so the
    /// corner doesn't change size as the panel opens. The teleprompter keeps its tight 5 pt shoulders.
    public func bodyShoulderCornerRadius(
        for visualState: VoiceBarNotchVisualState
    ) -> CGFloat {
        switch visualState {
        case .hoverLauncher, .history:
            compactOuterCornerRadius(for: .hoverLauncher)
        case .idle, .recording, .compactStatus, .teleprompter:
            inverseJoinRadius
        }
    }
}

public enum VoiceBarNotchWingContentAlignment: Equatable {
    case core
    case center
    case screenLeading
    /// Against the wing's outer edge.
    case outer
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
    case historyPanel
}

public struct VoiceBarNotchPresentation: Equatable {
    public let visualState: VoiceBarNotchVisualState
    public let geometry: VoiceBarNotchGeometry
    public let visibleCoreOcclusionInset: CGFloat
    public let virtualNotchIdleCoreHeight: CGFloat?
    public let contentRoles: [VoiceBarNotchContentRole]
    public let accessibilityLabel: String
    /// NOTCH1: the measured width of a transient note (the selection busy/rejection note). Non-nil means
    /// the notch grows a band directly under its top row to hold the note.
    public private(set) var transientNoteWidth: CGFloat? = nil
    public private(set) var feedback: VoiceBarNotchFeedback? = nil
    /// Etan, QA 0510 R3: a drawer (History or Settings) hangs below whatever band the notch's activity has: the
    /// launcher's, the recording wings, or a compact status (transcribing, Typed). Non-nil only for `.history`.
    public private(set) var drawerBand: VoiceBarNotchVisualState? = nil
    /// C7 L3 V10: a read is on screen (playing or paused, shown or hidden). Its canvas keeps the teleprompter's
    /// eight lines in the compact state too (`VoiceBarNotchMorphCanvasLayout`), so Hide, Show and Pause never
    /// shrink the canvas or the window under a shell that is still collapsing.
    public private(set) var holdsReadingCanvas = false

    public func holdingReadingCanvas(_ holds: Bool) -> Self {
        var copy = self
        copy.holdsReadingCanvas = holds
        return copy
    }

    /// What the 32 pt band shows: the visual state, or under a drawer the activity's own band.
    public var bandState: VoiceBarNotchVisualState { drawerBand ?? visualState }

    public var feedbackHeight: CGFloat {
        feedback?.height ?? (transientNoteWidth == nil ? 0 : VoiceBarNotchContract.transientNoteBandHeight)
    }

    /// N1: the compact-status wing's label. While any notice shows under the notch the wing carries none; it
    /// neither repeats, abbreviates nor substitutes for the notice.
    public func wingLabel(for statusText: String) -> String {
        if let feedback { return feedback.wingText }
        return transientNoteRect == nil ? statusText : ""
    }

    /// The lower surface this shell has without any note (the teleprompter's or History's body), or 0.
    var ownBodyHeight: CGFloat {
        geometry.lowerSurfaceHeight - feedbackHeight
    }

    /// Adds readable text using the existing lower-note shell; all top-row geometry is preserved.
    public func addingFeedback(_ feedback: VoiceBarNotchFeedback) -> Self {
        let ownBody = ownBodyHeight
        let note = VoiceBarNotchContract.noteBodyExtents(for: geometry, ownBodyHeight: ownBody)
        let grown = VoiceBarNotchGeometry(coreWidth: geometry.coreWidth, topHeight: geometry.topHeight,
            leadingWingWidth: geometry.leadingWingWidth, trailingWingWidth: geometry.trailingWingWidth,
            bodyLeadingExtent: note.leading,
            bodyTrailingExtent: note.trailing,
            lowerSurfaceHeight: ownBody + feedback.height)
        return VoiceBarNotchPresentation(visualState: visualState, geometry: grown,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset, virtualNotchIdleCoreHeight: virtualNotchIdleCoreHeight,
            contentRoles: contentRoles, accessibilityLabel: accessibilityLabel,
            transientNoteWidth: transientNoteWidth, feedback: feedback, drawerBand: drawerBand,
            holdsReadingCanvas: holdsReadingCanvas)
    }

    /// Where the transient note draws: the band directly under the top row, across the lower body. Any
    /// existing lower content (teleprompter, History) sits below it.
    public var transientNoteRect: CGRect? {
        guard transientNoteWidth != nil else { return nil }
        // N1: the note's own column, centred in the body (the tab itself, or the under-notch column inside a
        // teleprompter or History body), not the full width of a body it merely shares.
        let column = min(geometry.bodyWidth,
                         VoiceBarNotchContract.noteColumnWidth(for: geometry, ownBodyHeight: ownBodyHeight))
        return CGRect(
            x: geometry.bodyOriginX + (geometry.bodyWidth - column) / 2,
            y: geometry.topHeight,
            width: column,
            height: feedback?.noteHeight ?? VoiceBarNotchContract.transientNoteBandHeight
        )
    }

    /// NOTCH2: this presentation as SwiftUI draws it mid-morph, at an interpolated shell geometry. The AppKit hit
    /// gate is tested against it.
    func drawn(at geometry: VoiceBarNotchGeometry) -> VoiceBarNotchPresentation {
        VoiceBarNotchPresentation(
            visualState: visualState,
            geometry: geometry,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            virtualNotchIdleCoreHeight: virtualNotchIdleCoreHeight,
            contentRoles: contentRoles,
            accessibilityLabel: accessibilityLabel,
            transientNoteWidth: transientNoteWidth, feedback: feedback, drawerBand: drawerBand,
            holdsReadingCanvas: holdsReadingCanvas
        )
    }

    public static func resolve(
        hasTeleprompter: Bool,
        isRecording: Bool,
        hasCompactStatus: Bool,
        hasHistoryPanel: Bool = false,
        historyRows: Int = NotchHistoryMorph.visibleRows,
        teleprompterLines: Int = TeleprompterA.lineRange.lowerBound,
        compactStatusLeadingWingWidth: CGFloat? = nil,
        compactStatusTrailingWingWidth: CGFloat? = nil,
        recordingLeadingWingWidth: CGFloat? = nil,
        recordingTrailingWingWidth: CGFloat? = nil,
        teleprompterLeadingWingWidth: CGFloat? = nil,
        teleprompterTrailingWingWidth: CGFloat? = nil,
        isHovered: Bool,
        isKeyboardFocused: Bool,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0,
        virtualNotchIdleCoreHeight: CGFloat? = nil,
        transientNoteWidth: CGFloat? = nil,
        feedback: VoiceBarNotchFeedback? = nil
    ) -> VoiceBarNotchPresentation {
        // 0510 R3: a drawer outranks recording and a compact status (their wings stay in the band above it);
        // only the teleprompter outranks a drawer.
        let visualState: VoiceBarNotchVisualState = if hasTeleprompter {
            .teleprompter
        } else if hasHistoryPanel {
            .history
        } else if isRecording {
            .recording
        } else if hasCompactStatus {
            .compactStatus
        } else if isHovered || isKeyboardFocused || transientNoteWidth != nil {
            // An idle notch draws no glass, so a note shows the launcher shell rather than nothing.
            .hoverLauncher
        } else {
            .idle
        }

        let drawerBand: VoiceBarNotchVisualState? = visualState != .history ? nil
            : isRecording ? .recording : hasCompactStatus ? .compactStatus : nil
        let drawerBandWings: (leading: CGFloat, trailing: CGFloat)? = drawerBand.map { band in
            let base = VoiceBarNotchContract.geometry(for: band, coreWidth: coreWidth,
                                                      visibleCoreOcclusionInset: visibleCoreOcclusionInset)
            return band == .recording
                ? (recordingLeadingWingWidth ?? base.leadingWingWidth, recordingTrailingWingWidth ?? base.trailingWingWidth)
                : (compactStatusLeadingWingWidth ?? base.leadingWingWidth,
                   min(compactStatusTrailingWingWidth ?? base.trailingWingWidth, VoiceBarNotchContract.morphCanvasWingCapacity))
        }
        let baseGeometry = VoiceBarNotchContract.geometry(
            for: visualState,
            coreWidth: coreWidth,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            resolvedTopHeight: visualState == .idle
                ? virtualNotchIdleCoreHeight ?? VoiceBarNotchContract.topHeight
                : VoiceBarNotchContract.topHeight
        )
        var geometry = if visualState == .compactStatus,
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
        } else if visualState == .history {
            // V6: the extended panel's hit region is the rows the handle settled on. 0510 R3: the band keeps the
            // activity's own wings (recording, transcribing, Typed) above the drawer.
            VoiceBarNotchGeometry(
                coreWidth: baseGeometry.coreWidth,
                topHeight: baseGeometry.topHeight,
                leadingWingWidth: drawerBandWings?.leading ?? baseGeometry.leadingWingWidth,
                trailingWingWidth: drawerBandWings?.trailing ?? baseGeometry.trailingWingWidth,
                bodyLeadingExtent: baseGeometry.bodyLeadingExtent,
                bodyTrailingExtent: baseGeometry.bodyTrailingExtent,
                lowerSurfaceHeight: NotchHistoryMorph.lowerSurfaceHeight(rows: CGFloat(historyRows))
            )
        } else if visualState == .teleprompter,
                  teleprompterLeadingWingWidth != nil || teleprompterTrailingWingWidth != nil {
            VoiceBarNotchGeometry(
                coreWidth: baseGeometry.coreWidth,
                topHeight: baseGeometry.topHeight,
                leadingWingWidth: teleprompterLeadingWingWidth ?? baseGeometry.leadingWingWidth,
                trailingWingWidth: min(teleprompterTrailingWingWidth ?? baseGeometry.trailingWingWidth,
                                       VoiceBarNotchContract.morphCanvasWingCapacity),
                bodyLeadingExtent: baseGeometry.bodyLeadingExtent,
                bodyTrailingExtent: baseGeometry.bodyTrailingExtent,
                lowerSurfaceHeight: baseGeometry.lowerSurfaceHeight
            )
        } else {
            baseGeometry
        }
        // U5: the teleprompter body follows the lines its handle settled on (hit region and resting shape).
        let lines = TeleprompterA.clamp(teleprompterLines)
        if visualState == .teleprompter, lines != TeleprompterA.lineRange.lowerBound {
            geometry = VoiceBarNotchGeometry(
                coreWidth: geometry.coreWidth, topHeight: geometry.topHeight,
                leadingWingWidth: geometry.leadingWingWidth, trailingWingWidth: geometry.trailingWingWidth,
                bodyLeadingExtent: geometry.bodyLeadingExtent, bodyTrailingExtent: geometry.bodyTrailingExtent,
                lowerSurfaceHeight: VoiceBarNotchContract.teleprompterLowerSurfaceHeight(lines: lines))
        }

        let resolved = VoiceBarNotchPresentation(
            visualState: visualState,
            geometry: transientNoteWidth.map {
                VoiceBarNotchContract.addingTransientNoteBand(to: geometry.bodyFlushWithWings, noteWidth: $0)
            } ?? geometry.bodyFlushWithWings,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            virtualNotchIdleCoreHeight: virtualNotchIdleCoreHeight,
            contentRoles: contentRoles(for: visualState),
            accessibilityLabel: accessibilityLabel(for: visualState),
            transientNoteWidth: transientNoteWidth,
            drawerBand: drawerBand
        )
        return feedback.map { resolved.addingFeedback($0) } ?? resolved
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
        case .history:
            [.microphone, .history, .dictionary, .historyPanel]
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
        case .history:
            "VoiceBar history"
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
    /// 2.4 design: wing content must stay at least 8 pt from the physical camera housing,
    /// from the physical camera housing. The calibrated core edge IS the housing edge (#359, operator and phone
    /// verified: AppKit's auxiliary gap includes a clear shoulder, which `hardwareHorizontalCalibrationInset` removes),
    /// so every core-side inset is measured from it and must be at least this. NotchRealGeometryTests checks it.
    public static let physicalNotchClearance: CGFloat = 8
    public static let compactStatusTrailingSafetyInset: CGFloat = 8
    public static let compactIndicatorLaneWidth = compactContentFitWingWidth(
        contentWidth: material.compactControlSize
    )

    /// 2.3 U2 (Etan, 2026-11-03, the 3-wings mock): both wings are one fixed width in every state the mock draws
    /// (idle launcher, History, recording, transcribing, setup error, reading aloud), so the outline never moves
    /// between them (R0856-05). It is today's two-control wing (the launcher's History + Settings and the
    /// recording Stop + Cancel), which the mock measured as 73 pt; it fits mic + chevron or Stop + Cancel.
    public static let fixedWingWidth = compactContentFitWingWidth(
        contentWidth: 2 * material.compactControlSize + material.compactControlSpacing
    )

    /// The inset a fixed trailing wing keeps on both sides of its centred content (the reading time + Stop row
    /// fills the remaining 57.5 pt exactly).
    public static let fixedWingContentInset: CGFloat = 8

    public static let hoverLauncherTrailingWingWidth = fixedWingWidth

    public static let waveformWingWidth = WaveformLayout.coreGap +
        material.waveformSlotWidth + WaveformLayout.outerInset

    public static let compactStatusDefaultTrailingWingWidth = waveformWingWidth +
        material.compactControlSpacing +
        material.compactControlSize

    public static let compactStatusMaximumTrailingWingWidth =
        compactStatusDefaultTrailingWingWidth +
        material.compactControlSpacing +
        material.compactControlSize

    public static let recordingLeadingWingWidth = fixedWingWidth

    /// The time/meter row with its insets: 8 pt clear of the physical notch, and (C7-W) the left wing's own outer
    /// inset past the meter, so the band's two ends match.
    public static func recordingTrailingWingWidth(visibleCoreOcclusionInset: CGFloat) -> CGFloat {
        max(0, visibleCoreOcclusionInset) + fixedWingContentInset + VoiceBarRecordingWingLabel.width +
            VoiceBarRecordingWingLabel.recordingMeterGap + WaveformLayout.viewportWidth + material.compactContentInset
    }

    /// The flat-display (no hidden notch) recording right wing.
    public static var recordingTrailingWingWidth: CGFloat { recordingTrailingWingWidth(visibleCoreOcclusionInset: 0) }

    public static let recordingLeadingWingWidthWithHoldControl: CGFloat =
        recordingLeadingWingWidth + material.compactControlSpacing + material.compactControlSize

    /// The fixed morph canvas reserves this much space on either side of the
    /// hardware core. Dynamic content must lay itself out inside this bound so
    /// SwiftUI truncates it before the canvas edge clips it.
    public static var morphCanvasWingCapacity: CGFloat {
        compactStatusMaximumTrailingWingWidth
    }

    public static let topHeight: CGFloat = 32
    /// NOTCH1: the band a transient note adds under the top row: one 12 pt line with breathing room above
    /// and room below for the shell's rounded lower corners.
    public static let transientNoteBandHeight: CGFloat = 26
    /// NOTCH2: room the morph canvas keeps under the note band, so the shell's lower curve and its edge
    /// stroke never sit on the window edge while the note is up.
    public static let transientNoteClearance: CGFloat = 6
    /// NOTCH2: everything a visible notch's canvas holds below its resting body, so a note can arrive and
    /// leave without resizing the window under the animating shell.
    // Reserve the bounded worst-case status + note even while hidden. Otherwise clearing long feedback
    // shrinks the AppKit window before the shell has finished closing and clips the morph.
    public static let transientNoteCanvasReserve: CGFloat =
        2 * VoiceBarNotchFeedback.maximumTextHeight + 16 + 34 + 10 + transientNoteClearance
    public static let transientNoteHorizontalInset: CGFloat = 16
    /// Spec §4: History uses the teleprompter shell with reduced width and increased height (teleprompter
    /// body is 465 × 196 pt). 2.3 lane U4 (approved mock 5-history): 420 pt wide, seven 46 pt two-line rows.
    public static let historyBodyWidth: CGFloat = NotchHistoryMorph.bodyWidth
    public static let historyLowerSurfaceHeight: CGFloat = NotchHistoryMorph.lowerSurfaceHeight
    /// 2.4 design: widen the teleprompter and reduce unused internal space. The
    /// body reaches 180 pt past each side of the core (545 pt at a 185 pt core, was 465), so a read wraps onto fewer
    /// lines. Lane B's text column follows the body's width.
    public static let teleprompterBodyExtent: CGFloat = 180
    public static let teleprompterLeadingContentWidth: CGFloat = 50
    public static let teleprompterTrailingContentWidth = WaveformLayout.viewportWidth

    public static let teleprompterLeadingWingWidth = teleprompterContentFitWingWidth(
        contentWidth: teleprompterLeadingContentWidth
    )

    public static let teleprompterTrailingWingWidth = fixedWingWidth

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

    /// 2.3 U2: the reading-aloud right wing is the fixed wing (time + Stop), like every other state.
    /// U5: the teleprompter's lower surface for `lines` Teleprompter A lines. T8 (Etan QA 2026-11-09): the footer
    /// row is gone and the gaps are tight, so three lines take 163 pt (was 196).
    public static func teleprompterLowerSurfaceHeight(lines: Int) -> CGFloat {
        TeleprompterA.lowerSurfaceHeight(lines: lines)
    }

    public static func teleprompterWaveformWingWidth(
        visibleCoreOcclusionInset _: CGFloat
    ) -> CGFloat {
        fixedWingWidth
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
            // Etan, 2026-09-30: the mic's wing hugs the mic (this overrides UX pass #4's equal wings).
            // No body here; its extents are the wings', so an opening History panel starts flush with both and
            // only its left side then steps out. From a zero extent the body grew out of the core narrower than
            // the wings, squaring their corners mid-morph.
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: fixedWingWidth,
                trailingWingWidth: fixedWingWidth,
                bodyLeadingExtent: fixedWingWidth,
                bodyTrailingExtent: fixedWingWidth
            )
        case .recording:
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: fixedWingWidth,
                trailingWingWidth: fixedWingWidth
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
                trailingWingWidth: fixedWingWidth,
                bodyLeadingExtent: teleprompterBodyExtent,
                bodyTrailingExtent: teleprompterBodyExtent,
                lowerSurfaceHeight: teleprompterLowerSurfaceHeight(lines: TeleprompterA.lineRange.lowerBound)
            )
        case .history:
            // The wings (controls, hit targets) stay the launcher's. 2.3 lane U4: the morph shape draws the top row
            // flush with the 420 pt panel (`VoiceBarNotchHistoryMorphInput.flushTop`), as in the mock.
            geometry(
                coreWidth: coreWidth,
                topHeight: resolvedTopHeight,
                leadingWingWidth: fixedWingWidth,
                trailingWingWidth: fixedWingWidth,
                bodyLeadingExtent: historyBodyExtent(coreWidth: coreWidth),
                bodyTrailingExtent: historyBodyExtent(coreWidth: coreWidth),
                lowerSurfaceHeight: historyLowerSurfaceHeight
            )
        }
    }

    /// Grow down inside the existing shell. Text must wrap rather than widen either side of the notch;
    /// a teleprompter or History body keeps its existing width and its content below the note.
    static func addingTransientNoteBand(
        to geometry: VoiceBarNotchGeometry,
        noteWidth _: CGFloat
    ) -> VoiceBarNotchGeometry {
        let note = noteBodyExtents(for: geometry, ownBodyHeight: geometry.lowerSurfaceHeight)
        return VoiceBarNotchGeometry(
            coreWidth: geometry.coreWidth,
            topHeight: geometry.topHeight,
            leadingWingWidth: geometry.leadingWingWidth,
            trailingWingWidth: geometry.trailingWingWidth,
            bodyLeadingExtent: note.leading,
            bodyTrailingExtent: note.trailing,
            lowerSurfaceHeight: geometry.lowerSurfaceHeight + transientNoteBandHeight
        )
    }

    /// Reported 2026-11-02 (N1): keep notes inside a compact tab below the hardware notch.
    /// That tab is no wider than the notch (or this
    /// minimum on a narrow virtual notch); it never spans the wings and never steps out past one.
    public static let noteMinimumWidth: CGFloat = coreWidth

    /// The body extents a note-bearing shell draws. A teleprompter or History body keeps its own extents and
    /// hosts the note at its top; otherwise the note is a tab under the core, never wider than either wing allows.
    static func noteBodyExtents(
        for geometry: VoiceBarNotchGeometry,
        ownBodyHeight: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        if ownBodyHeight > 0 {
            return (geometry.bodyLeadingExtent, geometry.bodyTrailingExtent)
        }
        let spare = max(0, noteMinimumWidth - geometry.coreWidth) / 2
        return (min(spare, geometry.leadingWingWidth), min(spare, geometry.trailingWingWidth))
    }

    /// The width the note's text column is laid out in: the tab's own width, or, inside a wider teleprompter or
    /// History body, the same under-notch column centred in that body.
    public static func noteColumnWidth(for geometry: VoiceBarNotchGeometry, ownBodyHeight: CGFloat) -> CGFloat {
        let extents = noteBodyExtents(for: geometry, ownBodyHeight: 0)
        let tab = geometry.coreWidth + extents.leading + extents.trailing
        return ownBodyHeight > 0 ? min(geometry.bodyWidth, max(tab, noteMinimumWidth)) : tab
    }

    /// The History panel is centred on the core and `historyBodyWidth` wide (2.3 mock: 420 pt), top row and body
    /// alike. It never gets narrower than the launcher's wings on a wide core.
    static func historyBodyExtent(coreWidth: CGFloat) -> CGFloat {
        max((historyBodyWidth - coreWidth) / 2, hoverLauncherTrailingWingWidth, compactIndicatorLaneWidth)
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
