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
    static let nothingSelected = "Select text\nfirst"
    static let copyTimedOut = "Timed out\nReselect"
    static let copyEmpty = "No text\nReselect"
    static let copyFailed = "Can't copy\nCheck A11y"

    static func contains(_ text: String?) -> Bool {
        guard let text else { return false }
        return [clipboardChanged, nothingSelected, copyTimedOut, copyEmpty, copyFailed].contains(text)
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

/// Recording pause: Pause beside Stop on a PTT take; paused, it becomes Resume (selected, like Lock).
public struct VoiceBarRecordingPauseControl: Equatable {
    public var iconName: String
    public var accessibilityLabel: String
    public var accessibilityHint: String
    public var isSelected: Bool
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

/// T1 (Etan QA 2026-11-09): the reading wing's Forward. It walks the current queue only (QUEUE1's queued Option+F5
/// reads) and is disabled when nothing waits; agent speech waiting behind the read shows its count but cannot be
/// skipped.
public struct VoiceBarReadingForwardControl: Equatable {
    public let isEnabled: Bool
    /// The waiting count on Forward's corner; nil when nothing waits.
    public let countLabel: String?
    public let countAccessibilityLabel: String?
    public let accessibilityHint: String
    /// Q1 (open for Etan): nothing queued and an Ask answer still transcribing, so its spinner takes Forward's slot.
    public let showsProcessingSpinner: Bool
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
    /// Recording pause takes the third recording slot on a PTT take, where Lock sits on a VAD take.
    public var showsRecordingPause: Bool
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
    /// V6: the rows the History panel's extend handle settled on (7…12).
    public var historyRows: Int = NotchHistoryMorph.visibleRows
    public var teleprompterLines: Int = TeleprompterA.lineRange.lowerBound
    /// N5: whether `transientNote` is the busy-selection note (Open History inline). Callers that know set it from
    /// `VoiceState.selectionFeedbackNoteOffersHistory`; nil falls back to recognising the app's own busy copy.
    public var transientNoteOffersHistory: Bool?
    public var isCollapsed: Bool
    public var coreWidth: CGFloat
    public var visibleCoreOcclusionInset: CGFloat
    /// NOTCH1: a transient note shown inside the notch, in a band under the top row.
    public var transientNote: String?
    /// 2.3 N1: an earlier take is still transcribing while this one records (the spinner beside Stop).
    public var showsEarlierTakeProcessing: Bool
    /// 0510 N9: an idle notice's left wing holds the mic and its microphone control (two slots).
    public var showsIdleMicrophoneControl: Bool = false

    public init(
        mode: VoiceMode,
        showsRecordingHold: Bool = false,
        showsRecordingPause: Bool = false,
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
        transientNote: String? = nil,
        transientNoteOffersHistory: Bool? = nil,
        showsEarlierTakeProcessing: Bool = false
    ) {
        self.showsEarlierTakeProcessing = showsEarlierTakeProcessing
        self.mode = mode
        self.showsRecordingHold = showsRecordingHold
        self.showsRecordingPause = showsRecordingPause
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
        self.transientNoteOffersHistory = transientNoteOffersHistory
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

    /// N5: the notes `selectionBusyNote` produces, which carry Open History inline.
    public static func isSelectionBusyNote(_ text: String) -> Bool {
        let notes: [String?] = [
            selectionBusyNote(isRequested: true, mode: .recording, hotkeyPhase: .idle),
            selectionBusyNote(isRequested: true, mode: .transcribing, hotkeyPhase: .idle),
            selectionBusyNote(isRequested: true, mode: .idle, hotkeyPhase: .pressing),
        ]
        return notes.contains(text)
    }

    /// 0510 N9: an idle notice (Typed, a paste flow, a queued badge, the F5 preview) shows the launcher's mic and
    /// its microphone control, unless a parked read's pause or queue controls hold that wing.
    public static func showsIdleMicrophoneControl(for state: VoiceState) -> Bool {
        state.mode == .idle && playbackPauseControl(for: state) == nil && readQueueControl(for: state) == nil
    }

    public static func notchPresentation(
        from input: VoiceBarNotchOperationalInput
    ) -> VoiceBarNotchPresentation {
        var input = input
        // N2: nothing is shown under the notch while transcribing, a note included.
        if input.mode == .transcribing { input.transientNote = nil }
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
            // N1: a confirmation is a notice, so it shows (as the tab) even from a collapsed notch; with a note
            // as well, the note's launcher shell already surfaces both.
            let collapsedNotice = isCollapsedIdle && !confirmation.isEmpty && (input.transientNote ?? "").isEmpty
            hasCompactStatus = collapsedNotice || !isCollapsedIdle && (!confirmation.isEmpty || hasWaitingReadQueue ||
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

        let resolved = VoiceBarNotchPresentation.resolve(
            hasTeleprompter: hasTeleprompter,
            isRecording: isRecording,
            hasCompactStatus: hasCompactStatus,
            hasHistoryPanel: input.isHistoryPanelOpen,
            historyRows: input.historyRows,
            teleprompterLines: input.teleprompterLines,
            compactStatusLeadingWingWidth: compactStatusLeadingWingWidth(input: input),
            compactStatusTrailingWingWidth: compactStatusTrailingWingWidth(input: input),
            recordingLeadingWingWidth: recordingLeadingWingWidth(
                mode: input.mode,
                showsRecordingHold: input.showsRecordingHold || input.showsRecordingPause,
                showsEarlierTakeProcessing: input.showsEarlierTakeProcessing
            ),
            recordingTrailingWingWidth: input.mode == .recording
                ? VoiceBarNotchContract.recordingTrailingWingWidth(
                    visibleCoreOcclusionInset: input.visibleCoreOcclusionInset)
                : nil,
            teleprompterLeadingWingWidth: input.mode == .speaking
                ? readingLeadingWingWidth(slotCount: input.readQueueLeadingSlotCount)
                : nil,
            teleprompterTrailingWingWidth: input.mode == .speaking && !input.isTeleprompterReadback
                ? readingTrailingWingWidth(visibleCoreOcclusionInset: input.visibleCoreOcclusionInset)
                : nil,
            isHovered: input.isHovered || keepsIdleExpanded,
            isKeyboardFocused: input.isKeyboardFocused,
            coreWidth: input.coreWidth,
            visibleCoreOcclusionInset: input.visibleCoreOcclusionInset,
            transientNoteWidth: input.transientNote.map(Theme.intrinsicPillStatusWidth(for:))
        )
        return VoiceBarNotchFeedback.resolve(input: input, presentation: resolved)
            .map { resolved.addingFeedback($0) } ?? resolved
    }

    private static func compactStatusLeadingWingWidth(
        input: VoiceBarNotchOperationalInput
    ) -> CGFloat? {
        switch input.mode {
        case .speaking:
            readingLeadingWingWidth(slotCount: input.readQueueLeadingSlotCount)
        case .idle:
            input.showsIdleMicrophoneControl
                ? VoiceBarNotchContract.fixedWingWidth
                : playbackLeadingWingWidth(slotCount: input.readQueueLeadingSlotCount)
        case .transcribing:
            // 2.3 U2: the spinner sits where Stop was, in the same fixed wing.
            VoiceBarNotchContract.fixedWingWidth
        case .recording, .error, .disconnected:
            VoiceBarNotchContract.compactIndicatorLaneWidth
        }
    }

    /// 2.3 U2: reading aloud keeps the fixed wing; only a queued read's Next + "+N" (which the mock does not
    /// draw) can still widen it past two slots.
    public static func readingLeadingWingWidth(slotCount: Int) -> CGFloat {
        max(VoiceBarNotchContract.fixedWingWidth, playbackLeadingWingWidth(slotCount: slotCount))
    }

    /// QUEUE1: the leading wing fits its control slots exactly, so the hit rects (from the core outward) match.
    /// T1/T6: the reading transport (speed, Back, Pause, Forward) is its own fixed width.
    public static func playbackLeadingWingWidth(slotCount: Int) -> CGFloat {
        if slotCount >= readingTransportSlotCount { return readingTransportWingWidth }
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

    public static func playbackLeadingSlotCount(for state: VoiceState) -> Int {
        // T1/T6: a live read always shows the whole transport, whatever is queued.
        if playbackPauseControl(for: state) != nil { return readingTransportSlotCount }
        return (readQueueControl(for: state)?.leadingSlotCount ?? 1) + (state.showsReadingProcessingSpinner ? 1 : 0)
    }

    // MARK: - T1/T6 reading transport (Etan QA 2026-11-09)

    /// Speed, Back, Pause/Play and Forward: four controls, counted from the core like every wing slot.
    public static let readingTransportSlotCount = 4
    /// T6: "1×" up to "1.25×" at 10.5 pt; the outermost control, wider than a slot.
    public static let readingSpeedChipWidth: CGFloat = 30
    public static let disabledTransportOpacity: Double = 0.4
    /// Three slots, then the chip; the wing keeps the fixed wings' 8 pt outer inset, inside the 130 pt morph canvas.
    public static var readingTransportContentWidth: CGFloat {
        let material = VoiceBarNotchContract.material
        return 3 * material.compactControlSize + 3 * material.compactControlSpacing + readingSpeedChipWidth
    }
    public static var readingTransportWingWidth: CGFloat {
        VoiceBarNotchContract.compactCoreContentInset + readingTransportContentWidth +
            VoiceBarNotchContract.fixedWingContentInset
    }

    public static func readingForwardControl(for state: VoiceState) -> VoiceBarReadingForwardControl {
        readingForwardControl(readQueue: readQueueControl(for: state), readQueueCount: state.readQueueCount,
                              queuedSpeech: state.queuedSpeakCount,
                              showsProcessingSpinner: state.showsReadingProcessingSpinner)
    }

    public static func readingForwardControl(readQueue: VoiceBarReadQueueControl?, readQueueCount: Int,
                                             queuedSpeech: Int, showsProcessingSpinner: Bool) -> VoiceBarReadingForwardControl {
        if readQueue != nil {
            let waiting = max(0, readQueueCount)
            return VoiceBarReadingForwardControl(
                isEnabled: true, countLabel: "\(waiting)", countAccessibilityLabel: "\(waiting) queued",
                accessibilityHint: "Skip to the next queued selection; \(waiting) waiting",
                showsProcessingSpinner: false)
        }
        let speech = max(0, queuedSpeech)
        return VoiceBarReadingForwardControl(
            isEnabled: false,
            countLabel: speech > 0 ? "\(speech)" : nil,
            countAccessibilityLabel: speech > 0 ? "\(speech) queued speeches" : nil,
            accessibilityHint: speech > 0 ? "Agent speech plays after this read" : "Nothing queued after this read",
            showsProcessingSpinner: showsProcessingSpinner && speech == 0)
    }

    /// Collapsed Stop sits centred in the recording wing's outer region (26 pt since 0510 N10), 3 pt in from each side.
    public static var readingStopOuterRegionInset: CGFloat {
        (VoiceBarRecordingWingLabel.outerRegionWidth - VoiceBarNotchContract.material.compactControlSize) / 2
    }

    /// T5/T7: the reading right wing is the recording wing (time, meter, outer region).
    public static func readingTrailingWingWidth(visibleCoreOcclusionInset: CGFloat) -> CGFloat {
        VoiceBarNotchContract.recordingTrailingWingWidth(visibleCoreOcclusionInset: visibleCoreOcclusionInset)
    }

    // MARK: - T4/T7 teleprompter lower row (Etan QA 2026-11-09)

    /// The lower row's pitch is a control plus 10 pt (`VoiceBarNotchHitRegion`).
    public static let teleprompterLowerControlSpacing: CGFloat = 10

    /// Replay (when available) and the eye: the group centred in the body.
    public static func teleprompterLowerGroupCount(canReplay: Bool) -> Int { canReplay ? 2 : 1 }

    /// The terminal control (Stop or X) centre, from the body's centre: one pitch past the group's trailing edge.
    public static func teleprompterTerminalOffset(groupControlCount: Int) -> CGFloat {
        let size = VoiceBarNotchContract.material.compactControlSize
        let count = CGFloat(max(1, groupControlCount))
        let groupWidth = count * size + (count - 1) * teleprompterLowerControlSpacing
        return groupWidth / 2 + teleprompterLowerControlSpacing + size / 2
    }

    /// The lower row's distance from the body's bottom edge: the handle band (or its reserve) sits under it.
    public static let teleprompterLowerControlBottomInset: CGFloat =
        TeleprompterA.bodyBottomInset + TeleprompterA.handleBandHeight + TeleprompterA.handleGap

    public static func readQueueControl(for state: VoiceState) -> VoiceBarReadQueueControl? {
        readQueueControl(
            // 2.4 Lane A: a paused read waiting out "Typed" keeps the paused layout (Play, Next, +N).
            mode: state.isParkedReadAwaitingFeedback ? .speaking : state.mode,
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
        case .speaking:
            // T5/T7: reading is laid out like recording (time, meter, and Stop in the outer region while collapsed).
            return readingTrailingWingWidth(visibleCoreOcclusionInset: input.visibleCoreOcclusionInset)
        case .transcribing:
            // 2.3 U2: History + Settings while transcribing.
            return VoiceBarNotchContract.fixedWingWidth
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
        showsRecordingHold: Bool,
        showsEarlierTakeProcessing: Bool
    ) -> CGFloat? {
        guard mode == .recording else { return nil }
        let material = VoiceBarNotchContract.material
        // 2.3 N1: the earlier take's spinner is one more slot at the wing's outer edge.
        return (showsRecordingHold
            ? VoiceBarNotchContract.recordingLeadingWingWidthWithHoldControl
            : VoiceBarNotchContract.recordingLeadingWingWidth) +
            (showsEarlierTakeProcessing ? material.compactControlSpacing + material.compactControlSize : 0)
    }

    /// 2.3 N1 (Etan, queued-recording clip F1): while this take records, an earlier take is still queued,
    /// transcribing or delivering, per the daemon's job snapshot. The live take itself is never counted.
    public static func showsEarlierTakeProcessing(for state: VoiceState) -> Bool {
        state.mode == .recording && state.processingTakeCount > 0
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

    public static func recordingPauseControl(
        mode: VoiceMode,
        recordingMode: String?,
        isPaused: Bool
    ) -> VoiceBarRecordingPauseControl? {
        guard mode == .recording, recordingMode == "ptt" else { return nil }
        return isPaused
            ? VoiceBarRecordingPauseControl(iconName: "play.fill", accessibilityLabel: "Resume recording",
                                            accessibilityHint: "Continue the same take", isSelected: true)
            : VoiceBarRecordingPauseControl(iconName: "pause.fill", accessibilityLabel: "Pause recording",
                                            accessibilityHint: "Stop adding audio to this take until you resume",
                                            isSelected: false)
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
    /// The wing's pause/play for `state`, including a paused read that is waiting out a dictation's feedback.
    public static func playbackPauseControl(for state: VoiceState) -> VoiceBarPlaybackPauseControl? {
        if state.isParkedReadAwaitingFeedback {
            return playbackPauseControl(mode: .speaking, isPaused: true, isReadback: false)
        }
        return playbackPauseControl(mode: state.mode, isPaused: state.isPlaybackPaused, isReadback: state.isTeleprompterReadback)
    }

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
            "Speaking…"
        case .recording:
            recordingContent(hotkeyPhase: hotkeyPhase).statusText
        case .transcribing:
            {
                let trimmed = transcribingStatusText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? "Transcribing…" : trimmed
            }()
        case .error:
            errorStatusText(errorMessage)
        }
    }

    public static func errorStatusText(_ errorMessage: String?) -> String {
        let trimmed = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // N4: an empty diagnostic is hidden; the notch never invents "Error" copy for it.
        guard !trimmed.isEmpty else { return "" }
        if trimmed.lowercased() == "busy" {
            return "Busy"
        }
        return trimmed
    }
}
