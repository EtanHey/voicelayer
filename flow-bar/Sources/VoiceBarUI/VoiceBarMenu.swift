import Foundation

public enum VoicePastePlan: Equatable {
    case autoPaste
    case repaste

    public var activationDelay: TimeInterval {
        switch self {
        case .autoPaste:
            0
        case .repaste:
            0.12
        }
    }

    public var pasteDelay: TimeInterval {
        switch self {
        case .autoPaste:
            0.25
        case .repaste:
            0.08
        }
    }
}

public struct VoiceBarMenuAction: Identifiable {
    public let title: String
    public let perform: () -> Void

    public var id: String {
        title
    }
}

public enum VoiceBarMenu {
    public static func quickActions(
        isSnoozed: Bool = false,
        openSettings: @escaping () -> Void,
        snoozeToggle: @escaping () -> Void,
        transcribeLatestRecording: @escaping () -> Void,
        pasteLastTranscript: @escaping () -> Void,
        quit: @escaping () -> Void
    ) -> [VoiceBarMenuAction] {
        [
            VoiceBarMenuAction(title: "Settings", perform: openSettings),
            VoiceBarMenuAction(
                title: isSnoozed ? "Show VoiceBar" : "Hide for 1 hour",
                perform: snoozeToggle
            ),
            VoiceBarMenuAction(
                title: "Transcribe latest recording",
                perform: transcribeLatestRecording
            ),
            VoiceBarMenuAction(title: "Paste last transcript", perform: pasteLastTranscript),
            VoiceBarMenuAction(title: "Quit VoiceBar", perform: quit),
        ]
    }
}
