import Foundation
import VoiceBarUI

enum RetainedReadbackPointerPolicy {
    static func isInsideVisibleSurface(
        screenPoint: CGPoint,
        panelFrame: CGRect,
        convertFromScreen: (CGPoint) -> CGPoint,
        containsLocalPoint: (CGPoint) -> Bool
    ) -> Bool {
        guard panelFrame.contains(screenPoint) else { return false }
        return containsLocalPoint(convertFromScreen(screenPoint))
    }
}

final class RetainedReadbackDismissalCoordinator {
    private let delay: Duration
    private var dismissalTask: Task<Void, Never>?

    init(delay: Duration = VoiceBarRetainedReadbackPolicy.dismissDelay) {
        self.delay = delay
    }

    deinit {
        dismissalTask?.cancel()
    }

    func synchronize(
        isReadback: Bool,
        isPointerInsideVisibleSurface: @escaping @MainActor @Sendable () -> Bool,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        dismissalTask?.cancel()
        dismissalTask = nil
        guard isReadback else { return }
        schedulePointerAwareDismissal(
            isPointerInsideVisibleSurface: isPointerInsideVisibleSurface,
            onDismiss: onDismiss
        )
    }

    func cancel() {
        dismissalTask?.cancel()
        dismissalTask = nil
    }

    private func schedulePointerAwareDismissal(
        isPointerInsideVisibleSurface: @escaping @MainActor @Sendable () -> Bool,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        let delay = delay
        dismissalTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if isPointerInsideVisibleSurface() {
                schedulePointerAwareDismissal(
                    isPointerInsideVisibleSurface: isPointerInsideVisibleSurface,
                    onDismiss: onDismiss
                )
                return
            }
            dismissalTask = nil
            onDismiss()
        }
    }
}
