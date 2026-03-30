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
        openSettings: @escaping () -> Void,
        hideForOneHour: @escaping () -> Void,
        pasteLastTranscript: @escaping () -> Void,
        quit: @escaping () -> Void
    ) -> [VoiceBarMenuAction] {
        [
            VoiceBarMenuAction(title: "Settings", perform: openSettings),
            VoiceBarMenuAction(title: "Hide for 1 hour", perform: hideForOneHour),
            VoiceBarMenuAction(title: "Paste last transcript", perform: pasteLastTranscript),
            VoiceBarMenuAction(title: "Quit VoiceBar", perform: quit),
        ]
    }
}
