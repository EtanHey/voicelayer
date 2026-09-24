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
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let delay: Duration
    private let sleep: Sleep
    private var dismissalTask: Task<Void, Never>?

    /// `sleep` is the polling clock. Production uses `Task.sleep`; tests pass a
    /// manual ticker so grace-window assertions do not race wall-clock time.
    init(
        delay: Duration = VoiceBarRetainedReadbackPolicy.dismissDelay,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    deinit {
        dismissalTask?.cancel()
    }

    func synchronize(
        isReadback: Bool,
        isPointerInsideVisibleSurface: @escaping @MainActor @Sendable () -> Bool,
        onDismiss: @escaping @MainActor @Sendable () -> Void
    ) {
        guard isReadback else {
            cancel()
            return
        }
        guard dismissalTask == nil else { return }
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
        let sleep = sleep
        dismissalTask = Task { @MainActor [weak self] in
            var requiresFreshGraceAfterExit = isPointerInsideVisibleSurface()
            while !Task.isCancelled {
                try? await sleep(delay)
                guard !Task.isCancelled else { return }
                if isPointerInsideVisibleSurface() {
                    requiresFreshGraceAfterExit = true
                    continue
                }
                if requiresFreshGraceAfterExit {
                    requiresFreshGraceAfterExit = false
                    continue
                }
                self?.dismissalTask = nil
                onDismiss()
                return
            }
        }
    }
}
