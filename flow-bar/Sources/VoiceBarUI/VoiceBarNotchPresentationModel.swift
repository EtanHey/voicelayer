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
    @ObservationIgnored private let onLayoutInvalidated: () -> Void
    @ObservationIgnored private let retainedReadbackDismissDelay: Duration
    @ObservationIgnored private var retainedReadbackDismissTask: Task<Void, Never>?

    public init(
        retainedReadbackDismissDelay: Duration = VoiceBarRetainedReadbackPolicy.dismissDelay,
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
        self.retainedReadbackDismissDelay = retainedReadbackDismissDelay
        self.onLayoutInvalidated = onLayoutInvalidated
    }

    public var activeTransition: VoiceBarNotchActiveTransition? {
        motionCoordinator.activeTransition
    }

    public func updateOperationalEnvelope(
        hasTeleprompter: Bool,
        isRecording: Bool,
        hasCompactStatus: Bool
    ) {
        self.hasTeleprompter = hasTeleprompter
        self.isRecording = isRecording
        self.hasCompactStatus = hasCompactStatus
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

    public func updateRetainedReadback(
        isReadback: Bool,
        isHovered: Bool,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        retainedReadbackDismissTask?.cancel()
        retainedReadbackDismissTask = nil
        guard isReadback, !isHovered else { return }

        let delay = retainedReadbackDismissDelay
        retainedReadbackDismissTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    public func cancelRetainedReadbackDismissal() {
        retainedReadbackDismissTask?.cancel()
        retainedReadbackDismissTask = nil
    }

    private func resolvePresentation() {
        let next = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: hasTeleprompter,
            isRecording: isRecording,
            hasCompactStatus: hasCompactStatus,
            isHovered: isHovered,
            isKeyboardFocused: isKeyboardFocused
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
