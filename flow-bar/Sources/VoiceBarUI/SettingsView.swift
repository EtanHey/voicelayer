import Foundation
import SwiftUI

public enum SettingsTab: Hashable {
    case general
    case audio
    case history
    case dictionary
}

private enum DictEditorField: Hashable {
    case search
    case newTerm
    case editTerm
    case addVariant
}

private enum DictionaryCardLayout {
    static let headerHeight: CGFloat = 24
    static let inlineControlHeight: CGFloat = 28
    static let inlineFieldVerticalPadding: CGFloat = 5
}

public struct SettingsView: View {
    public let hotkeyEnabled: Bool
    public let missingPermissions: [HotkeyPermission]
    public let availableDevices: () -> [MicrophoneDevice]
    public let selectedDeviceID: () -> String?
    public let onSelectDevice: (String) -> Void
    public let polishDegradation: () -> STTPolishDegradation?
    public let onDismissPolishDegradation: () -> Void
    public let anchorMode: () -> VoiceBarAnchorMode
    public let onSelectAnchorMode: (VoiceBarAnchorMode) -> Void
    public let performanceEffort: () -> VoiceBarPerformanceEffort
    public let performanceEffortNotice: () -> String?
    public let onSelectPerformanceEffort: (VoiceBarPerformanceEffort) -> Void
    public let vocabularyPreview: () -> STTVocabularyPreview
    public let onAddVocabularyAlias: (String, String) -> Void
    public let onRemoveVocabularyAlias: (STTVocabularyAliasPreview) -> Void
    public let onAddPromptTerm: (String) -> Void
    public let onRemovePromptTerm: (String) -> Void
    public let isHotkeyRemapActive: () -> Bool
    public let isMicrophonePermissionGranted: () -> Bool
    public let isVoiceBarHidden: () -> Bool
    public let onHideVoiceBar: () -> Void
    public let onShowVoiceBar: () -> Void
    public let onRunRelaySetup: (@escaping (String) -> Void) -> Void
    public let historyPage: @Sendable (Int) -> SettingsHistoryPage
    public let onCopyHistoryTranscript: (String) -> Void
    public let onPasteHistoryTranscript: (String) -> Void
    public let onRetranscribeHistoryEntry: (String) -> Void
    public let isHistoryRetranscribing: (String) -> Bool

    private let latestHistoryAnchorID = "settings-history-latest-anchor"
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
    @State private var isHistoryLoading = false
    @State private var historyLoadGeneration = 0
    @State private var historyRefreshTask: Task<Void, Never>?
    @State private var dictionarySearch = ""
    @State private var localEntries: [STTDictionaryEntry]
    @State private var editingCanonical: String?
    @State private var editTermText = ""
    @State private var addingVariantFor: String?
    @State private var variantText = ""
    @State private var pendingDeleteCanonical: String?
    @State private var newTermText = ""
    @State private var relaySetupFeedback: String?
    @State private var relaySetupRunning = false
    @FocusState private var focusedEditorField: DictEditorField?

    public init(
        hotkeyEnabled: Bool,
        missingPermissions: [HotkeyPermission],
        availableDevices: @escaping () -> [MicrophoneDevice],
        selectedDeviceID: @escaping () -> String?,
        onSelectDevice: @escaping (String) -> Void,
        polishDegradation: @escaping () -> STTPolishDegradation? = { nil },
        onDismissPolishDegradation: @escaping () -> Void = {},
        anchorMode: @escaping () -> VoiceBarAnchorMode = { .follow },
        onSelectAnchorMode: @escaping (VoiceBarAnchorMode) -> Void = { _ in },
        performanceEffort: @escaping () -> VoiceBarPerformanceEffort = { .accurate },
        performanceEffortNotice: @escaping () -> String? = { nil },
        onSelectPerformanceEffort: @escaping (VoiceBarPerformanceEffort) -> Void = { _ in },
        vocabularyPreview: @escaping () -> STTVocabularyPreview = {
            STTVocabularyPreview(updatedAt: nil, promptTerms: [], aliases: [])
        },
        onAddVocabularyAlias: @escaping (String, String) -> Void = { _, _ in },
        onRemoveVocabularyAlias: @escaping (STTVocabularyAliasPreview) -> Void = { _ in },
        onAddPromptTerm: @escaping (String) -> Void = { _ in },
        onRemovePromptTerm: @escaping (String) -> Void = { _ in },
        isHotkeyRemapActive: @escaping () -> Bool = { false },
        isMicrophonePermissionGranted: @escaping () -> Bool = { true },
        isVoiceBarHidden: @escaping () -> Bool = { false },
        onHideVoiceBar: @escaping () -> Void = {},
        onShowVoiceBar: @escaping () -> Void = {},
        onRunRelaySetup: @escaping (@escaping (String) -> Void) -> Void = { completion in
            completion("Relay setup requested.")
        },
        historyPage: @escaping @Sendable (Int) -> SettingsHistoryPage = { limit in
            SettingsHistoryArchive.loadPage(limit: limit)
        },
        historyGroups: (@Sendable () -> [SettingsHistoryDayGroup])? = nil,
        initialHistoryPage: SettingsHistoryPage? = nil,
        onCopyHistoryTranscript: @escaping (String) -> Void = { _ in },
        onPasteHistoryTranscript: @escaping (String) -> Void = { _ in },
        onRetranscribeHistoryEntry: @escaping (String) -> Void = { _ in },
        isHistoryRetranscribing: @escaping (String) -> Bool = { _ in false },
        initialTab: SettingsTab = .general
    ) {
        self.hotkeyEnabled = hotkeyEnabled
        self.missingPermissions = missingPermissions
        self.availableDevices = availableDevices
        self.selectedDeviceID = selectedDeviceID
        self.onSelectDevice = onSelectDevice
        self.polishDegradation = polishDegradation
        self.onDismissPolishDegradation = onDismissPolishDegradation
        self.anchorMode = anchorMode
        self.onSelectAnchorMode = onSelectAnchorMode
        self.performanceEffort = performanceEffort
        self.performanceEffortNotice = performanceEffortNotice
        self.onSelectPerformanceEffort = onSelectPerformanceEffort
        self.vocabularyPreview = vocabularyPreview
        self.onAddVocabularyAlias = onAddVocabularyAlias
        self.onRemoveVocabularyAlias = onRemoveVocabularyAlias
        self.onAddPromptTerm = onAddPromptTerm
        self.onRemovePromptTerm = onRemovePromptTerm
        self.isHotkeyRemapActive = isHotkeyRemapActive
        self.isMicrophonePermissionGranted = isMicrophonePermissionGranted
        self.isVoiceBarHidden = isVoiceBarHidden
        self.onHideVoiceBar = onHideVoiceBar
        self.onShowVoiceBar = onShowVoiceBar
        self.onRunRelaySetup = onRunRelaySetup
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
        self.onCopyHistoryTranscript = onCopyHistoryTranscript
        self.onPasteHistoryTranscript = onPasteHistoryTranscript
        self.onRetranscribeHistoryEntry = onRetranscribeHistoryEntry
        self.isHistoryRetranscribing = isHistoryRetranscribing
        let initialAnchorMode = anchorMode()
        let initialPerformanceEffort = performanceEffort()
        let initialVocabulary = vocabularyPreview()
        _selectedTab = State(initialValue: initialTab)
        _selectedAnchorMode = State(initialValue: initialAnchorMode)
        _selectedPerformanceEffort = State(initialValue: initialPerformanceEffort)
        _localVoiceBarHidden = State(initialValue: isVoiceBarHidden())
        let initialHistoryLimit = max(Self.historyPageSize, initialHistoryPage?.loadedEntryCount ?? 0)
        _historyDayGroups = State(initialValue: initialHistoryPage?.groups ?? [])
        _historyLoadedEntryCount = State(initialValue: initialHistoryPage?.loadedEntryCount ?? 0)
        _historyLoadedEntryLimit = State(initialValue: initialHistoryLimit)
        _historyHasMore = State(initialValue: initialHistoryPage?.hasMore ?? false)
        _localEntries = State(initialValue: initialVocabulary.entries)
        _selectedAnchoredMode = State(
            initialValue: VoiceBarAnchorMode.anchoredPositionModes.contains(initialAnchorMode)
                ? initialAnchorMode
                : .topCenter
        )
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(SettingsTab.general)
            audioTab
                .tabItem { Label("Audio", systemImage: "mic.fill") }
                .tag(SettingsTab.audio)
            historyTab
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(SettingsTab.history)
            dictionaryTab
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
                .tag(SettingsTab.dictionary)
        }
        .frame(width: 520, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: vocabularyPreview()) { _, preview in
            reconcileLocalEntries(with: preview.entries)
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .history {
                requestHistoryReload()
            }
        }
        .onDisappear {
            historyRefreshTask?.cancel()
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Permissions & Hotkey Setup") {
                LabeledContent("Shortcut") {
                    HStack(spacing: 6) {
                        Image(systemName: "keyboard")
                            .foregroundStyle(.secondary)
                        Text(VoiceBarHotkeyContract.shortcutChainLabel(remapDetected: isHotkeyRemapActive()))
                            .foregroundStyle(.secondary)
                    }
                }
                if isHotkeyRemapActive() {
                    Text(VoiceBarHotkeyContract.remapExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(hotkeyEnabled ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(hotkeyStatusText)
                    }
                }

                permissionRow(.microphone, isGranted: isMicrophonePermissionGranted())
                permissionRow(.accessibility, isGranted: !missingPermissions.contains(.accessibility))
                permissionRow(.inputMonitoring, isGranted: !missingPermissions.contains(.inputMonitoring))

                LabeledContent("Relay (hidutil LaunchAgent)") {
                    HStack(spacing: 8) {
                        statusBadge(isHotkeyRemapActive() ? "Ready" : "Needs setup", isReady: isHotkeyRemapActive())
                        Button("Set up") {
                            runRelaySetup()
                        }
                        .disabled(relaySetupRunning)
                    }
                }

                if let relaySetupFeedback {
                    Text(relaySetupFeedback)
                        .font(.caption)
                        .foregroundStyle(isHotkeyRemapActive() ? Color.secondary : Color.red)
                }
            }

            visibilitySection

            Section("Gestures") {
                LabeledContent("Single tap") {
                    Text(VoiceBarHotkeyContract.singleTapDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Hold") {
                    Text(VoiceBarHotkeyContract.holdDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Double-tap") {
                    Text(VoiceBarHotkeyContract.doubleTapDescription)
                        .foregroundStyle(.secondary)
                }
                LabeledContent(VoiceBarHotkeyContract.repasteShortcutLabel) {
                    Text(VoiceBarHotkeyContract.repasteDescription)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Position") {
                Toggle("Anchor", isOn: Binding(
                    get: { selectedAnchorMode != .follow },
                    set: { enabled in
                        if enabled {
                            selectAnchorMode(selectedAnchoredMode)
                        } else {
                            selectAnchorMode(.follow)
                        }
                    }
                ))

                if selectedAnchorMode != .follow {
                    Picker("Position", selection: Binding(
                        get: { selectedAnchoredMode },
                        set: { mode in
                            selectAnchorMode(mode)
                        }
                    )) {
                        ForEach(VoiceBarAnchorMode.anchoredPositionModes) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Text(positionModeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

    // MARK: - Audio Tab

    private var audioTab: some View {
        Form {
            Section("Input Device") {
                let devices = availableDevices()
                let selected = selectedDeviceID()

                if devices.isEmpty {
                    Text("No input devices found")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Microphone", selection: Binding(
                        get: { selected ?? "" },
                        set: { onSelectDevice($0) }
                    )) {
                        ForEach(devices, id: \.id) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
            }

            Section("Performance") {
                if let degradation = polishDegradation() {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        Text(degradation.hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Button {
                            onDismissPolishDegradation()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss STT polish warning")
                        .accessibilityLabel("Dismiss STT polish warning")
                    }
                    .accessibilityElement(children: .combine)
                }
                Picker("Effort", selection: Binding(
                    get: { selectedPerformanceEffort },
                    set: { effort in
                        selectedPerformanceEffort = effort
                        onSelectPerformanceEffort(effort)
                    }
                )) {
                    ForEach(VoiceBarPerformanceEffort.allCases) { effort in
                        Text(performanceEffortLabel(effort)).tag(effort)
                    }
                }
                .pickerStyle(.segmented)
                if let notice = performanceEffortNotice() {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - History Tab

    private var historyTab: some View {
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
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            Color.clear
                                .frame(height: 1)
                                .id(latestHistoryAnchorID)

                            ForEach(historyDayGroups) { group in
                                historyDaySection(group)
                            }

                            if historyHasMore {
                                Button {
                                    loadOlderHistory()
                                } label: {
                                    if isHistoryLoading {
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
                                .disabled(isHistoryLoading)
                                .frame(maxWidth: .infinity)
                                .help("Load older history")
                                .accessibilityLabel("Load older history")
                            }
                        }
                        .padding(18)
                    }
                }
            }
            .onAppear {
                if historyDayGroups.isEmpty {
                    requestHistoryReload(scrollProxy: proxy, animated: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceBarHistoryArchiveDidChange)) { _ in
                requestHistoryReload(scrollProxy: proxy, debounce: true, scrollToLatest: false)
            }
        }
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

    private func historyDaySection(_ group: SettingsHistoryDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(group.dayTitle())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
            }

            ForEach(group.entries) { entry in
                historyEntryRow(entry)
            }
        }
    }

    private func historyEntryRow(_ entry: SettingsHistoryEntry) -> some View {
        let isRetranscribing = isHistoryRetranscribing(entry.audioPath.path)

        return HStack(alignment: .top, spacing: 12) {
            Text(entry.timestamp())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 8) {
                Text(entry.displayTranscript)
                    .font(.body)
                    .foregroundStyle(entry.hasTranscript ? .primary : .secondary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                if isRetranscribing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Re-transcribing...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                historyEntryActions(entry, isRetranscribing: isRetranscribing)
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
        .opacity(isRetranscribing ? 0.62 : 1)
        .disabled(isRetranscribing)
    }

    private func historyEntryActions(_ entry: SettingsHistoryEntry, isRetranscribing: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                onCopyHistoryTranscript(entry.transcript)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(!entry.hasTranscript || isRetranscribing)
            .help("Copy transcript")
            .accessibilityLabel("Copy transcript")

            Button {
                onPasteHistoryTranscript(entry.transcript)
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .disabled(!entry.hasTranscript || isRetranscribing)
            .help("Paste transcript")
            .accessibilityLabel("Paste transcript")

            Button {
                onRetranscribeHistoryEntry(entry.audioPath.path)
            } label: {
                Label("Re-transcribe", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isRetranscribing)
            .help("Re-transcribe stored audio")
            .accessibilityLabel("Re-transcribe stored audio")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    // MARK: - Dictionary Tab

    private var dictionaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                addTermRow
                searchRow

                ForEach(localVocabularyPreview.filteredEntries(matching: dictionarySearch), id: \.canonical) { entry in
                    dictionaryEntryCard(entry)
                }
            }
            .padding(18)
        }
    }

    private var addTermRow: some View {
        HStack(spacing: 8) {
            HStack {
                TextField("Add a term, e.g. VoiceLayer", text: $newTermText)
                    .dictionaryTextField()
                    .focused($focusedEditorField, equals: .newTerm)
                    .onSubmit(commitNewTerm)
            }
            .dictionaryFieldContainer()
            .contentShape(Rectangle())
            .onTapGesture {
                focusedEditorField = .newTerm
            }
            Button(action: commitNewTerm) {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(newTermText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Add term")
            .accessibilityLabel("Add term")
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

    private func dictionaryEntryCard(_ entry: STTDictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            dictionaryEntryHeader(entry)
            Divider()
            variantChips(entry)
            if addingVariantFor == entry.canonical {
                addVariantInlineEditor(entry)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func dictionaryEntryHeader(_ entry: STTDictionaryEntry) -> some View {
        if editingCanonical == entry.canonical {
            HStack(spacing: 8) {
                TextField("Term", text: $editTermText)
                    .dictionaryTextField()
                    .focused($focusedEditorField, equals: .editTerm)
                    .onSubmit { saveTermRename(entry.canonical) }
                    .frame(maxWidth: .infinity)
                Button("Cancel") {
                    cancelTermRename()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(height: DictionaryCardLayout.headerHeight)
                Button("Save") {
                    saveTermRename(entry.canonical)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(height: DictionaryCardLayout.headerHeight)
                .disabled(editTermText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(minHeight: DictionaryCardLayout.headerHeight)
        } else {
            HStack(spacing: 8) {
                Text(entry.canonical)
                    .font(.headline)
                Spacer()
                if pendingDeleteCanonical == entry.canonical {
                    deleteDictionaryEntryButton(entry.canonical)
                } else {
                    Button {
                        beginTermRename(entry.canonical)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit term")
                    .accessibilityLabel("Edit term \(entry.canonical)")
                    deleteDictionaryEntryButton(entry.canonical)
                }
            }
            .frame(minHeight: DictionaryCardLayout.headerHeight)
        }
    }

    private func variantChips(_ entry: STTDictionaryEntry) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(entry.variants, id: \.self) { variant in
                HStack(spacing: 6) {
                    Text(variant)
                    Button {
                        SettingsDictionaryMutations.removeVariant(
                            canonical: entry.canonical,
                            variant: variant,
                            localEntries: &localEntries,
                            onRemoveVocabularyAlias: onRemoveVocabularyAlias
                        )
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove variant \(variant)")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.24))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            addVariantButton(entry.canonical)
        }
    }

    private func addVariantButton(_ canonical: String) -> some View {
        Button {
            addingVariantFor = canonical
            variantText = ""
            focusedEditorField = .addVariant
        } label: {
            Text("+ add misheard variant")
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Add misheard variant for \(canonical)")
    }

    private func addVariantInlineEditor(_ entry: STTDictionaryEntry) -> some View {
        HStack(spacing: 8) {
            TextField("Type the misheard spelling...", text: $variantText)
                .dictionaryTextField()
                .focused($focusedEditorField, equals: .addVariant)
                .onSubmit { saveVariant(entry.canonical) }
                .padding(.vertical, DictionaryCardLayout.inlineFieldVerticalPadding)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(addVariantInputFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 1.5)
                )
                .frame(maxWidth: .infinity)
                .frame(height: DictionaryCardLayout.inlineControlHeight)
            Button("Cancel") {
                addingVariantFor = nil
                variantText = ""
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(height: DictionaryCardLayout.inlineControlHeight)
            Button("Add") {
                saveVariant(entry.canonical)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .frame(height: DictionaryCardLayout.inlineControlHeight)
            .disabled(variantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete term")
            .accessibilityLabel("Delete term \(canonical)")
        }
    }

    private func commitNewTerm() {
        SettingsDictionaryMutations.commitNewTerm(
            newTermText: &newTermText,
            localEntries: &localEntries,
            onAddPromptTerm: onAddPromptTerm
        )
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
        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        let loader = historyPage
        isHistoryLoading = true
        historyRefreshTask?.cancel()
        historyRefreshTask = Task {
            if debounce {
                try? await Task.sleep(for: .milliseconds(300))
            }
            guard !Task.isCancelled else { return }
            let page = await Task.detached(priority: .utility) {
                loader(limit)
            }.value
            await MainActor.run {
                guard generation == historyLoadGeneration, !Task.isCancelled else { return }
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
        historyLoadedEntryCount = page.loadedEntryCount
        historyHasMore = page.hasMore
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
                Button("Open") {
                    openPermissionSettings(permission)
                }
            }
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

    private var localVocabularyPreview: STTVocabularyPreview {
        STTVocabularyPreview(updatedAt: nil, entries: localEntries)
    }

    private var hasPendingDictionaryEdit: Bool {
        editingCanonical != nil ||
            addingVariantFor != nil ||
            pendingDeleteCanonical != nil ||
            !newTermText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func reconcileLocalEntries(with entries: [STTDictionaryEntry]) {
        guard !hasPendingDictionaryEdit else { return }
        localEntries = entries
    }

    private func beginTermRename(_ canonical: String) {
        editingCanonical = canonical
        editTermText = canonical
        pendingDeleteCanonical = nil
        focusedEditorField = .editTerm
    }

    private func cancelTermRename() {
        editingCanonical = nil
        editTermText = ""
        focusedEditorField = nil
    }

    private func saveTermRename(_ canonical: String) {
        SettingsDictionaryMutations.renameTerm(
            canonical,
            editText: &editTermText,
            localEntries: &localEntries,
            onAddPromptTerm: onAddPromptTerm,
            onRemovePromptTerm: onRemovePromptTerm,
            onAddVocabularyAlias: onAddVocabularyAlias
        )
        editingCanonical = nil
        focusedEditorField = nil
    }

    private func saveVariant(_ canonical: String) {
        SettingsDictionaryMutations.addVariant(
            canonical: canonical,
            variantText: &variantText,
            addingVariantFor: &addingVariantFor,
            localEntries: &localEntries,
            onAddVocabularyAlias: onAddVocabularyAlias
        )
        focusedEditorField = nil
    }

    private func selectAnchorMode(_ mode: VoiceBarAnchorMode) {
        selectedAnchorMode = mode
        if mode != .follow {
            selectedAnchoredMode = mode
        }
        onSelectAnchorMode(mode)
    }

    private var addVariantInputFill: Color {
        Color(red: 31 / 255, green: 39 / 255, blue: 51 / 255)
    }
}

enum SettingsDictionaryMutations {
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
        upsertEntry(canonical, in: &localEntries)
        guard let index = localEntries.firstIndex(where: { $0.canonical == canonical }) else { return }
        guard aliasKey(trimmed) != aliasKey(localEntries[index].canonical) else {
            variantText = ""
            addingVariantFor = nil
            return
        }
        if !localEntries[index].variants.contains(where: { aliasKey($0) == aliasKey(trimmed) }) {
            localEntries[index].variants.append(trimmed)
            onAddVocabularyAlias(canonical, trimmed)
        }
        variantText = ""
        addingVariantFor = nil
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
        guard !entries.contains(where: { $0.canonical.localizedCaseInsensitiveCompare(canonical) == .orderedSame })
        else {
            return
        }
        entries.append(STTDictionaryEntry(canonical: canonical, variants: []))
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
