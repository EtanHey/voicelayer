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
    public private(set) var isReducedMotionEnabled = false

    private var hasTeleprompter = false
    private var isRecording = false
    private var hasCompactStatus = false
    private var keepsIdleExpanded = false
    private var compactStatusLeadingWingWidth: CGFloat?
    private var compactStatusTrailingWingWidth: CGFloat?
    private var recordingLeadingWingWidth: CGFloat?
    private var recordingTrailingWingWidth: CGFloat?
    private var coreWidth = VoiceBarNotchContract.coreWidth
    private var visibleCoreOcclusionInset: CGFloat = 0
    private var virtualNotchIdleCoreHeight: CGFloat?
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
        keepsIdleExpanded: Bool = false,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0,
        virtualNotchIdleCoreHeight: CGFloat? = nil
    ) {
        self.hasTeleprompter = hasTeleprompter
        self.isRecording = isRecording
        self.hasCompactStatus = hasCompactStatus
        self.compactStatusLeadingWingWidth = compactStatusLeadingWingWidth
        self.compactStatusTrailingWingWidth = compactStatusTrailingWingWidth
        self.recordingLeadingWingWidth = recordingLeadingWingWidth
        self.recordingTrailingWingWidth = recordingTrailingWingWidth
        self.keepsIdleExpanded = keepsIdleExpanded
        self.coreWidth = coreWidth
        self.visibleCoreOcclusionInset = visibleCoreOcclusionInset
        self.virtualNotchIdleCoreHeight = virtualNotchIdleCoreHeight
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

    public func setReducedMotion(_ isEnabled: Bool) {
        isReducedMotionEnabled = isEnabled
    }

    private func resolvePresentation() {
        let next = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: hasTeleprompter,
            isRecording: isRecording,
            hasCompactStatus: hasCompactStatus,
            compactStatusLeadingWingWidth: compactStatusLeadingWingWidth,
            compactStatusTrailingWingWidth: compactStatusTrailingWingWidth,
            recordingLeadingWingWidth: recordingLeadingWingWidth,
            recordingTrailingWingWidth: recordingTrailingWingWidth,
            isHovered: isHovered || keepsIdleExpanded,
            isKeyboardFocused: isKeyboardFocused,
            coreWidth: coreWidth,
            visibleCoreOcclusionInset: visibleCoreOcclusionInset,
            virtualNotchIdleCoreHeight: virtualNotchIdleCoreHeight
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
