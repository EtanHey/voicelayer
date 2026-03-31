import Foundation

enum HotkeyPhase: Equatable {
    case idle
    case pressing
    case holding
    case awaitingSecondTap
}

struct VoiceBarRecordingContent: Equatable {
    var statusText: String
    var showsWaveform: Bool
    var usesPulsingLabelOpacity: Bool
}

struct VoiceBarQueuePreview: Equatable {
    var currentText: String
    var nextText: String?
    var overflowCount: Int
    var progress: Double
}

enum VoiceBarPresentation {
    private static let maxIdleWords = 3
    static let readyHotkeyHint = "⌘F6 to talk"

    static func hotkeyPermissionHint(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission]
    ) -> String {
        guard !hotkeyEnabled else { return "Hotkey: ⌘F6" }
        let labels = missingPermissions.map {
            switch $0 {
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            }
        }.sorted()
        guard !labels.isEmpty else { return "Hotkey: needs permission" }
        return "Hotkey: enable \(labels.joined(separator: " + "))"
    }

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

    static func recordingContent(hotkeyPhase: HotkeyPhase) -> VoiceBarRecordingContent {
        VoiceBarRecordingContent(
            statusText: hotkeyPhase == .holding ? "Release to send" : "Listening...",
            showsWaveform: true,
            usesPulsingLabelOpacity: true
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

        return hotkeyEnabled ? readyHotkeyHint : "Enable hotkey"
    }

    static func liveStatusText(
        mode: VoiceMode,
        transcript: String,
        confirmationText: String?,
        hotkeyPhase: HotkeyPhase,
        hotkeyEnabled: Bool,
        errorMessage: String?
    ) -> String {
        switch mode {
        case .idle:
            idleStatusText(
                transcript: transcript,
                confirmationText: confirmationText,
                hotkeyPhase: hotkeyPhase,
                hotkeyEnabled: hotkeyEnabled
            )
        case .disconnected:
            "Disconnected"
        case .speaking:
            "Speaking..."
        case .recording:
            recordingContent(hotkeyPhase: hotkeyPhase).statusText
        case .transcribing:
            "Thinking..."
        case .error:
            errorMessage ?? "Error"
        }
    }

    static func lastWords(_ text: String) -> String {
        let words = text.split(separator: " ")
        if words.count <= maxIdleWords { return text }
        return words.suffix(maxIdleWords).joined(separator: " ")
    }
}
