import AppKit

enum VoiceBarTerminationIntent {
    case menuBar
    case internalFailure
}

struct VoiceBarTerminationPolicy {
    private var authorizedIntent: VoiceBarTerminationIntent?

    mutating func authorize(_ intent: VoiceBarTerminationIntent) {
        authorizedIntent = intent
    }

    mutating func reply(enforcesSingleton: Bool) -> NSApplication.TerminateReply {
        defer { authorizedIntent = nil }

        if enforcesSingleton {
            return .terminateNow
        }
        return authorizedIntent == nil ? .terminateCancel : .terminateNow
    }
}
