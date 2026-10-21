import CoreGraphics
import Foundation

/// A typed delivery posted its key events; nothing read them back. One short, truthful line.
enum PasteDeliveryFeedback {
    static let typed = "Typed"
}

/// Recovery copy shares one identity between the producer and its two-line layout.
enum PasteRecoveryFeedback {
    static let notInserted = "Not pasted\nIn History"
    static let unverified = "Unverified\nIn History"
    static let partial = "Part pasted\nHistory: full"

    static func contains(_ text: String?) -> Bool {
        guard let text else { return false }
        return [notInserted, unverified, partial].contains(text)
    }
}

enum SelectionErrorFeedback {
    static let clipboardChanged = "Clipboard\nReselect"
    static let copyTimedOut = "Timed out\nReselect"
    static let copyEmpty = "No text\nReselect"
    static let copyFailed = "Can't copy\nCheck A11y"

    static func contains(_ text: String?) -> Bool {
        guard let text else { return false }
        return [clipboardChanged, copyTimedOut, copyEmpty, copyFailed].contains(text)
    }
}

/// MICDROP2: the input device was lost mid-recording. The pill and History share one clock.
enum MicDisconnectFeedback {
    static func clock(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, Int((Double(milliseconds) / 1000).rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    static func pill(atMs: Int) -> String { "Mic lost\nat \(clock(atMs))" }
    static func historyNote(atMs: Int) -> String { "Mic disconnected at \(clock(atMs))" }

    static func contains(_ text: String?) -> Bool {
        text?.hasPrefix("Mic lost\nat ") == true
    }
}

/// Only these short notices opt into two lines; transcript previews keep their limit.
enum TwoLineStatusFeedback {
    static func contains(_ text: String?) -> Bool {
        PasteRecoveryFeedback.contains(text) || SelectionErrorFeedback.contains(text)
            || MicDisconnectFeedback.contains(text)
    }
}

public enum HotkeyPhase: Equatable {
    case idle
    case pressing
    case holding
    case awaitingSecondTap
}

public enum SelectionBusyReason: String {
    case recording, transcribing
    case f5Preview = "f5_preview"
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

public struct VoiceBarPlaybackPauseControl: Equatable {
    public let iconName: String
    public let accessibilityLabel: String
    public let accessibilityHint: String
}

/// QUEUE1: Next and the "+N" count beside P16's pause/play while queued Option+F5 reads wait.
public struct VoiceBarReadQueueControl: Equatable {
    public let iconName: String
    /// "+N" while reads wait behind the current one; nil on the last item, where Next stops.
    public let countLabel: String?
    public let accessibilityLabel: String
    public let accessibilityHint: String
    /// Leading-wing slots: pause/play, Next and, with a count, the "+N" label.
    public let leadingSlotCount: Int
}

public struct VoiceBarNotchOperationalInput: Equatable {
    public var mode: VoiceMode
    public var showsRecordingHold: Bool
    public var hasTeleprompterText: Bool
    public var isTeleprompterDismissed: Bool
    public var isTeleprompterReadback: Bool
    /// P16: the read is parked by Pause; the teleprompter collapses until Resume.
    public var isPlaybackPaused: Bool
    /// QUEUE1: pause/play alone is 1 slot; Next and the "+N" count widen the leading wing.
    public var readQueueLeadingSlotCount: Int
    public var confirmationText: String?
    public var commandModeState: CommandModeState?
    public var activeClipMarker: ClipMarkerState?
    public var queueDepth: Int
    public var keepsPasteFlowEnvelope: Bool
    public var hotkeyPhase: HotkeyPhase
    public var statusText: String
    public var isHovered: Bool
    public var isKeyboardFocused: Bool
    /// The notch History panel is open (spec §4). Recording and the teleprompter still take precedence.
    public var isHistoryPanelOpen: Bool = false
    public var isCollapsed: Bool
    public var coreWidth: CGFloat
    public var visibleCoreOcclusionInset: CGFloat
    /// NOTCH1: a transient note shown inside the notch, in a band under the top row.
    public var transientNote: String?

    public init(
        mode: VoiceMode,
        showsRecordingHold: Bool = false,
        hasTeleprompterText: Bool = false,
        isTeleprompterDismissed: Bool = false,
        isTeleprompterReadback: Bool = false,
        isPlaybackPaused: Bool = false,
        readQueueLeadingSlotCount: Int = 1,
        confirmationText: String? = nil,
        commandModeState: CommandModeState? = nil,
        activeClipMarker: ClipMarkerState? = nil,
        queueDepth: Int = 0,
        keepsPasteFlowEnvelope: Bool = false,
        hotkeyPhase: HotkeyPhase = .idle,
        statusText: String = "",
        isHovered: Bool = false,
        isKeyboardFocused: Bool = false,
        isCollapsed: Bool = false,
        coreWidth: CGFloat = VoiceBarNotchContract.coreWidth,
        visibleCoreOcclusionInset: CGFloat = 0,
        transientNote: String? = nil
    ) {
        self.mode = mode
        self.showsRecordingHold = showsRecordingHold
        self.hasTeleprompterText = hasTeleprompterText
        self.isTeleprompterDismissed = isTeleprompterDismissed
        self.isTeleprompterReadback = isTeleprompterReadback
        self.isPlaybackPaused = isPlaybackPaused
        self.readQueueLeadingSlotCount = readQueueLeadingSlotCount
        self.confirmationText = confirmationText
        self.commandModeState = commandModeState
        self.activeClipMarker = activeClipMarker
        self.queueDepth = queueDepth
        self.keepsPasteFlowEnvelope = keepsPasteFlowEnvelope
        self.hotkeyPhase = hotkeyPhase
        self.statusText = statusText
        self.isHovered = isHovered
        self.isKeyboardFocused = isKeyboardFocused
        self.isCollapsed = isCollapsed
        self.coreWidth = coreWidth
        self.visibleCoreOcclusionInset = visibleCoreOcclusionInset
        self.transientNote = transientNote
    }
}

public enum VoiceBarPresentation {
    public static let readyHotkeyHint = "F5 to talk"
    public static let holdToTalkHint = "Hold to talk"
    public static let releaseToSendHint = "Release to send"
    public static let tapAgainToLockHint = "Tap again to lock"

    public static func selectionBusyReason(mode: VoiceMode, hotkeyPhase: HotkeyPhase) -> SelectionBusyReason? {
        if mode == .recording { return .recording }
        if mode == .transcribing { return .transcribing }
        return hotkeyPhase == .idle ? nil : .f5Preview
    }

    public static func selectionBusyNote(isRequested: Bool, mode: VoiceMode, hotkeyPhase: HotkeyPhase) -> String? {
        guard isRequested, let reason = selectionBusyReason(mode: mode, hotkeyPhase: hotkeyPhase) else { return nil }
        return switch reason {
        case .recording: "Busy recording. Selection not read"
        case .transcribing: "Busy transcribing. Selection not read"
        case .f5Preview: "Busy with F5. Selection not read"
        }
    }

    public static func notchPresentation(
        from input: VoiceBarNotchOperationalInput
    ) -> VoiceBarNotchPresentation {
        let isRecording = input.mode == .recording
        let hasWaitingReadQueue = input.mode == .idle && input.readQueueLeadingSlotCount > 1
        let isCollapsedIdle = input.mode == .idle && input.isCollapsed &&
            !input.isHovered && !input.isKeyboardFocused && !hasWaitingReadQueue
        let hasCompactStatus: Bool
        switch input.mode {
        case .recording:
            hasCompactStatus = false
        case .idle:
            let confirmation = input.confirmationText?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            hasCompactStatus = !isCollapsedIdle && (!confirmation.isEmpty || hasWaitingReadQueue ||
                input.commandModeState != nil ||
                input.activeClipMarker != nil ||
                input.queueDepth > 0 ||
                input.keepsPasteFlowEnvelope ||
                input.hotkeyPhase != .idle)
        case .speaking, .transcribing, .error, .disconnected:
            hasCompactStatus = true
        }
        let hasTeleprompter = !isCollapsedIdle && reservesTeleprompterEnvelope(
            hasText: input.hasTeleprompterText,
            isDismissed: input.isTeleprompterDismissed,
            isReadback: input.isTeleprompterReadback
        ) && !(input.mode == .idle && hasCompactStatus) && !isPlaybackPaused(input)
        let keepsIdleExpanded = input.mode == .idle && !input.isCollapsed

        return VoiceBarNotchPresentation.resolve(
            hasTeleprompter: hasTeleprompter,
            isRecording: isRecording,
            hasCompactStatus: hasCompactStatus,
            hasHistoryPanel: input.isHistoryPanelOpen,
            compactStatusLeadingWingWidth: compactStatusLeadingWingWidth(input: input),
            compactStatusTrailingWingWidth: compactStatusTrailingWingWidth(input: input),
            recordingLeadingWingWidth: recordingLeadingWingWidth(
                mode: input.mode,
                showsRecordingHold: input.showsRecordingHold
            ),
            recordingTrailingWingWidth: input.mode == .recording
                ? VoiceBarNotchContract.waveformWingWidth
                : nil,
            teleprompterLeadingWingWidth: input.mode == .speaking
                ? playbackLeadingWingWidth(slotCount: input.readQueueLeadingSlotCount)
                : nil,
            isHovered: input.isHovered || keepsIdleExpanded,
            isKeyboardFocused: input.isKeyboardFocused,
            coreWidth: input.coreWidth,
            visibleCoreOcclusionInset: input.visibleCoreOcclusionInset,
            transientNoteWidth: input.transientNote.map(Theme.intrinsicPillStatusWidth(for:))
        )
    }

    private static func compactStatusLeadingWingWidth(
        input: VoiceBarNotchOperationalInput
    ) -> CGFloat? {
        input.mode == .speaking || input.mode == .idle
            ? playbackLeadingWingWidth(slotCount: input.readQueueLeadingSlotCount)
            : VoiceBarNotchContract.compactIndicatorLaneWidth
    }

    /// QUEUE1: the leading wing fits its control slots exactly, so the hit rects (from the core outward) match.
    public static func playbackLeadingWingWidth(slotCount: Int) -> CGFloat {
        let material = VoiceBarNotchContract.material
        let slots = CGFloat(max(1, slotCount))
        return VoiceBarNotchContract.compactContentFitWingWidth(
            contentWidth: slots * material.compactControlSize + (slots - 1) * material.compactControlSpacing
        )
    }

    /// QUEUE1 (Etan, 2026-10-20): Next shows only while a read is queued behind the current one (PILL1).
    /// Never while recording, transcribing or on an ended readback.
    public static func readQueueControl(
        mode: VoiceMode,
        isReadback: Bool,
        currentRequestID: String?,
        count: Int
    ) -> VoiceBarReadQueueControl? {
        let waiting = max(0, count)
        // D2: after F5 interrupted the owner, idle keeps Next and "+N" (no pause) until Next or Stop.
        if mode == .idle, currentRequestID != nil, waiting > 0 {
            return VoiceBarReadQueueControl(
                iconName: "forward.fill", countLabel: "+\(waiting)", accessibilityLabel: "Next read",
                accessibilityHint: "Resume the queue with the next selection; \(waiting) waiting",
                leadingSlotCount: 2
            )
        }
        guard mode == .speaking, !isReadback, currentRequestID != nil, waiting > 0 else { return nil }
        return VoiceBarReadQueueControl(
            iconName: "forward.fill", countLabel: "+\(waiting)", accessibilityLabel: "Next read",
            accessibilityHint: "Skip to the next queued selection; \(waiting) waiting",
            leadingSlotCount: 3
        )
    }

    public static func readQueueControl(for state: VoiceState) -> VoiceBarReadQueueControl? {
        readQueueControl(
            mode: state.mode,
            isReadback: state.isTeleprompterReadback,
            currentRequestID: state.readQueueCurrentRequestID,
            count: state.readQueueCount
        )
    }

    private static func compactStatusTrailingWingWidth(
        input: VoiceBarNotchOperationalInput
    ) -> CGFloat? {
        let material = VoiceBarNotchContract.material
        let insets = WaveformLayout.coreGap + WaveformLayout.outerInset
        switch input.mode {
        case .transcribing:
            return insets + material.waveformSlotWidth +
                material.compactControlSpacing + material.compactControlSize
        case .speaking:
            let visibilityControl = input.isTeleprompterDismissed && !input.isPlaybackPaused
                ? material.compactControlSpacing + material.compactControlSize
                : 0
            return insets + material.waveformSlotWidth +
                material.compactControlSpacing + material.compactControlSize +
                visibilityControl
        case .error:
            return insets + Theme.intrinsicPillStatusWidth(for: input.statusText) +
                3 + material.compactControlSize +
                VoiceBarNotchContract.compactStatusTrailingSafetyInset
        case .idle:
            let queueWidth = input.queueDepth > 0
                ? Theme.intrinsicPillStatusWidth(for: "\(input.queueDepth)") + 16
                : 0
            return insets + queueWidth + Theme.intrinsicPillStatusWidth(for: input.statusText) +
                VoiceBarNotchContract.compactStatusTrailingSafetyInset
        case .disconnected:
            return insets + Theme.intrinsicPillStatusWidth(for: input.statusText) +
                VoiceBarNotchContract.compactStatusTrailingSafetyInset
        case .recording:
            return nil
        }
    }

    private static func recordingLeadingWingWidth(
        mode: VoiceMode,
        showsRecordingHold: Bool
    ) -> CGFloat? {
        guard mode == .recording else { return nil }
        return showsRecordingHold
            ? VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl
            : VoiceBarNotchContract.recordingLeadingWingWidth
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
            iconName: "lock.fill",
            accessibilityLabel: isEngaged ? "Unlock recording" : "Lock recording",
            accessibilityHint: isEngaged
                ? "Resume automatic silence stop"
                : "Keep recording through silence",
            isSelected: isEngaged
        )
    }

    private static func isPlaybackPaused(_ input: VoiceBarNotchOperationalInput) -> Bool {
        input.mode == .speaking && input.isPlaybackPaused
    }

    /// P16 (Etan, 2026-10-18): pause/play sits on the pill's left while VoiceBar speaks, never while
    /// recording, transcribing or idle (an ended readback has nothing playing).
    public static func playbackPauseControl(
        mode: VoiceMode,
        isPaused: Bool,
        isReadback: Bool
    ) -> VoiceBarPlaybackPauseControl? {
        guard mode == .speaking, !isReadback else { return nil }
        return isPaused
            ? VoiceBarPlaybackPauseControl(
                iconName: "play.fill",
                accessibilityLabel: "Resume speech",
                accessibilityHint: "Continue reading from the paused word"
            )
            : VoiceBarPlaybackPauseControl(
                iconName: "pause.fill",
                accessibilityLabel: "Pause speech",
                accessibilityHint: "Pause reading and collapse the teleprompter"
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
