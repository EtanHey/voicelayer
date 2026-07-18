import CoreGraphics
import Foundation

public enum HotkeyPhase: Equatable {
    case idle
    case pressing
    case holding
    case awaitingSecondTap
}

public struct VoiceBarRecordingContent: Equatable {
    public var statusText: String
    public var showsWaveform: Bool
    public var usesPulsingLabelOpacity: Bool
}

public struct VoiceBarRecordingHoldControl: Equatable {
    public var iconName: String
    public var accessibilityLabel: String
    public var accessibilityHint: String
    public var isSelected: Bool
}

public struct VoiceBarQueuePreview: Equatable {
    public var currentText: String
    public var nextText: String?
    public var overflowCount: Int
    public var progress: Double
}

public struct VoiceBarTranscriptPreviewLayout: Equatable {
    public var height: CGFloat
    public var lineLimit: Int
    public var isMultiline: Bool
}

public struct VoiceBarNotchOperationalInput: Equatable {
    public var mode: VoiceMode
    public var hasTeleprompterText: Bool
    public var isTeleprompterDismissed: Bool
    public var isTeleprompterReadback: Bool
    public var confirmationText: String?
    public var commandModeState: CommandModeState?
    public var activeClipMarker: ClipMarkerState?
    public var queueDepth: Int
    public var keepsPasteFlowEnvelope: Bool
    public var hotkeyPhase: HotkeyPhase
    public var isHovered: Bool
    public var isKeyboardFocused: Bool

    public init(
        mode: VoiceMode,
        hasTeleprompterText: Bool = false,
        isTeleprompterDismissed: Bool = false,
        isTeleprompterReadback: Bool = false,
        confirmationText: String? = nil,
        commandModeState: CommandModeState? = nil,
        activeClipMarker: ClipMarkerState? = nil,
        queueDepth: Int = 0,
        keepsPasteFlowEnvelope: Bool = false,
        hotkeyPhase: HotkeyPhase = .idle,
        isHovered: Bool = false,
        isKeyboardFocused: Bool = false
    ) {
        self.mode = mode
        self.hasTeleprompterText = hasTeleprompterText
        self.isTeleprompterDismissed = isTeleprompterDismissed
        self.isTeleprompterReadback = isTeleprompterReadback
        self.confirmationText = confirmationText
        self.commandModeState = commandModeState
        self.activeClipMarker = activeClipMarker
        self.queueDepth = queueDepth
        self.keepsPasteFlowEnvelope = keepsPasteFlowEnvelope
        self.hotkeyPhase = hotkeyPhase
        self.isHovered = isHovered
        self.isKeyboardFocused = isKeyboardFocused
    }
}

public enum VoiceBarPresentation {
    public static let readyHotkeyHint = "F5 to talk"
    public static let holdToTalkHint = "Hold to talk"
    public static let releaseToSendHint = "Release to send"
    public static let tapAgainToLockHint = "Tap again to lock"

    public static func notchPresentation(
        from input: VoiceBarNotchOperationalInput
    ) -> VoiceBarNotchPresentation {
        let hasTeleprompter = reservesTeleprompterEnvelope(
            hasText: input.hasTeleprompterText,
            isDismissed: input.isTeleprompterDismissed,
            isReadback: input.isTeleprompterReadback
        )
        let isRecording = input.mode == .recording
        let hasCompactStatus: Bool
        switch input.mode {
        case .recording:
            hasCompactStatus = false
        case .idle:
            let confirmation = input.confirmationText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hasCompactStatus = !confirmation.isEmpty ||
                input.commandModeState != nil ||
                input.activeClipMarker != nil ||
                input.queueDepth > 0 ||
                input.keepsPasteFlowEnvelope ||
                input.hotkeyPhase != .idle
        case .speaking, .transcribing, .error, .disconnected:
            hasCompactStatus = true
        }

        return VoiceBarNotchPresentation.resolve(
            hasTeleprompter: hasTeleprompter,
            isRecording: isRecording,
            hasCompactStatus: hasCompactStatus,
            isHovered: input.isHovered,
            isKeyboardFocused: input.isKeyboardFocused
        )
    }

    public static func hotkeyPermissionHint(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission]
    ) -> String {
        guard !hotkeyEnabled else { return "Hotkey: F5" }
        let labels = missingPermissions.map {
            switch $0 {
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            case .microphone: "Microphone"
            }
        }.sorted()
        guard !labels.isEmpty else { return "Hotkey: needs permission" }
        return "Hotkey: enable \(labels.joined(separator: " + "))"
    }

    public static func queuePreview(from items: [QueueItemState]) -> VoiceBarQueuePreview {
        let current = items.first(where: \.isCurrent) ?? items.first
        let next = items.dropFirst().first(where: { !$0.isCurrent }) ?? items.dropFirst().first

        return VoiceBarQueuePreview(
            currentText: current?.text ?? "Queued audio",
            nextText: next?.text,
            overflowCount: max(0, items.count - (next == nil ? 1 : 2)),
            progress: current?.progress ?? 0
        )
    }

    public static func recordingContent(hotkeyPhase: HotkeyPhase) -> VoiceBarRecordingContent {
        VoiceBarRecordingContent(
            statusText: "",
            showsWaveform: true,
            usesPulsingLabelOpacity: false
        )
    }

    public static func recordingHoldControl(
        mode: VoiceMode,
        recordingMode: String?,
        isEngaged: Bool
    ) -> VoiceBarRecordingHoldControl? {
        guard mode == .recording, recordingMode == "vad" else { return nil }
        return VoiceBarRecordingHoldControl(
            iconName: isEngaged ? "hand.raised.fill" : "hand.raised",
            accessibilityLabel: isEngaged ? "Release recording hold" : "Hold recording",
            accessibilityHint: isEngaged
                ? "Resume automatic silence stop"
                : "Keep recording through silence",
            isSelected: isEngaged
        )
    }

    public static func reservesTeleprompterEnvelope(
        hasText: Bool,
        isDismissed: Bool,
        isReadback: Bool
    ) -> Bool {
        hasText && (!isDismissed || isReadback)
    }

    public static func isHotkeyTransitionStatus(_ statusText: String) -> Bool {
        switch statusText {
        case holdToTalkHint, releaseToSendHint, tapAgainToLockHint:
            true
        default:
            false
        }
    }

    public static func isPanelDraggable(mode: VoiceMode) -> Bool {
        false
    }

    public static func idleAccessoryButtonCount(
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

    public static func transcriptPreviewText(
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

    public static func transcriptPreviewLayout(for text: String) -> VoiceBarTranscriptPreviewLayout {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let width = Theme.transcriptPreviewWidth(for: trimmed)
        let isMultiline = trimmed.count > 52 || width >= Theme.pillTranscriptPreviewWidth

        return VoiceBarTranscriptPreviewLayout(
            height: isMultiline ? Theme.pillTranscriptPreviewHeight : Theme.pillCompactHeight,
            lineLimit: isMultiline ? 2 : 1,
            isMultiline: isMultiline
        )
    }

    public static func idleStatusText(
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

    public static func liveStatusText(
        mode: VoiceMode,
        transcript: String,
        confirmationText: String?,
        hotkeyPhase: HotkeyPhase,
        hotkeyEnabled: Bool,
        errorMessage: String?,
        transcribingStatusText: String? = nil,
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
            {
                let trimmed = transcribingStatusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "Transcribing..." : trimmed
            }()
        case .error:
            errorStatusText(errorMessage)
        }
    }

    public static func errorStatusText(_ errorMessage: String?) -> String {
        let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return "Error" }
        if trimmed.lowercased() == "busy" {
            return "Busy"
        }
        return trimmed
    }
}
