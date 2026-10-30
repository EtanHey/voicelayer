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

        guard !voiceBusy, gatePermitsQuit else { return .terminateCancel }

        if enforcesSingleton {
            return .terminateNow
        }
        return authorizedIntent == nil ? .terminateCancel : .terminateNow
    }
}
