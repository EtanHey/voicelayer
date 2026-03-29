import Foundation

enum HotkeyPhase: Equatable {
    case idle
    case pressing
    case holding
    case awaitingSecondTap
}

struct VoiceBarQueuePreview: Equatable {
    var currentText: String
    var nextText: String?
    var overflowCount: Int
    var progress: Double
}

enum VoiceBarPresentation {
    private static let maxIdleWords = 3

    static func queuePreview(from items: [QueueItemState]) -> VoiceBarQueuePreview {
        let current = items.first(where: \.isCurrent) ?? items.first
        let next = items.dropFirst().first(where: { !$0.isCurrent }) ?? items.dropFirst().first

        return VoiceBarQueuePreview(
            currentText: current?.text ?? "Queued audio",
            nextText: next?.text,
            overflowCount: max(0, items.count - (next == nil ? 1 : 2)),
            progress: current?.progress ?? 0
        )
    }

    static func idleStatusText(
        transcript: String,
        confirmationText: String?,
        hotkeyPhase: HotkeyPhase,
        hotkeyEnabled: Bool
    ) -> String {
        if let confirmationText, !confirmationText.isEmpty {
            return confirmationText
        }

        switch hotkeyPhase {
        case .pressing:
            return "Hold to talk"
        case .holding:
            return "Release to send"
        case .awaitingSecondTap:
            return "Tap again to lock"
        case .idle:
            break
        }

        if !transcript.isEmpty {
            return lastWords(transcript)
        }

        return hotkeyEnabled ? "Right ⌘ to talk" : "Enable hotkey"
    }

    static func lastWords(_ text: String) -> String {
        let words = text.split(separator: " ")
        if words.count <= maxIdleWords { return text }
        return words.suffix(maxIdleWords).joined(separator: " ")
    }
}
