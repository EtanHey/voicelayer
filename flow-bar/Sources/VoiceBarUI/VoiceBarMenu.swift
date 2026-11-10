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
    public var isEnabled = true
    public var disabledReason: String? = nil
    public let perform: () -> Void

    public var id: String {
        title
    }
}

public enum VoiceBarMenu {
    public static func quickActions(
        isSnoozed: Bool = false,
        hideDisabledReason: String? = nil,
        openSettings: @escaping () -> Void,
        showVoiceBar: @escaping () -> Void,
        snoozeToggle: @escaping () -> Void,
        transcribeLatestRecording: @escaping () -> Void,
        pasteLastTranscript: @escaping () -> Void,
        quit: @escaping () -> Void
    ) -> [VoiceBarMenuAction] {
        var actions = [
            VoiceBarMenuAction(title: "Settings", perform: openSettings),
            VoiceBarMenuAction(title: "Show VoiceBar", perform: showVoiceBar),
        ]

        if !isSnoozed {
            actions.append(VoiceBarMenuAction(title: "Hide for 1 hour", isEnabled: hideDisabledReason == nil,
                                              disabledReason: hideDisabledReason, perform: {
                if hideDisabledReason == nil { snoozeToggle() }
            }))
        }

        actions.append(contentsOf: [
            VoiceBarMenuAction(
                title: "Transcribe latest recording",
                perform: transcribeLatestRecording
            ),
            VoiceBarMenuAction(title: "Paste last transcript", perform: pasteLastTranscript),
            VoiceBarMenuAction(title: "Quit VoiceBar", perform: quit),
        ])
        return actions
    }
}
