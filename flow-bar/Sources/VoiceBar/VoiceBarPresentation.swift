import CoreGraphics
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

struct VoiceBarTranscriptPreviewLayout: Equatable {
    var height: CGFloat
    var lineLimit: Int
    var isMultiline: Bool
}

enum VoiceBarPresentation {
    static let readyHotkeyHint = "F5 to talk"
    static let holdToTalkHint = "Hold to talk"
    static let releaseToSendHint = "Release to send"
    static let tapAgainToLockHint = "Tap again to lock"

    static func hotkeyPermissionHint(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission]
    ) -> String {
        guard !hotkeyEnabled else { return "Hotkey: F5" }
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
            statusText: "",
            showsWaveform: true,
            usesPulsingLabelOpacity: false
        )
    }

    static func isHotkeyTransitionStatus(_ statusText: String) -> Bool {
        switch statusText {
        case holdToTalkHint, releaseToSendHint, tapAgainToLockHint:
            return true
        default:
            return false
        }
    }

    static func isPanelDraggable(mode: VoiceMode) -> Bool {
        false
    }

    static func idleAccessoryButtonCount(
        recentTranscriptions: [String],
        transcriptionVocabularyTerms: [String],
        transcriptionVocabularyAliases: [STTVocabularyAliasPreview],
        canReplay: Bool
    ) -> Int {
        var count = 0
        if !recentTranscriptions.isEmpty {
            count += 1
        }
        if !transcriptionVocabularyTerms.isEmpty || !transcriptionVocabularyAliases.isEmpty {
            count += 1
        }
        if canReplay {
            count += 1
        }
        return count
    }

    static func transcriptPreviewText(
        mode: VoiceMode,
        confirmationText: String?,
        commandModeState: CommandModeState?,
        activeClipMarker: ClipMarkerState?
    ) -> String? {
        guard mode == .idle,
              commandModeState == nil,
              activeClipMarker == nil else {
            return nil
        }
        let text = confirmationText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    static func transcriptPreviewLayout(for text: String) -> VoiceBarTranscriptPreviewLayout {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let width = Theme.transcriptPreviewWidth(for: trimmed)
        let isMultiline = trimmed.count > 52 || width >= Theme.pillTranscriptPreviewWidth

        return VoiceBarTranscriptPreviewLayout(
            height: isMultiline ? Theme.pillTranscriptPreviewHeight : Theme.pillCompactHeight,
            lineLimit: isMultiline ? 2 : 1,
            isMultiline: isMultiline
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
            return holdToTalkHint
        case .holding:
            return releaseToSendHint
        case .awaitingSecondTap:
            return tapAgainToLockHint
        case .idle:
            break
        }

        return hotkeyEnabled ? readyHotkeyHint : "Enable hotkey"
    }

    static func liveStatusText(
        mode: VoiceMode,
        transcript: String,
        confirmationText: String?,
        hotkeyPhase: HotkeyPhase,
        hotkeyEnabled: Bool,
        errorMessage: String?,
        commandModeState: CommandModeState?,
        activeClipMarker: ClipMarkerState?
    ) -> String {
        if let commandModeState {
            switch commandModeState.phase {
            case .applying:
                let promptText = commandModeState.prompt?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "Command: \((promptText?.isEmpty == false ? promptText! : "Apply to selection"))"
            case .fallback:
                return "Command fallback"
            case .done:
                return "Command applied"
            case .error:
                return "Command failed"
            case .listening:
                return "Command: listening"
            case .capturing:
                return "Command: capture selection"
            }
        }

        if let activeClipMarker {
            let label = activeClipMarker.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? "Clip marked" : "Clip marked: \(label)"
        }

        return switch mode {
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
            ""
        case .error:
            errorMessage ?? "Error"
        }
    }

}
