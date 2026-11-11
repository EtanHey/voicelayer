import Foundation
import SwiftUI

public enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case general
    case transcription
    case dictionary
    case speech
    case history

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .speech: "Speech"
        case .transcription: "Transcription"
        case .dictionary: "Dictionary"
        case .history: "History"
        }
    }

    /// Case-insensitive `voicebar://settings/<tab>` routing; `models` is a permanent legacy alias.
    public init?(urlComponent: String) {
        if urlComponent.lowercased() == "models" {
            self = .transcription
            return
        }
        guard let tab = Self.allCases.first(where: { $0.title.lowercased() == urlComponent.lowercased() })
        else { return nil }
        self = tab
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .speech: "speaker.wave.2"
        case .transcription: "waveform"
        case .dictionary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// Asks an open Settings window to show `tab`. The app swaps the hosting controller's root view and
/// SwiftUI keeps `@State` across that swap, so `initialTab` cannot switch a live window; a new `id` makes
/// a repeat request for the same tab fire again, and an unchanged request never overrides the user.
public struct SettingsTabRequest: Equatable {
    public let tab: SettingsTab
    public let focus: SettingsFocus?
    /// History only: the dictation to select, by its audio path (a notch History row click, 2.3 U4). When it isn't
    /// on the loaded page the list keeps its usual selection.
    public let historyRecordingID: String?
    public let historyDestination: SettingsHistoryDestination?
    public let id: Int

    public init(tab: SettingsTab, focus: SettingsFocus? = nil, historyRecordingID: String? = nil, historyDestination: SettingsHistoryDestination? = nil, id: Int) {
        self.tab = tab
        self.focus = focus
        self.historyRecordingID = historyRecordingID
        self.historyDestination = historyDestination
        self.id = id
    }
}

/// A section a Settings request scrolls to after switching tab.
public enum SettingsFocus: String, Equatable, Hashable {
    /// General › Microphone priority, where the default microphone is chosen (D2 "Change…").
    case microphonePriority = "settings-general-microphone-priority"
    /// General › Setup, at its first broken step: where the notch gear's setup badge leads (2.3 U2). Permissions
    /// are Setup steps since U3a (R2), so the case keeps U2's name and raw value.
    case permissions = "settings-general-permissions"
}

/// History scopes in on-screen order; Dictations remains the default.
public enum SettingsHistoryScope: String, Hashable, CaseIterable, Sendable {
    case recording
    case ask
    case speech

    public var title: String {
        switch self {
        case .recording: "Dictations"
        case .ask: "Ask"
        case .speech: "Speech"
        }
    }
}

enum SettingsHistoryPartRole: Hashable {
    case recording
    case question
    case response
    case speech
}

enum SettingsHistoryAction: Hashable {
    case play
    case copy
    case paste
    case retranscribe
    case finder
}

/// The shared presentation unit for one independently actionable piece of retained History media.
/// Recording rows contain one unlabeled part; Ask rows preserve two ordered, labeled parts.
struct SettingsHistoryMediaPart: Equatable {
    let role: SettingsHistoryPartRole
    let displayText: String
    let isPlaceholder: Bool
    let actionableText: String?
    let audioPath: URL?
    let durationLabel: String?
    let transcribedDurationLabel: String?
    /// ≈ speech time with pauses left out; when present it replaces `transcribedDurationLabel` (F1: no third
    /// number).
    var spokenDurationLabel: String?
    /// "1.2 s processing", the same figure as the last-dictation card.
    var processingLabel: String?
    /// MICDROP2: "Mic disconnected at 0:42" when the input device was lost mid-recording.
    var micDisconnectLabel: String?
    var playbackQueue: [URL] = []

    var label: String? {
        switch role {
        case .recording: nil
        case .question: "Question"
        case .response: "Response"
        case .speech: nil
        }
    }

    var systemImage: String? {
        switch role {
        case .recording: nil
        case .question: "speaker.wave.2.fill"
        case .response: "mic.fill"
        case .speech: "speaker.wave.2.fill"
        }
    }

    var accessibilityNoun: String {
        switch role {
        case .recording: "recording audio"
        case .question: "question audio"
        case .response: "response audio"
        case .speech: "speech audio"
        }
    }

    var actions: [SettingsHistoryAction] {
        switch role {
        case .recording:
            [.play, .copy, .paste, .retranscribe, .finder]
        case .speech:
            [.play, .copy, .finder]
        case .question:
            [.play]
        case .response:
            // Ask-safe Re-transcribe is deliberately deferred to B2.
            [.play, .copy, .paste, .finder]
        }
    }

    func isEnabled(_ action: SettingsHistoryAction) -> Bool {
        guard actions.contains(action) else { return false }
        return switch action {
        case .play, .retranscribe, .finder:
            audioPath != nil
        case .copy, .paste:
            actionableText != nil
        }
    }
}

/// Whether a History action shows, and if it is blocked for now, why (UI pass #10: a disabled button with no
/// reason looks broken).
enum SettingsHistoryActionStyle {
    /// On top of the system's own dimming of a disabled button.
    static let disabledOpacity = 0.4
}

enum SettingsHistoryActionAvailability: Equatable {
    case available
    /// Can never apply to this part (no transcript to copy, no audio to play): not shown at all.
    case hidden
    /// Blocked for now; the reason is the tooltip and the VoiceOver hint.
    case unavailable(String)
}

/// One production admission result for archive controls in the drawer, window and latest menu.
public enum HistoryRetranscriptionAvailability: Equatable {
    case available
    case unavailable(String)
    public var reason: String? { if case let .unavailable(reason) = self { return reason }; return nil }
    public var isEnabled: Bool { self == .available }
}

struct SettingsHistoryActionEnablement: Equatable {
    let isRetranscribing: Bool
    let isRecording: Bool
    let isTranscribing: Bool
    /// The recording being re-transcribed, so its own Re-transcribe says so instead of "Another…".
    var retranscribingPath: String?
    var isVoiceBusy: Bool = false
    var archiveAdmission: HistoryRetranscriptionAvailability?

    func isEnabled(
        _ action: SettingsHistoryAction,
        for part: SettingsHistoryMediaPart
    ) -> Bool {
        guard part.isEnabled(action) else { return false }
        if action == .retranscribe, let archiveAdmission { return archiveAdmission.isEnabled }

        if action == .play, isRecording || isTranscribing || isVoiceBusy {
            return false
        }
        if action == .retranscribe, isRetranscribing || isRecording || isTranscribing {
            return false
        }
        if isRetranscribing, action == .copy || action == .paste {
            return false
        }
        return true
    }

    func availability(
        _ action: SettingsHistoryAction,
        for part: SettingsHistoryMediaPart
    ) -> SettingsHistoryActionAvailability {
        guard part.isEnabled(action) else { return .hidden }
        if action == .retranscribe, let archiveAdmission {
            return archiveAdmission.reason.map(SettingsHistoryActionAvailability.unavailable) ?? .available
        }
        guard !isEnabled(action, for: part) else { return .available }
        switch action {
        case .play, .retranscribe:
            if action == .play,
               isVoiceBusy { return .unavailable(SettingsHistoryCopy.playBusy) }
            if isRecording { return .unavailable("Unavailable while recording") }
            // AIDEV-NOTE: a re-transcription also puts the daemon in "transcribing", so this must be checked first
            // or every blocked button said "Unavailable while transcribing" (QA 2.2.25 C6, 04:52).
            if isRetranscribing {
                if action == .play { return .unavailable("Wait for the re-transcription to finish") }
                if let path = part.audioPath?.path, path == retranscribingPath {
                    return .unavailable("Re-transcribing this recording")
                }
                return .unavailable("Another re-transcription is running")
            }
            if isTranscribing { return .unavailable("Unavailable while transcribing") }
            return .unavailable("Unavailable right now")
        case .copy, .paste:
            return .unavailable("Wait for the re-transcription to finish")
        case .finder:
            return .unavailable("Unavailable right now")
        }
    }
}

struct SettingsHistoryRowModel: Equatable {
    let timestamp: String
    let parts: [SettingsHistoryMediaPart]
    var buildLabel: String? = nil

    static func recording(_ entry: SettingsHistoryEntry) -> SettingsHistoryRowModel {
        // F1: spoken length (≤ the trimmed length) replaces the trimmed one; entries archived before it was
        // measured keep the trimmed label.
        let hasSpokenLength = entry.spokenDurationMs != nil
        let durationLabels = durationLabels(
            durationMs: entry.durationMs,
            transcribedDurationMs: hasSpokenLength ? entry.spokenDurationMs : entry.transcribedDurationMs
        )
        return SettingsHistoryRowModel(
            timestamp: entry.timestamp(),
            parts: [
                SettingsHistoryMediaPart(
                    role: .recording,
                    displayText: entry.displayTranscript,
                    isPlaceholder: !entry.hasTranscript,
                    actionableText: entry.hasTranscript ? entry.transcript : nil,
                    audioPath: entry.audioPath,
                    durationLabel: durationLabels.audio,
                    transcribedDurationLabel: hasSpokenLength ? nil : durationLabels.transcribed,
                    spokenDurationLabel: hasSpokenLength ? durationLabels.transcribed : nil,
                    processingLabel: processingLabel(entry.processingDurationMs),
                    micDisconnectLabel: [entry.micDisconnectNote, entry.deliveryNote].compactMap { $0 }.joined(separator: " · ").settingsArchiveNilIfEmpty
                        ?? entry.micDisconnectedAtMs.map(MicDisconnectFeedback.historyNote(atMs:))
                ),
            ]
        )
    }

    static func processingLabel(_ milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        return String(format: "%.1f s processing", Double(milliseconds) / 1000)
    }

    static func ask(_ entry: SettingsAskHistoryEntry) -> SettingsHistoryRowModel {
        let durationLabels = durationLabels(
            durationMs: entry.responseDurationMs,
            transcribedDurationMs: entry.responseTranscribedDurationMs
        )
        return SettingsHistoryRowModel(
            timestamp: entry.timestamp(),
            parts: [
                SettingsHistoryMediaPart(
                    role: .question,
                    displayText: entry.displayQuestionText,
                    isPlaceholder: !entry.hasQuestionText,
                    actionableText: nil,
                    audioPath: entry.questionAudioPath,
                    durationLabel: nil,
                    transcribedDurationLabel: nil
                ),
                SettingsHistoryMediaPart(
                    role: .response,
                    displayText: entry.displayResponseTranscript,
                    isPlaceholder: !entry.hasResponseTranscript,
                    actionableText: entry.hasResponseTranscript ? entry.responseTranscript : nil,
                    audioPath: entry.responseAudioPath,
                    durationLabel: durationLabels.audio,
                    transcribedDurationLabel: durationLabels.transcribed
                ),
            ], buildLabel: entry.appBuild?.label
        )
    }

    /// Applies Recording's existing clock and one-second-difference rule to either domain model.
    private static func durationLabels(
        durationMs: Int?,
        transcribedDurationMs: Int?
    ) -> (audio: String?, transcribed: String?) {
        let audio = SettingsHistoryEntry.clockLabel(durationMs)
        guard let durationMs, let transcribedDurationMs else {
            return (audio, nil)
        }
        let difference = transcribedDurationMs.subtractingReportingOverflow(durationMs)
        guard difference.overflow || difference.partialValue.magnitude >= 1000 else {
            return (audio, nil)
        }
        return (audio, SettingsHistoryEntry.clockLabel(transcribedDurationMs))
    }
}

private enum DictEditorField: Hashable {
    case search
    /// The term list itself, so Delete/Backspace and the arrow keys act on the selected row.
    case list
}

private enum DictionaryCardLayout {
    static let headerHeight: CGFloat = 24
    /// UI pass #19: the pencil and trash were 10–12 pt targets.
    static let actionTarget: CGFloat = 24
}

struct SettingsVocabularyRevisionObserver: ViewModifier {
    let revision: UInt64
    let onRefresh: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: revision) {
            onRefresh()
        }
    }
}

struct SettingsHistoryLoadFence {
    private var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func cancel() {
        generation &+= 1
    }

    func accepts(_ candidate: Int) -> Bool {
        candidate == generation
    }
}

public enum SettingsShortcutCheck {
    static let readyMessage = "Shortcut ready: F5 listener and relay are active."

    public static func message(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        relayReady: Bool,
        relaySummary: String
    ) -> String {
        if hotkeyEnabled, missingPermissions.isEmpty, relayReady {
            return readyMessage
        }
        var problems: [String] = []
        if !hotkeyEnabled { problems.append("F5 listener unavailable") }
        if !missingPermissions.isEmpty { problems.append("Required permissions missing") }
        if !relayReady { problems.append(relaySummary) }
        return "Shortcut needs attention: \(problems.joined(separator: "; "))."
    }

    /// R4 UI pass #15: pressing Check changed nothing on screen. The line now says when the check ran and
    /// marks a pass, e.g. "Checked ✓ just now · Shortcut ready: …".
    public static func feedback(
        message: String,
        checkedAt: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let when = VoiceBarRelativeTime.label(checkedAt, now: now, calendar: calendar) ?? "Just now"
        // Only the relative words read mid-sentence in lower case; a date keeps its capitalisation
        // (#163 review: "Checked sep 18").
        let phrase = ["Just now", "Yesterday"].contains(when) ? when.lowercased() : when
        return "\(message == readyMessage ? "Checked ✓" : "Checked") \(phrase) · \(message)"
    }
}

/// R4 UI pass #14: "Hidden" didn't say when VoiceBar comes back.
/// The dot beside a Settings status: green when ready, red when something is wrong, gray when it is a choice.
public enum SettingsStatusTone: Equatable {
    case ready
    case attention
    case neutral
}

public enum SettingsVisibility {
    /// Hidden by choice isn't broken (#163 review), so it gets the neutral dot, not red.
    public static func tone(isHidden: Bool) -> SettingsStatusTone {
        isHidden ? .neutral : .ready
    }

    public static func hiddenStatus(until: Date?, calendar: Calendar = .current) -> String {
        guard let until else { return "Hidden" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return "Hidden until \(formatter.string(from: until))"
    }
}

public struct SettingsView: View {
    public let hotkeyEnabled: Bool
    public let missingPermissions: [HotkeyPermission]
    public let availableDevices: () -> [MicrophoneDevice]
    public let selectedDeviceID: () -> String?
    public let prioritySnapshot: () -> MicrophonePrioritySnapshot
    public let onReorderPriority: ([String]) -> Void
    public let polishDegradation: () -> STTPolishDegradation?
    public let onDismissPolishDegradation: () -> Void
    public let performanceEffort: () -> VoiceBarPerformanceEffort
    public let performanceEffortNotice: () -> String?
    public let onSelectPerformanceEffort: (VoiceBarPerformanceEffort) -> Void
    public let modelsStatus: () -> ModelsSettingsState
    public let tabRequest: SettingsTabRequest?
    /// Tells the app which tab is showing, so a Settings window rebuilt after a close reopens on it.
    public let onSelectedTabChange: (SettingsTab) -> Void
    public let onRefreshModelsStatus: () -> Void
    public let residencyNotice: () -> String?
    public let onSelectResidency: ((VoiceModelResidency) -> Void)?
    public let recognizerStatus: () -> RecognizerPickerState
    public let onManageRecognizer: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)?
    public let onSelectRecognizer: ((RecognizerPickerEngine) -> Void)?
    public let onSetUnloadWhenIdle: ((Bool) -> Void)?
    public let speechControls: () -> SpeechControlsState?
    public let speechConnected: () -> Bool
    public let speechBusyReason: () -> String?
    public let speechPending: () -> [String: SpeechValue]
    public let speechNotice: () -> String?
    public let onChangeSpeech: ((String, SpeechValue) -> Void)?
    public let onSelectSpeechEngine: ((SpeechProfile, String, String) -> Void)?
    public let onPreviewSpeech: ((SpeechProfile) -> Void)?
    /// V10 clone-engine row (Speech). The app feeds it `clone_engine` events and acks; nil reads "Unavailable".
    public let cloneEngineControl: CloneEngineControlViewModel?
    public let onReadClipboard: (() -> Void)?
    public let processingPending: () -> [ProcessingKey: Bool]
    public let processingNotice: () -> String?
    public let onToggleProcessing: ((ProcessingKey, Bool) -> Void)?
    public let vocabularyPreview: () -> STTVocabularyPreview
    private let hasInitialDictionaryPreview: Bool
    public let vocabularyRevision: () -> UInt64
    public let onRequestVocabularySnapshot: () -> Void
    public let onAddVocabularyAlias: (String, String) -> Void
    public let onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    public let onAddPromptTerm: (String) -> Void
    public let onRemovePromptTerm: (String) -> Void
    public let isHotkeyRemapActive: () -> Bool
    /// C12: when the latest left-mouse press happened (system uptime), from the app's event source. It tells one
    /// drag session from the next; nil means unknown. VoiceBarUI stays presentation-only, so the app reads it.
    public let lastMousePressUptime: () -> TimeInterval?
    public let onCheckShortcut: (@escaping (String) -> Void) -> Void
    /// Starts the F5 listener again after permissions were granted post-launch; the app refuses while recording.
    public let onRestartHotkeyListener: () -> HotkeyListenerRestartOutcome
    /// Read live, like the wizard's row: a never-asked microphone has to be requested before System Settings lists
    /// VoiceBar in its Microphone pane.
    public let microphoneAuthorization: () -> SetupMicrophoneAuthorization
    /// The wizard's request path (`AVCaptureDevice.requestAccess`); calls back on main once the prompt is answered.
    public let onRequestMicrophone: (@escaping () -> Void) -> Void
    public let onOpenPermissionURL: (URL) -> Void
    public let isVoiceBarHidden: () -> Bool
    public let hideVoiceBarDisabledReason: () -> String?
    public let voiceBarHiddenUntil: () -> Date?
    public let onHideVoiceBar: () -> Void
    public let onShowVoiceBar: () -> Void
    public let onRunRelaySetup: (@escaping (SettingsRelaySetupResult) -> Void) -> Void
    public let lastDictationEntry: () -> RecentTranscriptionEntry?
    public let lastDictationInsertionStatus: () -> DictationInsertionStatus
    public let onCopyLastDictation: (String) -> Bool
    public let historyPage: @Sendable (Int) async -> SettingsHistoryPage
    public let askHistoryPage: @Sendable (Int) async -> SettingsAskHistoryPage
    /// H1-c: a page of matches for a non-blank query, paged and cached by the index like the unfiltered pages.
    public let historySearchPage: @Sendable (Int, String) async -> SettingsHistoryPage
    public let askHistorySearchPage: @Sendable (Int, String) async -> SettingsAskHistoryPage
    /// Warms the search text in the background once History has its pages (lead add-on).
    public let searchPrewarm: @Sendable () async -> Void
    public let onCopyHistoryTranscript: (String) -> Void
    public let onPasteHistoryTranscript: (String) -> Void
    public let onRetranscribeHistoryEntry: (String) -> Void
    public let historyRunLog: () -> SettingsHistoryRunLog
    public let historyDiagnostics: @Sendable (URL) async -> SettingsHistoryDiagnostics
    public let historyAttempts: SettingsHistoryAttemptLogReader
    public let historyRetranscriptionAvailability: () -> HistoryRetranscriptionAvailability?
    public let isHistoryRetranscribing: (String) -> Bool
    public let isAnyHistoryRetranscribing: () -> Bool
    public let microphonePriorityDisabledReason: () -> String?
    public let isRecordingActive: () -> Bool
    public let isTranscribingActive: () -> Bool
    public let onRevealHistoryFile: (URL) -> Void
    public let footerPresentation: () -> VoiceBarFooterPresentation
    /// Setup's "Speaking voice" step; nil (not wired yet) leaves the step out.
    public let speakingVoiceStatus: () -> SettingsSetupVoiceStatus?
    /// Nil until the app exposes these: the rows then carry no switch.
    public let openAtLogin: SettingsToggleInput?
    public let mouseSideButtons: SettingsToggleInput?
    /// Transcription › Language and the K-ui last-dictation note; nil (not wired yet) hides them.
    public let transcriptionLanguage: SettingsChoiceInput?
    public let lastDictationNote: () -> SettingsLastDictationNote?
    /// Sidebar footer: the running bundle's version and release commit.
    public let installedVersion: VoiceBarInstalledVersion
    /// Nil (tests, the UI E2E host) means no network check; the row then shows the version only.
    public let versionCheck: VoiceBarVersionCheck?
    public let onVersionStatusChange: (VoiceBarVersionStatus) -> Void

    private let latestHistoryAnchorID = "settings-history-latest-anchor"
    private let latestAskHistoryAnchorID = "settings-ask-history-latest-anchor"
    private static let historyPageSize = SettingsHistoryArchive.defaultPageSize
    /// 2.4 (Etan, QA 0510 R2/N1: "settings should be in the notch app, not open the extra settings window"). Non-nil
    /// renders only this tab's own pane, without the window's sidebar and title, for the notch Settings drawer. The
    /// window keeps nil. History is not embedded: the drawer reuses the notch's own History rows for that tab.
    private var notchEmbeddedTab: SettingsTab?

    @State private var selectedTab: SettingsTab
    @State private var hotkeyListenerRestartLine: HotkeyListenerRestartLine?
    @State private var permissionsRefreshTick = 0
    @State private var localVoiceBarHidden: Bool
    @State private var historyDayGroups: [SettingsHistoryDayGroup]
    @State private var historyLoadedEntryCount: Int
    @State private var historyLoadedEntryLimit: Int
    @State private var historyHasMore: Bool
    /// QA-06: selection, scroll target and details state for Dictations, kept across tab changes.
    @State private var historyMemory: SettingsHistoryRecordingMemory
    /// QA-06: where the Dictations list and detail pane were scrolled; not observed, so scrolling is free.
    @State private var historyScroll = SettingsHistoryScrollMemory()
    private var selectedHistoryEntryID: String? { historyMemory.selectedID }
    @State private var isHistoryLoading = false
    @State private var historyLoadFence = SettingsHistoryLoadFence()
    @State private var historyRefreshTask: Task<Void, Never>?
    @State private var historyChangesDuringLoad = SettingsHistoryArchiveChanges()
    private let historyDetailsInitiallyExpanded: Bool
    private let speechHistoryRoot: URL
    @State private var speechLoading = SettingsSpeechHistoryLoading()
    @State private var speechEntries: [SettingsSpeechHistoryEntry] = []
    @State private var selectedSpeechID: String?
    @State private var selectedAskID: String?
    @State private var speechReload = SettingsSpeechHistoryReloadRequest()
    @State private var selectedHistoryScope: SettingsHistoryScope
    @State private var askHistoryDayGroups: [SettingsAskHistoryDayGroup]
    @State private var askHistoryLoadedEntryCount: Int
    @State private var askHistoryLoadedEntryLimit: Int
    @State private var askHistoryHasMore: Bool
    @State private var isAskHistoryLoading = false
    @State private var askHistoryLoadFence = SettingsHistoryLoadFence()
    @State private var askHistoryRefreshTask: Task<Void, Never>?
    @State private var askChangesDuringLoad = SettingsHistoryArchiveChanges()
    @State private var hasPrefetchedAskHistory = false
    /// History scopes shown at least once in this Settings session; they stay mounted (lane E).
    @State private var mountedHistoryScopes: Set<SettingsHistoryScope> = []
    @State private var searchPrewarmTask: Task<Void, Never>?
    @State private var historyPlayback = SettingsAudioPlayback.system()
    @State private var dictionarySearch = ""
    @State private var historySearch = ""
    @State private var askHistorySearch = ""
    @State private var includedTermsExpanded = false
    /// Etan (M27): "a collapsible Personal section". Expanded by default.
    @State private var yourTermsExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// UI pass #18: after Add/Edit the saved term is scrolled to, selected and flashed.
    @State private var selectedTermRowID: String?
    @State private var flashingTermRowID: String?
    @State private var pendingScrollRowID: String?
    @State private var dictionaryLoading = false
    @State private var hasLoadedDictionaryOnce: Bool
    @State private var dictionaryReloadQueued = false
    @State private var dictionaryReloadGate = DictionaryReloadGate()
    @State private var localEntries: [STTDictionaryEntry]
    @State private var dictionaryDisplayIndex: STTDictionaryDisplayIndex
    /// The one Add/Edit sheet (nil = closed). Etan's 2.2.24 review #3: no inline box, no per-term misheard row.
    @State private var termSheet: DictionaryTermEdit?
    /// A term deleted from Your terms that Undo can still put back (4 s; spec Dictionary).
    @State private var pendingDeletion: DictionaryPendingDeletion?
    @State private var hoveredTermRowID: String?
    /// The last Set up / Reinstall: which one ran, and its result (nil while it runs).
    @State private var relaySetupFeedback: (
        action: SettingsRelaySetupFeedback.Action,
        result: SettingsRelaySetupResult?
    )?
    @State private var relaySetupRunning = false
    @State private var shortcutCheckRunning = false
    @State private var shortcutCheckFeedback: (message: String, checkedAt: Date)?
    @State private var isAdvancedExpanded = false
    @State private var hoveredMicrophoneIndex: Int?
    @Environment(\.settingsHoverPreview) private var settingsHoverPreview
    @State private var setupHighlight = SettingsArrivalHighlight()
    @FocusState private var focusedSetupFix: SettingsSetupStepID?
    @State private var microphoneSnapshot = MicrophonePrioritySnapshot.unavailable
    @State private var microphoneDrag: MicrophoneDragState
    /// Nil until Settings first appears with a checker; then checking, then the result.
    @State private var versionStatus: VoiceBarVersionStatus?
    @FocusState private var focusedEditorField: DictEditorField?

    public init(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        availableDevices: @escaping () -> [MicrophoneDevice],
        selectedDeviceID: @escaping () -> String?,
        prioritySnapshot: @escaping () -> MicrophonePrioritySnapshot = { .unavailable },
        onReorderPriority: @escaping ([String]) -> Void = { _ in },
        polishDegradation: @escaping () -> STTPolishDegradation? = { nil },
        onDismissPolishDegradation: @escaping () -> Void = {},
        performanceEffort: @escaping () -> VoiceBarPerformanceEffort = { .accurate },
        performanceEffortNotice: @escaping () -> String? = { nil },
        onSelectPerformanceEffort: @escaping (VoiceBarPerformanceEffort) -> Void = { _ in },
        modelsStatus: @escaping () -> ModelsSettingsState,
        onRefreshModelsStatus: @escaping () -> Void,
        residencyNotice: @escaping () -> String? = { nil },
        onSelectResidency: ((VoiceModelResidency) -> Void)? = nil,
        recognizerStatus: @escaping () -> RecognizerPickerState = { .unavailable },
        onSelectRecognizer: ((RecognizerPickerEngine) -> Void)? = nil,
        onManageRecognizer: ((RecognizerPickerEngine, RecognizerManagementAction) -> Void)? = nil,
        onSetUnloadWhenIdle: ((Bool) -> Void)? = nil,
        speechControls: @escaping () -> SpeechControlsState? = { nil },
        speechConnected: @escaping () -> Bool = { false },
        speechBusyReason: @escaping () -> String? = { nil },
        speechPending: @escaping () -> [String: SpeechValue] = { [:] },
        speechNotice: @escaping () -> String? = { nil },
        onChangeSpeech: ((String, SpeechValue) -> Void)? = nil,
        onSelectSpeechEngine: ((SpeechProfile, String, String) -> Void)? = nil,
        onPreviewSpeech: ((SpeechProfile) -> Void)? = nil,
        cloneEngineControl: CloneEngineControlViewModel? = nil,
        onReadClipboard: (() -> Void)? = nil,
        processingPending: @escaping () -> [ProcessingKey: Bool] = { [:] },
        processingNotice: @escaping () -> String? = { nil },
        onToggleProcessing: ((ProcessingKey, Bool) -> Void)? = nil,
        vocabularyPreview: @escaping () -> STTVocabularyPreview = {
            STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        },
        vocabularyRevision: @escaping () -> UInt64,
        onRequestVocabularySnapshot: @escaping () -> Void = {},
        onAddVocabularyAlias: @escaping (String, String) -> Void = { _, _ in },
        onRemoveVocabularyAlias: @escaping (STTVocabularyAliasPreview) -> Void = { _ in },
        onAddPromptTerm: @escaping (String) -> Void = { _ in },
        onRemovePromptTerm: @escaping (String) -> Void = { _ in },
        isHotkeyRemapActive: @escaping () -> Bool = { false },
        lastMousePressUptime: @escaping () -> TimeInterval? = { nil },
        onCheckShortcut: @escaping (@escaping (String) -> Void) -> Void = { $0("Shortcut check unavailable.") },
        onRestartHotkeyListener: @escaping () -> HotkeyListenerRestartOutcome = { .failed(missing: []) },
        microphoneAuthorization: @escaping () -> SetupMicrophoneAuthorization = { .granted },
        onRequestMicrophone: @escaping (@escaping () -> Void) -> Void = { $0() },
        onOpenPermissionURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        isVoiceBarHidden: @escaping () -> Bool = { false },
        hideVoiceBarDisabledReason: @escaping () -> String? = { nil },
        voiceBarHiddenUntil: @escaping () -> Date? = { nil },
        onHideVoiceBar: @escaping () -> Void = {},
        onShowVoiceBar: @escaping () -> Void = {},
        onRunRelaySetup: @escaping (@escaping (SettingsRelaySetupResult) -> Void) -> Void = { completion in
            completion(SettingsRelaySetupResult(outcome: .failed(reason: "not available here"), finishedAt: Date()))
        },
        lastDictationEntry: @escaping () -> RecentTranscriptionEntry? = { nil },
        lastDictationInsertionStatus: @escaping () -> DictationInsertionStatus = { .unverified },
        onCopyLastDictation: @escaping (String) -> Bool = { _ in false },
        historyPage: @escaping @Sendable (Int) async -> SettingsHistoryPage = { limit in
            await SettingsArchiveIndex.shared.dictationPage(limit: limit)
        },
        historyGroups: (@Sendable () -> [SettingsHistoryDayGroup])? = nil,
        initialHistoryPage: SettingsHistoryPage? = nil,
        askHistoryPage: @escaping @Sendable (Int) async -> SettingsAskHistoryPage = { limit in
            await SettingsArchiveIndex.shared.askPage(limit: limit)
        },
        historySearchPage: @escaping @Sendable (Int, String) async -> SettingsHistoryPage = { limit, query in
            await SettingsArchiveIndex.shared.dictationPage(limit: limit, matching: query)
        },
        askHistorySearchPage: @escaping @Sendable (Int, String) async -> SettingsAskHistoryPage = { limit, query in
            await SettingsArchiveIndex.shared.askPage(limit: limit, matching: query)
        },
        searchPrewarm: @escaping @Sendable () async -> Void = {
            await SettingsArchiveIndex.shared.prewarmSearchText()
        },
        initialAskHistoryPage: SettingsAskHistoryPage? = nil,
        onCopyHistoryTranscript: @escaping (String) -> Void = { _ in },
        onPasteHistoryTranscript: @escaping (String) -> Void = { _ in },
        onRetranscribeHistoryEntry: @escaping (String) -> Void = { _ in },
        historyRunLog: @escaping () -> SettingsHistoryRunLog = { SettingsHistoryRunLog() },
        historyDiagnostics: @escaping @Sendable (URL) async -> SettingsHistoryDiagnostics = { url in
            await Task.detached(priority: .utility) {
                SettingsHistoryDiagnostics.load(audioPath: url, root: SettingsHistoryArchive.defaultRoot)
            }.value
        },
        historyAttempts: @escaping SettingsHistoryAttemptLogReader = { _ in nil },
        historyRetranscriptionAvailability: @escaping () -> HistoryRetranscriptionAvailability? = { nil },
        isHistoryRetranscribing: @escaping (String) -> Bool = { _ in false },
        isAnyHistoryRetranscribing: @escaping () -> Bool = { false },
        microphonePriorityDisabledReason: @escaping () -> String? = { nil },
        isRecordingActive: @escaping () -> Bool = { false },
        isTranscribingActive: @escaping () -> Bool = { false },
        onRevealHistoryFile: @escaping (URL) -> Void = { _ in },
        footerPresentation: @escaping () -> VoiceBarFooterPresentation = {
            .resolve(
                isConnected: false,
                mode: .disconnected,
                captureLive: false,
                errorMessage: nil,
                remoteSTTConfigured: nil
            )
        },
        speakingVoiceStatus: @escaping () -> SettingsSetupVoiceStatus? = { nil },
        openAtLogin: SettingsToggleInput? = nil,
        mouseSideButtons: SettingsToggleInput? = nil,
        transcriptionLanguage: SettingsChoiceInput? = nil,
        lastDictationNote: @escaping () -> SettingsLastDictationNote? = { nil },
        initialTab: SettingsTab = .general,
        tabRequest: SettingsTabRequest? = nil,
        initialHistoryScope: SettingsHistoryScope = .recording,
        historyDetailsInitiallyExpanded: Bool = false,
        speechHistoryRoot: URL = SettingsHistoryArchive.defaultRoot,
        initialSpeechEntryID: String? = nil,
        initialDictionarySearch: String = "",
        initialHistorySearch: String = "",
        initialAskHistorySearch: String = "",
        initialAdvancedExpanded: Bool = false,
        initialRelaySetupFeedback: (action: SettingsRelaySetupFeedback.Action,
                                    result: SettingsRelaySetupResult?)? = nil,
        initialMicrophoneDrag: MicrophoneDragState = MicrophoneDragState(),
        initialHotkeyListenerRestart: HotkeyListenerRestartOutcome? = nil,
        initialDictionaryPreview: STTVocabularyPreview? = nil,
        initialIncludedTermsExpanded: Bool = false,
        initialYourTermsExpanded: Bool = true,
        initialSelectedTermRowID: String? = nil,
        onSelectedTabChange: @escaping (SettingsTab) -> Void = { _ in },
        historyPlayback: SettingsAudioPlayback? = nil,
        installedVersion: VoiceBarInstalledVersion = .current(),
        versionCheck: VoiceBarVersionCheck? = nil,
        onVersionStatusChange: @escaping (VoiceBarVersionStatus) -> Void = { _ in }
    ) {
        self.hotkeyEnabled = hotkeyEnabled
        self.missingPermissions = missingPermissions
        self.availableDevices = availableDevices
        self.selectedDeviceID = selectedDeviceID
        self.prioritySnapshot = prioritySnapshot
        self.onReorderPriority = onReorderPriority
        self.polishDegradation = polishDegradation
        self.onDismissPolishDegradation = onDismissPolishDegradation
        self.performanceEffort = performanceEffort
        self.performanceEffortNotice = performanceEffortNotice
        self.onSelectPerformanceEffort = onSelectPerformanceEffort
        self.modelsStatus = modelsStatus
        self.onRefreshModelsStatus = onRefreshModelsStatus
        self.residencyNotice = residencyNotice
        self.onSelectResidency = onSelectResidency
        self.recognizerStatus = recognizerStatus
        self.onManageRecognizer = onManageRecognizer
        self.onSelectRecognizer = onSelectRecognizer
        self.onSetUnloadWhenIdle = onSetUnloadWhenIdle
        self.speechControls = speechControls
        self.speechConnected = speechConnected
        self.speechBusyReason = speechBusyReason
        self.speechPending = speechPending
        self.speechNotice = speechNotice
        self.onChangeSpeech = onChangeSpeech
        self.onSelectSpeechEngine = onSelectSpeechEngine
        self.onPreviewSpeech = onPreviewSpeech
        self.cloneEngineControl = cloneEngineControl
        self.onReadClipboard = onReadClipboard
        self.processingPending = processingPending
        self.processingNotice = processingNotice
        self.onToggleProcessing = onToggleProcessing
        self.vocabularyPreview = vocabularyPreview
        hasInitialDictionaryPreview = initialDictionaryPreview != nil
        self.vocabularyRevision = vocabularyRevision
        self.onRequestVocabularySnapshot = onRequestVocabularySnapshot
        self.onAddVocabularyAlias = onAddVocabularyAlias
        self.onRemoveVocabularyAlias = onRemoveVocabularyAlias
        self.onAddPromptTerm = onAddPromptTerm
        self.onRemovePromptTerm = onRemovePromptTerm
        self.isHotkeyRemapActive = isHotkeyRemapActive
        self.lastMousePressUptime = lastMousePressUptime
        self.onCheckShortcut = onCheckShortcut
        self.onRestartHotkeyListener = onRestartHotkeyListener
        self.microphoneAuthorization = microphoneAuthorization
        self.onRequestMicrophone = onRequestMicrophone
        self.onOpenPermissionURL = onOpenPermissionURL
        self.isVoiceBarHidden = isVoiceBarHidden
        self.hideVoiceBarDisabledReason = hideVoiceBarDisabledReason
        self.voiceBarHiddenUntil = voiceBarHiddenUntil
        self.onHideVoiceBar = onHideVoiceBar
        self.onShowVoiceBar = onShowVoiceBar
        self.onRunRelaySetup = onRunRelaySetup
        self.lastDictationEntry = lastDictationEntry
        self.lastDictationInsertionStatus = lastDictationInsertionStatus
        self.onCopyLastDictation = onCopyLastDictation
        if let historyGroups {
            self.historyPage = { limit in
                let groups = Self.newestFirstHistoryGroups(historyGroups())
                let limitedGroups = Self.limitHistoryGroups(groups, to: limit)
                return SettingsHistoryPage(
                    groups: limitedGroups,
                    loadedEntryCount: limitedGroups.reduce(0) { $0 + $1.entries.count },
                    hasMore: groups.reduce(0) { $0 + $1.entries.count } > limit
                )
            }
        } else {
            self.historyPage = historyPage
        }
        self._selectedSpeechID = State(initialValue: initialSpeechEntryID)
        self.historyDetailsInitiallyExpanded = historyDetailsInitiallyExpanded
        self.speechHistoryRoot = speechHistoryRoot
        self.askHistoryPage = askHistoryPage
        self.historySearchPage = historySearchPage
        self.askHistorySearchPage = askHistorySearchPage
        self.searchPrewarm = searchPrewarm
        self.onCopyHistoryTranscript = onCopyHistoryTranscript
        self.onPasteHistoryTranscript = onPasteHistoryTranscript
        self.onRetranscribeHistoryEntry = onRetranscribeHistoryEntry
        self.historyRunLog = historyRunLog
        self.historyDiagnostics = historyDiagnostics
        self.historyAttempts = historyAttempts
        self.historyRetranscriptionAvailability = historyRetranscriptionAvailability
        self.isHistoryRetranscribing = isHistoryRetranscribing
        self.isAnyHistoryRetranscribing = isAnyHistoryRetranscribing
        self.microphonePriorityDisabledReason = microphonePriorityDisabledReason
        self.isRecordingActive = isRecordingActive
        self.isTranscribingActive = isTranscribingActive
        self.onRevealHistoryFile = onRevealHistoryFile
        self.footerPresentation = footerPresentation
        self.speakingVoiceStatus = speakingVoiceStatus
        self.openAtLogin = openAtLogin
        self.mouseSideButtons = mouseSideButtons
        self.transcriptionLanguage = transcriptionLanguage
        self.lastDictationNote = lastDictationNote
        self.installedVersion = installedVersion
        self.versionCheck = versionCheck
        self.onVersionStatusChange = onVersionStatusChange
        self.tabRequest = tabRequest
        self.onSelectedTabChange = onSelectedTabChange
        _selectedTab = State(initialValue: tabRequest?.tab ?? initialTab)
        _dictionarySearch = State(initialValue: initialDictionarySearch)
        _historySearch = State(initialValue: initialHistorySearch)
        _askHistorySearch = State(initialValue: initialAskHistorySearch)
        _isAdvancedExpanded = State(initialValue: initialAdvancedExpanded)
        _relaySetupFeedback = State(initialValue: initialRelaySetupFeedback)
        _hotkeyListenerRestartLine = State(initialValue: initialHotkeyListenerRestart
            .map(HotkeyListenerRestartLine.init))
        _microphoneDrag = State(initialValue: initialMicrophoneDrag)
        // The list is there on the first frame instead of flashing "No known input devices" until onAppear.
        _microphoneSnapshot = State(initialValue: prioritySnapshot())
        _includedTermsExpanded = State(initialValue: initialIncludedTermsExpanded)
        _yourTermsExpanded = State(initialValue: initialYourTermsExpanded)
        _selectedTermRowID = State(initialValue: initialSelectedTermRowID)
        _selectedHistoryScope = State(initialValue: initialHistoryScope)
        if let historyPlayback {
            _historyPlayback = State(initialValue: historyPlayback)
        }
        _askHistoryDayGroups = State(initialValue: initialAskHistoryPage?.groups ?? [])
        _askHistoryLoadedEntryCount = State(initialValue: initialAskHistoryPage?.loadedEntryCount ?? 0)
        _askHistoryLoadedEntryLimit = State(
            initialValue: max(Self.historyPageSize, initialAskHistoryPage?.loadedEntryCount ?? 0)
        )
        _askHistoryHasMore = State(initialValue: initialAskHistoryPage?.hasMore ?? false)
        _localVoiceBarHidden = State(initialValue: isVoiceBarHidden())
        let initialHistoryLimit = max(Self.historyPageSize, initialHistoryPage?.loadedEntryCount ?? 0)
        _historyDayGroups = State(initialValue: initialHistoryPage?.groups ?? [])
        _historyLoadedEntryCount = State(initialValue: initialHistoryPage?.loadedEntryCount ?? 0)
        var historyMemory = SettingsHistoryRecordingMemory(
            initialPage: initialHistoryPage.map { $0.groups.flatMap(\.entries).map(\.id) })
        if tabRequest?.tab == .history, let recording = tabRequest?.historyRecordingID {
            historyMemory.request(recording)
            _selectedHistoryScope = State(initialValue: .recording)
        }
        if tabRequest?.tab == .history, let destination = tabRequest?.historyDestination {
            _selectedHistoryScope = State(initialValue: destination.scope)
            switch destination.scope {
            case .recording: historyMemory.request(destination.entryID)
            case .ask: _selectedAskID = State(initialValue: destination.entryID)
            case .speech: _selectedSpeechID = State(initialValue: destination.entryID)
            }
        }
        _historyMemory = State(initialValue: historyMemory)
        _historyLoadedEntryLimit = State(initialValue: initialHistoryLimit)
        _historyHasMore = State(initialValue: initialHistoryPage?.hasMore ?? false)
        _localEntries = State(initialValue: initialDictionaryPreview?.entries ?? [])
        _hasLoadedDictionaryOnce = State(initialValue: initialDictionaryPreview != nil)
        _dictionaryDisplayIndex = State(initialValue: initialDictionaryPreview
            .map(STTDictionaryDisplayIndex.init(preview:))
            ?? STTDictionaryDisplayIndex(entries: [], bundledRowsKnown: false))
    }

    /// The same view, showing only `tab`'s pane for the notch Settings drawer (no sidebar, no title, no minimum size).
    public func notchDrawerPane(_ tab: SettingsTab) -> SettingsView {
        var copy = self
        copy.notchEmbeddedTab = tab
        return copy
    }

    public var body: some View {
        if let notchEmbeddedTab {
            notchPane(notchEmbeddedTab)
        } else {
            windowBody
        }
    }

    @ViewBuilder
    private func notchPaneContent(_ tab: SettingsTab) -> some View {
        switch tab {
        case .general: generalTab
        case .transcription: transcriptionTab
        case .dictionary: dictionaryTab
        case .speech: speechPane
        case .history: EmptyView()
        }
    }

    /// Each pane scrolls inside itself (a grouped Form, or the dictionary's list), so the drawer only gives it a
    /// frame. The window's background is hidden: the notch's glass is the background.
    private func notchPane(_ tab: SettingsTab) -> some View {
        notchPaneContent(tab)
            .scrollContentBackground(.hidden)
            // Etan (QA 2026-11-11): "the gutters on the sides are still huge". A grouped Form insets its cards 20 pt
            // inside the drawer's own 8 pt, and `contentMargins` does not move them (measured on macOS 26.5). The
            // drawer widens a Form pane by that inset, so its cards line up with the tab bar's edges (lane S
            // DESIGN.md §1), and moves the overlay scroller back inside the visible pane.
            .modifier(NotchGroupedFormGutter(isGroupedForm: tab.notchUsesGroupedForm))
            .environment(\.settingsRowWrapsFully, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .modifier(
                SettingsVocabularyRevisionObserver(
                    revision: vocabularyRevision(),
                    onRefresh: { loadDictionaryPreview() }
                )
            )
            .task(id: tab) {
                guard tab == .dictionary else { return }
                onRequestVocabularySnapshot()
                if !hasInitialDictionaryPreview { loadDictionaryPreview() }
            }
    }

    private var speechPane: some View {
        SpeechSettingsView(controls: speechControls(), connected: speechConnected(),
                           busy: speechBusyReason() != nil, busyReason: speechBusyReason(), pending: speechPending(), notice: speechNotice(),
                           onChange: onChangeSpeech, onSelectEngine: onSelectSpeechEngine, onPreview: onPreviewSpeech,
                           cloneEngine: cloneEngineControl)
            .onAppear { onRefreshModelsStatus() }
    }

    private var windowBody: some View {
        SettingsNavigationShell(
            selection: $selectedTab, footer: footerPresentation(),
            installedVersion: installedVersion, versionStatus: versionStatus
        ) {
            switch selectedTab {
            case .dictionary:
                dictionaryTab
            case .history:
                settingsPage(
                    title: "History",
                    subtitle: "Your recordings and conversations"
                ) { historyTab }
            case .speech:
                settingsPage(title: "Speech") { speechPane }
            case .transcription:
                settingsPage(title: "Transcription") { transcriptionTab }
            case .general:
                settingsPage(title: "General") { generalTab }
            }
        }
        .frame(minWidth: 780, maxWidth: .infinity, minHeight: 620, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .modifier(
            SettingsVocabularyRevisionObserver(
                revision: vocabularyRevision(),
                onRefresh: { loadDictionaryPreview() }
            )
        )
        .onChange(of: tabRequest) { _, request in
            if let request { selectedTab = request.tab }
            if request?.tab == .history, let recording = request?.historyRecordingID {
                selectedHistoryScope = .recording
                historyMemory.request(recording)
                historyMemory.applyPage(historyDayGroups.flatMap(\.entries).map(\.id))
            }
            if request?.tab == .history, let destination = request?.historyDestination {
                selectedHistoryScope = destination.scope
                switch destination.scope {
                case .recording:
                    historyMemory.request(destination.entryID)
                    historyMemory.applyPage(historyDayGroups.flatMap(\.entries).map(\.id))
                case .ask:
                    askHistorySearch = ""
                    selectedAskID = destination.entryID
                case .speech: selectedSpeechID = destination.entryID
                }
            }
        }
        // A view built on a requested tab sets it in init, where no onChange fires; report it here too.
        .onAppear { onSelectedTabChange(selectedTab) }
        // Once per Settings open; the checker retains its six-hour cache across windows.
        .task {
            guard let versionCheck, versionStatus == nil else { return }
            versionStatus = .checking
            let status = await versionCheck.status(installed: installedVersion.version)
            versionStatus = status
            onVersionStatusChange(status)
        }
        .task(id: selectedTab) {
            guard selectedTab == .dictionary else { return }
            // UXP-1: the bundled rows come only from the daemon's reply; ask again if they never arrived.
            onRequestVocabularySnapshot()
            if !hasInitialDictionaryPreview { loadDictionaryPreview() }
        }
        .onChange(of: selectedTab) { _, tab in
            onSelectedTabChange(tab)
            if tab == .history {
                switch selectedHistoryScope {
                case .recording:
                    // QA-06: the reload keeps the remembered row; it no longer jumps to the newest.
                    if !isHistoryLoading {
                        requestHistoryReload()
                    }
                case .speech:
                    break // The mounted Speech view reloads on appearance.
                case .ask:
                    if !isAskHistoryLoading {
                        requestAskHistoryReload()
                    }
                }
            } else {
                historyPlayback.stop()
            }
        }
        .onDisappear {
            cancelHistoryLoads()
            historyPlayback.stop()
        }
        .onChange(of: isRecordingActive() || isTranscribingActive()) { _, active in
            if active { historyPlayback.stop() }
        }
    }

    private func settingsPage(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 19)
            .padding(.bottom, 14)

            Divider()
            content()
        }
    }

    // MARK: - General Tab

    /// The General pane alone, for the V12 row-width snapshots at 720 and 390 pt (the window has a 780 pt minimum).
    var generalPaneForSnapshots: some View {
        settingsPage(title: "General") { generalTab }
    }

    private var generalTab: some View {
        ScrollViewReader { proxy in
            generalForm
                .onAppear { scrollToRequestedFocus(proxy, animated: false) }
                .onChange(of: tabRequest) { _, _ in scrollToRequestedFocus(proxy, animated: true) }
        }
    }

    /// "Change…" from the menu or popover lands here with the Microphone priority list in view (D2).
    private func scrollToRequestedFocus(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let focus = tabRequest?.focus, tabRequest?.tab == .general else { return }
        DispatchQueue.main.async {
            if focus == .permissions, generalSetup.firstBroken != nil { return arriveAtSetup(proxy) }
            if animated {
                withAnimation { proxy.scrollTo(focus, anchor: .top) }
            } else {
                proxy.scrollTo(focus, anchor: .top)
            }
        }
    }

    private var generalSetup: SettingsGeneralSetup {
        // Reading the tick re-reads the providers once the microphone prompt is answered.
        let _ = permissionsRefreshTick
        return SettingsGeneralSetup(
            permissions: permissionRowModels,
            hotkeyListenerActive: hotkeyEnabled,
            f5CheckedAt: shortcutCheckFeedback?.message == SettingsShortcutCheck.readyMessage
                ? shortcutCheckFeedback?.checkedAt : nil,
            voice: speakingVoiceStatus()
        )
    }

    private var generalForm: some View {
        Form {
            setupSection
            microphonePrioritySection
            dictationSection
            shortcutsSection
            voiceBarSection

            SettingsDisclosureRow("Advanced", isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRow(title: SettingsGeneralCopy.relayTitle, description: relayHelperDescription) {
                        Button(isHotkeyRemapActive() ? "Reinstall" : "Set up") {
                            runRelaySetup()
                        }
                        .disabled(relaySetupRunning)
                    }
                    .help(VoiceBarHotkeyContract.remapExplanation)
                    // C13: the last Set up / Reinstall sits right under its button, with a check or a warning.
                    if let feedback = relaySetupFeedback {
                        let action = feedback.action
                        if let result = feedback.result {
                            Label {
                                Text(SettingsRelaySetupFeedback.line(for: result, action: action))
                                    .foregroundStyle(result.succeeded ? Color.primary : Color.red)
                            } icon: {
                                Image(systemName: result.succeeded ? "checkmark.circle.fill"
                                    : "exclamationmark.triangle.fill")
                                    .foregroundStyle(result.succeeded ? Color.green : Color.red)
                            }
                            .font(.callout)
                            SettingsCopyButton(text: result.failureCopyText, label: "F5 setup error")
                        } else {
                            Label {
                                Text(SettingsRelaySetupFeedback.running(action))
                                    .foregroundStyle(.secondary)
                            } icon: {
                                ProgressView().controlSize(.small)
                            }
                            .font(.callout)
                        }
                    }
                    if isHotkeyRemapActive() {
                        Text(VoiceBarHotkeyContract.remapPlainSummary)
                            .font(.caption).foregroundStyle(SettingsPanePalette.helper)
                    }
                    Divider()
                    // S1: the version lives once, in the sidebar footer. This row only copies the diagnostic summary.
                    SettingsRow(title: "Diagnostic summary", description: SettingsGeneralCopy.diagnosticDescription) {
                        SettingsCopyButton(text: SettingsDiagnosticSummary.build(models: modelsStatus()),
                                           label: "build and diagnostic summary")
                    }
                }
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        // A success line has nothing left to say once health is back; a later break starts clean.
        .onChange(of: generalSetup.isHealthy) { _, healthy in
            if healthy { hotkeyListenerRestartLine = nil }
        }
        .onAppear(perform: refreshMicrophoneSnapshot)
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refreshMicrophoneSnapshot()
        }
    }

    private var relayHelperDescription: String {
        SettingsGeneralCopy.relayDescription(installed: isHotkeyRemapActive(), listenerActive: hotkeyEnabled)
    }

    // MARK: - General setup (R2)

    /// Permission health (Etan, 2026-11-07): nothing at all when every permission is on and F5 works, even right after
    /// the restart that fixed it; otherwise only the broken steps, each with its fix, and the last restart's line.
    @ViewBuilder
    private var setupSection: some View {
        let setup = generalSetup
        if setup.showsSection {
            Section {
                ForEach(setup.steps, id: \.id) { step in
                    setupStepRow(step)
                }
                if let hotkeyListenerRestartLine = setup.visibleRestartLine(hotkeyListenerRestartLine) {
                    HStack(alignment: .top) {
                        HotkeyListenerRestartLineView(line: hotkeyListenerRestartLine)
                        if !hotkeyListenerRestartLine.succeeded {
                            SettingsCopyButton(text: hotkeyListenerRestartLine.text, label: "F5 listener error")
                        }
                    }
                }
            } header: {
                Text(setup.header ?? "Setup")
                    .id(SettingsFocus.permissions)
            }
        }
    }

    private func setupStepRow(_ step: SettingsSetupStep) -> some View {
        SettingsRow(title: step.title, description: step.description, lead: { SettingsSetupMark(kind: step.markKind) }) {
            if let fix = step.fix {
                Button(fix.title) { perform(fix) }
                    .buttonStyle(.bordered)
                    .disabled(fix == .checkF5 && shortcutCheckRunning)
                    .focused($focusedSetupFix, equals: step.id)
                    .accessibilityLabel("\(fix.title): \(step.title)")
            }
        }
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SettingsArrivalHighlight.color.opacity(setupHighlight.step == step.id ? 0.35 : 0))
                .allowsHitTesting(false)
        )
        .id(step.id)
    }

    private func perform(_ fix: SettingsSetupFix) {
        switch fix {
        case let .permission(action):
            SettingsPermissionActions.perform(
                action,
                openURL: onOpenPermissionURL,
                requestMicrophone: onRequestMicrophone,
                refresh: { permissionsRefreshTick &+= 1 }
            )
        case .checkF5:
            shortcutCheckRunning = true
            onCheckShortcut { result in
                shortcutCheckFeedback = (result, Date())
                shortcutCheckRunning = false
            }
        case .restartF5Listener:
            hotkeyListenerRestartLine = HotkeyListenerRestartLine(outcome: onRestartHotkeyListener())
        case .manageVoice, .startVoiceEngine:
            selectedTab = .speech
        }
    }

    /// Arriving at Setup (the notch's orange dot) scrolls to the first broken step, flashes it amber for 1.6 s
    /// (not under Reduce Motion) and moves focus to its fix.
    private func arriveAtSetup(_ proxy: ScrollViewProxy) {
        guard let step = generalSetup.firstBroken else { return }
        proxy.scrollTo(step, anchor: .center)
        focusedSetupFix = step
        setupHighlight.arrive(at: step, reduceMotion: reduceMotion)
        guard setupHighlight.step == step else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: SettingsArrivalHighlight.duration)) { setupHighlight.expire(step) }
        }
    }

    // MARK: - General dictation and VoiceBar

    private var dictationSection: some View {
        Section("Dictation") {
            SettingsRow(title: SettingsGeneralCopy.dictationKeyTitle,
                        description: SettingsGeneralCopy.dictationKeyDescription) {
                // The key itself; how macOS remaps it lives under Advanced › F5 key helper.
                let key = "F5"
                HStack(spacing: 8) {
                    Text(key)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(.tertiary))
                        .accessibilityLabel("Dictation key: \(key)")
                    // The F5 check moved here from the healthy F5 setup row, which permission health no longer shows.
                    Button(SettingsSetupFix.checkF5.title) { perform(.checkF5) }
                        .buttonStyle(.bordered)
                        .disabled(shortcutCheckRunning)
                        .accessibilityLabel("Check shortcut")
                }
            }
            if let shortcutCheckFeedback {
                HStack(alignment: .top) {
                    SettingsShortcutCheckLine(message: shortcutCheckFeedback.message,
                                              checkedAt: shortcutCheckFeedback.checkedAt)
                    SettingsCopyButton(text: shortcutCheckFeedback.message, label: "shortcut check result")
                }
            }
            SettingsRow(title: SettingsGeneralCopy.mouseTitle, description: SettingsGeneralCopy.mouseDescription) {
                if let mouseSideButtons {
                    Toggle("Mouse side buttons", isOn: Binding(get: mouseSideButtons.isOn, set: mouseSideButtons.set))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }

    /// Etan (QA 2026-11-11, shot 3: "still very jumbled"): the gestures were a bare "Gestures" line inside Advanced,
    /// labels left and grey descriptions right-aligned and wrapping under them, with Read Clipboard alone below.
    /// They are now their own section of ordinary rows: the key as the title, what it does as the description, and
    /// Read Clipboard as a row whose button sits in the trailing column.
    private var shortcutsSection: some View {
        Section(SettingsGeneralCopy.shortcutsHeader) {
            SettingsRow(title: SettingsGeneralCopy.singleTapTitle,
                        description: VoiceBarHotkeyContract.singleTapDescription) { EmptyView() }
            SettingsRow(title: VoiceBarHotkeyContract.repasteShortcutLabel,
                        description: VoiceBarHotkeyContract.repasteDescription) { EmptyView() }
            SettingsRow(title: VoiceBarHotkeyContract.speakSelectionShortcutLabel,
                        description: VoiceBarHotkeyContract.speakSelectionDescription) { EmptyView() }
            SettingsRow(title: SettingsGeneralCopy.readClipboardTitle,
                        description: VoiceBarHotkeyContract.readClipboardDescription) {
                Button(VoiceBarHotkeyContract.readClipboardActionLabel) { onReadClipboard?() }
                    .disabled(onReadClipboard == nil)
            }
        }
    }

    private var voiceBarSection: some View {
        Section("VoiceBar") {
            if let openAtLogin {
                SettingsRow(title: SettingsGeneralCopy.openAtLoginTitle) {
                    Toggle("Open at login", isOn: Binding(get: openAtLogin.isOn, set: openAtLogin.set))
                        .labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsRow(title: SettingsGeneralCopy.hideTitle,
                        description: localVoiceBarHidden
                            ? SettingsVisibility.hiddenStatus(until: voiceBarHiddenUntil()) + ". VoiceBar keeps working."
                            : hideVoiceBarDisabledReason() ?? SettingsGeneralCopy.hideDescription) {
                if localVoiceBarHidden {
                    Button("Show VoiceBar") {
                        onShowVoiceBar()
                        localVoiceBarHidden = isVoiceBarHidden()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Hide for 1 hour") {
                        onHideVoiceBar()
                        localVoiceBarHidden = isVoiceBarHidden()
                    }
                    .disabled(hideVoiceBarDisabledReason() != nil)
                    .help(hideVoiceBarDisabledReason() ?? "Hide VoiceBar for 1 hour")
                }
            }
        }
        .onAppear {
            localVoiceBarHidden = isVoiceBarHidden()
        }
    }

    // MARK: - General microphone priority

    private var microphoneEditReason: String? {
        microphonePriorityDisabledReason() ?? (isRecordingActive() ? "Finish recording to change microphones" : nil)
    }

    private var microphonePrioritySection: some View {
        Section {
            if let visibleFirst = microphoneSnapshot.visibleFirstUIDs {
                SettingsRow(title: "Next dictation: \(microphoneSnapshot.nextVisibleDeviceName ?? "Unavailable")",
                            description: "A hidden system or virtual device would be used next.") {
                    Button("Use visible microphones first") {
                        guard microphoneEditReason == nil else { return }
                        onReorderPriority(visibleFirst)
                        refreshMicrophoneSnapshot()
                    }
                    .disabled(microphoneEditReason != nil)
                    .background(PillControlTooltip(text: microphoneEditReason ?? "This puts your microphones ahead of it."))
                    .accessibilityHint(microphoneEditReason ?? "This puts your microphones ahead of it.")
                }
            }

            if microphoneSnapshot.visibleRows.isEmpty {
                Text("No known input devices")
                    .foregroundStyle(.secondary)
            }
            let visibleRows = microphoneSnapshot.visibleRows
            ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, row in
                microphonePriorityRow(row, at: index, visibleCount: visibleRows.count)
            }
            Label(SettingsGeneralCopy.microphoneNote, systemImage: "info.circle")
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPanePalette.helper)
        } header: {
            Text("Microphone priority")
                .id(SettingsFocus.microphonePriority)
        }
    }

    /// Etan's 2.2.24 review #5: one click makes a microphone the default, and rows drag to reorder. The
    /// arrows are gone; VoiceOver keeps Make default / Move up / Move down as named actions.
    @ViewBuilder
    private func microphonePriorityRow(_ row: MicrophonePriorityRow, at index: Int, visibleCount: Int) -> some View {
        let isUsed = SettingsMicrophoneRowPresentation.isUsedForDictation(row, snapshot: microphoneSnapshot)
        let isHovered = hoveredMicrophoneIndex == index || settingsHoverPreview.microphoneRow == index
        // Etan (QA 2026-11-11, shots 1-2): status and the "Used for dictation" pill share the second line, and Make
        // default is the row's only trailing control. Nothing appears under the row and hovering moves nothing.
        let content = SettingsRow(title: row.label, description: SettingsMicrophoneRowPresentation.status(row),
                                  badge: isUsed ? SettingsMicrophoneRowPresentation.usedBadge : nil, lead: {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(row.canPrioritize ? 1 : 0)
                .accessibilityHidden(true)
        }) {
            // Review R1 #736: the pill and Make default are independent. The mic in use can still sit below a
            // disconnected one, and promoting it keeps it first when that one reconnects.
            if SettingsMicrophoneRowPresentation.offersMakeDefault(row, at: index) {
                // Hover reveals it in space it always holds; VoiceOver and the keyboard keep the named action below.
                Button("Make default") {
                    makeMicrophoneDefault(at: index)
                }
                .controlSize(.small)
                .disabled(microphoneEditReason != nil)
                .opacity(isHovered ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovered)
            }
        }
        .opacity(row.isConnected ? 1 : 0.55)
        .onHover { hovering in
            if hovering { hoveredMicrophoneIndex = index } else if hoveredMicrophoneIndex == index { hoveredMicrophoneIndex = nil }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .background(PillControlTooltip(text: microphoneEditReason))
        .accessibilityHint(microphoneEditReason ?? "Drag to reorder microphones")
        .accessibilityActions {
            if microphoneEditReason == nil {
                if SettingsMicrophoneRowPresentation.offersMakeDefault(row, at: index) {
                    Button("Make default") { makeMicrophoneDefault(at: index) }
                }
                if microphoneSnapshot.reorderedVisibleUIDs(moving: index, by: -1) != nil {
                    Button("Move up") { moveMicrophone(at: index, by: -1) }
                }
                if microphoneSnapshot.reorderedVisibleUIDs(moving: index, by: 1) != nil {
                    Button("Move down") { moveMicrophone(at: index, by: 1) }
                }
            }
        }
        if let uid = row.uid, row.canPrioritize, microphoneEditReason == nil {
            // C12: while a drag hovers this row, an insertion line marks where the mic will land, and the row
            // being dragged dims. The drop itself still reads the dragged UID from the payload.
            let edge = microphoneDrag.targetIndex == index
                ? microphoneSnapshot.dropEdge(dragging: microphoneDrag.sourceUID, onto: index) : nil
            content
                .opacity(microphoneDrag.targetIndex != nil && microphoneDrag.sourceUID == uid ? 0.45 : 1)
                .overlay(alignment: edge == .bottom ? .bottom : .top) {
                    if edge != nil {
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(height: 3)
                            .offset(y: edge == .bottom ? Self.dropLineOffset : -Self.dropLineOffset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .onDrag {
                    microphoneDrag = .started(dragging: uid, pressedAt: lastMousePressUptime())
                    return NSItemProvider(object: uid as NSString)
                } preview: {
                    content // the row lifts, as with .draggable
                }
                .dropDestination(for: String.self) { uids, _ in
                    microphoneDrag = MicrophoneDragState()
                    return dropMicrophone(uids.first, onto: index)
                } isTargeted: { targeted in
                    if targeted {
                        microphoneDrag.hover(index, pressedAt: lastMousePressUptime())
                    } else {
                        microphoneDrag.leave(index)
                    }
                }
        } else {
            content
        }
    }

    /// Half the gap between two priority rows' content, so the line sits on the divider between them.
    private static let dropLineOffset: CGFloat = 11.5

    private func makeMicrophoneDefault(at index: Int) {
        guard microphoneEditReason == nil, let uids = microphoneSnapshot.makingDefaultUIDs(at: index) else { return }
        onReorderPriority(uids)
        refreshMicrophoneSnapshot()
    }

    /// Dropping onto a row lands the dragged mic in that row's place: below it when dragged down, above it
    /// when dragged up (SwiftUI onMove indices), exactly where the insertion line was drawn.
    private func dropMicrophone(_ uid: String?, onto index: Int) -> Bool {
        guard microphoneEditReason == nil, let uid, let uids = microphoneSnapshot.droppingVisibleUIDs(uid, onto: index) else { return false }
        onReorderPriority(uids)
        refreshMicrophoneSnapshot()
        return true
    }

    private func refreshMicrophoneSnapshot() {
        let latest = prioritySnapshot()
        if latest != microphoneSnapshot {
            microphoneSnapshot = latest
        }
    }

    private func moveMicrophone(at index: Int, by offset: Int) {
        guard microphoneEditReason == nil, let uids = microphoneSnapshot.reorderedVisibleUIDs(moving: index, by: offset) else { return }
        onReorderPriority(uids)
        refreshMicrophoneSnapshot()
    }

    private var transcriptionTab: some View {
        VStack(spacing: 0) {
            ModelsSettingsView(
                state: modelsStatus(),
                notice: performanceEffortNotice(),
                residencyNotice: residencyNotice(),
                onSelectResidency: onSelectResidency,
                degradation: polishDegradation(),
                onDismissDegradation: onDismissPolishDegradation,
                processingPending: processingPending(),
                processingNotice: processingNotice(),
                onToggleProcessing: onToggleProcessing,
                recognizerState: recognizerStatus(),
                onSelectRecognizer: onSelectRecognizer, onManageRecognizer: onManageRecognizer,
                onSetUnloadWhenIdle: onSetUnloadWhenIdle,
                language: transcriptionLanguage,
                lastDictationNote: lastDictationNote()
            )
            VStack(alignment: .leading, spacing: 4) {
                if let failure = SettingsCopyPayload.nonempty(residencyNotice()) {
                    HStack { Text("Recognizer error"); SettingsCopyButton(text: failure, label: "recognizer error") }
                }
                if modelsStatus().availability == .available,
                   modelsStatus().polishControls != nil,
                   let failure = SettingsCopyPayload.nonempty(processingNotice()) {
                    HStack { Text("Processing error"); SettingsCopyButton(text: failure, label: "processing error") }
                }
                if let degradation = polishDegradation() {
                    HStack {
                        Text("Punctuation warning")
                        SettingsCopyButton(text: degradation.reason + "\n" + degradation.hint, label: "punctuation warning")
                    }
                }
            }.font(.caption).padding(.horizontal).padding(.bottom, 8)
        }
        .onAppear {
            onRefreshModelsStatus()
        }
    }

    // MARK: - History Tab

    private var historyNoticeKind: SettingsHistoryNotice.Kind? {
        SettingsHistoryNotice.Kind(isVoiceBusy: historyPlayback.isVoiceBusy, failureMessage: historyPlayback.failureMessage)
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyScopePicker
            SettingsHistoryNoticeSlot(kind: historyNoticeKind)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)

            // AIDEV-NOTE: lane E (QA 2.2.25 C10). A `switch` here tore down and rebuilt the whole list on every
            // Dictations ↔ Ask click; on the 11k archive that rebuild was most of the switch's main-thread time.
            // Each scope mounts the first time it is shown and then stays; the hidden one is fully inert (not
            // drawn, not hit-testable, not focusable, hidden from VoiceOver).
            ZStack(alignment: .topLeading) {
                if mountedHistoryScopes.contains(.recording) || selectedHistoryScope == .recording {
                    recordingHistoryScope
                        .historyScopeVisibility(selectedHistoryScope == .recording)
                }
                if mountedHistoryScopes.contains(.speech) || selectedHistoryScope == .speech {
                    speechHistoryScope
                        .historyScopeVisibility(selectedHistoryScope == .speech)
                }
                if mountedHistoryScopes.contains(.ask) || selectedHistoryScope == .ask {
                    askHistoryScope
                        .historyScopeVisibility(selectedHistoryScope == .ask)
                }
            }
            // The glass pill owns the spring; retained scope content swaps without an inherited fade.
            .transaction { $0.animation = nil }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: historyNoticeKind)
        // AIDEV-NOTE: A scope not yet mounted in this History visit is out of the view hierarchy, so its
        // `.onReceive(voiceBarHistoryArchiveDidChange)` never fired — it reloads when first shown. Once mounted it
        // stays mounted (hidden) and keeps itself current, so switching back to it does not reload (lane E).
        // Leaving the History tab unmounts both, so the set resets in `.onDisappear`.
        // H1-c: a new query starts from the first page again; typing is debounced by the load itself.
        .onChange(of: SettingsHistorySearch(historySearch)) { _, _ in
            historyLoadedEntryLimit = Self.historyPageSize
            requestHistoryReload(debounce: true, scrollToLatest: false)
        }
        .onChange(of: SettingsHistorySearch(askHistorySearch)) { _, _ in
            askHistoryLoadedEntryLimit = Self.historyPageSize
            requestAskHistoryReload(debounce: true, scrollToLatest: false)
        }
        .onAppear { mountedHistoryScopes.insert(selectedHistoryScope) }
        .onChange(of: selectedHistoryScope) { _, scope in
            historyPlayback.stop()
            // A scope that stayed mounted kept its own `.onReceive(voiceBarHistoryArchiveDidChange)` and search
            // reloads while hidden, so its list is current: showing it again needs no reload (lane E). A scope
            // shown for the first time since History appeared loads as before.
            guard mountedHistoryScopes.insert(scope).inserted else { return }
            switch scope {
            case .recording:
                requestHistoryReload()
            case .speech:
                break
            case .ask:
                requestAskHistoryReload()
            }
        }
        .onDisappear {
            cancelHistoryLoads()
            historyPlayback.stop()
            mountedHistoryScopes = []
        }
    }

    // AIDEV-NOTE: Recording is deliberately first (left) and the default scope — the F5 list is
    // unchanged by the Ask tab, and ask exchanges never appear in it.
    private var speechHistoryScope: some View {
        ScrollViewReader { proxy in
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(speechEntries.isEmpty && speechLoading.isLoading ? "Loading…" : "\(speechEntries.count) speech record\(speechEntries.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { selectedSpeechID = nil; speechReload.refresh() }
            }.padding(.horizontal, 18).padding(.vertical, 10)
            Divider()
            if speechEntries.isEmpty, speechLoading.isLoading {
                VStack(spacing: 8) {
                    if speechLoading.showSpinner {
                        ProgressView().controlSize(.small).accessibilityLabel("Loading speech history")
                        Text("Loading speech history…").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: speechReload.taskID) {
                    speechLoading.showSpinner = false
                    try? await Task.sleep(for: .milliseconds(200))
                    guard !Task.isCancelled else { return }
                    speechLoading.showSpinner = true
                }
            } else if speechEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("No speech yet").font(.headline)
                    Text("Spoken outputs will appear here.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(speechEntries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.createdAt, style: .relative)
                                    Text(entry.voice)
                                    Spacer()
                                    Text(entry.statusLabel).padding(.horizontal, 8).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                }.font(.caption).foregroundStyle(.secondary)
                                historyMediaPartRow(entry.mediaPart)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(10)
                                    .background(Color(nsColor: .controlBackgroundColor))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                if entry.audioPath == nil || entry.missingAudioCount > 0 {
                                    Text(entry.audioPath == nil ? "Audio unavailable" : "Some audio unavailable").font(.caption).foregroundStyle(.secondary)
                                }
                                Button(selectedSpeechID == entry.id ? "Hide details" : "Details") {
                                    selectedSpeechID = selectedSpeechID == entry.id ? nil : entry.id
                                }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                                if selectedSpeechID == entry.id {
                                    HStack(alignment: .top, spacing: 16) {
                                        if entry.textsDiffer {
                                            speechTextDetail("Requested text", text: entry.originalText)
                                        }
                                        speechTextDetail("Generated speech text", text: entry.spokenText)
                                    }
                                    if let sentence = entry.reasonSentence {
                                        Text(sentence).font(.caption).foregroundStyle(.secondary)
                                            .help(entry.reason ?? "")
                                    }
                                }
                            }
                            .id(entry.id)
                            .accessibilityIdentifier("history-speech-\(entry.id)")
                            .accessibilityAddTraits(entry.id == selectedSpeechID ? .isSelected : [])
                        }
                        if speechEntries.count >= speechReload.limit {
                            Button("Load older") { speechReload.loadOlder() }
                        }
                    }.padding(18)
                }
            }
        }
        .onChange(of: selectedSpeechID) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
        .onChange(of: speechEntries) { _, _ in
            if let selectedSpeechID { proxy.scrollTo(selectedSpeechID, anchor: .top) }
        }
        .onAppear { if let selectedSpeechID { proxy.scrollTo(selectedSpeechID, anchor: .top) } }
        .task(id: speechReload.taskID) {
            let invocation = speechLoading.begin()
            defer { speechLoading.finish(invocation) }
            let limit = speechReload.limit
            let root = speechHistoryRoot
            let debounce = speechReload.takeDebounce()
            await SettingsSpeechHistoryReload.reload(debounce: debounce, load: {
                SettingsSpeechHistoryArchive.load(from: root, limit: limit)
            }, apply: { speechEntries = $0 })
        }
        .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { notification in
            guard !(notification.object is SettingsHistoryArchiveChange) else { return }
            speechReload.archiveChanged()
        }
        }
    }

    private func speechTextDetail(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text.isEmpty ? "No text stored" : text).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var historyScopePicker: some View {
        SettingsHistoryScopePicker(selection: $selectedHistoryScope)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityLabel("History scope")
    }

    private var recordingHistoryScope: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                historyToolbar(proxy: proxy)
                Divider()

                if historyDayGroups.isEmpty, isHistoryLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(SettingsHistorySearch(historySearch).isActive ? "Searching…" : "Loading history…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if historyDayGroups.isEmpty, SettingsHistorySearch(historySearch).isActive {
                    historyNoMatches(SettingsHistorySearch(historySearch).query)
                } else if historyDayGroups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(SettingsHistoryRecordingCopy.emptyTitle)
                            .font(.headline)
                        Text(SettingsHistoryRecordingCopy.emptyHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        SettingsHistoryWorkspace {
                            ScrollView(.vertical) {
                                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                                    Color.clear.frame(height: 0).id(latestHistoryAnchorID)
                                    ForEach(historyDayGroups) { group in
                                        Section {
                                            ForEach(group.entries) { entry in
                                                Button { historyMemory.select(entry.id) } label: {
                                                    recordingHistoryListRow(entry)
                                                }.buttonStyle(.plain)
                                            }
                                        } header: { historyDayHeader(group.dayTitle(), coversAbove: 0) }
                                    }
                                    if historyHasMore {
                                        Button(SettingsHistoryRecordingCopy.loadMoreTitle(isLoading: isHistoryLoading)) { loadOlderHistory() }
                                            .disabled(isHistoryLoading)
                                            .controlSize(.small)
                                            .frame(maxWidth: .infinity)
                                            .padding(.top, 8)
                                    }
                                }.padding([.horizontal, .bottom], 12)
                                .background(SettingsHistoryScrollKeeper(memory: historyScroll, key: .list))
                            }
                            // V27: the top inset sits outside the scroll view, so a pinned day header needs no
                            // cover above it, and an unpinned one never paints over the previous day's last row.
                            .padding(.top, 12)
                            .clipped()
                        } detail: {
                            if let entry = selectedHistoryEntry {
                                SettingsHistoryAttemptDetailPane(entry: entry, load: historyDiagnostics,
                                    loadAttempts: historyAttempts, runs: historyRunLog().runs(for: entry.audioPath.path),
                                    omittedCount: historyRunLog().omittedCount,
                                    detailsExpanded: historyMemory.detailsExpanded(for: entry.id),
                                    scrollMemory: historyScroll,
                                    onDetailsExpandedChange: { historyMemory.rememberDetailsExpanded($0, for: entry.id) }) {
                                        EmptyView() // QA-16: the list highlight already says which row is shown.
                                } content: { displayedEntry in
                                    recordingHistoryDetail(displayedEntry)
                                } actions: { displayedEntry in
                                    recordingHistoryActions(displayedEntry)
                                }
                                .id(entry.id)
                            } else {
                                Text(SettingsHistoryRecordingCopy.noSelection)
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        Divider()
                        HStack {
                            Text(SettingsHistorySearch(historySearch).isActive
                                ? "\(historyLoadedEntryCount) matches shown"
                                : "\(historyLoadedEntryCount) saved shown").foregroundStyle(.secondary)
                            Spacer()
                        }.font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
                    }

                }
            }
            .onAppear {
                // A preloaded page is unfiltered, so an active query must still search (#165 Macroscope).
                if historyDayGroups.isEmpty || SettingsHistorySearch(historySearch).isActive, !isHistoryLoading {
                    requestHistoryReload(scrollProxy: proxy, animated: false)
                } // Otherwise the list's SettingsHistoryScrollKeeper puts back where it was left (QA-06).
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { notification in
                if let change = notification.object as? SettingsHistoryArchiveChange {
                    historyChangesDuringLoad.receive(change, duringLoad: isHistoryLoading, apply: applyHistoryChange)
                } else {
                    requestHistoryReload(scrollProxy: proxy, debounce: true, scrollToLatest: false)
                }
            }
        }
    }

    private var selectedHistoryEntry: SettingsHistoryEntry? {
        historyDayGroups.lazy.flatMap(\.entries).first { $0.id == selectedHistoryEntryID }
    }

    private func recordingHistoryListRow(_ entry: SettingsHistoryEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayTranscript)
                    .lineLimit(1)
                Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let duration = entry.durationLabel {
                Text(duration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            entry.id == selectedHistoryEntryID
                ? Color.accentColor.opacity(0.13)
                : Color.clear
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        // UI pass #7: one element, one concise label; the children each repeated the transcript.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SettingsHistoryAccessibility.rowLabel(entry))
        .accessibilityAddTraits(entry.id == selectedHistoryEntryID ? .isSelected : [])
    }

    private func recordingHistoryDetail(_ entry: SettingsHistoryEntry) -> some View {
        SettingsHistoryTranscriptDetail(entry: entry, initiallyExpanded: historyDetailsInitiallyExpanded)
    }

    private func recordingHistoryActions(_ entry: SettingsHistoryEntry) -> some View {
        let part = SettingsHistoryRowModel.recording(entry).parts[0]
        let retranscribing = isHistoryRetranscribing(entry.audioPath.path)
        let enablement = SettingsHistoryActionEnablement(
            isRetranscribing: isAnyHistoryRetranscribing(), isRecording: isRecordingActive(),
            isTranscribing: isTranscribingActive(), retranscribingPath: retranscribing ? entry.audioPath.path : nil,
            isVoiceBusy: historyPlayback.isVoiceBusy, archiveAdmission: historyRetranscriptionAvailability())
        return VStack(alignment: .leading, spacing: 6) {
            historyMediaPartStats(part)
            historyMediaPartActions(part, isRetranscribing: retranscribing, enablement: enablement)
            // Etan, 2026-11-05: a Re-transcribe that produced the same words said nothing. Now it says so here.
            if !retranscribing,
               let note = SettingsHistoryDiagnosticsCopy.latestRequestNote(runs: historyRunLog().runs(for: entry.audioPath.path)) {
                Label(note, systemImage: "equal.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("history-retranscribe-unchanged")
            }
            if historyPlayback.playingURL == part.audioPath {
                SettingsPlaybackScrubBar(playback: historyPlayback, url: entry.audioPath, accessibilityNoun: part.accessibilityNoun)
            }
        }
    }

    // MARK: - History Tab (Ask scope)

    private var askHistoryScope: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                askHistoryToolbar()
                Divider()

                if askHistoryDayGroups.isEmpty, isAskHistoryLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(SettingsHistorySearch(askHistorySearch).isActive ? "Searching…" : "Loading ask history…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if askHistoryDayGroups.isEmpty, SettingsHistorySearch(askHistorySearch).isActive {
                    historyNoMatches(SettingsHistorySearch(askHistorySearch).query)
                } else if askHistoryDayGroups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No ask exchanges yet")
                            .font(.headline)
                        Text("Questions VoiceLayer asks will appear here with your answer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: 18,
                            pinnedViews: [.sectionHeaders]
                        ) {
                            ForEach(askHistoryDayGroups) { group in
                                historyDaySection(title: group.dayTitle()) {
                                    ForEach(group.entries) { entry in
                                        historyEntryRow(SettingsHistoryRowModel.ask(entry))
                                            .id(entry.id)
                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(
                                                entry.id == selectedAskID ? Color.accentColor : .clear, lineWidth: 2))
                                            .accessibilityIdentifier("history-ask-\(entry.id)")
                                            .accessibilityAddTraits(entry.id == selectedAskID ? .isSelected : [])
                                    }
                                }
                            }

                            if askHistoryHasMore {
                                Button {
                                    loadOlderAskHistory()
                                } label: {
                                    if isAskHistoryLoading {
                                        HStack(spacing: 6) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Loading older")
                                        }
                                    } else {
                                        Label("Load older", systemImage: "chevron.down")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(isAskHistoryLoading)
                                .frame(maxWidth: .infinity)
                                .help("Load older ask history")
                                .accessibilityLabel("Load older ask history")
                            }
                        }
                        // UI pass #10: the scroll anchor sits behind the stack, not in it, so no stack spacing
                        // follows it; with the old in-stack anchor the first date sat ~50 pt down.
                        .background(alignment: .top) {
                            Color.clear.frame(height: 0).id(latestAskHistoryAnchorID)
                        }
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                        .padding(.top, SettingsHistoryLayout.askListTopInset)
                    }
                }
            }
            .onChange(of: selectedAskID) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
            .onChange(of: askHistoryDayGroups) { _, _ in
                if let selectedAskID { proxy.scrollTo(selectedAskID, anchor: .top) }
            }
            .onAppear {
                if let selectedAskID { proxy.scrollTo(selectedAskID, anchor: .top) }
                if askHistoryDayGroups.isEmpty || SettingsHistorySearch(askHistorySearch).isActive,
                   !isAskHistoryLoading {
                    requestAskHistoryReload(scrollProxy: proxy, animated: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { notification in
                if let change = notification.object as? SettingsHistoryArchiveChange {
                    askChangesDuringLoad.receive(change, duringLoad: isAskHistoryLoading, apply: applyAskHistoryChange)
                } else {
                    requestAskHistoryReload(scrollProxy: proxy, debounce: true, scrollToLatest: false)
                }
            }
        }
    }

    private func askHistoryToolbar(proxy: ScrollViewProxy? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask")
                    .font(.title3.weight(.semibold))
                Text(Self.historyCountLabel(
                    askHistoryLoadedEntryCount,
                    hasMore: askHistoryHasMore,
                    noun: "exchanges",
                    searching: SettingsHistorySearch(askHistorySearch).isActive,
                    loading: isAskHistoryLoading
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            historySearchField("Search questions and answers", text: $askHistorySearch)
            if isAskHistoryLoading {
                ProgressView()
                    .controlSize(.small)
            }
            SettingsIconButton(spec: .refreshAskHistory) {
                requestAskHistoryReload(scrollProxy: proxy)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func historyToolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dictations")
                    .font(.title3.weight(.semibold))
                Text(Self.historyCountLabel(
                    historyLoadedEntryCount,
                    hasMore: historyHasMore,
                    noun: "transcripts",
                    searching: SettingsHistorySearch(historySearch).isActive,
                    loading: isHistoryLoading
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            historySearchField("Search transcripts", text: $historySearch)
            if isHistoryLoading {
                ProgressView()
                    .controlSize(.small)
            }
            SettingsIconButton(spec: .refreshHistory) {
                requestHistoryReload(scrollProxy: proxy)
            }

            SettingsIconButton(spec: .jumpToLatest) {
                scrollToLatest(proxy)
            }
            .disabled(historyDayGroups.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func historySearchField(_ prompt: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
            if !text.wrappedValue.isEmpty {
                // Inside the field: the 24 pt target overhangs its 14 pt glyph instead of growing the field.
                SettingsIconButton(spec: .clearSearch, layoutInset: 5) {
                    text.wrappedValue = ""
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
        .frame(maxWidth: 240)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(prompt)
    }

    private func historyNoMatches(_ query: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No matches for \u{201C}\(query)\u{201D}")
                .font(.headline)
            Text("Search looks through the whole archive, not just the loaded page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "12 transcripts", or while searching "3 matches" / "100+ matches" (more load with Load more), and
    /// "Searching…" while a search is still loading.
    static func historyCountLabel(
        _ count: Int,
        hasMore: Bool,
        noun: String,
        searching: Bool,
        loading: Bool = false
    ) -> String {
        guard searching else { return "\(count) \(noun)" }
        guard !loading else { return "Searching…" }
        let shown = hasMore ? "\(count)+" : "\(count)"
        return "\(shown) \(count == 1 && !hasMore ? "match" : "matches")"
    }

    private func historyDaySection(
        title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        } header: {
            historyDayHeader(title)
        }
    }

    // AIDEV-NOTE: both scope stacks pin this same Section header. Its opaque background keeps
    // Recording's existing behavior and prevents tall Ask cards from scrolling through it.
    /// A pinned day header is opaque so rows scroll under it. `coversAbove` extends that cover over the list's own
    /// top padding while pinned, and must never exceed the stack spacing above the header: past it, an unpinned
    /// header paints over the bottom of the previous day's last row (V27, Etan: "only the last in the list in a
    /// given date… right before the title of the next date"). The Ask list spaces its sections 18 pt apart; the
    /// Dictations list spaces rows 2 pt apart and keeps its top inset outside the scroll view instead.
    private func historyDayHeader(_ title: String, coversAbove: CGFloat = 18) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityHidden(true) // the cover below is the header's one accessibility element
            .background(
                Rectangle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, -18)
                    .padding(.top, -coversAbove)
                    // The header's accessibility element is the cover itself, so its frame is the painted area
                    // including `coversAbove`: UI tests can prove it never reaches over the row above (V27).
                    .accessibilityElement()
                    .accessibilityLabel(title)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier(Self.historyDayHeaderCoverIdentifier)
            )
    }

    static let historyDayHeaderCoverIdentifier = "history.dayHeader.cover"

    private func historyEntryRow(_ row: SettingsHistoryRowModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.timestamp)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(row.parts.enumerated()), id: \.element.role) { index, part in
                    if index > 0 {
                        Divider()
                    }
                    historyMediaPartRow(part)
                }
                if let build = row.buildLabel { Text("Built from \(build)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func historyMediaPartRow(_ part: SettingsHistoryMediaPart) -> some View {
        let isRetranscribing = part.actions.contains(.retranscribe)
            && part.audioPath.map { isHistoryRetranscribing($0.path) } == true
        let enablement = SettingsHistoryActionEnablement(
            isRetranscribing: isAnyHistoryRetranscribing(),
            isRecording: isRecordingActive(),
            isTranscribing: isTranscribingActive(),
            retranscribingPath: isRetranscribing ? part.audioPath?.path : nil,
            isVoiceBusy: historyPlayback.isVoiceBusy, archiveAdmission: historyRetranscriptionAvailability()
        )

        VStack(alignment: .leading, spacing: 6) {
            if let label = part.label, let systemImage = part.systemImage {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(part.displayText)
                .font(.body)
                .foregroundStyle(part.isPlaceholder ? .secondary : .primary)
                .textSelection(.enabled)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            historyMediaPartStats(part)

            historyMediaPartActions(
                part,
                isRetranscribing: isRetranscribing,
                enablement: enablement
            )

            if let audioPath = historyPlayback.playingURL,
               part.audioPath == audioPath || part.playbackQueue.contains(audioPath) {
                SettingsPlaybackScrubBar(
                    playback: historyPlayback,
                    url: audioPath,
                    accessibilityNoun: part.accessibilityNoun
                )
            }
        }
    }

    // AIDEV-NOTE: these remain two separate facts: waveform is mic-on time, while
    // text.viewfinder is the meaningfully shorter slice sent to speech-to-text.
    @ViewBuilder
    private func historyMediaPartStats(_ part: SettingsHistoryMediaPart) -> some View {
        let audioLabel = part.durationLabel
        let heardLabel = part.transcribedDurationLabel
        let spokenLabel = part.spokenDurationLabel
        let processingLabel = part.processingLabel
        let micDisconnectLabel = part.micDisconnectLabel

        if audioLabel != nil || heardLabel != nil || spokenLabel != nil || processingLabel != nil
            || micDisconnectLabel != nil
        {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { historyStatLabels(part) }
                VStack(alignment: .leading, spacing: 4) { historyStatLabels(part) }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    @ViewBuilder
    private func historyStatLabels(_ part: SettingsHistoryMediaPart) -> some View {
        let audioLabel = part.durationLabel
        let heardLabel = part.transcribedDurationLabel
        let spokenLabel = part.spokenDurationLabel
        let processingLabel = part.processingLabel
        let micDisconnectLabel = part.micDisconnectLabel
        if let audioLabel {
            Label(audioLabel, systemImage: "waveform")
                .help(part.role == .speech ? "Retained speech duration; playback time when generated duration is unavailable" : "Audio length: how long the mic was on")
                .accessibilityLabel("Audio length \(audioLabel)")
        }
        if let heardLabel {
            Label(heardLabel, systemImage: "text.viewfinder")
                .help(
                    "Transcribed: the audio VoiceBar transcribed, after cutting the silence at the end"
                )
                .accessibilityLabel("Transcribed length \(heardLabel)")
        }
        if let spokenLabel {
            Label(spokenLabel, systemImage: "waveform.path")
                .help("Spoken: speech time without pauses, estimated in quarter-second steps")
                .accessibilityLabel("Spoken length about \(spokenLabel)")
        }
        if let processingLabel {
            Label(processingLabel, systemImage: "timer")
                .help("Processing: from the end of recording to the finished transcript")
                .accessibilityLabel("Processing time \(processingLabel)")
        }
        if let micDisconnectLabel {
            Label(micDisconnectLabel, systemImage: "mic.slash")
                .foregroundStyle(.orange)
                .help("The microphone signal was lost here; the whole recording is kept, and only the audio before it was transcribed")
                .accessibilityLabel(micDisconnectLabel)
        }
    }

    private func historyMediaPartActions(
        _ part: SettingsHistoryMediaPart,
        isRetranscribing: Bool,
        enablement: SettingsHistoryActionEnablement
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(part.actions.filter { enablement.availability($0, for: part) != .hidden }, id: \.self) { action in
                historyActionButton(
                    action,
                    for: part,
                    isRetranscribing: isRetranscribing,
                    enablement: enablement
                )
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // AIDEV-NOTE: the in-flight Re-transcribe icon turns off the clock (HistorySpinningSymbol), never an implicit
    // animation. It used `.animation(.repeatForever, value: isSpinning)`: that only started on a false→true flip,
    // so an entry already re-transcribing when shown sat still (QA 2.2.25 C8), and once started it animated every
    // later layout move too, so the icon animated from stale positions or disappeared (C7, C9). Fixed 28 pt slot.
    private func historyActionLabel(
        _ title: String,
        systemImage: String,
        isEnabled: Bool,
        isSpinning: Bool = false
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            if isSpinning {
                HistorySpinningSymbol(systemName: systemImage)
            } else {
                Image(systemName: systemImage)
            }
        }
        .labelStyle(.iconOnly)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        // The system dims a disabled borderless button too little to read as blocked (QA 2.2.25 C6, 04:55). The
        // spinning icon is the entry's status, so it keeps full strength.
        .opacity(isEnabled || isSpinning ? 1 : SettingsHistoryActionStyle.disabledOpacity)
    }

    @ViewBuilder
    private func historyActionButton(
        _ action: SettingsHistoryAction,
        for part: SettingsHistoryMediaPart,
        isRetranscribing: Bool,
        enablement: SettingsHistoryActionEnablement
    ) -> some View {
        let disabled = !enablement.isEnabled(action, for: part)
        let reason: String? = if case let .unavailable(why) = enablement.availability(action, for: part) {
            why
        } else {
            nil
        }
        let isPlaying = part.audioPath.map(historyPlayback.isPlaying) ?? false

        switch action {
        case .play:
            Button {
                guard let audioPath = part.audioPath else { return }
                guard !isRecordingActive(), !isTranscribingActive() else {
                    historyPlayback.stop()
                    return
                }
                if part.playbackQueue.isEmpty {
                    historyPlayback.toggle(audioPath)
                } else {
                    historyPlayback.toggle(part.playbackQueue)
                }
            } label: {
                historyActionLabel(
                    isPlaying ? "Stop" : "Play",
                    systemImage: isPlaying ? "stop.fill" : "play.fill",
                    isEnabled: !disabled
                )
            }
            .disabled(disabled)
            .help(reason ?? (isPlaying ? "Stop" : "Play"))
            .accessibilityHint(reason ?? "")
            .accessibilityLabel("\(isPlaying ? "Stop" : "Play") \(part.accessibilityNoun)")

        case .copy:
            Button {
                guard let text = part.actionableText else { return }
                onCopyHistoryTranscript(text)
            } label: {
                historyActionLabel("Copy", systemImage: "doc.on.doc", isEnabled: !disabled)
            }
            .disabled(disabled)
            .help(reason ?? "Copy transcript") // QA-03: says which copy this is.
            .accessibilityHint(reason ?? "")
            .accessibilityLabel("Copy transcript")

        case .paste:
            Button {
                guard let text = part.actionableText else { return }
                onPasteHistoryTranscript(text)
            } label: {
                historyActionLabel("Paste", systemImage: VoiceBarActionSymbol.paste, isEnabled: !disabled)
            }
            .disabled(disabled)
            .help(reason ?? "Paste")
            .accessibilityHint(reason ?? "")
            .accessibilityLabel("Paste transcript")

        case .retranscribe:
            Button {
                guard let audioPath = part.audioPath else { return }
                guard historyRetranscriptionAvailability()?.isEnabled != false else { return }
                onRetranscribeHistoryEntry(audioPath.path)
            } label: {
                historyActionLabel(
                    "Re-transcribe",
                    systemImage: "arrow.triangle.2.circlepath",
                    isEnabled: !disabled,
                    isSpinning: isRetranscribing
                )
            }
            .disabled(disabled)
            .help(reason ?? "Re-transcribe")
            .accessibilityHint(reason ?? "")
            .accessibilityLabel(
                isRetranscribing ? "Re-transcribing stored audio" : "Re-transcribe stored audio"
            )

        case .finder:
            Button {
                guard let audioPath = part.audioPath else { return }
                onRevealHistoryFile(audioPath)
            } label: {
                historyActionLabel("Open in Finder", systemImage: "folder", isEnabled: !disabled)
            }
            .disabled(disabled)
            .help(reason ?? "Open in Finder")
            .accessibilityHint(reason ?? "")
            .accessibilityLabel("Open stored audio in Finder")
        }
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // The notch drawer's tab already says Dictionary, and it carries no explanatory prose (0510 N2).
                    if notchEmbeddedTab == nil {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Dictionary").font(.title2.weight(.semibold))
                            Text("Used on every dictation").font(.subheadline).foregroundStyle(SettingsPanePalette.helper)
                        }
                    }
                    Spacer(minLength: 12)
                    Button {
                        termSheet = DictionaryTermEdit()
                    } label: {
                        Label("Add term", systemImage: "plus")
                    }
                    .fixedSize()
                    .disabled(!Self.addTermEnabled(loaded: hasLoadedDictionaryOnce))
                    .help("Add a term to your dictionary")
                }
                searchRow
            }
            // In the drawer the search field and lists start on the tab bar's edge, like the Form cards (lane S).
            .padding(.horizontal, notchEmbeddedTab == nil ? 22 : 0)
            .padding(.top, notchEmbeddedTab == nil ? 19 : 8)
            .padding(.bottom, notchEmbeddedTab == nil ? 14 : 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    let isSearching = !Self.dictionaryQuery(dictionarySearch).isEmpty
                    let personal = dictionaryDisplayIndex.entries(source: "personal", matching: dictionarySearch)
                    let included = dictionaryDisplayIndex.entries(source: "bundled", matching: dictionarySearch)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let query = DictionarySearchPresentation.addSuggestion(
                            search: dictionarySearch, loaded: hasLoadedDictionaryOnce,
                            personalMatches: personal.count, includedMatches: included.count
                        ) {
                            dictionaryNoMatches(query)
                        }
                        let yourTermsTitle = Self.dictionarySectionTitle(
                            "Your terms", count: dictionaryDisplayIndex.personalCount,
                            matches: isSearching ? personal.count : nil,
                            loaded: hasLoadedDictionaryOnce
                        )
                        SettingsDisclosureHeader(yourTermsTitle, isExpanded: $yourTermsExpanded)
                            .help(yourTermsExpanded ? "Collapse your terms" : "Show your terms")
                        if yourTermsExpanded || isSearching {
                            switch Self.dictionaryPlaceholder(
                                loaded: hasLoadedDictionaryOnce, personalIsEmpty: personal.isEmpty,
                                searching: isSearching
                            ) {
                            case .loading:
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…").foregroundStyle(SettingsPanePalette.helper)
                                }
                                .frame(maxWidth: .infinity, minHeight: 170)
                            case .empty:
                                VStack(spacing: 10) {
                                    Image(systemName: "text.book.closed").font(.largeTitle).foregroundStyle(.secondary)
                                    Text("No terms yet").font(.headline)
                                    Text("Add names, products, and other preferred spellings.")
                                        .font(.caption).foregroundStyle(SettingsPanePalette.helper)
                                }
                                .frame(maxWidth: .infinity, minHeight: 170)
                            case nil:
                                EmptyView()
                            }
                            ForEach(personal, id: \.rowID) { row in
                                dictionaryEntryCard(row.entry, rowID: row.rowID)
                                    .id(row.rowID)
                                Divider()
                            }
                        }
                        let includedHeader = Self.includedTermsHeader(
                            index: dictionaryDisplayIndex,
                            matches: isSearching ? included.count : nil,
                            loaded: hasLoadedDictionaryOnce
                        )
                        // Nothing to open while loading, or for a list the daemon reports empty (UXP-1).
                        SettingsDisclosureHeader(
                            includedHeader.title, isExpanded: $includedTermsExpanded,
                            isEnabled: includedHeader.showsChevron, hint: "Built-in terms are read-only"
                        ) {
                            includedTermsHeaderLabel(includedHeader)
                        }
                        .help(includedTermsExpanded ? "Collapse included terms" : "Show included terms")
                        .padding(.top, 18)
                        if includedHeader.showsChevron, !isSearching {
                            includedTermsSummary(expanded: includedTermsExpanded)
                        }
                        if includedTermsExpanded || isSearching {
                            ForEach(included, id: \.rowID) { row in
                                dictionaryEntryCard(row.entry, rowID: row.rowID, isEditable: false)
                                Divider()
                            }
                        }
                    }
                    .padding(18)
                }
                // The list takes key focus like a macOS table: arrows move the selection, Delete/Backspace removes
                // the selected term of your own (with Undo). The search field keeps its own text editing.
                .focusable()
                .focused($focusedEditorField, equals: .list)
                .focusEffectDisabled()
                .onMoveCommand { direction in
                    let offset = direction == .up ? -1 : direction == .down ? 1 : 0
                    guard offset != 0 else { return }
                    selectedTermRowID = DictionaryDeletion.selection(
                        movingFrom: selectedTermRowID, by: offset, in: visibleTermRowIDs
                    )
                    if let rowID = selectedTermRowID { proxy.scrollTo(rowID) }
                }
                .onDeleteCommand { deleteSelectedTerm() }
                .onChange(of: pendingScrollRowID) { _, rowID in
                    guard let rowID else { return }
                    // The saved row lands in the list on the same update; scroll once it has been laid out.
                    DispatchQueue.main.async {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
                            proxy.scrollTo(rowID, anchor: .center)
                        }
                        pendingScrollRowID = nil
                    }
                }
            }
            if let pendingDeletion {
                dictionaryUndoBar(pendingDeletion)
                    .transition(reduceMotion
                        ? AnyTransition.opacity
                        : AnyTransition.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2), value: pendingDeletion)
        .task(id: pendingDeletion?.deadline) {
            guard let deadline = pendingDeletion?.deadline else { return }
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            DictionaryDeletion.commitIfExpired(now: Date(), pending: &pendingDeletion, commit: commitDeletion)
        }
        .modifier(DictionaryTermEditorPresentation(edit: $termSheet, inDrawer: notchEmbeddedTab != nil) { edit in
            DictionaryAddSheetView(edit: edit, existingEntries: localEntries, onSave: { saved in
                saveTermSheet(saved)
            }, onCancel: { termSheet = nil })
        })
        .onChange(of: termSheet) { _, sheet in
            // A save could re-add the very term waiting for its Undo window; send that removal first.
            if sheet != nil { DictionaryDeletion.commitNow(pending: &pendingDeletion, commit: commitDeletion) }
        }
        .onAppear {
            resetDictionaryEditors()
        }
        .onDisappear {
            DictionaryDeletion.commitNow(pending: &pendingDeletion, commit: commitDeletion)
        }
        .onChange(of: hasPendingDictionaryEdit) { _, pending in
            if !pending, dictionaryReloadGate.editEnded() { loadDictionaryPreview() }
        }
        .onChange(of: localEntries) { _, entries in
            let bundled = dictionaryDisplayIndex.sortedEntries.filter { !$0.isPersonal }
            dictionaryDisplayIndex = STTDictionaryDisplayIndex(
                entries: bundled + entries.map { STTDictionaryDisplayEntry(source: "personal", entry: $0) },
                bundledRowsKnown: dictionaryDisplayIndex.bundledRowsKnown
            )
        }
    }

    private func includedTermsHeaderLabel(_ header: IncludedTermsHeader) -> some View {
        HStack {
            Text(header.title)
            if header.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…").font(.caption).foregroundStyle(SettingsPanePalette.helper)
            }
            Spacer()
            Text("built in").font(.caption).foregroundStyle(SettingsPanePalette.helper)
        }
    }

    /// Spec: Included terms (closed) shows a sample of the daemon's own rows as chips, and why they can't be edited.
    private func includedTermsSummary(expanded: Bool) -> some View {
        let sample = DictionarySearchPresentation.includedSample(
            dictionaryDisplayIndex.sortedEntries.filter { !$0.isPersonal }.map(\.entry)
        )
        return VStack(alignment: .leading, spacing: 8) {
            if !expanded, !sample.isEmpty {
                DictionaryChipFlow(spacing: 6) {
                    ForEach(sample, id: \.self) { term in
                        Text(term)
                            .font(.system(size: 11.5))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Included terms include " + sample.joined(separator: ", "))
            }
            Text(DictionarySearchPresentation.includedExplanation)
                .font(.system(size: 11.5))
                .foregroundStyle(SettingsPanePalette.helper)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private func dictionaryNoMatches(_ query: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No terms match \u{201C}\(query)\u{201D}.")
                .font(SettingsRowLabel.titleFont)
                .lineLimit(2)
            Button {
                termSheet = DictionaryTermEdit(correct: query)
            } label: {
                Label(DictionarySearchPresentation.addSuggestionTitle(query), systemImage: "plus")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(DictionarySearchPresentation.addSuggestionTitle(query))
            .accessibilityIdentifier("dictionary-add-search-query")
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 14)
    }

    private func dictionaryUndoBar(_ deletion: DictionaryPendingDeletion) -> some View {
        HStack(spacing: 12) {
            Text(DictionaryDeletion.undoMessage(deletion))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Undo") { undoDeletion() }
                .keyboardShortcut(focusedEditorField == .search ? nil : KeyboardShortcut("z", modifiers: .command))
                .accessibilityHint("Puts the term back")
        }
        .font(.callout)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // The search is a plain TextField: normal macOS editing, Edit menu ⌘V, and P1's paste integration reach it
            // through `focusedEditorField == .search`. No paste path of its own.
            TextField("Search terms and variants", text: $dictionarySearch)
                .dictionaryTextField()
                .focused($focusedEditorField, equals: .search)
                .onExitCommand { dictionarySearch = "" }
                .accessibilityLabel("Search your dictionary")
            // QA-27: the same clear (X) the History search has. It follows the raw field, not the trimmed query:
            // a lone space is not a search, but it is still text the X should clear.
            if dictionarySearch != "" {
                SettingsIconButton(spec: .clearSearch, layoutInset: 5) {
                    dictionarySearch = ""
                    focusedEditorField = .search
                }
                .foregroundStyle(.secondary)
            }
        }
        .dictionaryFieldContainer()
        .contentShape(Rectangle())
        .onTapGesture {
            focusedEditorField = .search
        }
    }

    private func dictionaryEntryCard(
        _ entry: STTDictionaryEntry,
        rowID: String,
        isEditable: Bool = true
    ) -> some View {
        let isSelected = selectedTermRowID == rowID
        return dictionaryEntryHeader(entry, rowID: rowID, isEditable: isEditable)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(
                        flashingTermRowID == rowID ? 0.28 : isSelected ? 0.12 : 0
                    ))
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: flashingTermRowID)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredTermRowID = rowID } else if hoveredTermRowID == rowID { hoveredTermRowID = nil }
            }
            .onTapGesture(count: 2) {
                if isEditable { termSheet = DictionaryTermEdit(original: entry) }
            }
            .onTapGesture {
                selectedTermRowID = rowID
                focusedEditorField = .list
            }
            .accessibilityAddTraits(selectedTermRowID == rowID ? .isSelected : [])
            .accessibilityAction(named: "Edit") {
                if isEditable { termSheet = DictionaryTermEdit(original: entry) }
            }
            .accessibilityAction(named: "Delete") {
                if isEditable { deleteTerm(entry.canonical, rowID: rowID) }
            }
    }

    /// A term's misheard spellings, as the row's description, only when it has some.
    static func variantSummary(_ variants: [String]) -> String {
        "Also heard as " + variants.joined(separator: ", ")
    }

    private func dictionaryEntryHeader(
        _ entry: STTDictionaryEntry,
        rowID: String,
        isEditable: Bool
    ) -> some View {
        let isSelected = selectedTermRowID == rowID
        // Spec: hover or selection shows the row's actions. They keep their width while hidden, so the text never
        // reflows under the pointer; VoiceOver reaches them as row actions instead.
        let showsActions = isSelected || hoveredTermRowID == rowID
        let label = SettingsRowLabel(
            title: entry.canonical,
            description: entry.variants.isEmpty ? nil : Self.variantSummary(entry.variants),
            isSelected: isSelected
        )
        let actions = HStack(spacing: 4) {
            SettingsCopyButton(text: entry.canonical, label: "term \(entry.canonical)")
            if isEditable {
                Button {
                    termSheet = DictionaryTermEdit(original: entry)
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: DictionaryCardLayout.actionTarget, height: DictionaryCardLayout.actionTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Edit term")
                .accessibilityLabel("Edit term \(entry.canonical)")
                deleteDictionaryEntryButton(entry.canonical, rowID: rowID)
            }
        }
        .fixedSize()
        .opacity(showsActions ? 1 : 0)
        .allowsHitTesting(showsActions)
        .accessibilityHidden(!showsActions)
        // Trailing controls keep their natural width; when the text column can't keep its minimum beside them they
        // wrap under the text (V12).
        return SettingsRowLayout {
            label
            actions
        }
        .frame(minHeight: DictionaryCardLayout.headerHeight)
    }

    @ViewBuilder
    private func deleteDictionaryEntryButton(_ canonical: String, rowID: String) -> some View {
        Button {
            deleteTerm(canonical, rowID: rowID)
        } label: {
            Image(systemName: "trash")
                .frame(width: DictionaryCardLayout.actionTarget, height: DictionaryCardLayout.actionTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.red)
        .help("Delete term")
        .accessibilityLabel("Delete term \(canonical)")
    }

    /// The rows arrow keys move through, in display order.
    private var visibleTermRowIDs: [String] {
        let isSearching = !Self.dictionaryQuery(dictionarySearch).isEmpty
        var rows: [String] = []
        if yourTermsExpanded || isSearching {
            rows += dictionaryDisplayIndex.entries(source: "personal", matching: dictionarySearch).map(\.rowID)
        }
        if includedTermsExpanded || isSearching {
            rows += dictionaryDisplayIndex.entries(source: "bundled", matching: dictionarySearch).map(\.rowID)
        }
        return rows
    }

    /// Delete/Backspace: only a selected term of your own; an included row has nothing to delete.
    private func deleteSelectedTerm() {
        guard let rowID = selectedTermRowID,
              let row = dictionaryDisplayIndex.entries(source: "personal", matching: dictionarySearch)
                  .first(where: { $0.rowID == rowID })
        else { return }
        deleteTerm(row.entry.canonical, rowID: rowID)
    }

    private func deleteTerm(_ canonical: String, rowID: String) {
        let rows = dictionaryDisplayIndex.entries(source: "personal", matching: dictionarySearch).map(\.rowID)
        let nextSelection = DictionaryDeletion.selection(afterRemoving: rowID, from: rows)
        guard DictionaryDeletion.begin(
            canonical, localEntries: &localEntries, pending: &pendingDeletion, now: Date(), commit: commitDeletion
        ) != nil else { return }
        if selectedTermRowID == rowID { selectedTermRowID = nextSelection }
        if hoveredTermRowID == rowID { hoveredTermRowID = nil }
        // Keep keyboard focus in the list so the next Delete or ⌘Z lands where the user is.
        if focusedEditorField != .search { focusedEditorField = .list }
    }

    private func undoDeletion() {
        guard let entry = DictionaryDeletion.undo(localEntries: &localEntries, pending: &pendingDeletion, now: Date())
        else { return }
        selectedTermRowID = STTDictionaryDisplayEntry(source: "personal", entry: entry).rowID
        pendingScrollRowID = selectedTermRowID
    }

    /// The removal reaches the daemon only here, when the Undo window has closed.
    private func commitDeletion(_ entry: STTDictionaryEntry) {
        onRemovePromptTerm(entry.canonical)
        dictionaryReloadGate.mutationSent()
    }

    // MARK: - Helpers

    private func requestHistoryReload(
        scrollProxy: ScrollViewProxy? = nil,
        debounce: Bool = false,
        scrollToLatest shouldScrollToLatest: Bool = true,
        animated: Bool = true
    ) {
        let limit = historyLoadedEntryLimit
        loadHistory(
            limit: limit,
            scrollProxy: scrollProxy,
            debounce: debounce,
            scrollToLatest: shouldScrollToLatest,
            animated: animated
        )
    }

    private func loadOlderHistory() {
        let nextLimit = historyLoadedEntryLimit + Self.historyPageSize
        historyLoadedEntryLimit = nextLimit
        loadHistory(limit: nextLimit, scrollToLatest: false)
    }

    private func loadHistory(
        limit: Int,
        scrollProxy: ScrollViewProxy? = nil,
        debounce: Bool = false,
        scrollToLatest shouldScrollToLatest: Bool = true,
        animated: Bool = true
    ) {
        let generation = historyLoadFence.begin()
        let search = SettingsHistorySearch(historySearch)
        let pageLoader = historyPage
        let searchLoader = historySearchPage
        let loader: @Sendable (Int) async -> SettingsHistoryPage
        if search.isActive {
            let query = search.query
            loader = { limit in await searchLoader(limit, query) }
        } else {
            loader = pageLoader
        }
        isHistoryLoading = true
        historyRefreshTask?.cancel()
        historyRefreshTask = Task.detached(priority: .utility) {
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let page = await loader(limit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard historyLoadFence.accepts(generation), !Task.isCancelled else { return }
                historyChangesDuringLoad.publish(page, applyPage: applyHistoryPage, applyChange: applyHistoryChange)
                isHistoryLoading = false
                prefetchAskHistoryIfNeeded()
                if shouldScrollToLatest, let scrollProxy {
                    scrollToLatest(scrollProxy, animated: animated)
                }
            }
        }
    }

    private func applyHistoryPage(_ page: SettingsHistoryPage) {
        historyDayGroups = Self.newestFirstHistoryGroups(page.groups)
        historyMemory.applyPage(historyDayGroups.flatMap(\.entries).map(\.id))
        historyLoadedEntryCount = page.loadedEntryCount
        historyHasMore = page.hasMore
    }

    private func applyHistoryChange(_ change: SettingsHistoryArchiveChange) {
        let current = SettingsHistoryPage(groups: historyDayGroups, hasMore: historyHasMore)
        let updated = change.applying(to: current, matching: historySearch)
        guard updated != current else { return }
        historyDayGroups = updated.groups
        historyLoadedEntryCount = updated.loadedEntryCount
        historyLoadedEntryLimit = max(historyLoadedEntryLimit, updated.loadedEntryCount)
        // Keep the selection unless this row stopped matching the active search (then the newest row).
        historyMemory.applyPage(updated.groups.flatMap(\.entries).map(\.id))
    }

    private func applyAskHistoryChange(_ change: SettingsHistoryArchiveChange) {
        let current = SettingsAskHistoryPage(groups: askHistoryDayGroups, hasMore: askHistoryHasMore)
        let updated = change.applying(to: current, matching: askHistorySearch)
        guard updated != current else { return }
        askHistoryDayGroups = updated.groups
        askHistoryLoadedEntryCount = updated.loadedEntryCount
        askHistoryLoadedEntryLimit = max(askHistoryLoadedEntryLimit, updated.loadedEntryCount)
    }

    /// Cancels both in-flight archive loads and clears their loading flags.
    ///
    /// AIDEV-NOTE: The flag must be cleared with the cancel. A scope reopens without reloading when
    /// it already has entries, so a stranded `true` leaves the spinner up and "Load older" disabled
    /// for the rest of the session.
    private func cancelHistoryLoads() {
        historyRefreshTask?.cancel()
        historyRefreshTask = nil
        historyLoadFence.cancel()
        isHistoryLoading = false
        _ = historyChangesDuringLoad.takePending()
        askHistoryRefreshTask?.cancel()
        askHistoryRefreshTask = nil
        askHistoryLoadFence.cancel()
        isAskHistoryLoading = false
        _ = askChangesDuringLoad.takePending()
        searchPrewarmTask?.cancel()
        searchPrewarmTask = nil
    }

    /// #153 review MUST-FIX 2: the first switch to Ask walked that scope cold (~2.5x the Dictations page,
    /// 304.7 ms on an 11k archive). Once the Dictations page has landed, load the Ask page in the background so
    /// the switch finds the index warm.
    ///
    /// AIDEV-NOTE: This runs from the Dictations load's completion on purpose. Started alongside it, the two
    /// detached loads race for the index actor and the prefetch can delay the page the user is looking at.
    /// A switch while it is in flight cancels it, and the walk keeps what it already decoded.
    private func prefetchAskHistoryIfNeeded() {
        guard !hasPrefetchedAskHistory, askHistoryDayGroups.isEmpty, !isAskHistoryLoading else { return }
        hasPrefetchedAskHistory = true
        requestAskHistoryReload(scrollToLatest: false)
    }

    /// Lead add-on: the first search of a Settings session read ~11k text files (2.3–3.2 s). Once the Ask page
    /// has landed (after the Dictations page and its prefetch), warm the search text in the background so a search
    /// typed a couple of seconds later is served from memory.
    ///
    /// AIDEV-NOTE: Background priority, and the index yields between chunks, so it never delays a page the user
    /// asked for. `cancelHistoryLoads()` cancels it when History goes away; closing Settings drops this view and
    /// releases the index, which also stops a prewarm mid-walk.
    private func startSearchPrewarmIfNeeded() {
        guard searchPrewarmTask == nil else { return }
        let prewarm = searchPrewarm
        searchPrewarmTask = Task.detached(priority: .background) {
            await prewarm()
        }
    }

    private func requestAskHistoryReload(
        scrollProxy: ScrollViewProxy? = nil,
        debounce: Bool = false,
        scrollToLatest shouldScrollToLatest: Bool = true,
        animated: Bool = true
    ) {
        loadAskHistory(
            limit: askHistoryLoadedEntryLimit,
            scrollProxy: scrollProxy,
            debounce: debounce,
            scrollToLatest: shouldScrollToLatest,
            animated: animated
        )
    }

    private func loadOlderAskHistory() {
        let nextLimit = askHistoryLoadedEntryLimit + Self.historyPageSize
        askHistoryLoadedEntryLimit = nextLimit
        loadAskHistory(limit: nextLimit, scrollToLatest: false)
    }

    private func loadAskHistory(
        limit: Int,
        scrollProxy: ScrollViewProxy? = nil,
        debounce: Bool = false,
        scrollToLatest shouldScrollToLatest: Bool = true,
        animated: Bool = true
    ) {
        let generation = askHistoryLoadFence.begin()
        let search = SettingsHistorySearch(askHistorySearch)
        let pageLoader = askHistoryPage
        let searchLoader = askHistorySearchPage
        let loader: @Sendable (Int) async -> SettingsAskHistoryPage
        if search.isActive {
            let query = search.query
            loader = { limit in await searchLoader(limit, query) }
        } else {
            loader = pageLoader
        }
        isAskHistoryLoading = true
        askHistoryRefreshTask?.cancel()
        askHistoryRefreshTask = Task.detached(priority: .utility) {
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let page = await loader(limit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard askHistoryLoadFence.accepts(generation), !Task.isCancelled else { return }
                askChangesDuringLoad.publish(page, applyPage: applyAskHistoryPage, applyChange: applyAskHistoryChange)
                isAskHistoryLoading = false
                startSearchPrewarmIfNeeded()
                if shouldScrollToLatest, let scrollProxy {
                    scrollToLatestAsk(scrollProxy, animated: animated)
                }
            }
        }
    }

    private func applyAskHistoryPage(_ page: SettingsAskHistoryPage) {
        askHistoryDayGroups = page.groups
        askHistoryLoadedEntryCount = page.loadedEntryCount
        askHistoryHasMore = page.hasMore
    }

    private func scrollToLatestAsk(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !askHistoryDayGroups.isEmpty else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(latestAskHistoryAnchorID, anchor: .top)
                }
            } else {
                proxy.scrollTo(latestAskHistoryAnchorID, anchor: .top)
            }
        }
    }

    private func scrollToLatest(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard !historyDayGroups.isEmpty else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(latestHistoryAnchorID, anchor: .top)
                }
            } else {
                proxy.scrollTo(latestHistoryAnchorID, anchor: .top)
            }
        }
    }

    private static func newestFirstHistoryGroups(
        _ groups: [SettingsHistoryDayGroup]
    ) -> [SettingsHistoryDayGroup] {
        groups
            .sorted { lhs, rhs in
                if lhs.date == rhs.date {
                    return lhs.dayKey > rhs.dayKey
                }
                return lhs.date > rhs.date
            }
            .map { group in
                SettingsHistoryDayGroup(
                    dayKey: group.dayKey,
                    date: group.date,
                    entries: group.entries.sorted { lhs, rhs in
                        if lhs.createdAt == rhs.createdAt {
                            return lhs.recordingID > rhs.recordingID
                        }
                        return lhs.createdAt > rhs.createdAt
                    }
                )
            }
    }

    private static func limitHistoryGroups(
        _ groups: [SettingsHistoryDayGroup],
        to limit: Int
    ) -> [SettingsHistoryDayGroup] {
        var remaining = max(0, limit)
        var limitedGroups: [SettingsHistoryDayGroup] = []
        for group in newestFirstHistoryGroups(groups) where remaining > 0 {
            let entries = Array(group.entries.prefix(remaining))
            guard !entries.isEmpty else { continue }
            limitedGroups.append(SettingsHistoryDayGroup(
                dayKey: group.dayKey,
                date: group.date,
                entries: entries
            ))
            remaining -= entries.count
        }
        return limitedGroups
    }

    var showsHotkeyListenerRestart: Bool {
        HotkeyListenerRestartLine.showsRestart(listenerActive: hotkeyEnabled)
    }

    var permissionRowModels: [SetupPermissionRow] {
        // The wizard's rows (F3 step 1): a never-asked microphone offers "Allow…", a denied one "Open".
        SetupPermissionsStep(snapshot: SetupPermissionSnapshot(
            microphone: microphoneAuthorization(),
            accessibilityGranted: !missingPermissions.contains(.accessibility),
            inputMonitoringGranted: !missingPermissions.contains(.inputMonitoring),
            hotkeyListenerActive: hotkeyEnabled
        )).rows
    }

    private func runRelaySetup() {
        guard !relaySetupRunning else { return }
        relaySetupRunning = true
        let action: SettingsRelaySetupFeedback.Action = isHotkeyRemapActive() ? .reinstall : .setUp
        relaySetupFeedback = (action, nil)
        onRunRelaySetup { result in
            relaySetupFeedback = (action, result)
            relaySetupRunning = false
        }
    }

    struct DictionaryFocus: Equatable {
        let rowID: String
        let clearsSearch: Bool
    }

    /// Where the list goes after a save (UI pass #18): the saved term's row, and the search cleared if it
    /// would hide that term.
    /// The one trimmed search every Dictionary check uses; matching already trims (#148 Macroscope).
    static func dictionaryQuery(_ search: String) -> String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dictionaryFocus(afterSaving canonical: String, variants: [String] = [],
                                search: String) -> DictionaryFocus {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictionaryFocus(
            rowID: STTDictionaryDisplayEntry(
                source: "personal",
                entry: STTDictionaryEntry(canonical: canonical, variants: [])
            ).rowID,
            // The list matches misheard spellings too, so a search that still shows the term through one is kept.
            clearsSearch: !query.isEmpty && !([canonical] + variants).contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        )
    }

    /// Fold-3 review S2: a load that finishes while an edit is open must not overwrite the list, and must not be
    /// lost either. It is remembered and re-run when the edit ends.
    struct DictionaryReloadGate: Equatable {
        private(set) var reloadWhenEditEnds = false

        /// True when the finished load may be applied now.
        mutating func loadFinished(duringEdit: Bool) -> Bool {
            reloadWhenEditEnds = duringEdit
            return !duringEdit
        }

        /// A save or delete went to the daemon as the edit ended: its revision bump reloads with fresh data, so a
        /// deferred load must not run first and briefly undo the edit (#151 CodeRabbit).
        mutating func mutationSent() {
            reloadWhenEditEnds = false
        }

        /// True (once) when a deferred reload must run now that the edit ended.
        mutating func editEnded() -> Bool {
            defer { reloadWhenEditEnds = false }
            return reloadWhenEditEnds
        }
    }

    private var hasPendingDictionaryEdit: Bool {
        termSheet != nil || pendingDeletion != nil
    }

    /// Arriving on the tab never finds an editor already open (UI pass #17: the first row was).
    private func resetDictionaryEditors() {
        termSheet = nil
    }

    private func saveTermSheet(_ edit: DictionaryTermEdit) {
        guard edit.variantWarning(in: localEntries) == nil else { return }
        let entriesBefore = localEntries
        let saved = SettingsDictionaryMutations.apply(
            edit,
            localEntries: &localEntries,
            onAddPromptTerm: onAddPromptTerm,
            onRemovePromptTerm: onRemovePromptTerm,
            onAddVocabularyAlias: onAddVocabularyAlias,
            onRemoveVocabularyAlias: onRemoveVocabularyAlias
        )
        if localEntries != entriesBefore { dictionaryReloadGate.mutationSent() }
        termSheet = nil
        guard let saved else { return }
        let savedVariants = localEntries.first { $0.canonical == saved }?.variants ?? []
        let focus = Self.dictionaryFocus(afterSaving: saved, variants: savedVariants, search: dictionarySearch)
        if focus.clearsSearch { dictionarySearch = "" }
        yourTermsExpanded = true
        selectedTermRowID = focus.rowID
        flashingTermRowID = focus.rowID
        pendingScrollRowID = focus.rowID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if flashingTermRowID == focus.rowID { flashingTermRowID = nil }
        }
    }

    private func loadDictionaryPreview() {
        guard !dictionaryLoading else {
            dictionaryReloadQueued = true
            return
        }
        dictionaryLoading = true
        let provider = vocabularyPreview
        Task {
            let (preview, index) = await Task.detached(priority: .userInitiated) {
                let preview = provider()
                let index = STTDictionaryDisplayIndex(preview: preview)
                return (preview, index)
            }.value
            dictionaryLoading = false
            if dictionaryReloadQueued {
                dictionaryReloadQueued = false
                loadDictionaryPreview()
                return
            }
            guard dictionaryReloadGate.loadFinished(duringEdit: hasPendingDictionaryEdit) else { return }
            localEntries = preview.entries
            dictionaryDisplayIndex = index
            hasLoadedDictionaryOnce = true
        }
    }

    /// #201 r1: Add term waits for the first dictionary load. Until then the sheet would get no entries, and a load
    /// that lands while it is open is deferred, so it could not recognise a term that is already there.
    static func addTermEnabled(loaded: Bool) -> Bool {
        loaded
    }

    enum DictionaryPlaceholder: Equatable {
        case loading
        case empty
    }

    /// What stands in for "Your terms" rows: nothing while there are rows or a search, a quiet "Loading…" before
    /// the first async load lands (never a false "No terms yet"), and the empty state only once it has.
    static func dictionaryPlaceholder(loaded: Bool, personalIsEmpty: Bool, searching: Bool) -> DictionaryPlaceholder? {
        guard personalIsEmpty, !searching else { return nil }
        return loaded ? .empty : .loading
    }

    struct IncludedTermsHeader: Equatable {
        let title: String
        let isLoading: Bool
        let showsChevron: Bool
    }

    /// UXP-1: until the daemon's bundled rows arrive the count is unknown, not zero ("Loading…", nothing to open);
    /// a list the daemon reports empty has nothing to open either, so neither shows a chevron.
    static func includedTermsHeader(index: STTDictionaryDisplayIndex, matches: Int?,
                                    loaded: Bool) -> IncludedTermsHeader {
        guard loaded, index.bundledRowsKnown else {
            return IncludedTermsHeader(title: "Included terms", isLoading: true, showsChevron: false)
        }
        return IncludedTermsHeader(
            title: dictionarySectionTitle("Included terms", count: index.includedCount, matches: matches, loaded: true),
            isLoading: false,
            showsChevron: index.includedCount > 0
        )
    }

    static func dictionarySectionTitle(_ title: String, count: Int, matches: Int? = nil, loaded: Bool) -> String {
        guard loaded else { return title }
        guard let matches else { return "\(title) (\(count))" }
        return "\(title) (\(matches) of \(count))"
    }
}

/// The one Add/Edit term editor. In the window it is a sheet (Etan's 2.2.24 review #3). In the notch drawer it covers
/// the drawer's pane instead: a sheet on the notch panel would count as a modal (NotchModalObserver) and close the very
/// drawer it belongs to.
/// The cover owns Esc while it shows (0510 review F2): Esc cancels it and returns to Dictionary, the drawer kept.
struct DictionaryTermEditorPresentation<Editor: View>: ViewModifier {
    @Binding var edit: DictionaryTermEdit?
    let inDrawer: Bool
    var escapeOwnership: NotchEscapeOwnership = .shared
    @ViewBuilder let editor: (DictionaryTermEdit) -> Editor
    @State private var escapeClaim = UUID()

    func body(content: Content) -> some View {
        if inDrawer {
            content.overlay {
                if let edit {
                    ScrollView {
                        editor(edit)
                    }
                    .background(.regularMaterial)
                    .accessibilityAddTraits(.isModal)
                    .onAppear { escapeOwnership.claim(escapeClaim) { self.edit = nil } }
                    .onDisappear { escapeOwnership.release(escapeClaim) }
                }
            }
        } else {
            content.sheet(item: $edit) { edit in
                editor(edit).frame(width: 420)
            }
        }
    }
}

enum SettingsDictionaryMutations {
    /// Applies one Add/Edit sheet save through the existing single-step mutations (remove variants, rename,
    /// add), and returns the canonical spelling the term ends up under, so the list can scroll to it.
    @discardableResult
    static func apply(
        _ edit: DictionaryTermEdit,
        localEntries: inout [STTDictionaryEntry],
        onAddPromptTerm: (String) -> Void,
        onRemovePromptTerm: (String) -> Void,
        onAddVocabularyAlias: (String, String) -> Void,
        onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    ) -> String? {
        let correct = edit.trimmedCorrect
        guard !correct.isEmpty else { return nil }
        // Reject the whole edit before removing any old spelling.
        guard edit.variantWarning(in: localEntries) == nil else { return nil }
        var canonical = correct
        if let original = edit.original {
            canonical = original.canonical
            for variant in edit.removedVariants where original.variants.contains(variant) {
                removeVariant(canonical: canonical, variant: variant, localEntries: &localEntries,
                              onRemoveVocabularyAlias: onRemoveVocabularyAlias)
            }
            if correct != canonical {
                var editText = correct
                renameTerm(canonical, editText: &editText, localEntries: &localEntries,
                           onAddPromptTerm: onAddPromptTerm, onRemovePromptTerm: onRemovePromptTerm,
                           onAddVocabularyAlias: onAddVocabularyAlias)
            }
        } else if !localEntries.contains(where: { sameCanonical($0.canonical, correct) }) {
            // Persist a new term before adding its distinct misheard spelling.
            var newTermText = correct
            commitNewTerm(newTermText: &newTermText, localEntries: &localEntries, onAddPromptTerm: onAddPromptTerm)
        }
        let resolved = localEntries.first(where: { sameCanonical($0.canonical, correct) })?.canonical ?? correct
        if !edit.trimmedWrong.isEmpty {
            var variantText = edit.trimmedWrong
            var pending: String? = resolved
            addVariant(canonical: resolved, variantText: &variantText, addingVariantFor: &pending,
                       localEntries: &localEntries, onAddVocabularyAlias: onAddVocabularyAlias)
        }
        return localEntries.first(where: { sameCanonical($0.canonical, resolved) })?.canonical ?? resolved
    }

    static func commitNewTerm(
        newTermText: inout String,
        localEntries: inout [STTDictionaryEntry],
        onAddPromptTerm: (String) -> Void
    ) {
        let trimmed = newTermText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        upsertEntry(trimmed, in: &localEntries)
        onAddPromptTerm(trimmed)
        newTermText = ""
    }

    static func renameTerm(
        _ canonical: String,
        editText: inout String,
        localEntries: inout [STTDictionaryEntry],
        onAddPromptTerm: (String) -> Void,
        onRemovePromptTerm: (String) -> Void,
        onAddVocabularyAlias: (String, String) -> Void
    ) {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = localEntries.firstIndex(where: { $0.canonical == canonical }) else {
            return
        }
        // F2b (#201 r2): the same `sameCanonical` rule as the save's lookup in `apply`. A case-only check here let a
        // rename onto "zephyr   board" create a second row while the new variant went to "Zephyr Board".
        guard !sameCanonical(localEntries[index].canonical, trimmed) else {
            editText = ""
            return
        }
        let variants = localEntries[index].variants
        if let existingIndex = localEntries.firstIndex(where: { sameCanonical($0.canonical, trimmed) }) {
            let targetCanonical = localEntries[existingIndex].canonical
            for variant in variants where !localEntries[existingIndex].variants.contains(variant) {
                localEntries[existingIndex].variants.append(variant)
            }
            localEntries.remove(at: index)
            for variant in variants {
                onAddVocabularyAlias(targetCanonical, variant)
            }
            onRemovePromptTerm(canonical)
            editText = ""
            return
        }
        localEntries[index] = STTDictionaryEntry(canonical: trimmed, variants: variants)
        onAddPromptTerm(trimmed)
        for variant in variants {
            onAddVocabularyAlias(trimmed, variant)
        }
        onRemovePromptTerm(canonical)
        editText = ""
    }

    static func addVariant(
        canonical: String,
        variantText: inout String,
        addingVariantFor: inout String?,
        localEntries: inout [STTDictionaryEntry],
        onAddVocabularyAlias: (String, String) -> Void
    ) {
        let trimmed = variantText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defer {
            // AIDEV-NOTE: every exit clears the editor; a leftover addingVariantFor blocks all later reloads.
            variantText = ""
            addingVariantFor = nil
        }
        upsertEntry(canonical, in: &localEntries)
        // Same case-insensitive match as upsertEntry, so "swiftui" lands on an existing "SwiftUI".
        guard let index = localEntries.firstIndex(where: { sameCanonical($0.canonical, canonical) }) else { return }
        let existingCanonical = localEntries[index].canonical
        guard !DictionaryTermEdit.sameTerm(trimmed, existingCanonical) else { return }
        if !localEntries[index].variants.contains(where: { DictionaryTermEdit.sameTerm($0, trimmed) }) {
            localEntries[index].variants.append(trimmed)
            onAddVocabularyAlias(existingCanonical, trimmed)
        }
    }

    static func removeVariant(
        canonical: String,
        variant: String,
        localEntries: inout [STTDictionaryEntry],
        onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    ) {
        guard let index = localEntries.firstIndex(where: { $0.canonical == canonical }) else { return }
        localEntries[index].variants.removeAll { $0 == variant }
        onRemoveVocabularyAlias(STTVocabularyAliasPreview(from: variant, to: canonical))
    }

    private static func upsertEntry(_ canonical: String, in entries: inout [STTDictionaryEntry]) {
        guard !entries.contains(where: { sameCanonical($0.canonical, canonical) }) else { return }
        entries.append(STTDictionaryEntry(canonical: canonical, variants: []))
    }

    private static func sameCanonical(_ lhs: String, _ rhs: String) -> Bool {
        DictionaryTermEdit.sameTerm(lhs, rhs)
    }
}

/// Shared with the setup wizard's Permissions step (F3), so both name and open each pane the same way.
extension HotkeyPermission {
    var label: String {
        switch self {
        case .inputMonitoring:
            "Input Monitoring"
        case .accessibility:
            "Accessibility"
        case .microphone:
            "Microphone"
        }
    }

    var settingsURLString: String {
        switch self {
        case .inputMonitoring:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        case .accessibility:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
    }
}

private extension View {
    /// The scope not on screen stays mounted but inert: not drawn, not hit-testable, not focusable, not read by
    /// VoiceOver.
    func historyScopeVisibility(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .disabled(!visible)
            .accessibilityHidden(!visible)
            .zIndex(visible ? 1 : 0)
    }
}

/// One dispatch for a permission row's button, shared by Settings › General › Permissions and the wizard's step 1.
enum SettingsPermissionActions {
    static func perform(
        _ action: SetupPermissionAction,
        openURL: (URL) -> Void,
        requestMicrophone: (@escaping () -> Void) -> Void,
        refresh: @escaping () -> Void
    ) {
        switch action {
        case let .openSettings(url):
            if let url = URL(string: url) { openURL(url) }
        case .requestMicrophone:
            requestMicrophone(refresh)
        }
    }
}
