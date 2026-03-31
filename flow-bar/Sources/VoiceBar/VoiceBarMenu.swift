import Foundation

enum VoicePastePlan: Equatable {
    case autoPaste
    case repaste

    var activationDelay: TimeInterval {
        switch self {
        case .autoPaste:
            0
        case .repaste:
            0.12
        }
    }

    var pasteDelay: TimeInterval {
        switch self {
        case .autoPaste:
            0.25
        case .repaste:
            0.08
        }
    }
}

struct VoiceBarMenuAction: Identifiable {
    let title: String
    let perform: () -> Void

    var id: String {
        title
    }
}

enum VoiceBarMenu {
    static func quickActions(
        isSnoozed: Bool = false,
        openSettings: @escaping () -> Void,
        snoozeToggle: @escaping () -> Void,
        pasteLastTranscript: @escaping () -> Void,
        quit: @escaping () -> Void
    ) -> [VoiceBarMenuAction] {
        [
            VoiceBarMenuAction(title: "Settings", perform: openSettings),
            VoiceBarMenuAction(
                title: isSnoozed ? "Show VoiceBar" : "Hide for 1 hour",
                perform: snoozeToggle
            ),
            VoiceBarMenuAction(title: "Paste last transcript", perform: pasteLastTranscript),
            VoiceBarMenuAction(title: "Quit VoiceBar", perform: quit),
        ]
    }
}
