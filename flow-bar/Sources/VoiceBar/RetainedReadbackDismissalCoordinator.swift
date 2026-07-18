import Foundation
import VoiceBarUI

final class RetainedReadbackDismissalCoordinator {
    private let delay: Duration
    private var dismissalTask: Task<Void, Never>?

    init(delay: Duration = VoiceBarRetainedReadbackPolicy.dismissDelay) {
        self.delay = delay
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
