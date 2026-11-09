import AppKit

enum VoiceBarTerminationIntent {
    case menuBar
    case internalFailure
    case controlledUpdate
}

struct VoiceBarTerminationPolicy {
    private var controlledQuitCommitted = false
    private var authorizedIntent: VoiceBarTerminationIntent?

    mutating func authorize(_ intent: VoiceBarTerminationIntent) {
        if intent == .controlledUpdate { controlledQuitCommitted = true }
        authorizedIntent = intent
    }

    mutating func reply(enforcesSingleton: Bool, voiceBusy: Bool = false, gatePermitsQuit: Bool = true) -> NSApplication.TerminateReply {
        defer { authorizedIntent = nil }

        if controlledQuitCommitted { return .terminateNow }

        // User exit does not grant updater authority and never depends on gate evidence.
        let userQuit = authorizedIntent == .menuBar || (authorizedIntent == nil && enforcesSingleton)
        if userQuit { return voiceBusy ? .terminateLater : .terminateNow }
        guard !voiceBusy, gatePermitsQuit else { return .terminateCancel }

        if enforcesSingleton {
            return .terminateNow
        }
        return authorizedIntent == nil ? .terminateCancel : .terminateNow
    }
}

/// A bounded save window, independent of update-controller liveness or playback.
@MainActor enum VoiceBarQuitDeferral {
    nonisolated static let maximumWait: TimeInterval = 6
    static func waitWhileSaving(_ saving: () -> Bool,
                                now: () -> ContinuousClock.Instant = { ContinuousClock().now },
                                sleep: (Duration) async -> Void = { try? await Task.sleep(for: $0) }) async {
        let deadline = now().advanced(by: .seconds(maximumWait))
        while saving() {
            let remaining = now().duration(to: deadline)
            guard remaining > .zero else { return }
            await sleep(min(.milliseconds(100), remaining))
        }
    }
}
