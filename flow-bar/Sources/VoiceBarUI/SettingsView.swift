import Foundation
import SwiftUI

public enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case general
    case models
    case dictionary
    case history

    public var id: Self {
        self
    }

    public var title: String {
        switch self {
        case .general: "General"
        case .models: "Models"
        case .dictionary: "Dictionary"
        case .history: "History"
        }
    }

    public var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .models: "cpu"
        case .dictionary: "text.book.closed"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// The two lists inside Settings → History. Order is the on-screen order: recording sits on the
/// left and is the default; Ask sits on the right.
public enum SettingsHistoryScope: String, Hashable, CaseIterable, Sendable {
    case recording
    case ask

    public var title: String {
        switch self {
        case .recording: "Recording"
        case .ask: "Ask"
        }
    }
}

enum SettingsHistoryPartRole: Hashable {
    case recording
    case question
    case response
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

    var label: String? {
        switch role {
        case .recording: nil
        case .question: "Question"
        case .response: "Response"
        }
    }

    var systemImage: String? {
        switch role {
        case .recording: nil
        case .question: "speaker.wave.2.fill"
        case .response: "mic.fill"
        }
    }

    var accessibilityNoun: String {
        switch role {
        case .recording: "recording audio"
        case .question: "question audio"
        case .response: "response audio"
        }
    }

    var actions: [SettingsHistoryAction] {
        switch role {
        case .recording:
            [.play, .copy, .paste, .retranscribe, .finder]
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

struct SettingsHistoryActionEnablement: Equatable {
    let isRetranscribing: Bool
    let isRecording: Bool
    let isTranscribing: Bool

    func isEnabled(
        _ action: SettingsHistoryAction,
        for part: SettingsHistoryMediaPart
    ) -> Bool {
        guard part.isEnabled(action) else { return false }

        if action == .play, isRecording || isTranscribing {
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
}

struct SettingsHistoryRowModel: Equatable {
    let timestamp: String
    let parts: [SettingsHistoryMediaPart]

    static func recording(_ entry: SettingsHistoryEntry) -> SettingsHistoryRowModel {
        let durationLabels = durationLabels(
            durationMs: entry.durationMs,
            transcribedDurationMs: entry.transcribedDurationMs
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
                    transcribedDurationLabel: durationLabels.transcribed
                ),
            ]
        )
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
            ]
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
    public static func message(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        relayReady: Bool,
        relaySummary: String
    ) -> String {
        if hotkeyEnabled, missingPermissions.isEmpty, relayReady {
            return "Shortcut ready: F5 listener and relay are active."
        }
        var problems: [String] = []
        if !hotkeyEnabled { problems.append("F5 listener unavailable") }
        if !missingPermissions.isEmpty { problems.append("Required permissions missing") }
        if !relayReady { problems.append(relaySummary) }
        return "Shortcut needs attention: \(problems.joined(separator: "; "))."
    }
}

public struct SettingsView: View {
    public let hotkeyEnabled: Bool
    public let missingPermissions: [HotkeyPermission]
    public let availableDevices: () -> [MicrophoneDevice]
    public let selectedDeviceID: () -> String?
    public let onSelectDevice: (String) -> Void
    public let prioritySnapshot: () -> MicrophonePrioritySnapshot
    public let onReorderPriority: ([String]) -> Void
    public let polishDegradation: () -> STTPolishDegradation?
    public let onDismissPolishDegradation: () -> Void
    public let anchorMode: () -> VoiceBarAnchorMode
    public let onSelectAnchorMode: (VoiceBarAnchorMode) -> Void
    public let performanceEffort: () -> VoiceBarPerformanceEffort
    public let performanceEffortNotice: () -> String?
    public let onSelectPerformanceEffort: (VoiceBarPerformanceEffort) -> Void
    public let modelsStatus: () -> ModelsSettingsState
    public let onRefreshModelsStatus: () -> Void
    public let residencyNotice: () -> String?
    public let onSelectResidency: ((VoiceModelResidency) -> Void)?
    public let processingPending: () -> [ProcessingKey: Bool]
    public let processingNotice: () -> String?
    public let onToggleProcessing: ((ProcessingKey, Bool) -> Void)?
    public let vocabularyPreview: () -> STTVocabularyPreview
    private let hasInitialDictionaryPreview: Bool
    public let vocabularyRevision: () -> UInt64
    public let onAddVocabularyAlias: (String, String) -> Void
    public let onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    public let onAddPromptTerm: (String) -> Void
    public let onRemovePromptTerm: (String) -> Void
    public let isHotkeyRemapActive: () -> Bool
    public let onCheckShortcut: (@escaping (String) -> Void) -> Void
    public let isMicrophonePermissionGranted: () -> Bool
    public let isVoiceBarHidden: () -> Bool
    public let onHideVoiceBar: () -> Void
    public let onShowVoiceBar: () -> Void
    public let onRunRelaySetup: (@escaping (String) -> Void) -> Void
    public let lastDictationEntry: () -> RecentTranscriptionEntry?
    public let lastDictationInsertionStatus: () -> DictationInsertionStatus
    public let onCopyLastDictation: (String) -> Void
    public let historyPage: @Sendable (Int) -> SettingsHistoryPage
    public let askHistoryPage: @Sendable (Int) -> SettingsAskHistoryPage
    public let onCopyHistoryTranscript: (String) -> Void
    public let onPasteHistoryTranscript: (String) -> Void
    public let onRetranscribeHistoryEntry: (String) -> Void
    public let isHistoryRetranscribing: (String) -> Bool
    public let isAnyHistoryRetranscribing: () -> Bool
    public let isRecordingActive: () -> Bool
    public let isTranscribingActive: () -> Bool
    public let onRevealHistoryFile: (URL) -> Void
    public let footerPresentation: () -> VoiceBarFooterPresentation

    private let latestHistoryAnchorID = "settings-history-latest-anchor"
    private let latestAskHistoryAnchorID = "settings-ask-history-latest-anchor"
    private static let historyPageSize = SettingsHistoryArchive.defaultPageSize

    @State private var selectedTab: SettingsTab
    @State private var selectedAnchorMode: VoiceBarAnchorMode
    @State private var selectedAnchoredMode: VoiceBarAnchorMode
    @State private var selectedPerformanceEffort: VoiceBarPerformanceEffort
    @State private var localVoiceBarHidden: Bool
    @State private var historyDayGroups: [SettingsHistoryDayGroup]
    @State private var historyLoadedEntryCount: Int
    @State private var historyLoadedEntryLimit: Int
    @State private var historyHasMore: Bool
    @State private var selectedHistoryEntryID: String?
    @State private var isHistoryLoading = false
    @State private var historyLoadFence = SettingsHistoryLoadFence()
    @State private var historyRefreshTask: Task<Void, Never>?
    @State private var selectedHistoryScope: SettingsHistoryScope
    @State private var askHistoryDayGroups: [SettingsAskHistoryDayGroup]
    @State private var askHistoryLoadedEntryCount: Int
    @State private var askHistoryLoadedEntryLimit: Int
    @State private var askHistoryHasMore: Bool
    @State private var isAskHistoryLoading = false
    @State private var askHistoryLoadFence = SettingsHistoryLoadFence()
    @State private var askHistoryRefreshTask: Task<Void, Never>?
    @State private var historyPlayback = SettingsAudioPlayback.system()
    @State private var dictionarySearch = ""
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
    @State private var pendingDeleteCanonical: String?
    @State private var relaySetupFeedback: String?
    @State private var relaySetupRunning = false
    @State private var shortcutCheckRunning = false
    @State private var shortcutCheckFeedback: String?
    @State private var isAdvancedExpanded = false
    @State private var microphoneSnapshot = MicrophonePrioritySnapshot.unavailable
    @State private var lastDictationProvenanceLabel: String?
    @FocusState private var focusedEditorField: DictEditorField?

    public init(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        availableDevices: @escaping () -> [MicrophoneDevice],
        selectedDeviceID: @escaping () -> String?,
        onSelectDevice: @escaping (String) -> Void,
        prioritySnapshot: @escaping () -> MicrophonePrioritySnapshot = { .unavailable },
        onReorderPriority: @escaping ([String]) -> Void = { _ in },
        polishDegradation: @escaping () -> STTPolishDegradation? = { nil },
        onDismissPolishDegradation: @escaping () -> Void = {},
        anchorMode: @escaping () -> VoiceBarAnchorMode = { .follow },
        onSelectAnchorMode: @escaping (VoiceBarAnchorMode) -> Void = { _ in },
        performanceEffort: @escaping () -> VoiceBarPerformanceEffort = { .accurate },
        performanceEffortNotice: @escaping () -> String? = { nil },
        onSelectPerformanceEffort: @escaping (VoiceBarPerformanceEffort) -> Void = { _ in },
        modelsStatus: @escaping () -> ModelsSettingsState,
        onRefreshModelsStatus: @escaping () -> Void,
        residencyNotice: @escaping () -> String? = { nil },
        onSelectResidency: ((VoiceModelResidency) -> Void)? = nil,
        processingPending: @escaping () -> [ProcessingKey: Bool] = { [:] },
        processingNotice: @escaping () -> String? = { nil },
        onToggleProcessing: ((ProcessingKey, Bool) -> Void)? = nil,
        vocabularyPreview: @escaping () -> STTVocabularyPreview = {
            STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        },
        vocabularyRevision: @escaping () -> UInt64,
        onAddVocabularyAlias: @escaping (String, String) -> Void = { _, _ in },
        onRemoveVocabularyAlias: @escaping (STTVocabularyAliasPreview) -> Void = { _ in },
        onAddPromptTerm: @escaping (String) -> Void = { _ in },
        onRemovePromptTerm: @escaping (String) -> Void = { _ in },
        isHotkeyRemapActive: @escaping () -> Bool = { false },
        onCheckShortcut: @escaping (@escaping (String) -> Void) -> Void = { $0("Shortcut check unavailable.") },
        isMicrophonePermissionGranted: @escaping () -> Bool = { true },
        isVoiceBarHidden: @escaping () -> Bool = { false },
        onHideVoiceBar: @escaping () -> Void = {},
        onShowVoiceBar: @escaping () -> Void = {},
        onRunRelaySetup: @escaping (@escaping (String) -> Void) -> Void = { completion in
            completion("Relay setup requested.")
        },
        lastDictationEntry: @escaping () -> RecentTranscriptionEntry? = { nil },
        lastDictationInsertionStatus: @escaping () -> DictationInsertionStatus = { .unverified },
        onCopyLastDictation: @escaping (String) -> Void = { _ in },
        historyPage: @escaping @Sendable (Int) -> SettingsHistoryPage = { limit in
            SettingsHistoryArchive.loadPage(limit: limit)
        },
        historyGroups: (@Sendable () -> [SettingsHistoryDayGroup])? = nil,
        initialHistoryPage: SettingsHistoryPage? = nil,
        askHistoryPage: @escaping @Sendable (Int) -> SettingsAskHistoryPage = { limit in
            SettingsAskHistoryArchive.loadPage(limit: limit)
        },
        initialAskHistoryPage: SettingsAskHistoryPage? = nil,
        onCopyHistoryTranscript: @escaping (String) -> Void = { _ in },
        onPasteHistoryTranscript: @escaping (String) -> Void = { _ in },
        onRetranscribeHistoryEntry: @escaping (String) -> Void = { _ in },
        isHistoryRetranscribing: @escaping (String) -> Bool = { _ in false },
        isAnyHistoryRetranscribing: @escaping () -> Bool = { false },
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
        initialTab: SettingsTab = .general,
        initialHistoryScope: SettingsHistoryScope = .recording,
        initialDictionarySearch: String = "",
        initialAdvancedExpanded: Bool = false,
        initialDictionaryPreview: STTVocabularyPreview? = nil,
        initialIncludedTermsExpanded: Bool = false,
        initialYourTermsExpanded: Bool = true,
        initialSelectedTermRowID: String? = nil
    ) {
        self.hotkeyEnabled = hotkeyEnabled
        self.missingPermissions = missingPermissions
        self.availableDevices = availableDevices
        self.selectedDeviceID = selectedDeviceID
        self.onSelectDevice = onSelectDevice
        self.prioritySnapshot = prioritySnapshot
        self.onReorderPriority = onReorderPriority
        self.polishDegradation = polishDegradation
        self.onDismissPolishDegradation = onDismissPolishDegradation
        self.anchorMode = anchorMode
        self.onSelectAnchorMode = onSelectAnchorMode
        self.performanceEffort = performanceEffort
        self.performanceEffortNotice = performanceEffortNotice
        self.onSelectPerformanceEffort = onSelectPerformanceEffort
        self.modelsStatus = modelsStatus
        self.onRefreshModelsStatus = onRefreshModelsStatus
        self.residencyNotice = residencyNotice
        self.onSelectResidency = onSelectResidency
        self.processingPending = processingPending
        self.processingNotice = processingNotice
        self.onToggleProcessing = onToggleProcessing
        self.vocabularyPreview = vocabularyPreview
        hasInitialDictionaryPreview = initialDictionaryPreview != nil
        self.vocabularyRevision = vocabularyRevision
        self.onAddVocabularyAlias = onAddVocabularyAlias
        self.onRemoveVocabularyAlias = onRemoveVocabularyAlias
        self.onAddPromptTerm = onAddPromptTerm
        self.onRemovePromptTerm = onRemovePromptTerm
        self.isHotkeyRemapActive = isHotkeyRemapActive
        self.onCheckShortcut = onCheckShortcut
        self.isMicrophonePermissionGranted = isMicrophonePermissionGranted
        self.isVoiceBarHidden = isVoiceBarHidden
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
        self.askHistoryPage = askHistoryPage
        self.onCopyHistoryTranscript = onCopyHistoryTranscript
        self.onPasteHistoryTranscript = onPasteHistoryTranscript
        self.onRetranscribeHistoryEntry = onRetranscribeHistoryEntry
        self.isHistoryRetranscribing = isHistoryRetranscribing
        self.isAnyHistoryRetranscribing = isAnyHistoryRetranscribing
        self.isRecordingActive = isRecordingActive
        self.isTranscribingActive = isTranscribingActive
        self.onRevealHistoryFile = onRevealHistoryFile
        self.footerPresentation = footerPresentation
        let initialAnchorMode = anchorMode()
        let initialPerformanceEffort = performanceEffort()
        _selectedTab = State(initialValue: initialTab)
        _dictionarySearch = State(initialValue: initialDictionarySearch)
        _isAdvancedExpanded = State(initialValue: initialAdvancedExpanded)
        _includedTermsExpanded = State(initialValue: initialIncludedTermsExpanded)
        _yourTermsExpanded = State(initialValue: initialYourTermsExpanded)
        _selectedTermRowID = State(initialValue: initialSelectedTermRowID)
        _selectedHistoryScope = State(initialValue: initialHistoryScope)
        _askHistoryDayGroups = State(initialValue: initialAskHistoryPage?.groups ?? [])
        _askHistoryLoadedEntryCount = State(initialValue: initialAskHistoryPage?.loadedEntryCount ?? 0)
        _askHistoryLoadedEntryLimit = State(
            initialValue: max(Self.historyPageSize, initialAskHistoryPage?.loadedEntryCount ?? 0)
        )
        _askHistoryHasMore = State(initialValue: initialAskHistoryPage?.hasMore ?? false)
        _selectedAnchorMode = State(initialValue: initialAnchorMode)
        _selectedPerformanceEffort = State(initialValue: initialPerformanceEffort)
        _localVoiceBarHidden = State(initialValue: isVoiceBarHidden())
        let initialHistoryLimit = max(Self.historyPageSize, initialHistoryPage?.loadedEntryCount ?? 0)
        _historyDayGroups = State(initialValue: initialHistoryPage?.groups ?? [])
        _historyLoadedEntryCount = State(initialValue: initialHistoryPage?.loadedEntryCount ?? 0)
        _selectedHistoryEntryID = State(initialValue: initialHistoryPage?.groups.first?.entries.first?.id)
        _historyLoadedEntryLimit = State(initialValue: initialHistoryLimit)
        _historyHasMore = State(initialValue: initialHistoryPage?.hasMore ?? false)
        _localEntries = State(initialValue: initialDictionaryPreview?.entries ?? [])
        _hasLoadedDictionaryOnce = State(initialValue: initialDictionaryPreview != nil)
        _dictionaryDisplayIndex = State(initialValue: STTDictionaryDisplayIndex(entries:
            initialDictionaryPreview?.displayEntries ?? initialDictionaryPreview?.entries.map {
                STTDictionaryDisplayEntry(source: "personal", entry: $0)
            } ?? []))
        _selectedAnchoredMode = State(
            initialValue: VoiceBarAnchorMode.anchoredPositionModes.contains(initialAnchorMode)
                ? initialAnchorMode
                : .topCenter
        )
    }

    public var body: some View {
        SettingsNavigationShell(selection: $selectedTab, footer: footerPresentation()) {
            switch selectedTab {
            case .dictionary:
                dictionaryTab
            case .history:
                settingsPage(
                    title: "History",
                    subtitle: "Your recordings and conversations"
                ) { historyTab }
            case .models:
                settingsPage(title: "Models") { modelsTab }
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
        .task(id: selectedTab) {
            if selectedTab == .dictionary, !hasInitialDictionaryPreview { loadDictionaryPreview() }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .history {
                switch selectedHistoryScope {
                case .recording:
                    if !isHistoryLoading {
                        requestHistoryReload()
                    }
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

    private var generalTab: some View {
        Form {
            Section("Shortcut") {
                LabeledContent("Shortcut") {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.secondary)
                        Text(VoiceBarHotkeyContract.shortcutChainLabel(remapDetected: isHotkeyRemapActive()))
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hotkeyEnabled ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(hotkeyStatusText)
                    }
                    Spacer(minLength: 8)
                    Button("Check shortcut") {
                        shortcutCheckRunning = true
                        onCheckShortcut { result in
                            shortcutCheckFeedback = result
                            shortcutCheckRunning = false
                        }
                    }
                    .disabled(shortcutCheckRunning)
                }
                if !hotkeyEnabled {
                    Text(
                        "Set ‘Press Globe key to’ to ‘Do Nothing’ in Keyboard settings. Some keyboards do not report Fn to apps; try F5."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let shortcutCheckFeedback {
                    Text(shortcutCheckFeedback).font(.caption).foregroundStyle(.secondary)
                }
            }

            // Always flat, even when everything is granted (Etan's 2.2.24 review #4; BrainBar #920).
            Section("Permissions") {
                permissionRows
            }

            visibilitySection
            microphonePrioritySection

            SettingsDisclosureRow("Advanced", isExpanded: $isAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("F5 key helper") {
                        HStack(spacing: 8) {
                            if isHotkeyRemapActive() {
                                statusBadge("Installed", isReady: true)
                            } else if hotkeyEnabled {
                                Text("Not installed").foregroundStyle(.secondary)
                            } else {
                                statusBadge("Needs setup", isReady: false)
                            }
                            Button(isHotkeyRemapActive() ? "Reinstall" : "Set up") {
                                runRelaySetup()
                            }
                            .disabled(relaySetupRunning)
                        }
                    }
                    .help(VoiceBarHotkeyContract.remapExplanation)
                    Text("Lets F5 start dictation even if your Mac remaps the dictation key.")
                        .font(.caption).foregroundStyle(.secondary)
                    if isHotkeyRemapActive() {
                        Text(VoiceBarHotkeyContract.remapPlainSummary)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let relaySetupFeedback {
                        Text(relaySetupFeedback)
                            .font(.caption)
                            .foregroundStyle(isHotkeyRemapActive() ? Color.secondary : Color.red)
                    }
                    Divider()
                    Text("Gestures").font(.headline)
                    LabeledContent("Single tap", value: VoiceBarHotkeyContract.singleTapDescription)
                    LabeledContent("Hold", value: VoiceBarHotkeyContract.holdDescription)
                    LabeledContent("Double-tap", value: VoiceBarHotkeyContract.doubleTapDescription)
                    LabeledContent(VoiceBarHotkeyContract.repasteShortcutLabel,
                                   value: VoiceBarHotkeyContract.repasteDescription)
                }
                .padding(.top, 6)
            }

            Section("Last dictation") {
                if let entry = lastDictationEntry() {
                    DictationCard(
                        entry: entry,
                        insertionStatus: lastDictationInsertionStatus(),
                        onCopy: onCopyLastDictation
                    )
                    Button("View history →") {
                        selectedTab = .history
                    }
                    .buttonStyle(.link)
                } else {
                    Text("No dictation yet")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshMicrophoneSnapshot)
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refreshMicrophoneSnapshot()
        }
    }

    private var visibilitySection: some View {
        Section("Visibility") {
            LabeledContent("VoiceBar") {
                statusBadge(localVoiceBarHidden ? "Hidden" : "Visible", isReady: !localVoiceBarHidden)
            }

            if localVoiceBarHidden {
                Button {
                    onShowVoiceBar()
                    localVoiceBarHidden = isVoiceBarHidden()
                } label: {
                    Label("Show VoiceBar", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .help("Show VoiceBar")
                .accessibilityLabel("Show VoiceBar")
            } else {
                Button {
                    onHideVoiceBar()
                    localVoiceBarHidden = isVoiceBarHidden()
                } label: {
                    Label("Hide for 1 hour", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
                .help("Hide VoiceBar for 1 hour")
                .accessibilityLabel("Hide VoiceBar for 1 hour")
            }
        }
        .onAppear {
            localVoiceBarHidden = isVoiceBarHidden()
        }
    }

    // MARK: - General microphone priority

    private var microphonePrioritySection: some View {
        Section("Microphone priority") {
            LabeledContent("Next dictation") {
                Text(microphoneSnapshot.nextVisibleDeviceName ?? "Unavailable")
                    .foregroundStyle(.secondary)
            }
            if let visibleFirst = microphoneSnapshot.visibleFirstUIDs {
                Button("Use visible microphones first") {
                    onReorderPriority(visibleFirst)
                    refreshMicrophoneSnapshot()
                }
                .help("A hidden system or virtual device would be used next. This puts your microphones ahead of it.")
            }

            if microphoneSnapshot.visibleRows.isEmpty {
                Text("No known input devices")
                    .foregroundStyle(.secondary)
            }
            let visibleRows = microphoneSnapshot.visibleRows
            ForEach(Array(visibleRows.enumerated()), id: \.offset) { index, row in
                microphonePriorityRow(row, at: index, visibleCount: visibleRows.count)
            }
            Text("Make a microphone the default, or drag to reorder. Disconnected microphones keep their place.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Etan's 2.2.24 review #5: one click makes a microphone the default, and rows drag to reorder. The
    /// arrows are gone; VoiceOver keeps Make default / Move up / Move down as named actions.
    @ViewBuilder
    private func microphonePriorityRow(_ row: MicrophonePriorityRow, at index: Int, visibleCount: Int) -> some View {
        let content = HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(row.canPrioritize ? 1 : 0)
                .accessibilityHidden(true)
            Image(systemName: "mic")
                .foregroundStyle(.secondary)
            Text(row.label)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(row.isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !row.canPrioritize {
                Text("UID unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if index == 0 {
                Text("Default")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            } else {
                Button("Make default") {
                    makeMicrophoneDefault(at: index)
                }
                .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Make default") {
            makeMicrophoneDefault(at: index)
        }
        .accessibilityAction(named: "Move up") {
            moveMicrophone(at: index, by: -1)
        }
        .accessibilityAction(named: "Move down") {
            moveMicrophone(at: index, by: 1)
        }
        if let uid = row.uid {
            content
                .draggable(uid)
                .dropDestination(for: String.self) { uids, _ in
                    dropMicrophone(uids.first, onto: index)
                }
        } else {
            content
        }
    }

    private func makeMicrophoneDefault(at index: Int) {
        guard let uids = microphoneSnapshot.makingDefaultUIDs(at: index) else { return }
        onReorderPriority(uids)
        refreshMicrophoneSnapshot()
    }

    /// Dropping onto a row lands the dragged mic in that row's place: below it when dragged down, above it
    /// when dragged up (SwiftUI onMove indices).
    private func dropMicrophone(_ uid: String?, onto index: Int) -> Bool {
        guard let uid,
              let source = microphoneSnapshot.visibleRows.firstIndex(where: { $0.uid == uid }),
              let uids = microphoneSnapshot.movingVisibleUIDs(
                  from: IndexSet(integer: source),
                  to: index > source ? index + 1 : index
              )
        else { return false }
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
        guard let uids = microphoneSnapshot.reorderedVisibleUIDs(moving: index, by: offset) else { return }
        onReorderPriority(uids)
        refreshMicrophoneSnapshot()
    }

    private var modelsTab: some View {
        ModelsSettingsView(
            state: modelsStatus(),
            effort: $selectedPerformanceEffort,
            notice: performanceEffortNotice(),
            onSelectEffort: onSelectPerformanceEffort,
            residencyNotice: residencyNotice(),
            onSelectResidency: onSelectResidency,
            lastDictationLabel: lastDictationProvenanceLabel,
            degradation: polishDegradation(),
            onDismissDegradation: onDismissPolishDegradation,
            processingPending: processingPending(),
            processingNotice: processingNotice(),
            onToggleProcessing: onToggleProcessing
        )
        // The picker's local state gives one click instant feedback; it follows the app's value
        // (the selection in flight, else the daemon's effort) so a reject or a daemon-side change
        // never leaves it stale. There is no persisted copy (E2).
        .onChange(of: performanceEffort()) { _, current in
            selectedPerformanceEffort = current
        }
        .onAppear {
            selectedPerformanceEffort = performanceEffort()
            lastDictationProvenanceLabel = SettingsHistoryArchive.lastDictationProvenanceLabel(
                for: lastDictationEntry()?.recordingPath
            )
            onRefreshModelsStatus()
        }
        .onChange(of: lastDictationEntry()?.recordingPath) { _, path in
            lastDictationProvenanceLabel = SettingsHistoryArchive.lastDictationProvenanceLabel(for: path)
        }
    }

    // MARK: - History Tab

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            historyScopePicker

            switch selectedHistoryScope {
            case .recording:
                recordingHistoryScope
            case .ask:
                askHistoryScope
            }
        }
        // AIDEV-NOTE: Always reload the scope being switched to. An inactive scope is out of the
        // view hierarchy, so its `.onReceive(voiceBarHistoryArchiveDidChange)` never fires — without
        // this, switching back shows a list frozen at whenever that scope was last on screen.
        .onChange(of: selectedHistoryScope) { _, scope in
            historyPlayback.stop()
            switch scope {
            case .recording:
                requestHistoryReload()
            case .ask:
                requestAskHistoryReload()
            }
        }
        .onDisappear {
            cancelHistoryLoads()
            historyPlayback.stop()
        }
    }

    // AIDEV-NOTE: Recording is deliberately first (left) and the default scope — the F5 list is
    // unchanged by the Ask tab, and ask exchanges never appear in it.
    private var historyScopePicker: some View {
        Picker("History scope", selection: $selectedHistoryScope) {
            ForEach(SettingsHistoryScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
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
                        Text("Loading history...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if historyDayGroups.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No transcript history yet")
                            .font(.headline)
                        Text("Completed recordings will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                Color.clear.frame(height: 1).id(latestHistoryAnchorID)
                                ForEach(historyDayGroups) { group in
                                    ForEach(group.entries) { entry in
                                        Button {
                                            selectedHistoryEntryID = entry.id
                                        } label: {
                                            recordingHistoryListRow(entry)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            .padding(12)
                        }
                        .frame(minHeight: 100)

                        if let entry = selectedHistoryEntry {
                            Divider()
                            ScrollView {
                                recordingHistoryDetail(entry)
                                    .padding(18)
                            }
                            .frame(maxHeight: 260)
                        }

                        Divider()
                        HStack {
                            Text("\(historyLoadedEntryCount) saved shown")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if historyHasMore {
                                Button(isHistoryLoading ? "Loading…" : "Load more") {
                                    loadOlderHistory()
                                }
                                .disabled(isHistoryLoading)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                    }
                }
            }
            .onAppear {
                if historyDayGroups.isEmpty, !isHistoryLoading {
                    requestHistoryReload(scrollProxy: proxy, animated: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { _ in
                requestHistoryReload(scrollProxy: proxy, debounce: true, scrollToLatest: false)
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
            if let effort = entry.performanceEffort {
                Text(effort.displayName)
                    .font(.caption)
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
        .accessibilityLabel(
            "\(entry.displayTranscript), \(entry.createdAt.formatted()), \(entry.durationLabel ?? "duration unavailable")"
        )
    }

    private func recordingHistoryDetail(_ entry: SettingsHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            historyMediaPartRow(SettingsHistoryRowModel.recording(entry).parts[0])
            Divider()
            Label("Saved on this Mac", systemImage: "internaldrive")
                .font(.caption)
                .foregroundStyle(.secondary)
            let attribution = [entry.inputDeviceLabel, entry.modelLabel, entry.performanceEffort?.displayName]
                .compactMap { $0 }.joined(separator: " · ")
            if !attribution.isEmpty {
                Text(attribution)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text("Loading ask history...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                            Color.clear
                                .frame(height: 1)
                                .id(latestAskHistoryAnchorID)

                            ForEach(askHistoryDayGroups) { group in
                                historyDaySection(title: group.dayTitle()) {
                                    ForEach(group.entries) { entry in
                                        historyEntryRow(SettingsHistoryRowModel.ask(entry))
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
                        .padding(18)
                    }
                }
            }
            .onAppear {
                if askHistoryDayGroups.isEmpty, !isAskHistoryLoading {
                    requestAskHistoryReload(scrollProxy: proxy, animated: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { _ in
                requestAskHistoryReload(scrollProxy: proxy, debounce: true, scrollToLatest: false)
            }
        }
    }

    private func askHistoryToolbar(proxy: ScrollViewProxy? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask")
                    .font(.title3.weight(.semibold))
                Text("\(askHistoryLoadedEntryCount) exchanges")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isAskHistoryLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                requestAskHistoryReload(scrollProxy: proxy)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh ask history")
            .accessibilityLabel("Refresh ask history")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func historyToolbar(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("History")
                    .font(.title3.weight(.semibold))
                Text("\(historyLoadedEntryCount) transcripts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isHistoryLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                requestHistoryReload(scrollProxy: proxy)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh history")
            .accessibilityLabel("Refresh history")

            Button {
                scrollToLatest(proxy)
            } label: {
                Image(systemName: "arrow.up.to.line")
            }
            .buttonStyle(.borderless)
            .disabled(historyDayGroups.isEmpty)
            .help("Jump to latest")
            .accessibilityLabel("Jump to latest")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
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
    private func historyDayHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
        .padding(.vertical, 6)
        .background(
            Rectangle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, -18)
                .padding(.top, -18)
        )
    }

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
            isTranscribing: isTranscribingActive()
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
        }
    }

    // AIDEV-NOTE: these remain two separate facts: waveform is mic-on time, while
    // text.viewfinder is the meaningfully shorter slice sent to speech-to-text.
    @ViewBuilder
    private func historyMediaPartStats(_ part: SettingsHistoryMediaPart) -> some View {
        let audioLabel = part.durationLabel
        let heardLabel = part.transcribedDurationLabel

        if audioLabel != nil || heardLabel != nil {
            HStack(spacing: 12) {
                if let audioLabel {
                    Label(audioLabel, systemImage: "waveform")
                        .help("Audio length — how long the mic was on")
                        .accessibilityLabel("Audio length \(audioLabel)")
                }
                if let heardLabel {
                    Label(heardLabel, systemImage: "text.viewfinder")
                        .help(
                            "Transcribed — the audio actually sent to speech-to-text after trailing silence was trimmed"
                        )
                        .accessibilityLabel("Transcribed length \(heardLabel)")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    private func historyMediaPartActions(
        _ part: SettingsHistoryMediaPart,
        isRetranscribing: Bool,
        enablement: SettingsHistoryActionEnablement
    ) -> some View {
        HStack(spacing: 8) {
            ForEach(part.actions, id: \.self) { action in
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

    private func historyActionLabel(
        _ title: String,
        systemImage: String,
        isSpinning: Bool = false
    ) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .rotationEffect(.degrees(isSpinning ? 360 : 0))
                .animation(
                    isSpinning
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: isSpinning
                )
        }
        .labelStyle(.iconOnly)
        .frame(minWidth: 28, minHeight: 28)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func historyActionButton(
        _ action: SettingsHistoryAction,
        for part: SettingsHistoryMediaPart,
        isRetranscribing: Bool,
        enablement: SettingsHistoryActionEnablement
    ) -> some View {
        let disabled = !enablement.isEnabled(action, for: part)
        let isPlaying = part.audioPath.map(historyPlayback.isPlaying) ?? false

        switch action {
        case .play:
            Button {
                guard let audioPath = part.audioPath else { return }
                guard !isRecordingActive(), !isTranscribingActive() else {
                    historyPlayback.stop()
                    return
                }
                historyPlayback.toggle(audioPath)
            } label: {
                historyActionLabel(
                    isPlaying ? "Stop" : "Play",
                    systemImage: isPlaying ? "stop.fill" : "play.fill"
                )
            }
            .disabled(disabled)
            .help(isPlaying ? "Stop" : "Play")
            .accessibilityLabel("\(isPlaying ? "Stop" : "Play") \(part.accessibilityNoun)")

        case .copy:
            Button {
                guard let text = part.actionableText else { return }
                onCopyHistoryTranscript(text)
            } label: {
                historyActionLabel("Copy", systemImage: "doc.on.doc")
            }
            .disabled(disabled)
            .help("Copy")
            .accessibilityLabel("Copy transcript")

        case .paste:
            Button {
                guard let text = part.actionableText else { return }
                onPasteHistoryTranscript(text)
            } label: {
                historyActionLabel("Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(disabled)
            .help("Paste")
            .accessibilityLabel("Paste transcript")

        case .retranscribe:
            Button {
                guard let audioPath = part.audioPath else { return }
                onRetranscribeHistoryEntry(audioPath.path)
            } label: {
                historyActionLabel(
                    "Re-transcribe",
                    systemImage: "arrow.triangle.2.circlepath",
                    isSpinning: isRetranscribing
                )
            }
            .disabled(disabled)
            .help(enablement.isTranscribing ? "Transcribing…" : "Re-transcribe")
            .accessibilityLabel(
                isRetranscribing ? "Re-transcribing stored audio" : "Re-transcribe stored audio"
            )

        case .finder:
            Button {
                guard let audioPath = part.audioPath else { return }
                onRevealHistoryFile(audioPath)
            } label: {
                historyActionLabel("Open in Finder", systemImage: "folder")
            }
            .disabled(disabled)
            .help("Open in Finder")
            .accessibilityLabel("Open stored audio in Finder")
        }
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Dictionary").font(.title2.weight(.semibold))
                    Text("Used on every dictation").font(.subheadline).foregroundStyle(.secondary)
                }
                searchRow
                Button {
                    termSheet = DictionaryTermEdit()
                } label: {
                    Label("Add term", systemImage: "plus")
                }
                .help("Add a term to your dictionary")
            }
            .padding(.horizontal, 22)
            .padding(.top, 19)
            .padding(.bottom, 14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    let isSearching = !Self.dictionaryQuery(dictionarySearch).isEmpty
                    let personal = dictionaryDisplayIndex.entries(source: "personal", matching: dictionarySearch)
                    let included = dictionaryDisplayIndex.entries(source: "bundled", matching: dictionarySearch)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Button {
                            yourTermsExpanded.toggle()
                        } label: {
                            HStack {
                                Image(systemName: yourTermsExpanded ? "chevron.down" : "chevron.right")
                                    .frame(width: 14)
                                Text(Self.dictionarySectionTitle(
                                    "Your terms", count: dictionaryDisplayIndex.personalCount,
                                    matches: isSearching ? personal.count : nil,
                                    loaded: hasLoadedDictionaryOnce
                                ))
                                Spacer()
                            }
                            .font(.headline)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(yourTermsExpanded ? "Collapse your terms" : "Show your terms")
                        .accessibilityValue(yourTermsExpanded ? "Expanded" : "Collapsed")
                        .padding(.bottom, 8)
                        if yourTermsExpanded || isSearching {
                            switch Self.dictionaryPlaceholder(
                                loaded: hasLoadedDictionaryOnce, personalIsEmpty: personal.isEmpty,
                                searching: isSearching
                            ) {
                            case .loading:
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Loading…").foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, minHeight: 170)
                            case .empty:
                                VStack(spacing: 10) {
                                    Image(systemName: "text.book.closed").font(.largeTitle).foregroundStyle(.secondary)
                                    Text("No terms yet").font(.headline)
                                    Text("Add names, products, and other preferred spellings.")
                                        .font(.caption).foregroundStyle(.secondary)
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
                        Button {
                            includedTermsExpanded.toggle()
                        } label: {
                            HStack {
                                Image(systemName: includedTermsExpanded ? "chevron.down" : "chevron.right")
                                    .frame(width: 14)
                                Text(Self.dictionarySectionTitle(
                                    "Included terms", count: dictionaryDisplayIndex.includedCount,
                                    matches: isSearching ? included.count : nil,
                                    loaded: hasLoadedDictionaryOnce
                                ))
                                Spacer()
                                Text("built in").font(.caption).foregroundStyle(.secondary)
                            }
                            .font(.headline)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(includedTermsExpanded ? "Collapse included terms" : "Show included terms")
                        .accessibilityValue(includedTermsExpanded ? "Expanded" : "Collapsed")
                        .accessibilityHint("Built-in terms are read-only")
                        .padding(.top, 18)
                        if includedTermsExpanded || isSearching {
                            ForEach(included, id: \.rowID) { row in
                                dictionaryEntryCard(row.entry, rowID: row.rowID, isEditable: false)
                                Divider()
                            }
                        }
                    }
                    .padding(18)
                }
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
        }
        .sheet(item: $termSheet) { edit in
            DictionaryAddSheetView(edit: edit, onSave: { saved in
                saveTermSheet(saved)
            }, onCancel: { termSheet = nil })
                .frame(width: 420)
        }
        .onAppear {
            resetDictionaryEditors()
        }
        .onChange(of: hasPendingDictionaryEdit) { _, pending in
            if !pending, dictionaryReloadGate.editEnded() { loadDictionaryPreview() }
        }
        .onChange(of: localEntries) { _, entries in
            let bundled = dictionaryDisplayIndex.sortedEntries.filter { !$0.isPersonal }
            dictionaryDisplayIndex = STTDictionaryDisplayIndex(entries: bundled + entries.map {
                STTDictionaryDisplayEntry(source: "personal", entry: $0)
            })
        }
    }

    private var searchRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search terms and variants", text: $dictionarySearch)
                .dictionaryTextField()
                .focused($focusedEditorField, equals: .search)
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
        VStack(alignment: .leading, spacing: 4) {
            dictionaryEntryHeader(entry, rowID: rowID, isEditable: isEditable)
            if !entry.variants.isEmpty {
                Text(Self.variantSummary(entry.variants))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Self.variantSummary(entry.variants))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(
                    flashingTermRowID == rowID ? 0.28 : selectedTermRowID == rowID ? 0.12 : 0
                ))
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: flashingTermRowID)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if isEditable { termSheet = DictionaryTermEdit(original: entry) }
        }
        .onTapGesture {
            selectedTermRowID = rowID
        }
        .accessibilityAddTraits(selectedTermRowID == rowID ? .isSelected : [])
    }

    /// A term's misheard spellings on one quiet line under it, only when it has some.
    static func variantSummary(_ variants: [String]) -> String {
        "misheard as " + variants.joined(separator: ", ")
    }

    private func dictionaryEntryHeader(
        _ entry: STTDictionaryEntry,
        rowID: String,
        isEditable: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(entry.canonical)
                .font(.headline)
            Spacer()
            if isEditable {
                if pendingDeleteCanonical == entry.canonical {
                    deleteDictionaryEntryButton(entry.canonical)
                } else {
                    Button {
                        pendingDeleteCanonical = nil
                        termSheet = DictionaryTermEdit(original: entry)
                    } label: {
                        Image(systemName: "pencil")
                            .frame(width: DictionaryCardLayout.actionTarget, height: DictionaryCardLayout.actionTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Edit term")
                    .accessibilityLabel("Edit term \(entry.canonical)")
                    deleteDictionaryEntryButton(entry.canonical)
                }
            }
        }
        .frame(minHeight: DictionaryCardLayout.headerHeight)
    }

    @ViewBuilder
    private func deleteDictionaryEntryButton(_ canonical: String) -> some View {
        if pendingDeleteCanonical == canonical {
            Button("Cancel") {
                pendingDeleteCanonical = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(height: DictionaryCardLayout.headerHeight)
            Button("Delete?", role: .destructive) {
                SettingsDictionaryMutations.confirmDeleteTerm(
                    canonical,
                    pendingDeleteCanonical: &pendingDeleteCanonical,
                    localEntries: &localEntries,
                    onRemovePromptTerm: onRemovePromptTerm
                )
                dictionaryReloadGate.mutationSent()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(height: DictionaryCardLayout.headerHeight)
            .tint(.red)
        } else {
            Button {
                SettingsDictionaryMutations.requestDeleteTerm(
                    canonical,
                    pendingDeleteCanonical: &pendingDeleteCanonical
                )
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
        let loader = historyPage
        isHistoryLoading = true
        historyRefreshTask?.cancel()
        historyRefreshTask = Task.detached(priority: .utility) {
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let page = loader(limit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard historyLoadFence.accepts(generation), !Task.isCancelled else { return }
                applyHistoryPage(page)
                isHistoryLoading = false
                if shouldScrollToLatest, let scrollProxy {
                    scrollToLatest(scrollProxy, animated: animated)
                }
            }
        }
    }

    private func applyHistoryPage(_ page: SettingsHistoryPage) {
        historyDayGroups = Self.newestFirstHistoryGroups(page.groups)
        let entries = historyDayGroups.flatMap(\.entries)
        if !entries.contains(where: { $0.id == selectedHistoryEntryID }) {
            selectedHistoryEntryID = entries.first?.id
        }
        historyLoadedEntryCount = page.loadedEntryCount
        historyHasMore = page.hasMore
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
        askHistoryRefreshTask?.cancel()
        askHistoryRefreshTask = nil
        askHistoryLoadFence.cancel()
        isAskHistoryLoading = false
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
        let loader = askHistoryPage
        isAskHistoryLoading = true
        askHistoryRefreshTask?.cancel()
        askHistoryRefreshTask = Task.detached(priority: .utility) {
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let page = loader(limit)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard askHistoryLoadFence.accepts(generation), !Task.isCancelled else { return }
                applyAskHistoryPage(page)
                isAskHistoryLoading = false
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

    private var hotkeyStatusText: String {
        if hotkeyEnabled { return "Active" }
        let names = missingPermissions.map {
            switch $0 {
            case .inputMonitoring: "Input Monitoring"
            case .accessibility: "Accessibility"
            case .microphone: "Microphone"
            }
        }
        return "Missing: \(names.joined(separator: ", "))"
    }

    private var positionModeDescription: String {
        switch selectedAnchorMode {
        case .follow:
            "Follows the active screen while you drag freely."
        case .topCenter:
            "Anchored to the top center of the active screen."
        case .bottomCenter:
            "Anchored to the bottom center of the active screen."
        }
    }

    private func permissionRow(_ permission: HotkeyPermission, isGranted: Bool) -> some View {
        LabeledContent(permission.label) {
            HStack(spacing: 8) {
                statusBadge(isGranted ? "Granted" : "Missing", isReady: isGranted)
                if !isGranted {
                    Button("Open") {
                        openPermissionSettings(permission)
                    }
                }
            }
        }
    }

    private var permissionRows: some View {
        Group {
            permissionRow(.microphone, isGranted: isMicrophonePermissionGranted())
            permissionRow(.accessibility, isGranted: !missingPermissions.contains(.accessibility))
            permissionRow(.inputMonitoring, isGranted: !missingPermissions.contains(.inputMonitoring))
        }
    }

    private func statusBadge(_ text: String, isReady: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isReady ? .green : .red)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func openPermissionSettings(_ permission: HotkeyPermission) {
        if let url = URL(string: permission.settingsURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func runRelaySetup() {
        guard !relaySetupRunning else { return }
        relaySetupRunning = true
        relaySetupFeedback = "Setting up relay..."
        onRunRelaySetup { feedback in
            relaySetupFeedback = feedback
            relaySetupRunning = false
        }
    }

    private func performanceEffortLabel(_ effort: VoiceBarPerformanceEffort) -> String {
        switch effort {
        case .fast:
            "Fast"
        case .balanced:
            "Balanced"
        case .accurate:
            "Accurate"
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
        termSheet != nil || pendingDeleteCanonical != nil
    }

    /// Arriving on the tab never finds an editor already open (UI pass #17: the first row was).
    private func resetDictionaryEditors() {
        termSheet = nil
        pendingDeleteCanonical = nil
    }

    private func saveTermSheet(_ edit: DictionaryTermEdit) {
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
                let index = STTDictionaryDisplayIndex(entries: preview.displayEntries ?? preview.entries.map {
                    STTDictionaryDisplayEntry(source: "personal", entry: $0)
                })
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

    static func dictionarySectionTitle(_ title: String, count: Int, matches: Int? = nil, loaded: Bool) -> String {
        guard loaded else { return title }
        guard let matches else { return "\(title) (\(count))" }
        return "\(title) (\(matches) of \(count))"
    }

    private func selectAnchorMode(_ mode: VoiceBarAnchorMode) {
        selectedAnchorMode = mode
        if mode != .follow {
            selectedAnchoredMode = mode
        }
        onSelectAnchorMode(mode)
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
            // A new term is always persisted as a term, even when its misheard spelling is dropped below
            // (equal to it by alias key), or it would vanish on the next reload (#144 CodeRabbit).
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
        guard localEntries[index].canonical.localizedCaseInsensitiveCompare(trimmed) != .orderedSame else {
            editText = ""
            return
        }
        let variants = localEntries[index].variants
        if let existingIndex = localEntries.firstIndex(where: {
            $0.canonical.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }) {
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

    static func requestDeleteTerm(
        _ canonical: String,
        pendingDeleteCanonical: inout String?
    ) {
        pendingDeleteCanonical = canonical
    }

    static func confirmDeleteTerm(
        _ canonical: String,
        pendingDeleteCanonical: inout String?,
        localEntries: inout [STTDictionaryEntry],
        onRemovePromptTerm: (String) -> Void
    ) {
        guard pendingDeleteCanonical == canonical else { return }
        localEntries.removeAll { $0.canonical == canonical }
        onRemovePromptTerm(canonical)
        pendingDeleteCanonical = nil
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
        guard aliasKey(trimmed) != aliasKey(existingCanonical) else { return }
        if !localEntries[index].variants.contains(where: { aliasKey($0) == aliasKey(trimmed) }) {
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
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func aliasKey(_ value: String) -> String {
        value.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            switch scalar.value {
            case 48 ... 57, 97 ... 122:
                result.unicodeScalars.append(scalar)
            default:
                break
            }
        }
    }
}

private extension HotkeyPermission {
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
