import CoreGraphics
import Observation

public enum VoiceBarRetainedReadbackPolicy {
    public static let dismissDelay: Duration = .milliseconds(800)
}

@Observable
public final class VoiceBarNotchPresentationModel {
    public private(set) var presentation: VoiceBarNotchPresentation
    public private(set) var motionCoordinator: VoiceBarNotchMotionCoordinator
    public private(set) var isHovered = false
    public private(set) var isKeyboardFocused = false
    public private(set) var isHistoryPanelOpen = false
    public private(set) var isMenuPresented = false
    public private(set) var isReducedMotionEnabled = false

    private var hasTeleprompter = false
    private var isRecording = false
    private var hasCompactStatus = false
    private var keepsIdleExpanded = false
    private var compactStatusLeadingWingWidth: CGFloat?
    private var compactStatusTrailingWingWidth: CGFloat?
    private var recordingLeadingWingWidth: CGFloat?
    private var recordingTrailingWingWidth: CGFloat?
    private var teleprompterLeadingWingWidth: CGFloat?
    /// T5/T7: a live read's right wing is the recording-style time + meter wing, open or collapsed.
    private var teleprompterTrailingWingWidth: CGFloat?
    private var coreWidth = VoiceBarNotchContract.coreWidth
    private var visibleCoreOcclusionInset: CGFloat = 0
    private var virtualNotchIdleCoreHeight: CGFloat?
    private var feedback: VoiceBarNotchFeedback?
    private var transientNoteWidth: CGFloat?
    @ObservationIgnored private let onLayoutInvalidated: () -> Void

    public init(
        onLayoutInvalidated: @escaping () -> Void = {}
    ) {
        let initial = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: false,
            isRecording: false,
            hasCompactStatus: false,
            isHovered: false,
            isKeyboardFocused: false
        )
        presentation = initial
        motionCoordinator = VoiceBarNotchMotionCoordinator(
            initialState: initial.visualState
        )
        self.onLayoutInvalidated = onLayoutInvalidated
    }

    public var activeTransition: VoiceBarNotchActiveTransition? {
        motionCoordinator.activeTransition
    }

    public func updateOperationalEnvelope(
        hasTeleprompter: Bool,
        isRecording: Bool,
        hasCompactStatus: Bool,
        compactStatusLeadingWingWidth: CGFloat? = nil,
        compactStatusTrailingWingWidth: CGFloat? = nil,
        recordingLeadingWingWidth: CGFloat? = nil,
        recordingTrailingWingWidth: CGFloat? = nil,
        teleprompterLeadingWingWidth: CGFloat? = nil,
        teleprompterTrailingWingWidth: CGFloat? = nil,
        keepsIdleExpanded: Bool = false,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0,
        virtualNotchIdleCoreHeight: CGFloat? = nil,
        transientNoteWidth: CGFloat? = nil,
        feedback: VoiceBarNotchFeedback? = nil
    ) {
        self.hasTeleprompter = hasTeleprompter
        self.isRecording = isRecording
        self.hasCompactStatus = hasCompactStatus
        self.compactStatusLeadingWingWidth = compactStatusLeadingWingWidth
        self.compactStatusTrailingWingWidth = compactStatusTrailingWingWidth
        self.recordingLeadingWingWidth = recordingLeadingWingWidth
        self.recordingTrailingWingWidth = recordingTrailingWingWidth
        self.teleprompterLeadingWingWidth = teleprompterLeadingWingWidth
        self.teleprompterTrailingWingWidth = teleprompterTrailingWingWidth
        self.keepsIdleExpanded = keepsIdleExpanded
        self.coreWidth = coreWidth
        self.visibleCoreOcclusionInset = visibleCoreOcclusionInset
        self.virtualNotchIdleCoreHeight = virtualNotchIdleCoreHeight
        self.transientNoteWidth = transientNoteWidth
        self.feedback = feedback
        resolvePresentation()
    }

    public func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else { return }
        self.isHovered = isHovered
        resolvePresentation()
    }

    public func setKeyboardFocused(_ isKeyboardFocused: Bool) {
        guard self.isKeyboardFocused != isKeyboardFocused else { return }
        self.isKeyboardFocused = isKeyboardFocused
        resolvePresentation()
    }

    public func setMenuPresented(_ isOpen: Bool) {
        guard isMenuPresented != isOpen else { return }
        isMenuPresented = isOpen
        resolvePresentation()
    }

    public func setHistoryPanelOpen(_ isOpen: Bool) {
        guard isHistoryPanelOpen != isOpen else { return }
        isHistoryPanelOpen = isOpen
        resolvePresentation()
    }

    /// 2.3 lane U4: a History pull owns the pointer. The panel must keep taking mouse events for the whole drag,
    /// even when the pointer rubber-bands past the panel's edge, or the drag would lose its events mid-pull.
    public private(set) var isHistoryPullActive = false

    public func setHistoryPullActive(_ isActive: Bool) {
        guard isHistoryPullActive != isActive else { return }
        isHistoryPullActive = isActive
    }

    /// V6: the rows the History extend handle settled on. Kept for the app session (SPEC open question 4: a
    /// reopened panel keeps its height; a relaunch starts again at 7). The hit region follows it at once.
    public private(set) var historyRows = NotchHistoryMorph.visibleRows

    public func setHistoryRows(_ rows: Int) {
        guard historyRows != rows else { return }
        historyRows = rows
        resolvePresentation()
    }

    /// U5: the Teleprompter A handle's own pointer hold. Separate from History's, so neither releases the other's.
    public private(set) var isTeleprompterHandlePullActive = false

    public func setTeleprompterHandlePullActive(_ isActive: Bool) {
        isTeleprompterHandlePullActive = isActive
    }

    /// Any pull (History or the teleprompter handle) holding the panel's mouse events.
    public var isPointerHeldByPull: Bool { isHistoryPullActive || isTeleprompterHandlePullActive }

    /// U5: the lines the Teleprompter A handle settled on (app session only; SPEC open question 4).
    public private(set) var teleprompterLines = TeleprompterA.lineRange.lowerBound

    public func setTeleprompterLines(_ lines: Int) {
        let lines = TeleprompterA.clamp(lines)
        guard teleprompterLines != lines else { return }
        teleprompterLines = lines
        resolvePresentation()
    }

    public func setReducedMotion(_ isEnabled: Bool) {
        isReducedMotionEnabled = isEnabled
    }

    private func resolvePresentation() {
        let next = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: hasTeleprompter && !isMenuPresented && !isHistoryPanelOpen,
            isRecording: isRecording,
            hasCompactStatus: hasCompactStatus,
            hasHistoryPanel: isHistoryPanelOpen,
            historyRows: historyRows,
            teleprompterLines: teleprompterLines,
            compactStatusLeadingWingWidth: compactStatusLeadingWingWidth,
            compactStatusTrailingWingWidth: compactStatusTrailingWingWidth,
            recordingLeadingWingWidth: recordingLeadingWingWidth,
            recordingTrailingWingWidth: recordingTrailingWingWidth,
            teleprompterLeadingWingWidth: teleprompterLeadingWingWidth,
            teleprompterTrailingWingWidth: teleprompterTrailingWingWidth,
            isHovered: isHovered || keepsIdleExpanded || isMenuPresented,
            isKeyboardFocused: isKeyboardFocused,
            coreWidth: coreWidth,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            virtualNotchIdleCoreHeight: virtualNotchIdleCoreHeight,
            transientNoteWidth: transientNoteWidth, feedback: feedback
        )
        guard next != presentation else { return }

        motionCoordinator.replaceTarget(
            with: next.visualState,
            reducedMotion: isReducedMotionEnabled
        )
        presentation = next
        onLayoutInvalidated()
    }
}
